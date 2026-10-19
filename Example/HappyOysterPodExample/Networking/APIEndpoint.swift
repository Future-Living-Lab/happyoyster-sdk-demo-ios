import Foundation

/// Request target: decides which base URL is used to build the request.
enum APITarget {
    /// Local LAN server (address taken from AppEnvironment.localServerBaseURL).
    case local
    /// Public service (address taken from AppEnvironment.publicServiceBaseURL).
    case publicService
}

/// Full description of a single API request, decoupled from URLSession / business logic.
struct APIEndpoint {
    let target: APITarget
    let path: String
    let method: HTTPMethod
    /// URL query parameters (both key and value are String).
    var queryItems: [URLQueryItem]
    /// Request body (any Encodable; nil means no body).
    var body: (any Encodable)?
    /// Extra HTTP headers (merged with the default headers, taking precedence).
    var headers: [String: String]
    /// When true, skips automatic Bearer token injection (used by token-fetching endpoints such as fetchTempApiKey).
    var skipAuth: Bool
    /// The world mode this request belongs to. The server uses it to pick which Bailian gateway app route
    /// to call (models are split by mode), so every `/server-api` request must carry it except
    /// `temp-api-key` (a pure token exchange, unrelated to models).
    ///
    /// This demo writes it into the `X-Happy-Oyster-Mode` request header (value is `rawValue`: 1=adventure /
    /// 2=directing / 3=acting) — **this is only a convention of this demo's companion server; your own server can use any form**,
    /// see `APIClient.modeHeaderField`. When nil, the header is not written.
    var mode: ServerWorldMode?

    init(
        target: APITarget,
        path: String,
        method: HTTPMethod,
        queryItems: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        headers: [String: String] = [:],
        skipAuth: Bool = false,
        mode: ServerWorldMode? = nil
    ) {
        self.target = target
        self.path = path
        self.method = method
        self.queryItems = queryItems
        self.body = body
        self.headers = headers
        self.skipAuth = skipAuth
        self.mode = mode
    }
}
