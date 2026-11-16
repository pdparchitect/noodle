import NoodleCore
import XCTest

/// As in Noodle: Send to Pion offers the conversations something can be sent to, and what was sent arrives as
/// your message, then leaves the inbox.
@MainActor final class ShareTests: XCTestCase {
    func testSharedItemsArriveAsYourMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionShare-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root.appendingPathComponent("data"), messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        let inbox = SharedInbox(rootURL: root.appendingPathComponent("Sharing"))

        model.publishShareDestinations(to: inbox)
        XCTAssertEqual(try inbox.loadDestinations().map(\.id), [direct.id])

        try inbox.publish(SharedRequest(id: UUID(), conversationID: direct.id, body: "Look at this alert", filenames: []))
        await model.deliverShared(from: inbox)
        XCTAssertEqual(model.messages(in: direct.id).last?.body, "Look at this alert")
        XCTAssertEqual(model.messages(in: direct.id).last?.author, .user)
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    /// Shortcuts' Send to Agent, as in Noodle: the message and its files go at once, and the draft you were
    /// writing stays where it was.
    func testShortcutsSendLeavesTheDraftAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionShortcut-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let direct = try XCTUnwrap(model.directConversation(of: avery))
        model.drafts[direct.id].text = "half written"

        try model.sendFromShortcut("Check the firewall logs", files: [.data(Data("log".utf8), originalFilename: "fw.log",
                                                                            mediaType: "text/plain")], to: direct.id)
        let sent = try XCTUnwrap(model.messages(in: direct.id).last)
        XCTAssertEqual(sent.body, "Check the firewall logs")
        XCTAssertEqual(sent.attachmentIDs?.count, 1)
        XCTAssertEqual(model.drafts[direct.id].text, "half written")
        XCTAssertThrowsError(try model.sendFromShortcut("Hello", files: [], to: UUID()))
    }
}
