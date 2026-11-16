import NoodleCore
import XCTest

/// Pion says why an agent doesn't answer as Noodle does, and offers what brings it back.
@MainActor final class PauseTests: XCTestCase {
    func testASuspendedAgentShowsWhyAndOffersUnsuspendAndAGroupNamesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionPause-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        let group = try model.createGroup(name: "Triage", description: nil, members: [avery.id])
        XCTAssertNil(model.pause(of: direct))
        model.setSuspended(until: Date().addingTimeInterval(3_600), agent: avery)
        let pause = try XCTUnwrap(model.pause(of: try XCTUnwrap(model.conversation(direct.id))))
        XCTAssertTrue(pause.summary.hasPrefix("Suspended"))
        guard case .unsuspend(let agent)? = pause.action else { return XCTFail("Unsuspend") }
        XCTAssertEqual(agent.id, avery.id)
        XCTAssertEqual(model.pause(of: try XCTUnwrap(model.conversation(group.id)))?.summary, "Paused: Avery")
    }

    /// As in Noodle: an agent moved to another harness when its own ran out, or back again, says so in its conversation.
    func testAHarnessSwitchIsNotedInTheAgentsConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionPause-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        let onSwitch = try XCTUnwrap(model.runtime.onHarnessSwitch)
        onSwitch(avery.id, "Avery moved to Claude Code until Codex can be used again.")
        let notice = try XCTUnwrap(model.messages(in: direct.id).last)
        XCTAssertEqual(notice.author, .system)
        XCTAssertEqual(notice.body, "Avery moved to Claude Code until Codex can be used again.")
        XCTAssertFalse(model.isUnread(direct.id), "A notice leaves the conversation as read as it was")
    }
}
