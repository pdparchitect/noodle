import NoodleCore
import XCTest

/// Pasted pictures and files wait in the composer, as in Noodle.
@MainActor final class PasteTests: XCTestCase {
    func testPastedItemsWaitInTheComposer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionPaste-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let agent = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: agent))
        let attached = model.attach([.data(Data([1, 2, 3]), originalFilename: "Pasted Image.png", mediaType: "image/png")], to: direct.id)
        XCTAssertTrue(attached)
        XCTAssertEqual(model.pendingAttachments[direct.id]?.map(\.originalFilename), ["Pasted Image.png"])
        XCTAssertFalse(model.attach([], to: direct.id))
    }
}
