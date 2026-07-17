import Foundation
import HappyOysterSDK

// MARK: - TokenInfo

/// validToken / invalidateAndRefresh 的返回值：token 字符串 + 过期时间戳。
struct TokenInfo {
    let token: String
    let expiresAt: Date
}

/// 维护百炼临时 API Key 的有效性：
/// - token 到期前（expiry - leeway）自动静默刷新（autoRefreshEnabled == true 时）
/// - 鉴权失败后主动失效并立即刷新
///
/// 设计为 actor，所有状态变更都在 actor 隔离域内进行，调用方无需加锁。
actor TokenManager {

    // MARK: - Config（可运行时更新）

    /// 提前多少秒触发刷新（token 剩余时间 <= leeway 时视为"即将过期"）。
    private var leeway: TimeInterval

    /// 是否开启自动刷新。关闭时不再调度定时刷新任务。
    private var autoRefreshEnabled: Bool

    // MARK: - Dependencies

    /// 实际发起网络请求的闭包，解耦 APIClient 依赖。
    private let fetchToken: () async throws -> TempApiKeyResponse

    // MARK: - State

    private var stored: TempApiKeyResponse?
    private var scheduledRefreshTask: Task<Void, Never>?

    // MARK: - Init

    init(
        leeway: TimeInterval = 30,
        autoRefreshEnabled: Bool = true,
        fetchToken: @escaping () async throws -> TempApiKeyResponse
    ) {
        self.leeway = leeway
        self.autoRefreshEnabled = autoRefreshEnabled
        self.fetchToken = fetchToken
    }

    // MARK: - Public interface

    /// 当前缓存的 token 信息（不触发网络请求）。nil 表示尚未获取或已被清除。
    var currentInfo: TokenInfo? {
        guard let t = stored else { return nil }
        return TokenInfo(
            token: t.token,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(t.expiresAt))
        )
    }

    /// 返回当前有效的 token 信息。
    /// 缓存有效时直接返回；缓存不存在或即将过期时按"自动刷新"开关决定是否重取。
    /// - autoRefreshEnabled == true：缓存失效时自动重取。
    /// - autoRefreshEnabled == false：不主动刷新，直接返回已有缓存（即使已过期）；
    ///   仅在从未获取过 token 时才发起首次获取。
    func validToken() async throws -> TokenInfo {
        if let t = stored, isValid(t) {
            return TokenInfo(
                token: t.token,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(t.expiresAt))
            )
        }
        if !autoRefreshEnabled, let t = stored {
            return TokenInfo(
                token: t.token,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(t.expiresAt))
            )
        }
        return try await performRefresh()
    }

    /// 鉴权失败时调用：立即清除缓存并重新获取 token。
    @discardableResult
    func invalidateAndRefresh() async throws -> TokenInfo {
        stored = nil
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        return try await performRefresh()
    }

    /// 仅清除缓存（不立即刷新，下次 `validToken()` 时懒刷）。
    /// 适用于退出登录等主动清理场景。
    func invalidate() {
        stored = nil
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
    }

    /// 更新提前刷新间隔，并用新值重新调度下次刷新。
    func updateLeeway(_ newLeeway: TimeInterval) {
        leeway = newLeeway
        if let stored { scheduleRefresh(for: stored) }
    }

    /// 更新自动刷新开关。
    /// 关闭时取消已有调度；开启时立即补调度（如有缓存 token）。
    func setAutoRefresh(_ enabled: Bool) {
        autoRefreshEnabled = enabled
        if !enabled {
            scheduledRefreshTask?.cancel()
            scheduledRefreshTask = nil
        } else if let stored {
            scheduleRefresh(for: stored)
        }
    }

    // MARK: - Private

    private func isValid(_ t: TempApiKeyResponse) -> Bool {
        let expiry = Date(timeIntervalSince1970: TimeInterval(t.expiresAt))
        return expiry.timeIntervalSinceNow > leeway
    }

    private func performRefresh() async throws -> TokenInfo {
        scheduledRefreshTask?.cancel()
        let result = try await fetchToken()
        stored = result
        scheduleRefresh(for: result)
        // SDK HTTP 鉴权 token 同步注入，后续所有 SDK API 请求均自动携带
        let token = result.token
        Task { @MainActor in HappyOysterEngine.shared.updateToken(token) }
        return TokenInfo(
            token: result.token,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(result.expiresAt))
        )
    }

    private func scheduleRefresh(for token: TempApiKeyResponse) {
        guard autoRefreshEnabled else { return }
        scheduledRefreshTask?.cancel()
        let expiry = Date(timeIntervalSince1970: TimeInterval(token.expiresAt))
        // 到期前 leeway 秒触发；如果 delay 为负（token 已几乎过期）则立即重取
        let delay = max(expiry.timeIntervalSinceNow - leeway, 1)
        scheduledRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return  // Task 被取消（logout / invalidate），正常退出
            }
            guard !Task.isCancelled else { return }
            _ = try? await self?.performRefresh()
        }
    }
}
