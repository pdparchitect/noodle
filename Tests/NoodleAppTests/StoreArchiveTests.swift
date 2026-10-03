import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class StoreArchiveTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    func testAnArchivedBotNeverStartsHere() throws {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        let agent = try f.agent()
        f.runtime.archivedAgentIDs = [agent.id]
        f.runtime.startAll(agents: [agent], repository: f.repository)
        f.runtime.notify([agent], repository: f.repository)
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        f.runtime.startNewSession(agent: agent, repository: f.repository)
        XCTAssertTrue(f.factory.processes.isEmpty)
    }

    func testArchivingABotStopsItHidesItsChatAndKeepsEverything() throws {
        let f = try fixture(), group = try f.group()
        _ = try f.repository.sendUserMessage(conversationID: f.directA.id, body: "Keep this")
        f.store.refreshTranscripts()
        let ada = try f.runtime.start(f.a), grace = try f.runtime.start(f.b)

        XCTAssertTrue(f.store.setArchived(true, agentID: f.a.id))
        XCTAssertEqual(ada.stops, 1)
        XCTAssertEqual(grace.stops, 0)
        XCTAssertEqual(f.runtime.runtime.archivedAgentIDs, [f.a.id])
        XCTAssertTrue(f.store.isArchived(f.directA))
        XCTAssertFalse(f.store.isArchived(group))
        XCTAssertEqual(f.store.directConversations.map(\.id), [f.directB.id])
        XCTAssertEqual(f.store.groupConversations.map(\.id), [group.id])
        XCTAssertEqual(f.store.activeParticipants(for: group).map(\.id), [f.b.id])
        XCTAssertEqual(f.store.activeAgents.map(\.id), [f.b.id])
        XCTAssertEqual(f.store.participants(for: group).count, 2, "It is still a member")
        XCTAssertEqual(f.store.messages(for: f.directA).filter { $0.author == .user }.map(\.body), ["Keep this"])
        XCTAssertEqual(f.store.composerUnavailableReason(for: f.directA), "Ada is archived")
        XCTAssertNil(f.store.composerUnavailableReason(for: group))

        f.store.reload()
        XCTAssertTrue(f.store.isArchived(f.directA))
        XCTAssertEqual(f.runtime.runtime.archivedAgentIDs, [f.a.id])

        XCTAssertTrue(f.store.setArchived(false, agentID: f.a.id))
        XCTAssertTrue(f.runtime.runtime.archivedAgentIDs.isEmpty)
        XCTAssertEqual(Set(f.store.directConversations.map(\.id)), [f.directA.id, f.directB.id])
        XCTAssertNil(f.store.composerUnavailableReason(for: f.directA))
        XCTAssertNil(try f.repository.loadAgents().first { $0.id == f.a.id }?.archivedAt)
    }

    func testAGroupMessageSkipsItsArchivedBots() throws {
        let f = try fixture(), group = try f.group()
        let ada = try f.runtime.start(f.a), grace = try f.runtime.start(f.b)
        XCTAssertTrue(f.store.setArchived(true, agentID: f.a.id))
        f.store.setDraft("Hello team", for: group.id)
        f.store.sendDraft(to: group.id)
        XCTAssertTrue(ada.notifications.isEmpty)
        XCTAssertEqual(grace.notifications.count, 1)
        XCTAssertEqual(f.runtime.factory.processes.count, 2, "Nothing new started for Ada")

        XCTAssertTrue(f.store.setArchived(true, agentID: f.b.id))
        XCTAssertEqual(f.store.composerUnavailableReason(for: group), "Every bot in this group is archived")
    }

    func testArchivingAGroupHidesItAndKeepsItsBotsRunning() throws {
        let f = try fixture(), group = try f.group()
        let ada = try f.runtime.start(f.a)
        f.store.setPinned(true, conversationID: group.id)

        XCTAssertTrue(f.store.setArchived(true, conversationID: group.id))
        XCTAssertTrue(f.store.isArchived(group))
        XCTAssertTrue(f.store.groupConversations.isEmpty)
        XCTAssertTrue(f.store.pinnedConversations.isEmpty)
        XCTAssertEqual(Set(f.store.directConversations.map(\.id)), [f.directA.id, f.directB.id])
        XCTAssertEqual(f.store.archivedGroups.map(\.id), [group.id])
        XCTAssertEqual(ada.stops, 0)
        XCTAssertTrue(f.runtime.runtime.archivedAgentIDs.isEmpty)
        XCTAssertEqual(f.store.composerUnavailableReason(for: group), "This group is archived")

        f.store.searchText = "Project"
        XCTAssertTrue(f.store.filteredConversations.isEmpty)
        f.store.searchText = ""

        XCTAssertTrue(f.store.setArchived(false, conversationID: group.id))
        XCTAssertEqual(f.store.pinnedConversations.map(\.id), [group.id], "Unarchiving brings back its pin")
        XCTAssertTrue(f.store.archivedGroups.isEmpty)
    }
}
