import Foundation

/// App-side networking error, fully independent of the SDK's OysterError.
enum APIError: Error, LocalizedError {
    /// Local server address is not configured (AppEnvironment.localServerBaseURL is invalid).
    case missingBaseURL
    /// Failed to build the URL (invalid path / query).
    case invalidURL
    /// Failed to encode the request body.
    case encoding(underlying: Error)
    /// Transport-level network failure (URLError).
    case network(underlying: Error)
    /// Non-2xx HTTP response.
    case http(statusCode: Int, data: Data)
    /// Failed to decode the response body.
    case decoding(underlying: Error)
    /// Bailian business error: HTTP 200 but output.code != 0.
    case business(code: Int, message: String?, requestId: String?)
    /// Bailian proxy / gateway-level error (code is a string, e.g. ServiceUnavailable).
    case gateway(code: String, message: String?, requestId: String?)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return String(localized: "Local server address is not configured. Set HOST / PORT on the Profile page.")
        case .invalidURL:
            return String(localized: "Failed to build the request URL. Check the HOST / PORT settings.")
        case .encoding(let e):
            return String(localized: "Request encoding failed: \(e.localizedDescription)")
        case .network(let e):
            return String(localized: "Network error: \(e.localizedDescription)")
        case .http(let code, _):
            return String(localized: "HTTP error \(code)")
        case .decoding(let e):
            return String(localized: "Failed to parse response: \(e.localizedDescription)")
        case .business(let code, let msg, let rid):
            let ridSuffix = rid.map { " [req:\($0)]" } ?? ""
            let text = msg ?? String(localized: "(no description)")
            return String(localized: "Business error \(code): \(text)\(ridSuffix)")
        case .gateway(let code, let msg, let rid):
            let ridSuffix = rid.map { " [req:\($0)]" } ?? ""
            let text = msg ?? String(localized: "(no description)")
            return String(localized: "Gateway error \(code): \(text)\(ridSuffix)")
        }
    }
}
