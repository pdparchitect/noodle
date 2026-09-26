import Foundation
@testable import HubLink
import XCTest

final class LinkProtocolTests: XCTestCase {
    private let invitation = LinkInvitation(
        hubName: "Mac mini", hubKey: LinkIdentity().publicKey,
        endpoints: [LinkEndpoint(host: "Mac-mini.local", port: 38_415), LinkEndpoint(host: "fd00::1", port: 38_415)],
        userName: "Ada", joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date(timeIntervalSince1970: 1_790_000_000))

    func testInvitationsSurviveTheirLinkFromAnyNoodleBuild() throws {
        XCTAssertEqual(try LinkInvitation(text: invitation.url().absoluteString), invitation)
        XCTAssertEqual(try LinkInvitation(text: " \(invitation.url(scheme: "noodle-dev").absoluteString)\n"), invitation)
        let code = try XCTUnwrap(URLComponents(url: invitation.url(), resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        XCTAssertEqual(try LinkInvitation(text: code), invitation)
    }

    /// Devices that fetch pictures on their own say so with every request; older ones get them in lists.
    func testListsLeavePicturesOutOnlyForDevicesThatFetchThem() throws {
        XCTAssertTrue(LinkProtocol.fetchesPictures(try LinkProtocol.encode(.bots)))
        XCTAssertFalse(LinkProtocol.fetchesPictures(Data(#"{"version":1,"request":{"bots":{}}}"#.utf8)))
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        XCTAssertEqual(try LinkProtocol.decode(Data(#"{"version":1,"fetchesPictures":true,"request":{"picture":{"_0":{"bot":{"_0":"00000000-0000-0000-0000-00000000000A"}}}}}"#.utf8)).get(),
                       .picture(.bot(id)))

        let picture = Data([1, 2, 3])
        let browser = LinkBrowser(id: id, name: "Work", icon: picture).withoutPicture
        XCTAssertNil(browser.icon)
        XCTAssertEqual(browser.iconDigest, LinkPicture.digest(picture))
        XCTAssertEqual(LinkBrowser(id: id, name: "Work").withoutPicture, LinkBrowser(id: id, name: "Work"))
    }

    /// An edit sends a bot's picture only when it changed, and a removed one stays removed.
    func testAnEditLeavesOutOnlyThePictureTheHubHas() {
        let picture = Data([1, 2, 3])
        var draft = LinkBotDraft(name: "Alfred", provider: "claude-code", avatarImageData: picture)
        draft.avatarImageDigest = LinkPicture.digest(picture)
        XCTAssertNil(draft.leavingOutKnownPicture.avatarImageData)
        XCTAssertEqual(draft.leavingOutKnownPicture.avatarImageDigest, LinkPicture.digest(picture))

        var changed = draft
        changed.avatarImageData = Data([4])
        XCTAssertEqual(changed.leavingOutKnownPicture.avatarImageData, Data([4]))
        XCTAssertNil(changed.leavingOutKnownPicture.avatarImageDigest)

        var removed = draft
        removed.removePicture()
        XCTAssertNil(removed.leavingOutKnownPicture.avatarImageData)
        XCTAssertNil(removed.leavingOutKnownPicture.avatarImageDigest)
    }

    func testOtherTextIsNotAnInvitation() {
        XCTAssertThrowsError(try LinkInvitation(text: "https://example.com"))
        XCTAssertThrowsError(try LinkInvitation(text: "noodle://join-hub?i=bm90IGpzb24"))
    }

    /// A device proves it holds the key it pairs, for one invitation only.
    func testAJoinProofHoldsForItsKeyAndInvitationOnly() throws {
        let device = LinkIdentity(), invitation = LinkIdentity().publicKey
        let proof = try device.joinProof(for: invitation)
        XCTAssertTrue(device.publicKey.isJoinProof(proof, for: invitation))
        XCTAssertFalse(device.publicKey.isJoinProof(proof, for: LinkIdentity().publicKey))
        XCTAssertFalse(LinkIdentity().publicKey.isJoinProof(proof, for: invitation))
        XCTAssertFalse(device.publicKey.isJoinProof(Data([1, 2, 3]), for: invitation))
    }

    func testAnInvitationWithoutAUsableJoinKeyIsNotAnInvitation() {
        var broken = invitation
        broken.joinKey = Data([1, 2, 3])
        XCTAssertThrowsError(try LinkInvitation(text: broken.url().absoluteString))
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
