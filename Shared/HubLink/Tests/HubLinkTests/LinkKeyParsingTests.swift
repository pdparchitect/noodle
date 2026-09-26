import CryptoKit
import Foundation
@testable import HubLink
import Network
import Security
import X509
import XCTest

/// What a stranger controls before the Hub admits them is the certificate in their handshake.
/// Anything that is not a P-256 key the Hub knows, held by whoever presents it, is refused.
final class LinkKeyParsingTests: XCTestCase {
    func testMalformedKeysAreRefused() throws {
        let valid = LinkIdentity().publicKey.x963
        var offCurve = valid
        offCurve[64] ^= 1
        let malformed: [Data] = [Data(), Data([0]), Data([4]), Data(repeating: 0, count: 65),
                                 Data([4]) + Data(repeating: 0, count: 64), valid.prefix(64), valid + Data([0]),
                                 offCurve, Data(repeating: 0xFF, count: 65), Data(repeating: 0xFF, count: 1 << 16)]
        for bytes in malformed {
            XCTAssertThrowsError(try LinkPublicKey(x963: bytes), "\(bytes as NSData)")
        }
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(LinkPublicKey.self, from: Data(#""""#.utf8)))
        XCTAssertThrowsError(try decoder.decode(LinkPublicKey.self, from: Data("null".utf8)))
        XCTAssertThrowsError(try decoder.decode(LinkPublicKey.self, from: Data(#""AA==""#.utf8)))
    }

    func testCertificatesWithoutAP256KeyAreRefused() throws {
        XCTAssertNil(LinkPublicKey(certificate: try certificate(P384.Signing.PrivateKey())))
        XCTAssertNil(LinkPublicKey(certificate: try certificate(Curve25519.Signing.PrivateKey())))
        let identity = LinkIdentity()
        XCTAssertEqual(LinkPublicKey(certificate: try certificate(identity.privateKey)), identity.publicKey)
    }

    /// A paired device's certificate is no secret. Sent along in a chain, it gets nobody in: the
    /// Hub trusts only the first certificate, whose key TLS makes the client sign with.
    func testAPairedCertificateInAStrangersChainGetsNobodyIn() async throws {
        let hub = LinkIdentity(), paired = LinkIdentity(), thief = LinkIdentity()
        let requests = FrameBox(), presented = FrameBox()
        let server = try LinkServer(identity: hub, port: 0, admits: { key in
            presented.append(key.x963)
            return key == paired.publicKey
        }) { _, request in
            requests.append(request)
            return .response(request)
        }
        try await server.start()
        addTeardownBlock { server.stop() }
        let port = try XCTUnwrap(server.port)

        // The same path with the real key gets in, so a refusal below is the key's doing.
        let genuine = try await send(Data("genuine".utf8), as: try paired.secIdentity(), to: port)
        XCTAssertEqual(genuine, Data("genuine".utf8))

        let forged = try identity(of: thief, alsoPresenting: paired.publicKey)
        let stolen = try await send(Data("stolen".utf8), as: forged, to: port)
        XCTAssertNil(stolen)
        XCTAssertEqual(requests.frames, [Data("genuine".utf8)])
        XCTAssertEqual(presented.frames, [paired.publicKey.x963, thief.publicKey.x963])
    }

    private func certificate(_ key: some SigningKey) throws -> SecCertificate {
        let name = try DistinguishedName { CommonName("Test") }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: key.certificatePublicKey,
            notValidBefore: Date(), notValidAfter: Date().addingTimeInterval(3600), issuer: name, subject: name,
            signatureAlgorithm: key.signatureAlgorithm, extensions: Certificate.Extensions {}, issuerPrivateKey: key.certificatePrivateKey)
        return try XCTUnwrap(SecCertificateCreateWithData(nil, Data(try certificate.serializeAsPEM().derBytes) as CFData))
    }

    /// The thief's identity, with a certificate for `presented` after its own in the chain it sends.
    /// Security refuses to pair a key with another's certificate, and Network always sends the
    /// identity's own first, so this is as close to a stolen certificate as Apple's stack goes.
    private func identity(of thief: LinkIdentity, alsoPresenting presented: LinkPublicKey) throws -> sec_identity_t {
        let name = try DistinguishedName { CommonName("Noodle") }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PublicKey(try P256.Signing.PublicKey(x963Representation: presented.x963)),
            notValidBefore: Date().addingTimeInterval(-60), notValidAfter: Date().addingTimeInterval(3600), issuer: name, subject: name,
            signatureAlgorithm: .ecdsaWithSHA256, extensions: Certificate.Extensions {}, issuerPrivateKey: Certificate.PrivateKey(thief.privateKey))
        let victim = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(try certificate.serializeAsPEM().derBytes) as CFData))
        let own = try XCTUnwrap(sec_identity_copy_ref(try thief.secIdentity())).takeRetainedValue()
        return try XCTUnwrap(sec_identity_create_with_certificates(own, [victim] as CFArray))
    }

    /// Sends one request as `identity`, trusting any Hub; nil if the Hub never answers it.
    private func send(_ request: Data, as identity: sec_identity_t, to port: UInt16) async throws -> Data? {
        let options = NWProtocolQUIC.Options(alpn: [LinkQUIC.alpn])
        options.idleTimeout = 3_000
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, identity)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in complete(true) }, LinkQUIC.queue)
        let connection = NWConnection(host: "::1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)), using: NWParameters(quic: options))
        defer { connection.cancel() }
        let ready = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: true) }
                case .failed, .cancelled, .waiting: once.run { continuation.resume(returning: false) }
                default: break
                }
            }
            connection.start(queue: LinkQUIC.queue)
            LinkQUIC.queue.asyncAfter(deadline: .now() + 5) { once.run { continuation.resume(returning: false) } }
        }
        guard ready else { return nil }
        // A client may count its side of the handshake done before the Hub has checked it.
        guard (try? await LinkQUIC.send(request, on: connection)) != nil, let answer = try? await LinkQUIC.receive(connection),
              !answer.isEmpty else { return nil }
        return answer
    }
}

private protocol SigningKey {
    var certificatePublicKey: Certificate.PublicKey { get }
    var certificatePrivateKey: Certificate.PrivateKey { get }
    var signatureAlgorithm: Certificate.SignatureAlgorithm { get }
}

extension P256.Signing.PrivateKey: SigningKey {
    var certificatePublicKey: Certificate.PublicKey { Certificate.PublicKey(publicKey) }
    var certificatePrivateKey: Certificate.PrivateKey { Certificate.PrivateKey(self) }
    var signatureAlgorithm: Certificate.SignatureAlgorithm { .ecdsaWithSHA256 }
}

extension P384.Signing.PrivateKey: SigningKey {
    var certificatePublicKey: Certificate.PublicKey { Certificate.PublicKey(publicKey) }
    var certificatePrivateKey: Certificate.PrivateKey { Certificate.PrivateKey(self) }
    var signatureAlgorithm: Certificate.SignatureAlgorithm { .ecdsaWithSHA384 }
}

extension Curve25519.Signing.PrivateKey: SigningKey {
    var certificatePublicKey: Certificate.PublicKey { Certificate.PublicKey(publicKey) }
    var certificatePrivateKey: Certificate.PrivateKey { Certificate.PrivateKey(self) }
    var signatureAlgorithm: Certificate.SignatureAlgorithm { .ed25519 }
}
