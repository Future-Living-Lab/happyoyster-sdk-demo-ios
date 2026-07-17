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
    static let maxExperienceTimeSec = "app.play.maxExperienceTimeSec"
}

/// App 侧基础环境配置：持有本地服务器连接参数（HOST / PORT / scheme）以及公网服务地址。
/// 与 SDK 的 OysterConfig 完全独立——SDK 管百炼网关，
/// 这里管本示例自有的本地局域网服务器与公网服务。
/// UserDefaults 持久化；@Published 驱动 UI 实时响应变更。
final class AppEnvironment: ObservableObject {

    // MARK: - Published state

    /// 本地服务器监听地址，默认 127.0.0.1（服务端 HOST 变量）。
    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: Keys.host) }
    }

    /// 本地服务器监听端口；默认 3000，nil 时使用协议默认端口。
    @Published var port: Int? {
        didSet { UserDefaults.standard.set(port ?? 0, forKey: Keys.port) }
    }

    /// 连接协议（http / https），默认 http。
    /// 切到局域网 IP 自签名 HTTPS 时由 LocalServerTrustDelegate 兜底证书校验。
    @Published var scheme: String {
        didSet { UserDefaults.standard.set(scheme, forKey: Keys.scheme) }
    }

    /// 临时 Token 请求有效期（秒），合法范围 1...1800，默认 1800。
    @Published var tokenExpireSeconds: Int {
        didSet { UserDefaults.standard.set(tokenExpireSeconds, forKey: Keys.tokenExpireSeconds) }
    }

    /// 是否开启 Token 自动刷新，默认开启。
    @Published var tokenAutoRefresh: Bool {
        didSet { UserDefaults.standard.set(tokenAutoRefresh, forKey: Keys.tokenAutoRefresh) }
    }

    /// 到期前提前多少秒触发自动刷新（秒），默认 30。
    @Published var tokenRefreshLeeway: Int {
        didSet { UserDefaults.standard.set(tokenRefreshLeeway, forKey: Keys.tokenRefreshLeeway) }
    }

    /// SDK 接入的百炼网关地址，需在设置页手动配置后重置引擎生效。
    /// 不再提供内置默认值——未配置时为空字符串，SDK 内部拼出的网关路径会解析失败，
    /// SDK 相关请求以明确错误提示失败，倒逼用户先去设置页填写。
    ///
    /// app 侧只做去空白，原样透传给 SDK：裸域名不带 `http(s)://` 前缀也可以，SDK 内部
    /// （`OysterConfig.gatewayPath`）会自动补 `https://`——app 不用再自己判断"要不要拼前缀"。
    @Published var apiHost: String {
        didSet { UserDefaults.standard.set(apiHost, forKey: Keys.apiHost) }
    }

    /// 冒险模式的最大游玩时间（秒），默认 60。
    @Published var maxExperienceTimeSec: Int {
        didSet { UserDefaults.standard.set(maxExperienceTimeSec, forKey: Keys.maxExperienceTimeSec) }
    }

    /// 公网服务 base URL 占位，发布后替换为真实地址。
    let publicServiceBaseURL: URL = URL(string: "https://api.example.com")!

    // MARK: - Derived

    /// 由 scheme / host / port 组合派生的服务器地址。
    var localServerAddress: String {
        let portSuffix = port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portSuffix)"
    }

    /// 服务器地址，供 APIClient 解析请求目标。
    var localServerBaseURL: URL {
        URL(string: localServerAddress)!
    }

    /// 仅 host 部分，供 LocalServerTrustDelegate 做证书放行判断。
    var localHost: String { host }

    /// 共享的 app 侧 APIClient（与 SDK 内部客户端无关）。
    /// 因 APIClient 动态读取 localServerBaseURL，单例在整个 AppEnvironment 生命周期内有效。
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
        maxExperienceTimeSec = defaults.integer(forKey: Keys.maxExperienceTimeSec).nonZeroOr(60)
    }
}

private extension Int {
    func nonZeroOr(_ fallback: Int) -> Int { self == 0 ? fallback : self }
}
