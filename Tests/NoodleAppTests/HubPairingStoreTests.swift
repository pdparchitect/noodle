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
        joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date().addingTimeInterval(600))

    func testInvitationLinksOpenCompanionsReadyToJoin() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        XCTAssertTrue(f.store.receiveHubInvitation(invitation.url(scheme: "noodle-dev")))
        XCTAssertEqual(f.store.selectedSettingsTab, .hub)
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

/// All shows every bot and group with this Mac's own pins; a joined Hub's space shows only that Hub's, with the pins it keeps.
@MainActor final class SpaceStoreTests: XCTestCase {
    func testAHubsSpaceShowsItsBotsAndPins() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey) }
        // Pretend Fixture bot A is on a joined Hub, pinned there, while bot B stays on this Mac, pinned here.
        let folder = f.repository.rootURL.appendingPathComponent("Hubs/\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hub: [String: Any] = ["name": "Mac mini", "key": LinkIdentity().publicKey.x963.base64EncodedString(),
                                  "endpoints": [], "userName": "Ada"]
        try JSONSerialization.data(withJSONObject: hub).write(to: folder.appendingPathComponent("hub.json"))
        let entry: [String: Any] = ["remote": UUID().uuidString, "remoteConversation": UUID().uuidString,
                                    "agent": f.a.id.uuidString, "conversation": f.directA.id.uuidString, "synced": 0,
                                    "pinnedAt": 0]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: folder.appendingPathComponent("mirror.json"))
        try f.repository.savePinnedConversationIDs([f.directB.id])
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        let mirror = try XCTUnwrap(store.hubMirror(forAgent: f.a.id))

        XCTAssertNil(store.spaceMirror)
        XCTAssertEqual(Set(store.filteredConversations.map(\.id)), [f.directA.id, f.directB.id])
        XCTAssertEqual(store.pinnedConversations.map(\.id), [f.directB.id])
        XCTAssertEqual(store.directConversations.map(\.id), [f.directA.id])

        store.showSpace(mirror)
        XCTAssertEqual(store.filteredConversations.map(\.id), [f.directA.id])
        XCTAssertEqual(store.pinnedConversations.map(\.id), [f.directA.id])
        XCTAssertTrue(store.isPinned(f.directA.id))
        XCTAssertTrue(store.directConversations.isEmpty)

        // Kept for the next launch.
        let again = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        XCTAssertTrue(again.spaceMirror === again.hubMirror(forAgent: f.a.id))
        again.showSpace(nil)
        XCTAssertEqual(again.pinnedConversations.map(\.id), [f.directB.id])
    }
}

/// A bot kept on a Hub uses only the Hub's tools, never this Mac's.
@MainActor final class HubBotAssignmentTests: XCTestCase {
    /// A bot someone shared on a Hub is only talked with: Settings > Bots leaves it out and groups never offer it.
    func testABotSharedOnAHubIsOnlyTalkedWith() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        // Pretend Fixture bot A is this Mac's user's on a joined Hub, and bot B someone shared there.
        let folder = f.repository.rootURL.appendingPathComponent("Hubs/\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hub: [String: Any] = ["name": "Mac mini", "key": LinkIdentity().publicKey.x963.base64EncodedString(),
                                  "endpoints": [], "userName": "Ada"]
        try JSONSerialization.data(withJSONObject: hub).write(to: folder.appendingPathComponent("hub.json"))
        let own: [String: Any] = ["remote": UUID().uuidString, "remoteConversation": UUID().uuidString,
                                  "agent": f.a.id.uuidString, "conversation": f.directA.id.uuidString, "synced": 0]
        let shared: [String: Any] = ["remote": UUID().uuidString, "remoteConversation": UUID().uuidString,
                                     "agent": f.b.id.uuidString, "conversation": f.directB.id.uuidString, "synced": 0,
                                     "owner": "Bea"]
        try JSONSerialization.data(withJSONObject: [own, shared]).write(to: folder.appendingPathComponent("mirror.json"))
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        let mirror = try XCTUnwrap(store.hubMirror(forAgent: f.b.id))

        XCTAssertFalse(store.isShared(f.a.id))
        XCTAssertTrue(store.isShared(f.b.id))
        XCTAssertEqual(store.groupCandidates(on: mirror).map(\.id), [f.a.id])
        XCTAssertEqual(store.configurableAgents.map(\.id), [f.a.id])
    }

    /// A bot of this Mac's user's kept on a Hub runs there, so there is no activity or workspace here to show.
    func testABotOnAHubDoesNotRunHere() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        // Pretend Fixture bot A was made on a joined Hub, while bot B stays on this Mac.
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

        XCTAssertFalse(store.runsHere(f.a.id))
        XCTAssertTrue(store.runsHere(f.b.id))
    }

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
