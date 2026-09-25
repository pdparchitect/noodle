import Foundation
import HubLink
@testable import Noodle
import XCTest

@MainActor final class HubPairingStoreTests: XCTestCase {
    private let invitation = LinkInvitation(hubName: "Mac mini", hubKey: LinkIdentity().publicKey,
        endpoints: [LinkEndpoint(host: "Mac-mini.local", port: 38_415)], userName: "Ada",
        token: LinkInvitation.newToken(), expires: Date().addingTimeInterval(600))

    func testInvitationLinksOpenCompanionsReadyToJoin() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        XCTAssertTrue(f.store.receiveHubInvitation(invitation.url(scheme: "noodle-dev")))
        XCTAssertEqual(f.store.selectedSettingsTab, .companions)
        XCTAssertEqual(f.store.pendingHubInvitation, invitation.url(scheme: "noodle-dev").absoluteString)
    }

    func testOtherLinksAreNotInvitations() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        XCTAssertFalse(f.store.receiveHubInvitation(URL(string: "noodle://oauth/callback?code=1")!))
        XCTAssertNil(f.store.pendingHubInvitation)
    }

    func testJoinedHubsAreKeptWithNoodlesData() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        XCTAssertTrue(f.store.hubs.hubs.isEmpty)
        XCTAssertNil(f.store.hubs.joinError)
    }
}
