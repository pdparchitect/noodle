import NoodleCore
import XCTest

/// A call hears what the champion sends in its conversation, as Noodle's does, through the model's hook.
@MainActor final class CallHookTests: XCTestCase {
    func testSentMessagesReachTheCallHookWithTheirFilesNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RookCalls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RookModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let agent = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: agent))
        var heard: [(UUID, String, [String])] = []
        model.onSent = { heard.append(($0, $1, $2)) }
        try model.send("  Check the logs.  ", in: direct.id)
        XCTAssertEqual(heard.map(\.0), [direct.id])
        XCTAssertEqual(heard.first?.1, "Check the logs.")
        XCTAssertEqual(heard.first?.2, [])
    }
}
