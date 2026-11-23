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
    /// in eu-west-1; a global service such as iam.amazonaws.com is signed in us-east-1; S3 Control's account host,
    /// 123456789012.s3-control.eu-west-1.amazonaws.com, is signed as s3, its signing name. Nil outside amazonaws.com and
    /// for any other shape of host, such as a bucket's own name before s3, which is then sent unsigned and refused.
    static func scope(of host: String, defaultRegion: String) -> (service: String, region: String)? {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 3, labels.suffix(2) == ["amazonaws", "com"] else { return nil }
        let inner = Array(labels.dropLast(2))
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard inner.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(plain.contains) }) else { return nil }
        switch inner.count {
        case 1: return (signingName(inner[0]), "us-east-1")
        case 2: return (signingName(inner[0]), inner[1])
        case 3 where inner[1] == "s3-control" && inner[0].count == 12 && inner[0].allSatisfy(\.isNumber):
            return ("s3", inner[2])
        default: return nil
        }
    }

    /// The name a service signs with, where it differs from its host's first label.
    static func signingName(_ endpoint: String) -> String { endpoint == "s3-control" ? "s3" : endpoint }

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
        let payload = hex(SHA256.hash(data: request.httpBody ?? Data()))
        // S3 takes the payload's hash in a header of its own, which it requires, and signs it with the rest.
        let s3 = service == "s3"
        if s3 { request.setValue(payload, forHTTPHeaderField: "x-amz-content-sha256") }

        var headers: [String: String] = ["host": url.port.map { "\(host):\($0)" } ?? host]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where name.lowercased() != "authorization" {
            headers[name.lowercased()] = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let names = headers.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()
        let signedHeaders = names.joined(separator: ";")

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Every service but S3 takes each path segment, as sent, encoded once more; S3 takes each encoded only once.
        let path = (components?.percentEncodedPath).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        let canonicalPath = path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            s3 ? encode(String(segment).removingPercentEncoding ?? String(segment)) : encode(String(segment))
        }.joined(separator: "/")
        let pairs: [(name: String, value: String)] = (components?.queryItems ?? []).map { item in
            (encode(item.name), encode(item.value ?? ""))
        }
        let sorted = pairs.sorted { left, right in left.name == right.name ? left.value < right.value : left.name < right.name }
        let query = sorted.map { pair in pair.name + "=" + pair.value }.joined(separator: "&")
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
