import Foundation
import Combine
import HappyOysterSDK

/// App 侧登录态管理，完全独立于 SDK 鉴权（OysterTokenProvider / OysterAuthSession）。
/// SDK 管百炼网关的临时 Token；AppSession 管本示例自有服务的用户会话。
///
/// 临时 API Key（百炼 token）由内部 TokenManager 维护生命周期。
@MainActor
final class AppSession: ObservableObject {

    /// 临时 API Key 管理器（到期自动刷新 / 鉴权失败刷新）。
    /// 通过 `configure(environment:)` 初始化，app 入口调用一次即可。
    private(set) var tokenManager: TokenManager?

    private weak var environment: AppEnvironment?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Setup

    /// 将 AppEnvironment 的 APIClient 接入 TokenManager，并初始化 SDK。
    /// 幂等：已配置后重复调用无效。
    func configure(environment: AppEnvironment) {
        guard tokenManager == nil else { return }
        self.environment = environment
        let client = environment.apiClient
        let tm = TokenManager(
            leeway: TimeInterval(environment.tokenRefreshLeeway),
            autoRefreshEnabled: environment.tokenAutoRefresh
        ) {
            // 每次刷新时读取最新有效期设置
            let expire = await MainActor.run { environment.tokenExpireSeconds }
            return try await client.fetchTempApiKey(expireInSeconds: expire)
        }
        tokenManager = tm
        client.tokenManager = tm

        // 订阅 env 变更，实时同步到 TokenManager
        environment.$tokenRefreshLeeway
            .dropFirst()
            .sink { leeway in Task { await tm.updateLeeway(TimeInterval(leeway)) } }
            .store(in: &cancellables)

        environment.$tokenAutoRefresh
            .dropFirst()
            .sink { enabled in Task { await tm.setAutoRefresh(enabled) } }
            .store(in: &cancellables)

        // SDK 初始化：只传 apiHost（网关域名），应用路径版本号由 SDK 内部拼接，
        // app 侧不感知、也不维护这段随 SDK 版本演进的实现细节。与 app 侧本地服务器无关。
        // initialize 幂等（以首次为准），此处是唯一调用点；内部会自动注册流引擎。
        // apiHost 未配置（空字符串）时 SDK 内部网关路径解析失败，请求会以明确错误提示
        // 失败，不再有内置默认网关掩盖「忘了配置」的问题。
        HappyOysterEngine.shared.initialize(config: OysterConfig(
            apiHost: environment.apiHost,
            logLevel: .info
        ))
        
        OysterLog.setMinimumLevel(.info)
        
    }

    // MARK: - Token access

    /// 获取当前有效的百炼临时 API Key 信息（含过期时间）。
    /// 内部自动处理缓存命中、即将过期刷新、鉴权失败重取。
    func validToken() async throws -> TokenInfo {
        guard let tm = tokenManager else {
            throw APIError.missingBaseURL  // configure 未调用
        }
        return try await tm.validToken()
    }

    // MARK: - SDK 引擎重置

    /// 重置 SDK 引擎：先 cleanup() 释放运行时状态，再立即重新 initialize()，最后触发一次 Token 刷新。
    ///
    /// **适用场景**
    /// - 切换 SDK 接入的百炼网关 URL（`initialize` 幂等，不 cleanup 则新 config 不生效）
    /// - 排查问题时手动清除引擎状态（RTC 连接、tokenStore、注册的流引擎）
    /// - 集成方用户切换账号/身份，需要彻底重建 SDK 上下文
    ///
    /// **注意**：cleanup 会清除内部 tokenStore，重新 initialize 后必须重新注入 token，
    /// 此方法内部已自动触发一次 `invalidateAndRefresh`。
    func cleanupAndReinitialize() async {
        await HappyOysterEngine.shared.cleanup()
        HappyOysterEngine.shared.initialize(config: OysterConfig(
            apiHost: environment?.apiHost ?? "",
            logLevel: .info
        ))
        appLog("[SDK] initialized")
        _ = try? await tokenManager?.invalidateAndRefresh()
    }
}
