import Foundation

// MARK: - Bailian app gateway response envelope

/// Top-level wrapper of proxied routes: `{ request_id, output }`.
/// temp-api-key returns the DashScope format directly and does not use this type.
struct BailianResponse<T: Decodable>: Decodable {
    let requestId: String
    let output: BailianOutput<T>
}

/// Business envelope: `{ code, message, data }`.
/// `code == 0` means success; non-zero is a business error code (see APIError.business).
struct BailianOutput<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?
}

/// Proxy / gateway-level error response: `{ request_id, code: String, message }`.
/// Mutually exclusive with the business envelope — a string `code` means a proxy-level error, a numeric one is a business code.
private struct BailianGatewayError: Decodable {
    let requestId: String?
    let code: String
    let message: String?
}

// MARK: - APIClient unwrapping extension

extension APIClient {

    /// Sends the request, unwraps the Bailian envelope and returns `output.data`.
    /// - Automatically handles proxy-level errors (string code) → `APIError.gateway`
    /// - Automatically handles business errors (code != 0) → `APIError.business`
    /// - When `logRawResponse == true`, unconditionally prints the raw response body (whether decoding succeeds or not),
    ///   for diagnosing "fields parse fine but the content is wrong" cases that the decode result alone can't reveal.
    func requestBailian<T: Decodable>(_ endpoint: APIEndpoint, logRawResponse: Bool = false) async throws -> T {
        try await requestBailianWithRaw(endpoint, logRawResponse: logRawResponse).value
    }

    /// Same logic as `requestBailian`, but also returns the raw response body (the full JSON string before unwrapping/decoding),
    /// so the UI can display it directly (e.g. the debug info section at the bottom of the artifact detail page) without digging through console logs.
    func requestBailianWithRaw<T: Decodable>(
        _ endpoint: APIEndpoint, logRawResponse: Bool = false
    ) async throws -> (value: T, rawJSON: String) {
        let data = try await send(endpoint)
        let raw = String(data: data, encoding: .utf8) ?? "<binary \(data.count)B>"

        if logRawResponse {
            appLog("[APIClient] 📦 raw response for \(endpoint.path): \(raw)")
        }

        // First try to parse it as a proxy-level error (code is a String)
        if let gateway = try? JSONDecoder().decode(BailianGatewayError.self, from: data),
           !gateway.code.isEmpty,
           Int(gateway.code) == nil {
            throw APIError.gateway(code: gateway.code, message: gateway.message, requestId: gateway.requestId)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let envelope: BailianResponse<T>
        do {
            envelope = try decoder.decode(BailianResponse<T>.self, from: data)
        } catch {
            appLog("[APIClient] ❌ requestBailian decode failed for \(endpoint.path)")
            appLog("[APIClient]    raw response: \(raw)")
            appLog("[APIClient]    decode error: \(error)")
            throw APIError.decoding(underlying: error)
        }

        guard envelope.output.code == 0 else {
            throw APIError.business(
                code: envelope.output.code,
                message: envelope.output.message,
                requestId: envelope.requestId
            )
        }

        guard let result = envelope.output.data else {
            throw APIError.decoding(underlying: DecodingError.valueNotFound(
                T.self,
                DecodingError.Context(codingPath: [], debugDescription: "output.data is null")
            ))
        }
        return (result, raw)
    }
}

// MARK: - Generic pagination

struct PaginatedResponse<Item: Decodable>: Decodable {
    let items: [Item]
    let pagination: Pagination
}

struct Pagination: Decodable {
    let page: Int
    let pageSize: Int
    let total: Int
    let hasMore: Bool
}
