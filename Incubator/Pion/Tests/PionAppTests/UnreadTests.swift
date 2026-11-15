import NoodleCore
import XCTest

/// Unread, as Noodle keeps it: a new message from an agent makes its conversation unread unless it is open, it
/// stays unread across launches until read, and a muted group does not count.
@MainActor final class UnreadTests: XCTestCase {
    func testNewMessagesAreUnreadUntilReadAndKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionUnread-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
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

        let reopened = PionModel(root: root, messenger: nil, isScripted: true)
        reopened.start()
        XCTAssertTrue(reopened.isUnread(direct.id), "Kept until read")
        reopened.markRead(direct.id)
        XCTAssertFalse(reopened.isUnread(direct.id))

        model.selection = group.id
        _ = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: group.id, body: "More.")
        model.refresh()
        XCTAssertFalse(model.isUnread(group.id), "An open conversation is read as messages arrive")
    }
}
