import NoodleCore
import XCTest

/// The champion reacts to messages as in Noodle, and sees the change at once.
@MainActor final class ReactionTests: XCTestCase {
    func testReactingTogglesChangesAndRemovesAndShowsAtOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionReact-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let agent = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: agent))
        let sent = try model.repository.sendAgentMessage(agentID: agent.id, conversationID: direct.id, body: "Contained.")
        model.refresh()
        func mine() -> [String] { (model.messages(in: direct.id).first { $0.id == sent.id }?.reactions ?? []).map(\.emoji) }
        model.toggleReaction("👍", on: sent)
        XCTAssertEqual(mine(), ["👍"])
        model.changeReaction("👍", to: "✅", on: sent)
        XCTAssertEqual(mine(), ["✅"])
        model.removeReaction("✅", on: sent)
        XCTAssertEqual(mine(), [])
    }
}
