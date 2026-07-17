import Foundation

// MARK: - 百炼 app 网关响应信封

/// 代理路由的顶层包装：`{ request_id, output }`。
/// temp-api-key 直接返回 DashScope 格式，不走此类型。
struct BailianResponse<T: Decodable>: Decodable {
    let requestId: String
    let output: BailianOutput<T>
}

/// 业务信封：`{ code, message, data }`。
/// `code == 0` 表示成功；非 0 为业务错误码（见 APIError.business）。
struct BailianOutput<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?
}

/// 代理 / 网关层错误响应：`{ request_id, code: String, message }`。
/// 与业务信封互斥——`code` 为字符串时是代理层错误，数值时是业务码。
private struct BailianGatewayError: Decodable {
    let requestId: String?
    let code: String
    let message: String?
}

// MARK: - APIClient 拆包扩展

extension APIClient {

    /// 发起请求并拆包百炼信封，返回 `output.data`。
    /// - 自动处理代理层错误（字符串 code）→ `APIError.gateway`
    /// - 自动处理业务错误（code != 0）→ `APIError.business`
    /// - `logRawResponse == true` 时无条件打印原始响应体（不管解码成功与否），
    ///   用于排查"字段解析没问题但内容不对"这类光看 decode 结果看不出来的场景。
    func requestBailian<T: Decodable>(_ endpoint: APIEndpoint, logRawResponse: Bool = false) async throws -> T {
        try await requestBailianWithRaw(endpoint, logRawResponse: logRawResponse).value
    }

    /// 与 `requestBailian` 同逻辑，额外把原始响应体（拆包/解码前的完整 JSON 字符串）一起带出来，
    /// 供 UI 侧直接展示（如产物详情页底部的调试信息区），不用再单独翻控制台日志。
    func requestBailianWithRaw<T: Decodable>(
        _ endpoint: APIEndpoint, logRawResponse: Bool = false
    ) async throws -> (value: T, rawJSON: String) {
        let data = try await send(endpoint)
        let raw = String(data: data, encoding: .utf8) ?? "<binary \(data.count)B>"

        if logRawResponse {
            appLog("[APIClient] 📦 raw response for \(endpoint.path): \(raw)")
        }

        // 先尝试解析为代理层错误（code 为 String）
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

// MARK: - 通用分页

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
