import Foundation
import HubWire
import Security
import SwiftASN1
import X509

extension LinkIdentity {
    /// A self-signed certificate for TLS. Nothing checks its names or dates: peers are pinned by key.
    func secIdentity() throws -> sec_identity_t {
        let name = try DistinguishedName { CommonName("Noodle") }
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(privateKey.publicKey),
            notValidBefore: now.addingTimeInterval(-86_400), notValidAfter: now.addingTimeInterval(86_400 * 365 * 20),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {}, issuerPrivateKey: Certificate.PrivateKey(privateKey))
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        guard let secCertificate = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData) else {
            throw LinkError("Could not create the link certificate.")
        }
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(privateKey.x963Representation as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ] as CFDictionary, &error), let identity = SecIdentityCreate(nil, secCertificate, secKey),
              let secIdentity = sec_identity_create(identity) else {
            throw LinkError("Could not create the link identity.")
        }
        return secIdentity
    }
}

extension LinkPublicKey {
    init?(certificate: SecCertificate) {
        guard let key = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              let parsed = try? LinkPublicKey(x963: data) else { return nil }
        self = parsed
    }
}
