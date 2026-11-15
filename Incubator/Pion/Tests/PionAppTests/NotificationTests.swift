import HubLink
import NoodleCore
import XCTest

/// Which agent replies notify the champion, as in Noodle: every reply in an agent's own conversation, and in groups
/// as set for all groups or for that group alone.
@MainActor final class NotificationTests: XCTestCase {
    private var root: URL!
    private var model: PionModel!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PionNotifications-\(UUID())")
        model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
    }

    override func tearDownWithError() throws {
        model = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func reply(_ body: String, from agent: AgentRecord, in conversation: UUID) -> ChatMessage {
        ChatMessage(conversationID: conversation, author: .agent(agent.id), body: body, delivery: .delivered)
    }

    func testGroupsNotifyAsSetForAllGroupsOrForThemselves() throws {
        let avery = try model.createAgent(name: "Avery", description: "", instructions: "", provider: .codex, model: nil,
                                          effort: nil, symbol: "shield", color: 1)
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        let group = try model.createGroup(name: "Triage", description: "", members: [avery.id])
        let plain = reply("Done.", from: avery, in: group.id)
        let naming = reply("Done, \(model.champion).", from: avery, in: group.id)

        XCTAssertEqual(model.groupNotifications, .all)
        XCTAssertTrue(model.notifies(plain))

        model.groupNotifications = .mentions
        XCTAssertFalse(model.notifies(plain))
        XCTAssertTrue(model.notifies(naming))
        XCTAssertTrue(model.notifies(reply("Done.", from: avery, in: direct.id)), "An agent's own conversation always notifies")

        model.setNotifications(.all, conversationID: group.id)
        XCTAssertEqual(model.chosenNotifications(of: group.id), .all)
        XCTAssertTrue(model.notifies(plain))

        var withdrawn: [UUID] = []
        model.onNotificationsNarrowed = { withdrawn.append($0) }
        model.setNotifications(.muted, conversationID: group.id)
        XCTAssertFalse(model.notifies(naming))
        XCTAssertEqual(withdrawn, [group.id], "A group that goes quiet takes back what it showed")

        // Kept where Noodle keeps it, so it lasts.
        let reopened = PionModel(root: root, messenger: nil, isScripted: true)
        reopened.start()
        XCTAssertEqual(reopened.groupNotifications, .mentions)
        XCTAssertEqual(reopened.chosenNotifications(of: group.id), .muted)
        model.setNotifications(.default, conversationID: group.id)
        XCTAssertNil(model.chosenNotifications(of: group.id))
    }
}
