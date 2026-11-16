import NoodleCore
import XCTest

/// As in Noodle, the message field says why nothing can be sent: the agent, or every agent of a group, is archived.
@MainActor final class ComposerAvailabilityTests: XCTestCase {
    func testArchivedAgentsSayWhyTheMessageFieldIsOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionComposer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let group = try model.createGroup(name: "Triage", description: nil, members: [avery.id])
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        XCTAssertNil(model.composerUnavailableReason(for: direct))
        XCTAssertNil(model.composerUnavailableReason(for: group))

        _ = try model.repository.setAgentArchived(true, agentID: avery.id)
        model.reload()
        XCTAssertEqual(model.composerUnavailableReason(for: direct), "Avery is archived")
        XCTAssertEqual(model.composerUnavailableReason(for: try XCTUnwrap(model.conversation(group.id))),
                       "Every agent in this group is archived")
    }
}
