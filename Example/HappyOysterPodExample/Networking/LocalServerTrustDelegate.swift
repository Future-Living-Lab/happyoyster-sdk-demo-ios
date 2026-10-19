import Foundation

/// URLSessionDelegate: accepts self-signed certificates only for the local host configured in AppEnvironment.
/// Used during development to reach a LAN server over self-signed HTTPS. Not used in production.
final class LocalServerTrustDelegate: NSObject, URLSessionDelegate {

    private let trustedHost: () -> String

    /// - Parameter trustedHost: Closure that dynamically reads the currently configured local host (follows AppEnvironment changes).
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
