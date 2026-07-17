import Foundation

/// App 侧基础网络客户端，基于 URLSession + async/await。
/// 完全独立于 SDK 的 OysterAPIClient / OysterHTTPClient——SDK 管百炼网关，
/// 本客户端管示例自有的本地局域网服务器与公网服务接口。
///
/// token 注入策略：
/// - `tokenManager` 由 `AppSession.configure` 注入后，`send()` 对所有请求自动加
///   `Authorization: Bearer <token>`，并在鉴权失败时自动重试一次。
/// - `skipAuth == true` 的请求（如 `fetchTempApiKey`）跳过注入，避免循环依赖。
final class APIClient {

    private let environment: AppEnvironment
    private let session: URLSession
    private let trustDelegate: LocalServerTrustDelegate
    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// 由 AppSession.configure 注入，注入后所有请求自动携带 Bearer token。
    var tokenManager: TokenManager?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.trustDelegate = LocalServerTrustDelegate { environment.localHost }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: trustDelegate, delegateQueue: nil)
    }

    // MARK: - Public interface

    /// 发起请求并将响应体解码为指定类型。
    func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        let data = try await send(endpoint)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    /// 发起请求，返回原始响应 Data。
    /// 若已注入 tokenManager 且 endpoint.skipAuth == false，自动注入 Bearer token
    /// 并在鉴权失败（HTTP 401 / 业务 401xxx）时刷新 token 后重试一次。
    @discardableResult
    func send(_ endpoint: APIEndpoint) async throws -> Data {
        guard !endpoint.skipAuth, let tm = tokenManager else {
            return try await rawSend(endpoint)
        }
        return try await sendWithToken(endpoint, tokenManager: tm)
    }

    // MARK: - Private

    private func sendWithToken(_ endpoint: APIEndpoint, tokenManager: TokenManager) async throws -> Data {
        let info = try await tokenManager.validToken()
        var authed = endpoint
        authed.headers["Authorization"] = "Bearer \(info.token)"

        do {
            return try await rawSend(authed)
        } catch let error as APIError {
            if isAuthError(error) {
                let newInfo = try await tokenManager.invalidateAndRefresh()
                authed.headers["Authorization"] = "Bearer \(newInfo.token)"
                return try await rawSend(authed)
            }
            throw error
        }
    }

    private func rawSend(_ endpoint: APIEndpoint) async throws -> Data {
        let urlRequest = try buildRequest(for: endpoint)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.network(underlying: URLError(.badServerResponse))
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<binary \(data.count)B>"
                appLog("[APIClient] ❌ HTTP \(http.statusCode) — \(urlRequest.url?.path ?? endpoint.path)")
                appLog("[APIClient]    body: \(body)")
                throw APIError.http(statusCode: http.statusCode, data: data)
            }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.network(underlying: error)
        }
    }

    private func isAuthError(_ error: APIError) -> Bool {
        switch error {
        case .http(let code, _) where code == 401:
            return true
        case .business(let code, _, _) where (401000...401999).contains(code):
            return true
        default:
            return false
        }
    }

    // MARK: - Request building

    private func buildRequest(for endpoint: APIEndpoint) throws -> URLRequest {
        let baseURL: URL
        switch endpoint.target {
        case .local:
            baseURL = environment.localServerBaseURL
        case .publicService:
            baseURL = environment.publicServiceBaseURL
        }

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(endpoint.path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidURL
        }

        if !endpoint.queryItems.isEmpty {
            components.queryItems = endpoint.queryItems
        }

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body = endpoint.body {
            do {
                request.httpBody = try encoder.encode(AnyEncodable(body))
            } catch {
                throw APIError.encoding(underlying: error)
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        for (key, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        return request
    }
}

// MARK: - Type-erased Encodable helper

private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) { _encode = wrapped.encode }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}
