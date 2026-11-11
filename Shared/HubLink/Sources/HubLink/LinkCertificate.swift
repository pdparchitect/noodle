#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import HubWire
import SwiftASN1
import X509

/// The certificates the link carries keys in. Nothing checks their names or dates: peers are pinned
/// by key, as Noodle Hub on a Mac does.
public enum LinkCertificate {
    /// A self-signed certificate for `identity` and its private key, both PEM.
    public static func pem(for identity: LinkIdentity) throws -> (certificate: String, key: String) {
        let name = try DistinguishedName { CommonName("Noodle") }
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(identity.privateKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400), notValidAfter: now.addingTimeInterval(86_400 * 365 * 20),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {}, issuerPrivateKey: Certificate.PrivateKey(identity.privateKey))
        return (try certificate.serializeAsPEM().pemString, identity.privateKey.pemRepresentation)
    }

    /// The key a peer's certificate carries; nil for anything but a P-256 one.
    public static func key(of der: [UInt8]) -> LinkPublicKey? {
        guard let certificate = try? Certificate(derEncoded: der),
              let key = P256.Signing.PublicKey(certificate.publicKey) else { return nil }
        return LinkPublicKey(key)
    }
}
