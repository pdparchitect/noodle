import Foundation
import NoodleCore
#if canImport(Security)
import Security
#endif

/// A signed assertion for Google's token endpoint: a JWT naming the service account, the scopes it asks for and the
/// user it acts for, signed RS256 with the account's private key, which never leaves this Mac.
enum GoogleAssertion {
    /// Where every assertion goes. A key file's own token_uri is never used, so a crafted file cannot send one elsewhere.
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    static func make(_ key: ConnectionGoogleKey, scopes: [String], subject: String?, now: Date = Date()) throws -> String {
        let issued = Int(now.timeIntervalSince1970)
        var header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        if let id = key.privateKeyID { header["kid"] = id }
        var claims: [String: Any] = ["iss": key.clientEmail, "scope": scopes.joined(separator: " "),
                                     "aud": tokenEndpoint.absoluteString, "iat": issued, "exp": issued + 3_600]
        if let subject { claims["sub"] = subject }
        let input = try encoded(header) + "." + encoded(claims)
        return input + "." + base64URL(try sign(Data(input.utf8), with: key.privateKey))
    }

    /// Checks that the PEM holds an RSA key this Mac can sign with, before it is kept.
    static func validate(_ pem: String) throws {
        _ = try sign(Data("check".utf8), with: pem)
    }

    private static func encoded(_ object: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sign(_ data: Data, with pem: String) throws -> Data {
        #if canImport(Security)
        let body = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body), let pkcs1 = rsaKey(inPKCS8: der) ?? (der.first == 0x30 ? der : nil) else {
            throw ToolConnectionError.message("The key file's private key could not be read.")
        }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error),
              let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) as Data? else {
            throw ToolConnectionError.message("The key file's private key could not sign.")
        }
        return signature
        #else
        throw ToolConnectionServiceError.credentialStorage
        #endif
    }

    /// The RSA key inside a PKCS #8 PrivateKeyInfo, as Google issues it: SEQUENCE { version, algorithm, OCTET STRING key }.
    private static func rsaKey(inPKCS8 der: Data) -> Data? {
        let bytes = [UInt8](der)
        var index = 0
        func element() -> (tag: UInt8, body: Range<Int>)? {
            guard index + 2 <= bytes.count else { return nil }
            let tag = bytes[index]
            var length = Int(bytes[index + 1])
            index += 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard (1...3).contains(count), index + count <= bytes.count else { return nil }
                length = bytes[index..<index + count].reduce(0) { $0 << 8 | Int($1) }
                index += count
            }
            guard index + length <= bytes.count else { return nil }
            defer { index += length }
            return (tag, index..<index + length)
        }
        guard let outer = element(), outer.tag == 0x30 else { return nil }
        index = outer.body.lowerBound
        guard let version = element(), version.tag == 0x02, let algorithm = element(), algorithm.tag == 0x30,
              let key = element(), key.tag == 0x04 else { return nil }
        return Data(bytes[key.body])
    }
}
