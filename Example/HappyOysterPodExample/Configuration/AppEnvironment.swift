import Foundation
import Combine

private enum Keys {
    static let host = "app.localServer.host"
    static let port = "app.localServer.port"
    static let scheme = "app.localServer.scheme"
    static let tokenExpireSeconds  = "app.token.expireSeconds"
    static let tokenAutoRefresh    = "app.token.autoRefresh"
    static let tokenRefreshLeeway  = "app.token.refreshLeeway"
    static let apiHost             = "app.sdk.apiHost"
    static let model               = "app.sdk.model"
    static let maxExperienceTimeSec = "app.play.maxExperienceTimeSec"
}

/// App-side base environment configuration: holds the local server connection parameters (HOST / PORT / scheme) and the public service address.
/// Fully independent of the SDK's OysterConfig — the SDK handles the Bailian gateway,
/// while this handles the example's own local LAN server and public service.
/// Persisted in UserDefaults; @Published drives the UI to react to changes in real time.
final class AppEnvironment: ObservableObject {

    // MARK: - Published state

    /// Local server listen address, default 127.0.0.1 (the server's HOST variable).
    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Keys.host) }
    }

    /// Local server listen port; default 3000, nil uses the scheme's default port.
    @Published var port: Int? {
        didSet { UserDefaults.standard.set(port ?? 0, forKey: Keys.port) }
    }

    /// Connection scheme (http / https), default http.
    /// When switching to self-signed HTTPS on a LAN IP, LocalServerTrustDelegate handles certificate validation.
    @Published var scheme: String {
        didSet { UserDefaults.standard.set(scheme, forKey: Keys.scheme) }
    }

    /// Requested lifetime of the temporary token (seconds), valid range 1...1800, default 1800.
    @Published var tokenExpireSeconds: Int {
        didSet { UserDefaults.standard.set(tokenExpireSeconds, forKey: Keys.tokenExpireSeconds) }
    }

    /// Whether token auto refresh is enabled, on by default.
    @Published var tokenAutoRefresh: Bool {
        didSet { UserDefaults.standard.set(tokenAutoRefresh, forKey: Keys.tokenAutoRefresh) }
    }

    /// How many seconds before expiry to trigger auto refresh (seconds), default 30.
    @Published var tokenRefreshLeeway: Int {
        didSet { UserDefaults.standard.set(tokenRefreshLeeway, forKey: Keys.tokenRefreshLeeway) }
    }

    /// Bailian gateway address used by the SDK; must be configured manually on the Settings page, then takes effect after resetting the engine.
    /// No built-in default anymore — when unconfigured it is an empty string, the gateway path built inside the SDK fails to parse,
    /// and SDK requests fail with an explicit error, forcing the user to fill it in on the Settings page first.
    ///
    /// The app side only trims whitespace and passes it to the SDK as-is: a bare domain without the `http(s)://` prefix is fine, since the SDK
    /// (`OysterConfig.gatewayPath`) adds `https://` automatically — the app no longer needs to decide "whether to prepend the prefix".
    @Published var apiHost: String {
        didSet { UserDefaults.standard.set(apiHost, forKey: Keys.apiHost) }
    }

    /// Bailian model name (including version) used by the SDK; must be configured manually on the Settings page, then takes effect after resetting the engine.
    /// happyoyster is split into different sub-models by mode and the SDK cannot infer which to use, so it must be specified explicitly —
    /// like apiHost, **there is no built-in default**: when unconfigured it is an empty string, the SDK cannot build the gateway path,
    /// and related requests fail with an explicit error, forcing the user to pick one on the Settings page first (see ModelPreset.all).
    ///
    /// Must pair with apiHost: if the host and model belong to different environments, the gateway rejects with AccessDenied (106003).
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Keys.model) }
    }

    /// Maximum play time for adventure mode (seconds), default 60.
    @Published var maxExperienceTimeSec: Int {
        didSet { UserDefaults.standard.set(maxExperienceTimeSec, forKey: Keys.maxExperienceTimeSec) }
    }

    /// Placeholder public service base URL, to be replaced with the real address after release.
    let publicServiceBaseURL: URL = URL(string: "https://api.example.com")!

    // MARK: - Derived

    /// Server address derived from scheme / host / port.
    var localServerAddress: String {
        let portSuffix = port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portSuffix)"
    }

    /// Server address, used by APIClient to resolve request targets.
    var localServerBaseURL: URL {
        URL(string: localServerAddress)!
    }

    /// Host part only, used by LocalServerTrustDelegate to decide certificate trust.
    var localHost: String { host }

    /// Shared app-side APIClient (unrelated to the SDK's internal client).
    /// Since APIClient reads localServerBaseURL dynamically, the singleton stays valid for the whole AppEnvironment lifetime.
    private(set) lazy var apiClient: APIClient = APIClient(environment: self)

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        host   = defaults.string(forKey: Keys.host)   ?? "127.0.0.1"
        let storedPort = defaults.object(forKey: Keys.port) == nil ? 3000 : defaults.integer(forKey: Keys.port)
        port   = storedPort == 0 ? nil : storedPort
        scheme = defaults.string(forKey: Keys.scheme) ?? "http"
        tokenExpireSeconds = defaults.integer(forKey: Keys.tokenExpireSeconds).nonZeroOr(1800)
        tokenAutoRefresh   = defaults.object(forKey: Keys.tokenAutoRefresh) as? Bool ?? true
        tokenRefreshLeeway = defaults.integer(forKey: Keys.tokenRefreshLeeway).nonZeroOr(30)
        apiHost            = defaults.string(forKey: Keys.apiHost) ?? ""
        model              = defaults.string(forKey: Keys.model) ?? ""
        maxExperienceTimeSec = defaults.integer(forKey: Keys.maxExperienceTimeSec).nonZeroOr(60)
    }
}

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int { self == 0 ? fallback : self }
}
