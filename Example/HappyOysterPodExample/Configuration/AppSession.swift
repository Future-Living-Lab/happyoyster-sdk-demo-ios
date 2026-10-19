import Foundation
import Combine
import HappyOysterSDK

/// App-side login state management, fully independent of SDK auth (OysterTokenProvider / OysterAuthSession).
/// The SDK handles the Bailian gateway's temporary token; AppSession handles the user session of this example's own service.
///
/// The lifecycle of the temporary API key (Bailian token) is maintained by the internal TokenManager.
@MainActor
final class AppSession: ObservableObject {

    /// Temporary API key manager (auto refresh on expiry / refresh on auth failure).
    /// Initialized via `configure(environment:)`; call it once from the app entry point.
    private(set) var tokenManager: TokenManager?

    /// The model name currently in effect in the SDK; nil when not initialized / after cleanup.
    ///
    /// Reads the SDK's `Oyster.config` directly (public, not SPI; cleared by `cleanup()`), so the app doesn't keep its own copy.
    /// Must be checked together with `isReady`: `initialize` first stores the config via `Oyster.start(config)` and then validates
    /// whether `gatewayPath` is legal, so a non-nil config **does not mean initialization succeeded** — when model is empty or
    /// apiHost is invalid the config is still there, but the engine stays uninitialized.
    var activeModel: String? {
        guard HappyOysterEngine.shared.isReady else { return nil }
        return Oyster.config?.model
    }

    private weak var environment: AppEnvironment?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Setup

    /// Wires AppEnvironment's APIClient into TokenManager and initializes the SDK.
    /// Idempotent: repeated calls after configuration have no effect.
    func configure(environment: AppEnvironment) {
        guard tokenManager == nil else { return }
        self.environment = environment
        let client = environment.apiClient
        let tm = TokenManager(
            leeway: TimeInterval(environment.tokenRefreshLeeway),
            autoRefreshEnabled: environment.tokenAutoRefresh
        ) {
            // Read the latest lifetime setting on every refresh
            let expire = await MainActor.run { environment.tokenExpireSeconds }
            return try await client.fetchTempApiKey(expireInSeconds: expire)
        }
        tokenManager = tm
        client.tokenManager = tm

        // Subscribe to env changes and sync them to TokenManager in real time
        environment.$tokenRefreshLeeway
            .dropFirst()
            .sink { leeway in Task { await tm.updateLeeway(TimeInterval(leeway)) } }
            .store(in: &cancellables)

        environment.$tokenAutoRefresh
            .dropFirst()
            .sink { enabled in Task { await tm.setAutoRefresh(enabled) } }
            .store(in: &cancellables)

        // SDK initialization: pass apiHost (gateway domain) + model (model name with version). The `/api/v2/apps/`
        // between them and the `/openapi/v1` after are joined inside the SDK; the app is unaware of them
        // and doesn't maintain this implementation detail that evolves with SDK versions. Unrelated to the app's local server.
        // model is required because happyoyster is split into different sub-models by mode and the SDK cannot infer which to use.
        // initialize is idempotent (the first call wins), and this is the only call site; it registers the stream engine internally.
        // If either is unconfigured (empty string), the SDK's gateway path fails to parse and requests fail with an explicit
        // error — there is no longer a built-in default gateway/model masking a "forgot to configure" problem.
        HappyOysterEngine.shared.initialize(config: OysterConfig(
            apiHost: environment.apiHost,
            model: environment.model,
            logLevel: .info
        ))
        
        OysterLog.setMinimumLevel(.info)
        
    }

    // MARK: - Token access

    /// Gets the currently valid temporary Bailian API key info (including expiry time).
    /// Internally handles cache hits, refresh when about to expire, and refetch on auth failure.
    func validToken() async throws -> TokenInfo {
        guard let tm = tokenManager else {
            throw APIError.missingBaseURL  // configure was not called
        }
        return try await tm.validToken()
    }

    // MARK: - SDK engine reset

    /// Resets the SDK engine: first cleanup() to release runtime state, then initialize() again, and finally trigger a token refresh.
    ///
    /// **Use cases**: fully clearing engine state when troubleshooting (RTC connection, tokenStore, registered stream engines),
    /// or rebuilding the SDK context when switching account/identity.
    ///
    /// Note that cleanup is kept here **on purpose** — merely switching apiHost / model no longer needs it (when idle, just call
    /// `initialize` again; see `ensureModel(for:)`); what this method wants is exactly the "tear everything down and start over" effect.
    ///
    /// cleanup clears the internal tokenStore, so the token must be re-injected afterwards. This uses
    /// `invalidateAndRefresh` (not the lightweight re-injection in `reinitialize`) — this method's semantics are
    /// "tear everything down and start over", so getting a fresh token along the way fits the troubleshooting expectation.
    func cleanupAndReinitialize() async {
        await HappyOysterEngine.shared.cleanup()
        applyConfig(model: environment?.model ?? "")
        _ = try? await tokenManager?.invalidateAndRefresh()
    }

    // MARK: - Align model to world mode

    /// Before entering a world, switches the SDK to the model serving that world's mode; does nothing if it is already the target model.
    ///
    /// happyoyster is split into different sub-models by mode, each an independent gateway app route,
    /// and one `initialize` only serves worlds of one mode. The Android demo fetches its world list under a model,
    /// so it naturally only lists worlds of the current model; this demo's world list comes from the app's own backend with all three modes mixed,
    /// so it must align before entering, otherwise the request goes all the way to the gateway only to be rejected with `AccessDenied` (106003).
    ///
    /// Switching models just takes another `initialize`: when idle (no Travel in progress) the SDK allows reassembly with a new config,
    /// with no need to `cleanup()` first; the injected token is kept too, so no `updateToken` is needed.
    /// See `ModelPreset.resolve(configured:for:)` for the mapping rules — an unknown/legacy model configured on the Settings page is used as-is,
    /// with no guessing.
    func ensureModel(for mode: ServerWorldMode) async {
        let configured = environment?.model ?? ""
        let desired = ModelPreset.resolve(configured: configured, for: mode)
        // When activeModel is nil (not initialized / last initialization failed), rebuild as well; don't skip just because
        // "the configured model happens to equal the target" — the engine isn't actually running at this point.
        guard desired != activeModel else { return }
        appLog("[SDK] model switch for mode=\(mode.badgeLabel): "
               + "\(activeModel ?? "<none>") -> \(desired)")
        await reinitialize(model: desired)
    }

    /// (Re-)initializes with the given model and ensures the SDK holds a token internally.
    ///
    /// Switching models itself doesn't require re-injecting the token — re-initializing while idle doesn't touch the SDK's tokenStore.
    /// But there is one edge case to cover: this demo only calls the SDK's `updateToken` in `TokenManager.performRefresh()`,
    /// and does **not** inject again on a `validToken()` cache hit. So if the app already obtained a token,
    /// and that injection happened while the SDK had not yet initialized successfully (`updateToken` is then a no-op + warning,
    /// and the token is dropped), the freshly started engine ends up "with config, without token", and subsequent requests fail with 101001.
    /// So re-inject on demand here: do nothing if the SDK already has a token; only otherwise fetch from TokenManager
    /// (no network request while the cache is valid).
    private func reinitialize(model: String) async {
        applyConfig(model: model)
        guard HappyOysterEngine.shared.isReady, Oyster.tokenStore?.current == nil else { return }
        guard let info = try? await tokenManager?.validToken() else { return }
        HappyOysterEngine.shared.updateToken(info.token)
        appLog("[SDK] token re-injected after re-initialize")
    }

    /// Simply calls `initialize` once with the current apiHost + the given model, without touching the token.
    @discardableResult
    private func applyConfig(model: String) -> Bool {
        // The return value is the real answer to "did this config take effect": when a config change is rejected the old one keeps running, and isReady is still true.
        let applied = HappyOysterEngine.shared.initialize(config: OysterConfig(
            apiHost: environment?.apiHost ?? "",
            model: model,
            logLevel: .debug
        ))
        // activeModel is a computed property reading the SDK directly, with no @Published to rely on,
        // so after switching models we must notify manually once for the Settings page's "Running: xxx" row to refresh.
        objectWillChange.send()
        appLog(applied
               ? "[SDK] initialized (model=\(model))"
               : "[SDK] ⚠️ initialize rejected (model=\(model.isEmpty ? "<empty>" : model))"
                 + "; currently active: \(activeModel ?? "<none>")")
        return applied
    }
}
