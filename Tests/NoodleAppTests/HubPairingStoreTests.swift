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

/// A space the person makes gathers bots and groups from any Hub and this Mac, with pins of its own.
@MainActor final class CustomSpaceStoreTests: XCTestCase {
    func testACustomSpaceGathersBotsFromAnywhereWithItsOwnPins() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey) }
        // Pretend Fixture bot A is on a joined Hub, while bot B stays on this Mac.
        let folder = f.repository.rootURL.appendingPathComponent("Hubs/\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = LinkIdentity().publicKey.x963.base64EncodedString()
        let hub: [String: Any] = ["name": "Mac mini", "key": key, "endpoints": [], "userName": "Ada"]
        try JSONSerialization.data(withJSONObject: hub).write(to: folder.appendingPathComponent("hub.json"))
        let remote = UUID()
        let entry: [String: Any] = ["remote": UUID().uuidString, "remoteConversation": remote.uuidString,
                                    "agent": f.a.id.uuidString, "conversation": f.directA.id.uuidString, "synced": 0]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: folder.appendingPathComponent("mirror.json"))
        // One member is on a Hub this Mac has left; it stays in the space for when it is joined again.
        let away = CustomSpace.Member(hub: LinkIdentity().publicKey.x963.base64EncodedString(), conversation: UUID())
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        // As before this Mac served any device.
        store.thisMac.key = nil

        let space = try XCTUnwrap(store.addSpace(named: "Work"))
        XCTAssertEqual(store.shownCustomSpace?.id, space.id)
        XCTAssertTrue(store.filteredConversations.isEmpty)

        store.setMember(true, of: space.id, conversationID: f.directA.id)
        store.setMember(true, of: space.id, conversationID: f.directB.id)
        XCTAssertEqual(Set(store.filteredConversations.map(\.id)), [f.directA.id, f.directB.id])
        XCTAssertTrue(store.isMember(f.directA.id, of: space.id))
        // Named as every device knows them: a Hub bot by its Hub and conversation there, this Mac's own by its ID here.
        XCTAssertEqual(SpaceList(file: f.repository.rootURL.appendingPathComponent("spaces.json")).spaces.first?.members,
                       [CustomSpace.Member(hub: key, conversation: remote), CustomSpace.Member(hub: nil, conversation: f.directB.id)])

        store.setPinned(true, conversationID: f.directB.id)
        store.setPinned(true, conversationID: f.directA.id)
        XCTAssertEqual(store.pinnedConversations.map(\.id), [f.directB.id, f.directA.id])
        XCTAssertTrue(store.directConversations.isEmpty)
        // All's pins are untouched.
        XCTAssertEqual(try f.repository.loadPinnedConversationIDs(), [])

        try SpaceList(file: f.repository.rootURL.appendingPathComponent("spaces.json")).setMember(true, away, of: space.id)
        store.reload()
        store.renameSpace(space.id, to: "Projects")

        // Leaving the space drops its pin there too.
        store.setMember(false, of: space.id, conversationID: f.directB.id)
        XCTAssertEqual(store.filteredConversations.map(\.id), [f.directA.id])
        XCTAssertEqual(store.pinnedConversations.map(\.id), [f.directA.id])

        // Kept for the next launch, with the unreachable member still there.
        let again = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        XCTAssertEqual(again.shownCustomSpace?.name, "Projects")
        XCTAssertEqual(again.shownCustomSpace?.members, [CustomSpace.Member(hub: key, conversation: remote), away])
        XCTAssertEqual(again.pinnedConversations.map(\.id), [f.directA.id])
        XCTAssertNil(again.spaceMirror)

        again.deleteSpace(space.id)
        XCTAssertNil(again.shownCustomSpace)
        XCTAssertTrue(again.customSpaces.isEmpty)
        XCTAssertEqual(Set(again.filteredConversations.map(\.id)), [f.directA.id, f.directB.id])
    }

    /// Once this Mac has served its owner's devices, they name its bots by its key, so spaces here do too.
    func testThisMacsBotsAreNamedAsItsDevicesNameThem() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey) }
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        store.thisMac.key = "this-mac"
        let space = try XCTUnwrap(store.addSpace(named: "Work"))
        // Added on the phone, and before this Mac served any device.
        try store.spaceList.setMember(true, CustomSpace.Member(hub: "this-mac", conversation: f.directA.id), of: space.id)
        try store.spaceList.setMember(true, CustomSpace.Member(hub: nil, conversation: f.directB.id), of: space.id)
        XCTAssertEqual(Set(store.filteredConversations.map(\.id)), [f.directA.id, f.directB.id])
        XCTAssertTrue(store.isMember(f.directB.id, of: space.id))

        store.setPinned(true, conversationID: f.directB.id)
        XCTAssertEqual(store.pinnedConversations.map(\.id), [f.directB.id])
        store.setMember(false, of: space.id, conversationID: f.directB.id)
        store.setMember(false, of: space.id, conversationID: f.directA.id)
        XCTAssertEqual(store.shownCustomSpace?.members, [])
        XCTAssertEqual(store.shownCustomSpace?.pins, [])

        store.setMember(true, of: space.id, conversationID: f.directB.id)
        XCTAssertEqual(store.shownCustomSpace?.members, [CustomSpace.Member(hub: "this-mac", conversation: f.directB.id)])
    }

    /// A space deleted on another device while shown here leaves All shown, and the Spaces menu says so.
    func testASpaceDeletedElsewhereLeavesAll() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey) }
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        let space = try XCTUnwrap(store.addSpace(named: "Work"))
        XCTAssertFalse(store.isShowingAll)
        store.spaceList.applyRemote(saved: [], deleted: [space.id])
        XCTAssertTrue(store.isShowingAll)
        XCTAssertEqual(Set(store.filteredConversations.map(\.id)), [f.directA.id, f.directB.id])
    }

    /// A bot or group made while a space is shown joins it, so it appears there.
    func testNewGroupsJoinTheShownSpace() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey) }
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        let space = try XCTUnwrap(store.addSpace(named: "Work"))

        XCTAssertTrue(store.createGroup(named: "Team", publicDescription: "", participantIDs: [f.a.id]))
        let group = try XCTUnwrap(store.selectedConversationID)
        XCTAssertTrue(store.isMember(group, of: space.id))
        XCTAssertEqual(store.filteredConversations.map(\.id), [group])
    }
}

/// This Mac's space shows only the bots and groups kept here, with All's pins, which are this Mac's own.
@MainActor final class ThisMacSpaceTests: XCTestCase {
    func testThisMacsSpaceLeavesOutTheHubs() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey) }
        // Pretend Fixture bot A is on a joined Hub, while bot B stays on this Mac.
        let folder = f.repository.rootURL.appendingPathComponent("Hubs/\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hub: [String: Any] = ["name": "Mac mini", "key": LinkIdentity().publicKey.x963.base64EncodedString(),
                                  "endpoints": [], "userName": "Ada"]
        try JSONSerialization.data(withJSONObject: hub).write(to: folder.appendingPathComponent("hub.json"))
        let entry: [String: Any] = ["remote": UUID().uuidString, "remoteConversation": UUID().uuidString,
                                    "agent": f.a.id.uuidString, "conversation": f.directA.id.uuidString, "synced": 0]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: folder.appendingPathComponent("mirror.json"))
        try f.repository.savePinnedConversationIDs([f.directB.id, f.directA.id])
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)

        store.showThisMac()
        XCTAssertTrue(store.showsThisMac)
        XCTAssertFalse(store.isShowingAll)
        XCTAssertEqual(store.filteredConversations.map(\.id), [f.directB.id])
        XCTAssertEqual(store.pinnedConversations.map(\.id), [f.directB.id])
        store.setPinned(false, conversationID: f.directB.id)
        XCTAssertEqual(try f.repository.loadPinnedConversationIDs(), [f.directA.id])
        XCTAssertNil(store.spaceHarnessIdentifier)

        // Kept for the next launch; with no Hub joined it is the same as All, which shows instead.
        XCTAssertTrue(NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false).showsThisMac)
        try FileManager.default.removeItem(at: folder)
        let alone = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        XCTAssertFalse(alone.showsThisMac)
        XCTAssertTrue(alone.isShowingAll)
    }
}

/// New bots and groups start on the Hub whose space is shown, so they appear there; the person can still choose another place.
@MainActor final class SpaceCreationTests: XCTestCase {
    func testNewBotsAndGroupsStartOnTheShownHub() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: NoodleStore.spaceKey) }
        // Pretend Fixture bot A is on a joined Hub that lends Codex; bot B stays on this Mac.
        let folder = f.repository.rootURL.appendingPathComponent("Hubs/\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = LinkIdentity().publicKey
        let hub: [String: Any] = ["name": "Mac mini", "key": key.x963.base64EncodedString(), "endpoints": [], "userName": "Ada"]
        try JSONSerialization.data(withJSONObject: hub).write(to: folder.appendingPathComponent("hub.json"))
        let status = LinkStatus(hubName: "Mac mini", userName: "Ada", planName: "Family",
                                harnesses: [LinkHarness(provider: "codex", providerName: "Codex", profileName: nil)], endpoints: [])
        try JSONEncoder().encode(status).write(to: folder.appendingPathComponent("status.json"))
        let entry: [String: Any] = ["remote": UUID().uuidString, "remoteConversation": UUID().uuidString,
                                    "agent": f.a.id.uuidString, "conversation": f.directA.id.uuidString, "synced": 0]
        try JSONSerialization.data(withJSONObject: [entry]).write(to: folder.appendingPathComponent("mirror.json"))
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        let mirror = try XCTUnwrap(store.hubMirror(forAgent: f.a.id))

        XCTAssertNil(store.spaceHarnessIdentifier)
        XCTAssertNil(store.groupCreationHub(participantIDs: []))

        store.showSpace(mirror)
        XCTAssertEqual(store.spaceHarnessIdentifier, HubHarnessChoice(hub: key, provider: "codex", profile: nil).identifier)
        XCTAssertTrue(store.groupCreationHub(participantIDs: []) === mirror)
        XCTAssertTrue(store.groupCreationHub(participantIDs: [f.a.id]) === mirror)
        // A group started from this Mac's bot stays on this Mac.
        XCTAssertNil(store.groupCreationHub(participantIDs: [f.b.id]))
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

    /// A bot here shared through a Hub talks with people there in conversations this Mac keeps for it,
    /// which are theirs: none shows here, however the conversations are read again, and the bot still runs here.
    func testConversationsOfPeopleABotIsSharedWithAreNotShownHere() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        let guest = try f.repository.createGuestConversation(with: f.a, guest: ConversationGuest(id: UUID(), name: "Grace"))
        _ = try f.repository.sendUserMessage(conversationID: guest.id, body: "Hello")
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        XCTAssertFalse(store.conversations.contains { $0.id == guest.id })
        XCTAssertNil(store.messagesByConversation[guest.id])
        store.refreshTranscripts()
        XCTAssertFalse(store.conversations.contains { $0.id == guest.id })
        XCTAssertTrue(store.conversations.contains { $0.id == f.directA.id })
        XCTAssertTrue(store.runsHere(f.a.id))
    }

    /// A bot here can be shared through every joined Hub whose people may share bots; a bot kept on a Hub cannot.
    func testABotHereIsSharedThroughEveryHubThatLetsItsPeopleShare() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        func join(_ name: String, canShareBots: Bool) throws {
            let folder = f.repository.rootURL.appendingPathComponent("Hubs/\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let hub: [String: Any] = ["name": name, "key": LinkIdentity().publicKey.x963.base64EncodedString(),
                                      "endpoints": [], "userName": "Ada"]
            try JSONSerialization.data(withJSONObject: hub).write(to: folder.appendingPathComponent("hub.json"))
            try JSONEncoder().encode(LinkStatus(hubName: name, userName: "Ada", planName: "", harnesses: [], endpoints: [],
                                                canShareBots: canShareBots))
                .write(to: folder.appendingPathComponent("status.json"))
        }
        try join("Mac mini", canShareBots: true)
        try join("Studio", canShareBots: true)
        try join("Laptop", canShareBots: false)
        let store = NoodleStore(repository: f.repository, runtime: f.runtime.runtime, connectsServices: false)
        XCTAssertEqual(Set(store.sharingHubs(forLocalAgent: f.a.id).compactMap(\.pairing.hub?.name)), ["Mac mini", "Studio"])
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
