import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Duo's v5 request signing, which its Admin API takes in place of a token: each request is signed with the
/// application's secret key, which never leaves this Mac, over its date, method, host, path, parameters and body.
enum DuoSignature {
    /// Adds the Date header and the Authorization header, HTTP Basic with the integration key and the request's
    /// HMAC-SHA512 signature. A POST, PUT or PATCH without a body is given `{}`, the body Duo signs for no parameters.
    static func sign(_ request: inout URLRequest, integrationKey: String, secretKey: String, date: Date = Date()) {
        guard let url = request.url, let host = url.host?.lowercased() else { return }
        let method = (request.httpMethod ?? "GET").uppercased()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss '-0000'"
        let stamp = formatter.string(from: date)
        request.setValue(stamp, forHTTPHeaderField: "Date")

        let carriesBody = ["POST", "PUT", "PATCH"].contains(method)
        if carriesBody, request.httpBody == nil {
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let body = carriesBody ? request.httpBody ?? Data() : Data()

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = (components?.percentEncodedPath).flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        // Parameters as Duo reads them back: each name and value encoded alone, sorted by name.
        let pairs: [(name: String, value: String)] = (components?.queryItems ?? []).map { item in
            (encode(item.name), encode(item.value ?? ""))
        }
        let sorted = pairs.sorted { left, right in left.name == right.name ? left.value < right.value : left.name < right.name }
        let query = sorted.map { pair in pair.name + "=" + pair.value }.joined(separator: "&")
        // No X-Duo headers are signed, so their hash is the empty string's.
        let canonical = [stamp, method, host, path, query, hex(SHA512.hash(data: body)), hex(SHA512.hash(data: Data()))].joined(separator: "\n")
        let signature = hex(HMAC<SHA512>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: Data(secretKey.utf8))))
        request.setValue("Basic " + Data("\(integrationKey):\(signature)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
    }

    /// RFC 3986 encoding with upper-case hex digits: everything but letters, digits and -._~ escaped.
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? value
    }

    private static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
