import Foundation
import HubLink
import NoodleHubClient
@testable import Noodle
import NoodleCore
@testable import NoodleRuntimeSettings
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

final class HubHarnessChoiceTests: XCTestCase {
    /// The bot editor keeps a Hub harness in the same string as a local one.
    func testAHubHarnessSurvivesTheEditorsSelection() throws {
        let hub = LinkIdentity().publicKey
        let profile = UUID()
        let choice = HubHarnessChoice(hub: hub, provider: "claude-code", profile: profile)
        XCTAssertEqual(HubHarnessChoice(identifier: choice.identifier), choice)
        let system = HubHarnessChoice(hub: hub, provider: "codex", profile: nil)
        XCTAssertEqual(HubHarnessChoice(identifier: system.identifier), system)
        XCTAssertNil(HubHarnessChoice(identifier: "claude-code"))
    }
}

/// A bot kept on a Hub uses only the Hub's tools, never this Mac's.
@MainActor final class HubBotAssignmentTests: XCTestCase {
    func testThisMacsToolsAreNotGivenToAHubBot() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        // Pretend Fixture bot A was made on a joined Hub.
        let folder = f.repository.rootURL.appendingPathComponent("Hubs/\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hub: [String: Any] = ["name": "Mac mini", "key": LinkIdentity().publicKey.x963.base64EncodedString(),
                                  "endpoints": [], "userName": "Ada"]
        try JSONSerialization.data(withJSONObject: hub).write(to: folder.appendingPathComponent("hub.json"))
        let entry: [String: Any] = ["remote": UUID().uuidString, "remoteConversation": UUID().uuidString,
                                    "agent": f.a.id.uuidString, "conversation": f.directA.id.uuidString, "synced": 0]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: folder.appendingPathComponent("mirror.json"))
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        XCTAssertNotNil(store.hubMirror(forAgent: f.a.id))

        let account = try MCPConnectionRecord(name: "Fixture account", endpoint: URL(string: "https://example.com/mcp")!)
        try store.mcp.save(account)
        XCTAssertTrue(store.updateAgent(f.a, name: f.a.displayName, harnessIdentifier: f.a.harnessIdentifier ?? "",
                                        modelIdentifier: nil, reasoningEffort: nil, avatarSymbolName: nil, avatarColorIndex: 0,
                                        avatarImageData: nil, publicDescription: "", backstory: "",
                                        mcpConnectionIDs: [account.id]))
        XCTAssertEqual(store.mcp.selectedIDs(for: f.a), [])
    }
}
