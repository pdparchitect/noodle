import NoodleCore
import XCTest

/// Deleting, as in Noodle: an agent goes with its workspace and its own conversation and leaves every group;
/// a group goes with its messages, and its agents stay.
@MainActor final class DeleteTests: XCTestCase {
    func testDeletingAnAgentOrAGroup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionDelete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let morgan = try model.createAgent(name: "Morgan", description: nil, instructions: "", provider: .codex, model: nil)
        let group = try model.createGroup(name: "Triage", description: nil, members: [avery.id, morgan.id])
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        model.selection = direct.id

        XCTAssertTrue(model.delete(direct))
        XCTAssertNil(model.agent(avery.id))
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.conversation(group.id)?.participantIDs, [morgan.id])

        XCTAssertTrue(model.delete(try XCTUnwrap(model.conversation(group.id))))
        XCTAssertNil(model.conversation(group.id))
        XCTAssertNotNil(model.agent(morgan.id))
    }

    /// As in Noodle: an archived agent, which Settings still lists, can be deleted with its workspace and conversation.
    func testAnArchivedAgentCanBeDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionDelete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        model.setArchived(true, agentID: avery.id)
        XCTAssertTrue(model.delete(agent: avery))
        XCTAssertFalse(model.everyAgent.contains { $0.id == avery.id })
        XCTAssertFalse(model.everyConversation.contains { $0.id == direct.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.repository.directory(for: avery).path))
    }

    /// As in Noodle: a deleted group's own notification level and pin go with it, kept only while it was there;
    /// an archived group keeps both, since it can come back.
    func testADeletedGroupLeavesNoLevelOrPinBehind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionDelete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let gone = try model.createGroup(name: "Gone", description: nil, members: [avery.id])
        let kept = try model.createGroup(name: "Kept", description: nil, members: [avery.id])
        for group in [gone, kept] {
            model.setNotifications(.muted, conversationID: group.id)
            model.setPinned(true, conversationID: group.id)
        }
        model.setGroupArchived(true, id: kept.id)
        // Deleted elsewhere, as by an agent or another Pion, so only what is stored is left to tidy.
        try model.repository.deleteConversation(id: gone.id)
        model.refresh()

        XCTAssertEqual(Array(try model.repository.loadGroupNotifications().levels.keys), [kept.id])
        XCTAssertEqual(try model.repository.loadPinnedConversationIDs(), [kept.id])
        model.setGroupArchived(false, id: kept.id)
        XCTAssertEqual(model.pinnedIDs, [kept.id], "An archived group keeps its pin")
        XCTAssertEqual(model.notifications(of: kept.id), .muted)
    }
}
