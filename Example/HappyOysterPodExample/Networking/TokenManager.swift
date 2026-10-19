import Foundation
import HappyOysterSDK

// MARK: - TokenInfo

/// Return value of validToken / invalidateAndRefresh: token string + expiry timestamp.
struct TokenInfo {
    let token: String
    let expiresAt: Date
}

/// Keeps the temporary Bailian API key valid:
/// - Silently refreshes automatically before the token expires (expiry - leeway) (when autoRefreshEnabled == true)
/// - Proactively invalidates and refreshes immediately after an auth failure
///
/// Designed as an actor: all state changes happen inside the actor's isolation domain, so callers need no locking.
actor TokenManager {

    // MARK: - Config (updatable at runtime)

    /// How many seconds in advance to refresh (the token is considered "about to expire" when remaining time <= leeway).
    private var leeway: TimeInterval

    /// Whether auto refresh is enabled. When disabled, no scheduled refresh task is created.
    private var autoRefreshEnabled: Bool

    // MARK: - Dependencies

    /// Closure that performs the actual network request, decoupling the APIClient dependency.
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

    /// Currently cached token info (does not trigger a network request). nil means not fetched yet or already cleared.
    var currentInfo: TokenInfo? {
        guard let t = stored else { return nil }
        return TokenInfo(
            token: t.token,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(t.expiresAt))
        )
    }

    /// Returns the currently valid token info.
    /// Returns the cache directly when valid; when the cache is missing or about to expire, the "auto refresh" switch decides whether to refetch.
    /// - autoRefreshEnabled == true: refetches automatically when the cache is invalid.
    /// - autoRefreshEnabled == false: does not refresh proactively and returns the existing cache as-is (even if expired);
    ///   only performs the initial fetch when no token has ever been fetched.
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

    /// Called on auth failure: clears the cache immediately and fetches a new token.
    @discardableResult
    func invalidateAndRefresh() async throws -> TokenInfo {
        stored = nil
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        return try await performRefresh()
    }

    /// Only clears the cache (no immediate refresh; lazily refreshed on the next `validToken()`).
    /// Intended for proactive cleanup such as logging out.
    func invalidate() {
        stored = nil
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
    }

    /// Updates the early-refresh leeway and reschedules the next refresh with the new value.
    func updateLeeway(_ newLeeway: TimeInterval) {
        leeway = newLeeway
        if let stored { scheduleRefresh(for: stored) }
    }

    /// Updates the auto refresh switch.
    /// Disabling cancels any existing schedule; enabling schedules immediately (if a cached token exists).
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
        // Also inject the token into SDK HTTP auth, so all subsequent SDK API requests carry it automatically
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
        // Fires leeway seconds before expiry; if delay is negative (token nearly expired), refetch immediately
        let delay = max(expiry.timeIntervalSinceNow - leeway, 1)
        scheduledRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return  // Task was cancelled (logout / invalidate); exit normally
            }
            guard !Task.isCancelled else { return }
            _ = try? await self?.performRefresh()
        }
    }
}
