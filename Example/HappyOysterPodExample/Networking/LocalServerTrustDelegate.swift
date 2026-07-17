import Foundation

/// URLSessionDelegate：仅对 AppEnvironment 中配置的本地 host 放行自签名证书。
/// 用于开发期通过自签名 HTTPS 连接局域网服务器。生产环境不使用本类。
final class LocalServerTrustDelegate: NSObject, URLSessionDelegate {

    private let trustedHost: () -> String

    /// - Parameter trustedHost: 闭包动态读取当前配置的本地 host（跟随 AppEnvironment 变化）。
    init(trustedHost: @escaping () -> String) {
        self.trustedHost = trustedHost
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            challenge.protectionSpace.host == trustedHost(),
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
