import Foundation

/// App-side base networking client, built on URLSession + async/await.
/// Fully independent of the SDK's OysterAPIClient / OysterHTTPClient — the SDK handles the Bailian gateway,
/// while this client handles the example's own local LAN server and public service endpoints.
///
/// Token injection strategy:
/// - Once `tokenManager` is injected by `AppSession.configure`, `send()` automatically adds
///   `Authorization: Bearer <token>` to every request, and retries once automatically on auth failure.
/// - Requests with `skipAuth == true` (e.g. `fetchTempApiKey`) skip injection to avoid a circular dependency.
final class APIClient {

    /// World mode request header.
    ///
    /// **This is a convention of this demo's companion server — not an SDK contract, nor an open-platform contract.**
    /// Passing it as a header, this name, and the values 1/2/3 are all just what this demo agreed on with its `/server-api`
    /// server. When you build your own server you are completely free in how you tell your backend the mode — a query parameter,
    /// a request body field, separate per-mode paths, or not passing it at all and letting the backend look up the world's mode from `encryptedWorldId`.
    ///
    /// Only two things are truly non-negotiable, regardless of the transport form:
    /// 1. Your server must ultimately call the Bailian gateway with **the model matching that world's mode** (since models are split by mode,
    ///    `happyoyster-1.0-adventure` / `-directing` / `-acting` are each an independent gateway app route,
    ///    and the ticket is issued under one of them);
    /// 2. The client SDK's `OysterConfig.model` must match the route that issued the ticket,
    ///    otherwise `travel.start()` fails on the gateway side (see the `start()` section of the SDK API Reference).
    ///
    /// The value is `ServerWorldMode.rawValue`: 1=adventure, 2=directing, 3=acting.
    static let modeHeaderField = "X-Happy-Oyster-Mode"

    private let environment: AppEnvironment
    private let session: URLSession
    private let trustDelegate: LocalServerTrustDelegate
    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Injected by AppSession.configure; once injected, every request automatically carries the Bearer token.
    var tokenManager: TokenManager?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.trustDelegate = LocalServerTrustDelegate { environment.localHost }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: trustDelegate, delegateQueue: nil)
    }

    // MARK: - Public interface

    /// Sends the request and decodes the response body into the given type.
    func request<T: Decodable>(_ endpoint: APIEndpoint) async throws -> T {
        let data = try await send(endpoint)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    /// Sends the request and returns the raw response Data.
    /// If tokenManager is injected and endpoint.skipAuth == false, the Bearer token is injected automatically,
    /// and on auth failure (HTTP 401 / business 401xxx) the token is refreshed and the request retried once.
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
        // World mode: the server uses it to forward the request to the Bailian gateway app route for that mode (models are split by mode).
        // Carrying it in a header is this demo server's convention, not an SDK / open-platform contract — your own server can switch to
        // query, body or per-mode paths by changing just this spot; see `modeHeaderField`.
        if let mode = endpoint.mode {
            request.setValue(String(mode.rawValue), forHTTPHeaderField: APIClient.modeHeaderField)
        }

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
