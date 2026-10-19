import Foundation

// MARK: - Request / Response models

/// Request body for POST /server-api/temp-api-key.
/// The server accepts expire_in_seconds / expireInSeconds in the JSON body, or expire_in_seconds as a query parameter.
/// This client uses the JSON body, with snake_case field names to match the server.
private struct TempApiKeyRequest: Encodable {
    /// Temporary key lifetime (seconds), range 1...1800; when nil the field is omitted and the server default TTL is used.
    let expireInSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case expireInSeconds = "expire_in_seconds"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let value = expireInSeconds {
            try container.encode(value, forKey: .expireInSeconds)
        }
    }
}

/// Response body for POST /server-api/temp-api-key.
/// The server passes through the response of Bailian POST /api/v1/tokens; fields are snake_case.
/// JSONDecoder is configured with convertFromSnakeCase, so camelCase is used here.
public struct TempApiKeyResponse: Decodable, Sendable {
    /// Temporary API key (access token string, e.g. st-***).
    public let token: String
    /// Expiry timestamp (Unix seconds), corresponding to expires_at in the Bailian response.
    public let expiresAt: Int
}

// MARK: - APIClient extension

extension APIClient {

    /// Requests a temporary Bailian API key from the local server.
    ///
    /// The server uses the master DASHSCOPE_API_KEY to call Bailian /api/v1/tokens and issues a
    /// short-lived temporary key to the untrusted client (this app), so the master key never reaches the device.
    ///
    /// - Parameter expireInSeconds: Lifetime (seconds), valid range 1...1800.
    ///   Out-of-range values are clamped to the bounds. When nil it is omitted and the server default TTL is used (Bailian defaults to about 1800 seconds).
    /// - Returns: Temporary key response, containing the token string and expiry timestamp.
    func fetchTempApiKey(expireInSeconds: Int? = nil) async throws -> TempApiKeyResponse {
        let clamped: Int?
        if let raw = expireInSeconds {
            clamped = min(max(raw, 1), 1800)
        } else {
            clamped = nil
        }

        let endpoint = APIEndpoint(
            target: .local,
            path: "/server-api/temp-api-key",
            method: .post,
            body: TempApiKeyRequest(expireInSeconds: clamped),
            skipAuth: true  // This endpoint itself fetches the token, so it must not carry one (circular dependency)
        )
        return try await request(endpoint)
    }
}
