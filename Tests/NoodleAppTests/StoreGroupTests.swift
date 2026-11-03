import Foundation
import HubLink
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

    func testPinnedConversationsLeaveTheirSectionAndPersistInPinOrder() throws {
        let f = try fixture(), group = try f.group(name: "Launch team")
        XCTAssertTrue(f.store.pinnedConversations.isEmpty)
        f.store.setPinned(true, conversationID: group.id)
        f.store.setPinned(true, conversationID: f.directB.id)
        XCTAssertEqual(f.store.pinnedConversations.map(\.id), [group.id, f.directB.id])
        XCTAssertEqual(f.store.directConversations.map(\.id), [f.directA.id])
        XCTAssertTrue(f.store.groupConversations.isEmpty)
        try f.repository.savePinnedConversationIDs(f.store.pinnedConversationIDs + [UUID()])
        f.store.reload()
        XCTAssertEqual(f.store.pinnedConversationIDs, [group.id, f.directB.id])
        XCTAssertEqual(try f.repository.loadPinnedConversationIDs(), [group.id, f.directB.id])
        f.store.setPinned(false, conversationID: group.id)
        XCTAssertEqual(f.store.pinnedConversations.map(\.id), [f.directB.id])
        XCTAssertEqual(f.store.groupConversations.map(\.id), [group.id])
        XCTAssertEqual(try f.repository.loadPinnedConversationIDs(), [f.directB.id])
    }

    /// A muted group leaves Unread and the Dock's count but keeps its dot, and stays muted after a reload.
    /// Bots' own conversations always notify.
    func testAMutedGroupLeavesUnreadAndTheDockCount() throws {
        let f = try fixture(), group = try f.group(name: "Launch team"), now = Date()
        XCTAssertTrue(f.store.canMute(group))
        XCTAssertFalse(f.store.canMute(f.directA))
        try f.repository.append(ChatMessage(conversationID: group.id, author: .agent(f.a.id), body: "Shipped",
                                            createdAt: now.addingTimeInterval(10), delivery: .delivered))
        try f.repository.append(ChatMessage(conversationID: f.directB.id, author: .agent(f.b.id), body: "Hello",
                                            createdAt: now.addingTimeInterval(20), delivery: .delivered))
        f.store.refreshTranscripts()
        XCTAssertEqual(f.store.badgedConversationIDs, [group.id, f.directB.id])

        f.store.setMuted(true, conversationID: group.id)
        XCTAssertTrue(f.store.isMuted(group.id))
        XCTAssertEqual(f.store.badgedConversationIDs, [f.directB.id])
        XCTAssertTrue(f.store.hasUnreadMessages(in: group), "Its row still shows new replies")
        let section = f.store.sidebarSections(.unreadSection)
        XCTAssertEqual(section.unread.map(\.id), [f.directB.id])
        XCTAssertEqual(section.groups.map(\.id), [group.id])
        f.store.setMuted(true, conversationID: f.directA.id)
        XCTAssertFalse(f.store.isMuted(f.directA.id))

        f.store.reload()
        XCTAssertTrue(f.store.isMuted(group.id))
        XCTAssertEqual(try f.repository.loadGroupNotifications().levels, [group.id: "muted"])
        f.store.setMuted(false, conversationID: group.id)
        XCTAssertEqual(f.store.badgedConversationIDs, [group.id, f.directB.id])
        XCTAssertEqual(try f.repository.loadGroupNotifications().levels, [:])
    }

    /// In Mentions only, a group's replies still show unread, but it counts on the Dock only once a reply names the
    /// person, by full name or first name, until it is read. Choosing it for all groups covers groups on the default,
    /// a group's own level wins, and it all stays after a reload. Bots' own conversations notify every reply.
    func testMentionsOnlyCountsOnlyRepliesNamingThePerson() throws {
        let f = try fixture(), group = try f.group(name: "Launch team"), now = Date()
        f.store.ownerName = { "Petko Petkov" }
        XCTAssertTrue(f.store.canNotifyMentions(group))
        XCTAssertFalse(f.store.canNotifyMentions(f.directA))
        let say = { (conversation: BotConversation, body: String, seconds: Double) in
            try f.repository.append(ChatMessage(conversationID: conversation.id, author: .agent(f.a.id), body: body,
                                                createdAt: now.addingTimeInterval(seconds), delivery: .delivered))
            f.store.refreshTranscripts()
        }
        f.store.groupNotifications = .mentions
        XCTAssertEqual(f.store.notifications(of: group.id), .mentions)
        XCTAssertEqual(f.store.notifications(of: f.directA.id), .all)
        try say(group, "Shipped. Petkov signed it, `petko` approved.", 10)
        try say(f.directA, "Hello", 20)
        XCTAssertTrue(f.store.hasUnreadMessages(in: group))
        XCTAssertEqual(f.store.sidebarSections(.unreadSection).unread.map(\.id).sorted { $0.uuidString < $1.uuidString },
                       [group.id, f.directA.id].sorted { $0.uuidString < $1.uuidString }, "Other replies still show unread")
        XCTAssertEqual(f.store.badgedConversationIDs, [f.directA.id])
        XCTAssertFalse(f.store.notifies(f.store.messages(for: group).last!))

        try say(group, "petko, can you check?", 30)
        XCTAssertTrue(f.store.notifies(f.store.messages(for: group).last!))
        XCTAssertEqual(f.store.badgedConversationIDs, [group.id, f.directA.id])
        f.store.reload()
        XCTAssertEqual(f.store.badgedConversationIDs, [group.id, f.directA.id], "The mention is kept")
        XCTAssertEqual(try f.repository.loadGroupNotifications().inGroups, "mentions")
        f.store.markConversationRead(group.id)
        try say(group, "Anyone?", 40)
        XCTAssertEqual(f.store.badgedConversationIDs, [f.directA.id], "Read, the mention is gone")

        f.store.setNotifications(.all, conversationID: group.id)
        XCTAssertEqual(f.store.chosenNotifications(of: group.id), .all)
        XCTAssertEqual(f.store.badgedConversationIDs, [group.id, f.directA.id], "The group's own level wins")
        f.store.setNotifications(.muted, conversationID: group.id)
        try say(group, "Petko Petkov, urgent!", 50)
        XCTAssertEqual(f.store.badgedConversationIDs, [f.directA.id], "Muted is silent even for a mention")
        XCTAssertFalse(f.store.notifies(f.store.messages(for: group).last!))
        f.store.setNotifications(.default, conversationID: group.id)
        XCTAssertNil(f.store.chosenNotifications(of: group.id))
        XCTAssertEqual(f.store.badgedConversationIDs, [group.id, f.directA.id])
        f.store.groupNotifications = .all
        XCTAssertEqual(try f.repository.loadGroupNotifications(), GroupNotificationSettings())
    }

    func testSectionsOrderByLastMessageNotByOtherChanges() throws {
        let f = try fixture(), now = Date()
        try f.repository.append(ChatMessage(conversationID: f.directA.id, author: .user, body: "Latest",
                                            createdAt: now.addingTimeInterval(60), delivery: .delivered))
        var edited = try XCTUnwrap(f.store.conversations.first { $0.id == f.directB.id })
        edited.updatedAt = now.addingTimeInterval(120)
        try f.repository.updateConversation(edited)
        f.store.refreshTranscripts()
        XCTAssertEqual(f.store.directConversations.map(\.id), [f.directA.id, f.directB.id])
    }

    func testConversationOrderMovesUnreadButNeverPins() throws {
        let f = try fixture(), third = try f.runtime.agent("Linus")
        f.store.reload()
        let directC = try XCTUnwrap(f.store.conversations.first { $0.participantIDs == [third.id] })
        let group = try f.group(), now = Date()
        f.store.setPinned(true, conversationID: f.directA.id)
        f.store.setPinned(true, conversationID: group.id)
        func append(_ conversation: BotConversation, _ author: MessageAuthor, after seconds: TimeInterval) throws {
            try f.repository.append(ChatMessage(conversationID: conversation.id, author: author, body: "Hello",
                                                createdAt: now.addingTimeInterval(seconds), delivery: .delivered))
        }
        try append(f.directB, .agent(f.b.id), after: 10)
        try append(directC, .user, after: 20)
        try append(group, .agent(f.a.id), after: 30)
        f.store.refreshTranscripts()
        XCTAssertEqual(f.store.unreadConversationIDs, [f.directB.id, group.id])

        let newest = f.store.sidebarSections(.newestFirst)
        XCTAssertEqual(newest.unread.map(\.id), [])
        XCTAssertEqual(newest.pinned.map(\.id), [f.directA.id, group.id])
        XCTAssertEqual(newest.bots.map(\.id), [directC.id, f.directB.id])
        let unreadFirst = f.store.sidebarSections(.unreadFirst)
        XCTAssertEqual(unreadFirst.pinned.map(\.id), [f.directA.id, group.id], "Pins keep their order")
        XCTAssertEqual(unreadFirst.bots.map(\.id), [f.directB.id, directC.id])
        let section = f.store.sidebarSections(.unreadSection)
        XCTAssertEqual(section.unread.map(\.id), [f.directB.id], "Pins stay pinned")
        XCTAssertEqual(section.pinned.map(\.id), [f.directA.id, group.id])
        XCTAssertEqual(section.bots.map(\.id), [directC.id])
        XCTAssertEqual(section.groups.map(\.id), [])
    }

    func testSearchListsBotsAndGroupsByNameAndEachMentionWithItsText() async throws {
        let f = try fixture(), group = try f.group(name: "Launch team", description: "Quarterly planning")
        f.store.setPinned(true, conversationID: group.id)
        f.store.mentionSearchDelay = .zero
        _ = try f.repository.sendUserMessage(conversationID: f.directB.id, body: "A **violet** notebook")
        _ = try f.repository.sendUserMessage(conversationID: f.directA.id, body: "Ask Grace first")
        f.store.refreshTranscripts()
        let cases: [(String, [UUID], [UUID])] = [
            ("launch", [], [group.id]), ("QUARTERLY", [], [group.id]), ("  Ada  ", [f.directA.id], [group.id]),
            ("violet", [], []), ("unknown word", [], [])
        ]
        for (query, bots, groups) in cases {
            f.store.searchText = query
            let search = try XCTUnwrap(f.store.sidebarSearch, query)
            XCTAssertEqual(search.bots.map(\.id), bots, query)
            XCTAssertEqual(search.groups.map(\.id), groups, query)
        }
        f.store.searchText = " \n "
        XCTAssertNil(f.store.sidebarSearch)

        // What was said is found off the main thread, with the words around it.
        f.store.searchText = "violet"
        XCTAssertEqual(f.store.sidebarSearch?.isFindingMentions, true)
        await f.store.mentionSearch?.value
        XCTAssertEqual(f.store.sidebarSearch?.mentions.map(\.snippet), ["A violet notebook"])
        XCTAssertEqual(f.store.sidebarSearch?.mentions.map(\.conversationID), [f.directB.id])
        XCTAssertEqual(f.store.sidebarSearch?.isFindingMentions, false)

        // Grace is a bot, so her mentions wait below her.
        f.store.searchText = "Grace"
        await f.store.mentionSearch?.value
        XCTAssertEqual(f.store.sidebarSearch?.bots.map(\.id), [f.directB.id])
        XCTAssertEqual(f.store.sidebarSearch?.mentions.map(\.conversationID), [f.directA.id])

        // The list itself stays as it is while searching.
        XCTAssertEqual(f.store.pinnedConversations.map(\.id), [group.id])
        XCTAssertEqual(Set(f.store.directConversations.map(\.id)), [f.directA.id, f.directB.id])
        XCTAssertEqual(f.store.preview(for: f.directB), "A violet notebook")
    }

    func testOnlyTheNewestMentionsShowBesideAMatchingNameUntilAllAreAsked() async throws {
        let f = try fixture()
        f.store.mentionSearchDelay = .zero
        for index in 1...5 { _ = try f.repository.sendUserMessage(conversationID: f.directA.id, body: "Grace \(index)") }
        f.store.refreshTranscripts()
        f.store.searchText = "Grace"
        await f.store.mentionSearch?.value
        XCTAssertEqual(f.store.sidebarSearch?.mentions.count, 3)
        XCTAssertEqual(f.store.sidebarSearch?.hiddenMentions, 2)
        f.store.showsAllMentions = true
        XCTAssertEqual(f.store.sidebarSearch?.mentions.count, 5)
        f.store.searchText = "Grac"
        XCTAssertFalse(f.store.showsAllMentions, "A new search starts short again")
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
