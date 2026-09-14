import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class StoreGroupTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    func testCreateGroupPersistsNormalizedDetailsAndSelectsIt() throws {
        let f = try fixture()
        f.store.creationSheet = .group
        let group = try f.group(name: "  Research  ", description: "  Shared notes\n")
        XCTAssertEqual(group.displayName, "Research")
        XCTAssertEqual(group.publicDescription, "Shared notes")
        XCTAssertEqual(Set(group.participantIDs), [f.a.id, f.b.id])
        XCTAssertNil(f.store.creationSheet)
        XCTAssertTrue(f.store.messages(for: group).isEmpty)
        let saved = try XCTUnwrap(f.repository.loadConversations().first { $0.id == group.id })
        XCTAssertEqual(saved.displayName, group.displayName)
        XCTAssertEqual(saved.publicDescription, group.publicDescription)
        XCTAssertEqual(saved.participantIDs, group.participantIDs)
        XCTAssertEqual(saved.createdAt.timeIntervalSince1970, group.createdAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(f.runtime.factory.processes.isEmpty, "Creating a group alone does not wake bots")
    }

    func testInvalidGroupCreationLeavesSelectionAndDraftIntact() throws {
        let f = try fixture()
        f.store.selectedConversationID = f.directA.id
        f.store.setDraft("Keep this draft", for: f.directA.id)
        let before = f.store.conversations
        for (name, participants) in [("", Set([f.a.id])), ("Valid", []), ("Unknown", [UUID()])] {
            XCTAssertFalse(f.store.createGroup(named: name, publicDescription: "", participantIDs: participants))
            XCTAssertNotNil(f.store.errorMessage)
            XCTAssertEqual(f.store.conversations, before)
            XCTAssertEqual(f.store.selectedConversationID, f.directA.id)
            XCTAssertEqual(f.store.draft(for: f.directA.id), "Keep this draft")
        }
        XCTAssertEqual(try f.repository.loadConversations(), before)
    }

    func testMembershipAndDescriptionChangesNotifyOnlyCurrentParticipants() throws {
        let f = try fixture(), group = try f.group([f.a.id])
        let first = try f.runtime.start(f.a), second = try f.runtime.start(f.b)
        XCTAssertTrue(f.store.updateGroup(group, named: "New project", publicDescription: "New purpose", participantIDs: [f.b.id]))
        let updated = try XCTUnwrap(f.store.conversations.first { $0.id == group.id })
        XCTAssertEqual(updated.participantIDs, [f.b.id])
        XCTAssertEqual(updated.publicDescription, "New purpose")
        XCTAssertTrue(first.notifications.isEmpty)
        XCTAssertEqual(second.notifications, [false])
        XCTAssertFalse(f.store.messages(for: updated).isEmpty)
        XCTAssertEqual(f.store.messages(for: updated), try f.repository.loadMessages(conversationID: group.id))
    }

    func testCosmeticRenameDoesNotWakeParticipants() throws {
        let f = try fixture(), group = try f.group()
        let first = try f.runtime.start(f.a), second = try f.runtime.start(f.b)
        f.store.groupBeingEdited = group
        XCTAssertTrue(f.store.updateGroup(group, named: "Renamed", publicDescription: "  Shared research  ", participantIDs: [f.a.id, f.b.id]))
        XCTAssertTrue(first.notifications.isEmpty)
        XCTAssertTrue(second.notifications.isEmpty)
        XCTAssertNil(f.store.groupBeingEdited)
        XCTAssertEqual(f.store.conversations.first { $0.id == group.id }?.displayName, "Renamed")
    }

    func testInvalidGroupEditPreservesDetailsMessagesAndEditor() throws {
        let f = try fixture(), group = try f.group()
        f.store.groupBeingEdited = group
        let before = f.store.messages(for: group)
        XCTAssertFalse(f.store.updateGroup(group, named: "New", publicDescription: "Changed", participantIDs: [UUID()]))
        XCTAssertNotNil(f.store.errorMessage)
        XCTAssertEqual(f.store.groupBeingEdited?.id, group.id)
        XCTAssertEqual(f.store.conversations.first { $0.id == group.id }, group)
        XCTAssertEqual(f.store.messages(for: group), before)
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)
    }

    func testDeletingGroupClearsItsDraftAndKeepsBotsAndOtherDrafts() throws {
        let f = try fixture(), group = try f.group()
        f.store.setDraft("Group draft", for: group.id)
        f.store.setDraft("Direct draft", for: f.directA.id)
        let first = try f.runtime.start(f.a), second = try f.runtime.start(f.b)
        XCTAssertTrue(f.store.delete(group))
        XCTAssertFalse(f.store.conversations.contains { $0.id == group.id })
        XCTAssertNotEqual(f.store.selectedConversationID, group.id)
        XCTAssertTrue(f.store.draft(for: group.id).isEmpty)
        XCTAssertEqual(f.store.draft(for: f.directA.id), "Direct draft")
        XCTAssertEqual(Set(f.store.agents.map(\.id)), [f.a.id, f.b.id])
        XCTAssertEqual(first.stops, 0)
        XCTAssertEqual(second.stops, 0)
    }

    func testDeletingBotRemovesItsDirectChatAndUpdatesGroupMembership() throws {
        let f = try fixture(), group = try f.group()
        let first = try f.runtime.start(f.a), second = try f.runtime.start(f.b)
        XCTAssertTrue(f.store.delete(f.directA))
        XCTAssertFalse(f.store.agents.contains { $0.id == f.a.id })
        XCTAssertFalse(f.store.conversations.contains { $0.id == f.directA.id })
        XCTAssertEqual(f.store.conversations.first { $0.id == group.id }?.participantIDs, [f.b.id])
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(second.stops, 0)
        XCTAssertEqual(try f.repository.loadAgents().map(\.id), [f.b.id])
    }

    func testSearchFindsTitlesDescriptionsParticipantsAndMessageContent() throws {
        let f = try fixture(), group = try f.group(name: "Launch team", description: "Quarterly planning")
        _ = try f.repository.sendUserMessage(conversationID: f.directB.id, body: "A **violet** notebook")
        f.store.refreshTranscripts()
        let cases: [(String, Set<UUID>)] = [
            ("launch", [group.id]), ("QUARTERLY", [group.id]), ("  Ada  ", [f.directA.id, group.id]),
            ("violet", [f.directB.id]), ("unknown word", []), (" \n ", Set(f.store.conversations.map(\.id)))
        ]
        for (query, expected) in cases {
            f.store.searchText = query
            XCTAssertEqual(Set(f.store.filteredConversations.map(\.id)), expected, query)
        }
        f.store.searchText = "Grace"
        XCTAssertEqual(f.store.directConversations.map(\.id), [f.directB.id])
        XCTAssertEqual(f.store.groupConversations.map(\.id), [group.id])
        XCTAssertEqual(f.store.preview(for: f.directA), "No messages yet")
        XCTAssertEqual(f.store.preview(for: f.directB), "A violet notebook")
    }
    func testFailedAddedMemberInboxWriteRollsBackEarlierWritesAndRetryPreservesHistoryBoundary() throws {
        let f = try fixture(), third = try f.runtime.agent("Linus")
        f.store.reload()
        let group = try f.group([f.a.id])
        let history = try f.repository.sendUserMessage(conversationID: group.id, body: "Existing group history")
        let added = [f.b, third].sorted { $0.id.uuidString < $1.id.uuidString }
        for agent in added { _ = try f.repository.latestMessages(for: agent.id) }
        let inboxes = added.map { f.repository.directory(for: $0).appendingPathComponent(".noodle/inbox.json") }
        let originals = try inboxes.map { try Data(contentsOf: $0) }
        let file = f.repository.conversationDirectory(id: group.id).appendingPathComponent("conversation.json")
        let metadata = try Data(contentsOf: file)
        let blocked = inboxes[1].deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let members = Set([f.a.id, f.b.id, third.id])
        XCTAssertFalse(f.store.updateGroup(group, named: "New name", publicDescription: "New context", participantIDs: members))
        XCTAssertEqual(try Data(contentsOf: file), metadata)
        XCTAssertEqual(try inboxes.map { try Data(contentsOf: $0) }, originals)
        XCTAssertEqual(try f.repository.loadMessages(conversationID: group.id).map(\.id), [history.id])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        XCTAssertTrue(f.store.updateGroup(group, named: "New name", publicDescription: "New context", participantIDs: members))
        let messages = try f.repository.loadMessages(conversationID: group.id)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?.author, .system)
        for agent in added {
            let inbox = try JSONDecoder().decode(AgentInbox.self, from: Data(contentsOf: f.repository.directory(for: agent).appendingPathComponent(".noodle/inbox.json")))
            XCTAssertEqual(inbox.conversationOffsets[group.id.uuidString.lowercased()], 1)
        }
    }

}
