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
}
