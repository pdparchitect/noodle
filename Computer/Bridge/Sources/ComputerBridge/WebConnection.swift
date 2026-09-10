import Foundation
import Security

/// Ephemeral UI-only credentials; never persisted or passed to an agent.
public struct ComputerWebConnection: Codable, Sendable {
    public let url: URL
    public let certificate: Data
    public let password: String
    public let customWeb: Bool
    public init(url: URL, certificate: Data = Data(), password: String = "", customWeb: Bool = false) {
        self.url = url; self.certificate = certificate; self.password = password; self.customWeb = customWeb
    }
    public func permitsNavigation(to target: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil) }
        return ["http", "https"].contains(url.scheme) && target.scheme == url.scheme && target.host == url.host
            && target.user == nil && target.password == nil && port(target) == port(url)
    }
    public func authenticate(_ challenge: URLAuthenticationChallenge,
        completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        guard space.host == url.host, space.port == port, challenge.previousFailureCount == 0 else {
            completion(.cancelAuthenticationChallenge, nil); return
        }
        if customWeb { completion(.performDefaultHandling, nil); return }
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = space.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
           let leaf = chain.first, SecCertificateCopyData(leaf) as Data == certificate {
            completion(.useCredential, URLCredential(trust: trust))
        } else if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
            completion(.useCredential, URLCredential(user: "agent", password: password, persistence: .forSession))
        } else { completion(.cancelAuthenticationChallenge, nil) }
    }
}
