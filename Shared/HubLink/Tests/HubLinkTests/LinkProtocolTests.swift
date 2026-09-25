import Foundation
@testable import HubLink
import XCTest

final class LinkProtocolTests: XCTestCase {
    private let invitation = LinkInvitation(
        hubName: "Mac mini", hubKey: LinkIdentity().publicKey,
        endpoints: [LinkEndpoint(host: "Mac-mini.local", port: 38_415), LinkEndpoint(host: "fd00::1", port: 38_415)],
        userName: "Ada", token: LinkInvitation.newToken(), expires: Date(timeIntervalSince1970: 1_790_000_000))

    func testInvitationsSurviveTheirLinkFromAnyNoodleBuild() throws {
        XCTAssertEqual(try LinkInvitation(text: invitation.url().absoluteString), invitation)
        XCTAssertEqual(try LinkInvitation(text: " \(invitation.url(scheme: "noodle-dev").absoluteString)\n"), invitation)
        let code = try XCTUnwrap(URLComponents(url: invitation.url(), resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        XCTAssertEqual(try LinkInvitation(text: code), invitation)
    }

    func testOtherTextIsNotAnInvitation() {
        XCTAssertThrowsError(try LinkInvitation(text: "https://example.com"))
        XCTAssertThrowsError(try LinkInvitation(text: "noodle://join-hub?i=bm90IGpzb24"))
    }

    func testTokensAreKeptOnlyAsDigests() {
        let token = LinkInvitation.newToken()
        XCTAssertEqual(LinkInvitation.tokenDigest(token), LinkInvitation.tokenDigest(token))
        XCTAssertNotEqual(LinkInvitation.tokenDigest(token), LinkInvitation.tokenDigest(LinkInvitation.newToken()))
        XCTAssertFalse(LinkInvitation.tokenDigest(token).base64URL.contains(token))
    }

    func testTypedAddressesTakeAnOptionalPort() {
        XCTAssertEqual(LinkEndpoint(text: "hub.example.com", defaultPort: 1), LinkEndpoint(host: "hub.example.com", port: 1))
        XCTAssertEqual(LinkEndpoint(text: "203.0.113.5:4000", defaultPort: 1), LinkEndpoint(host: "203.0.113.5", port: 4000))
        XCTAssertEqual(LinkEndpoint(text: "[2001:db8::1]:4000", defaultPort: 1), LinkEndpoint(host: "2001:db8::1", port: 4000))
        XCTAssertEqual(LinkEndpoint(text: "2001:db8::1", defaultPort: 1), LinkEndpoint(host: "2001:db8::1", port: 1))
        XCTAssertNil(LinkEndpoint(text: "host:notaport", defaultPort: 1))
        XCTAssertNil(LinkEndpoint(text: " ", defaultPort: 1))
    }

    func testLocalAddressesNeverIncludeLoopbackOrLinkLocal() {
        let hosts = LinkEndpoint.local(port: 5).map(\.host)
        XCTAssertFalse(hosts.contains { $0 == "127.0.0.1" || $0 == "::1" || $0.lowercased().hasPrefix("fe80") })
        XCTAssertTrue(LinkEndpoint.local(port: 5).allSatisfy { $0.port == 5 })
    }

    func testTheKeySurvivesARelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hub-link-\(UUID())/device.key")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try LinkIdentity.loadOrCreate(at: url)
        XCTAssertEqual(try LinkIdentity.loadOrCreate(at: url).publicKey, first.publicKey)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }
}
