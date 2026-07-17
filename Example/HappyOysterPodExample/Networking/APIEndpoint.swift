import Foundation

/// 请求目标：决定使用哪个 base URL 构造请求。
enum APITarget {
    /// 本地局域网服务器（地址从 AppEnvironment.localServerBaseURL 获取）。
    case local
    /// 公网服务（地址从 AppEnvironment.publicServiceBaseURL 获取）。
    case publicService
}

/// 单个 API 请求的完整描述，与具体的 URLSession / 业务逻辑解耦。
struct APIEndpoint {
    let target: APITarget
    let path: String
    let method: HTTPMethod
    /// URL query 参数（key-value 均为 String）。
    var queryItems: [URLQueryItem]
    /// 请求体（任意 Encodable；nil 表示无 body）。
    var body: (any Encodable)?
    /// 额外 HTTP headers（会与默认 headers 合并，优先级更高）。
    var headers: [String: String]
    /// true 时跳过自动 Bearer token 注入（fetchTempApiKey 等获取 token 的接口使用）。
    var skipAuth: Bool

    init(
        target: APITarget,
        path: String,
        method: HTTPMethod,
        queryItems: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        headers: [String: String] = [:],
        skipAuth: Bool = false
    ) {
        self.target = target
        self.path = path
        self.method = method
        self.queryItems = queryItems
        self.body = body
        self.headers = headers
        self.skipAuth = skipAuth
    }
}
