import NoodleCore
import XCTest

/// Unread, as Noodle keeps it: a new message from an agent makes its conversation unread unless it is open, it
/// stays unread across launches until read, and a muted group does not count.
@MainActor final class UnreadTests: XCTestCase {
    func testNewMessagesAreUnreadUntilReadAndKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RookUnread-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RookModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        let group = try model.createGroup(name: "Quiet", description: nil, members: [avery.id])
        model.setNotifications(.muted, conversationID: group.id)
        model.selection = nil
        for id in [direct.id, group.id] {
            _ = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: id, body: "Contained.")
        }
        model.refresh()
        XCTAssertTrue(model.isUnread(direct.id))
        XCTAssertTrue(model.isUnread(group.id))
        XCTAssertTrue(model.countsAsUnread(direct.id))
        XCTAssertFalse(model.countsAsUnread(group.id), "A muted group is not shown as unread")

        // Reopens on the group: left to the latest activity, saved to the second, both messages often tie and the
        // direct conversation would open, and so be read, by chance.
        model.selection = group.id
        let reopened = RookModel(root: root, messenger: nil, isScripted: true)
        reopened.start()
        XCTAssertTrue(reopened.isUnread(direct.id), "Kept until read")
        reopened.markRead(direct.id)
        XCTAssertFalse(reopened.isUnread(direct.id))

        model.selection = group.id
        _ = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: group.id, body: "More.")
        model.refresh()
        XCTAssertFalse(model.isUnread(group.id), "An open conversation is read as messages arrive")
    }

    /// As in Noodle: a conversation deleted elsewhere leaves nothing unread behind, on disk too.
    func testADeletedConversationLeavesNoUnreadBehind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RookUnread-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RookModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        let group = try model.createGroup(name: "Gone", description: nil, members: [avery.id])
        model.selection = nil
        for id in [direct.id, group.id] {
            _ = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: id, body: "Avery Lin, look.")
        }
        model.refresh()
        try model.repository.deleteConversation(id: group.id)
        model.refresh()
        XCTAssertEqual(try model.repository.loadUnreadConversationIDs(), [direct.id])
        XCTAssertTrue(try model.repository.loadMentionedConversationIDs().isSubset(of: [direct.id]))
    }

    /// As in Noodle: what is on screen counts, a separate window included, not the main window's selection.
    func testArrivalsAreReadWhereTheyAreOnScreen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RookUnread-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RookModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        let group = try model.createGroup(name: "Watch", description: nil, members: [avery.id])
        model.selection = direct.id
        // The group is in a window of its own; Rook is in the background, so the main window shows nothing.
        model.isViewing = { $0 == group.id }
        for id in [direct.id, group.id] {
            _ = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: id, body: "Contained.")
        }
        model.refresh()
        XCTAssertTrue(model.unread.unread.contains(direct.id), "Selected but not on screen")
        XCTAssertTrue(model.isUnread(direct.id), "Its row is marked, as in Noodle")
        XCTAssertEqual(model.badgedConversationIDs, [direct.id], "and the Dock counts it")
        XCTAssertFalse(model.isUnread(group.id), "On screen in its own window")
    }

    /// As in Noodle: the app's own notices, such as a new lead, leave a conversation as read as it was.
    func testNoticesDoNotMakeAConversationUnread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RookUnread-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RookModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let group = try model.createGroup(name: "Watch", description: nil, members: [avery.id])
        model.markRead(group.id)
        model.selection = nil
        model.setLead(avery.id, of: group)
        XCTAssertTrue(model.messages(in: group.id).contains { $0.author == .system }, "The lead is announced")
        XCTAssertFalse(model.isUnread(group.id))
    }

    /// As in Noodle: a transcript rewritten within the same second is still read again, by its size.
    func testATranscriptChangedWithinTheSameSecondIsRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RookUnread-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RookModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        let file = model.repository.conversationDirectory(id: direct.id).appendingPathComponent("messages.json")
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: direct.id, body: "One.")
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        model.refresh()
        _ = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: direct.id, body: "Two.")
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        model.refresh()
        XCTAssertEqual(model.messages(in: direct.id).last?.body, "Two.")
    }
}
