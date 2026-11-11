import Foundation
import HubWire
@testable import HubLink
import X509
import XCTest

final class LinkCertificateTests: XCTestCase {
    /// The server's certificate carries its link key, which is what devices pin.
    func testACertificateCarriesTheIdentitysKey() throws {
        let identity = LinkIdentity()
        let pem = try LinkCertificate.pem(for: identity)
        let certificate = try Certificate(pemEncoded: pem.certificate)
        XCTAssertEqual(LinkCertificate.key(of: try certificate.serializeAsPEM().derBytes), identity.publicKey)
        XCTAssertTrue(pem.key.hasPrefix("-----BEGIN PRIVATE KEY-----") || pem.key.hasPrefix("-----BEGIN EC PRIVATE KEY-----"))
    }

    func testAnythingButACertificateHasNoKey() {
        XCTAssertNil(LinkCertificate.key(of: Array("not a certificate".utf8)))
        XCTAssertNil(LinkCertificate.key(of: []))
    }
}
