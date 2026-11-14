import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// AWS Signature Version 4: each request signed with the access key's secret, which never leaves this Mac.
enum AWSSignature {
    /// The service and region a request to `host` is signed for: cloudtrail.eu-west-1.amazonaws.com is cloudtrail
    /// in eu-west-1; a global service such as iam.amazonaws.com is signed in us-east-1. Nil outside amazonaws.com.
    static func scope(of host: String, defaultRegion: String) -> (service: String, region: String)? {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 3, labels.suffix(2) == ["amazonaws", "com"] else { return nil }
        let service = labels[0]
        return labels.count == 3 ? (service, "us-east-1") : (service, labels[1])
    }

    /// Adds X-Amz-Date, the session token when there is one, and the Authorization header, signing every header the
    /// request carries along with its host.
    static func sign(_ request: inout URLRequest, key: ConnectionAWSKey, region: String, service: String, date: Date = Date()) {
        guard let url = request.url, let host = url.host?.lowercased() else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: date)
        let day = String(stamp.prefix(8))
        request.setValue(stamp, forHTTPHeaderField: "X-Amz-Date")
        if let token = key.sessionToken { request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token") }

        var headers: [String: String] = ["host": url.port.map { "\(host):\($0)" } ?? host]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name.lowercased() != "authorization" {
            headers[name.lowercased()] = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Every service but S3 takes each path segment encoded twice.
        let path = (components?.percentEncodedPath).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        let canonicalPath = path.split(separator: "/", omittingEmptySubsequences: false).map { encode(String($0)) }.joined(separator: "/")
        let pairs: [(name: String, value: String)] = (components?.queryItems ?? []).map { item in
            (encode(item.name), encode(item.value ?? ""))
        }
        let sorted = pairs.sorted { left, right in left.name == right.name ? left.value < right.value : left.name < right.name }
        let query = sorted.map { pair in pair.name + "=" + pair.value }.joined(separator: "&")
        let payload = hex(SHA256.hash(data: request.httpBody ?? Data()))
        let canonical = [request.httpMethod ?? "GET", canonicalPath, query, canonicalHeaders, signedHeaders, payload].joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        var signing = SymmetricKey(data: Data(("AWS4" + key.secretAccessKey).utf8))
        for part in [day, region, service, "aws4_request"] {
            signing = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: signing)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: signing))
        request.setValue("AWS4-HMAC-SHA256 Credential=\(key.accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }

    /// RFC 3986 encoding: everything but letters, digits and -._~ escaped.
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? value
    }

    private static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
