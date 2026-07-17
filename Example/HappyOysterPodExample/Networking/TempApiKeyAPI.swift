import Foundation

// MARK: - Request / Response models

/// POST /server-api/temp-api-key 请求体。
/// 服务端接受 JSON body expire_in_seconds / expireInSeconds，或 query expire_in_seconds。
/// 本客户端采用 JSON body，字段用 snake_case 与服务端对齐。
private struct TempApiKeyRequest: Encodable {
    /// 临时 Key 有效期（秒），取值 1...1800；nil 时不传该字段，使用服务端默认 TTL。
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

/// POST /server-api/temp-api-key 响应体。
/// 服务端透传百炼 POST /api/v1/tokens 的返回，字段为 snake_case。
/// JSONDecoder 配置了 convertFromSnakeCase，此处用驼峰命名。
public struct TempApiKeyResponse: Decodable, Sendable {
    /// 临时 API Key（access token 字符串，如 st-***）。
    public let token: String
    /// 过期时间戳（Unix 秒），与百炼响应的 expires_at 对应。
    public let expiresAt: Int
}

// MARK: - APIClient extension

extension APIClient {

    /// 向本地服务器请求临时百炼 API Key。
    ///
    /// 服务端使用主 DASHSCOPE_API_KEY 调百炼 /api/v1/tokens，为不可信客户端（本 app）
    /// 签发短生命周期的临时 Key，避免主 Key 下端。
    ///
    /// - Parameter expireInSeconds: 有效期（秒），合法范围 1...1800。
    ///   超出范围会被 clamp 到边界。nil 时不传，使用服务端默认 TTL（百炼默认约 1800 秒）。
    /// - Returns: 临时 Key 响应，含 token 字符串与过期时间戳。
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
            skipAuth: true  // 本接口本身用于获取 token，不能携带 token（循环依赖）
        )
        return try await request(endpoint)
    }
}
