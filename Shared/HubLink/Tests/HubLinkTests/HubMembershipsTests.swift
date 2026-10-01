import Foundation
@testable import HubLink
import XCTest

/// Any web page or app can open an invitation link, so one opened that way joins only once confirmed.
@MainActor final class HubMembershipsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HubMembershipsTests-\(UUID())", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func invitation(expires: Date) -> LinkInvitation {
        LinkInvitation(hubName: "Mac mini", hubKey: LinkIdentity().publicKey,
                       endpoints: [LinkEndpoint(host: "Mac-mini.local", port: 38_415)], userName: "Ada",
                       joinKey: LinkIdentity().privateKey.rawRepresentation, expires: expires)
    }

    func testAnOpenedLinkWaitsWithTheHubsKeyUntilConfirmed() {
        let invitation = invitation(expires: Date().addingTimeInterval(600))
        let hubs = HubMemberships(directory: directory, deviceName: "Phone")
        hubs.offer(invitation.url().absoluteString)
        XCTAssertEqual(hubs.offered?.hubKey.fingerprint, invitation.hubKey.fingerprint)
        XCTAssertTrue(hubs.hubs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        hubs.declineOffered()
        XCTAssertNil(hubs.offered)
        XCTAssertTrue(hubs.hubs.isEmpty)
    }

    func testAJoinThatReachesNoHubKeepsItsInvitationForTroubleshooting() async {
        var unreachable = invitation(expires: Date().addingTimeInterval(600))
        unreachable.endpoints = []
        let hubs = HubMemberships(directory: directory, deviceName: "Phone")
        await hubs.join(unreachable.url().absoluteString)
        XCTAssertEqual(hubs.unreachableInvitation?.hubKey, unreachable.hubKey)
        XCTAssertTrue(hubs.hubs.isEmpty)
        hubs.clearJoinError()
        XCTAssertNil(hubs.unreachableInvitation)
    }

    func testAnExpiredInvitationIsNotATroubleReachingTheHub() async {
        let hubs = HubMemberships(directory: directory, deviceName: "Phone")
        await hubs.join(invitation(expires: Date().addingTimeInterval(-60)).url().absoluteString)
        XCTAssertNotNil(hubs.joinError)
        XCTAssertNil(hubs.unreachableInvitation)
    }

    func testACancelledJoinLeavesNoProblemBehind() async throws {
        var silent = invitation(expires: Date().addingTimeInterval(600))
        let server = try LinkServer(identity: LinkIdentity(), port: 0, admits: { _ in true }) { _, _ in .response(Data()) }
        try await server.start()
        silent.endpoints = [LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))]
        server.stop()
        let hubs = HubMemberships(directory: directory, deviceName: "Phone")
        let joining = Task { await hubs.join(silent.url().absoluteString) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(hubs.joining?.hubName, "Mac mini")
        let started = Date()
        hubs.cancelJoin()
        await joining.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNil(hubs.joining)
        XCTAssertNil(hubs.joinError)
        XCTAssertNil(hubs.unreachableInvitation)
        XCTAssertTrue(hubs.hubs.isEmpty)
    }

    func testABrokenLinkIsNotOffered() {
        let hubs = HubMemberships(directory: directory, deviceName: "Phone")
        hubs.offer("noodle://join-hub?i=bm90IGpzb24")
        XCTAssertNil(hubs.offered)
        XCTAssertNotNil(hubs.joinError)
    }
}
