import Foundation

/// app 侧网络层错误，完全独立于 SDK 的 OysterError。
enum APIError: Error, LocalizedError {
    /// 本地服务器地址未配置（AppEnvironment.localServerBaseURL 无效）。
    case missingBaseURL
    /// URL 构造失败（path / query 非法）。
    case invalidURL
    /// 请求体编码失败。
    case encoding(underlying: Error)
    /// 网络层传输失败（URLError）。
    case network(underlying: Error)
    /// HTTP 非 2xx 响应。
    case http(statusCode: Int, data: Data)
    /// 响应体解码失败。
    case decoding(underlying: Error)
    /// 百炼业务错误：HTTP 200 但 output.code != 0。
    case business(code: Int, message: String?, requestId: String?)
    /// 百炼代理 / 网关层错误（code 为字符串，如 ServiceUnavailable）。
    case gateway(code: String, message: String?, requestId: String?)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "本地服务器地址未配置，请在个人页设置 HOST / PORT。"
        case .invalidURL:
            return "请求 URL 构造失败，请检查 HOST / PORT 配置。"
        case .encoding(let e):
            return "请求编码失败：\(e.localizedDescription)"
        case .network(let e):
            return "网络错误：\(e.localizedDescription)"
        case .http(let code, _):
            return "HTTP 错误 \(code)"
        case .decoding(let e):
            return "响应解析失败：\(e.localizedDescription)"
        case .business(let code, let msg, let rid):
            let ridSuffix = rid.map { " [req:\($0)]" } ?? ""
            return "业务错误 \(code)：\(msg ?? "（无描述）")\(ridSuffix)"
        case .gateway(let code, let msg, let rid):
            let ridSuffix = rid.map { " [req:\($0)]" } ?? ""
            return "网关错误 \(code)：\(msg ?? "（无描述）")\(ridSuffix)"
        }
    }
}
