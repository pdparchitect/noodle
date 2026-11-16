import NoodleCore
import XCTest

/// Noodle's drafts and Forward… in Pion: an unsent annotation waits in its conversation's draft across launches,
/// and a file goes on to another conversation as one message, leaving what is being written there alone.
@MainActor final class AttachmentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PionAttachments-\(UUID())")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAnUnsentAnnotationWaitsInTheDraftAcrossLaunches() throws {
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let chat = try XCTUnwrap(model.directConversation(of: avery))
        let file = root.appendingPathComponent("capture.txt")
        try Data("Beacon".utf8).write(to: file)
        model.attach([file], to: chat.id)
        let source = try XCTUnwrap(model.drafts[chat.id].attachments.first)
        let note = AttachmentAnnotation(source: source, quote: "Beacon", comment: "Look here")
        try model.saveAnnotation(note, content: Data(note.textRepresentation.utf8), source: source)
        model.drafts[chat.id].text = "Half a thought"
        XCTAssertEqual(model.drafts[chat.id].attachments.count, 2)

        let reopened = PionModel(root: root, messenger: nil, isScripted: true)
        reopened.start()
        let restored = reopened.drafts[chat.id].attachments
        XCTAssertEqual(restored.compactMap(\.annotation).map(\.comment), ["Look here"], "Only the annotation comes back, as in Noodle")
        XCTAssertTrue(reopened.canEditAnnotation(try XCTUnwrap(restored.first)))
    }

    func testForwardingSendsACopyAndKeepsTheOtherDraft() throws {
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let blake = try model.createAgent(name: "Blake", description: nil, instructions: "", provider: .codex, model: nil)
        let from = try XCTUnwrap(model.directConversation(of: avery)), to = try XCTUnwrap(model.directConversation(of: blake))
        let url = root.appendingPathComponent("report.txt")
        try Data("Quarterly numbers".utf8).write(to: url)
        model.attach([url], to: from.id)
        let file = try XCTUnwrap(model.drafts[from.id].attachments.first)
        model.sendDraft(to: from.id)
        model.drafts[to.id].text = "Half a thought"

        XCTAssertEqual(model.forwardTargets(from: from.id, search: "").map(\.id), [to.id])
        try model.forward(file, to: to.id, comment: " For the review ")

        let message = try XCTUnwrap(model.messages(in: to.id).last)
        XCTAssertEqual(message.body, "For the review")
        let copy = try XCTUnwrap(model.files(of: message).first)
        XCTAssertNotEqual(copy.id, file.id)
        XCTAssertEqual(try Data(contentsOf: model.fileURL(copy)), Data("Quarterly numbers".utf8))
        XCTAssertEqual(model.drafts[to.id].text, "Half a thought")
    }

    /// As in Noodle: a file goes only where a message can, so not to an archived agent's conversation.
    func testForwardingOffersOnlyConversationsThatTakeMessages() throws {
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let blake = try model.createAgent(name: "Blake", description: nil, instructions: "", provider: .codex, model: nil)
        let averyChat = try XCTUnwrap(model.directConversation(of: avery))
        let blakeChat = try XCTUnwrap(model.directConversation(of: blake))
        _ = try model.repository.setAgentArchived(true, agentID: blake.id)
        model.reload()
        XCTAssertFalse(model.forwardTargets(from: averyChat.id, search: "").map(\.id).contains(blakeChat.id))
    }

    /// As in Noodle: files sent without words say how many there are, and sending reads the conversation.
    func testFilesSentAloneSayHowManyAndReadTheConversation() throws {
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let chat = try XCTUnwrap(model.directConversation(of: avery))
        let file = root.appendingPathComponent("capture.txt")
        try Data("Beacon".utf8).write(to: file)
        model.attach([file, file], to: chat.id)
        model.sendDraft(to: chat.id)
        XCTAssertEqual(model.messages(in: chat.id).last?.body, "Sent 2 attachments")

        model.selection = nil
        _ = try model.repository.sendAgentMessage(agentID: avery.id, conversationID: chat.id, body: "Contained.")
        model.refresh()
        XCTAssertTrue(model.isUnread(chat.id))
        try model.sendFromShortcut("", files: [.file(file)], to: chat.id)
        XCTAssertEqual(model.messages(in: chat.id).last?.body, "Sent 1 attachment")
        XCTAssertFalse(model.isUnread(chat.id), "Sent from Shortcuts, as from the message field")
    }
}

/// Noodle's patch review in Pion: the files ticked off stay ticked across launches, kept where Noodle keeps them,
/// and the review shows the comments made on the patch.
@MainActor final class PatchReviewTests: XCTestCase {
    func testViewedFilesAndCommentsComeFromThePatchsConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PionPatch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let avery = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        let chat = try XCTUnwrap(model.directConversation(of: avery))
        let url = root.appendingPathComponent("fix.diff")
        try Data("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n".utf8).write(to: url)
        model.attach([url], to: chat.id)
        let patch = try XCTUnwrap(model.drafts[chat.id].attachments.first)
        model.saveViewedPatchFiles(["x"], for: patch)
        let note = AttachmentAnnotation(source: patch, quote: "+b", comment: "Why b?")
        try model.saveAnnotation(note, content: Data(note.textRepresentation.utf8), source: patch)
        XCTAssertEqual(model.patchAnnotations(on: patch).map(\.comment), ["Why b?"])

        let reopened = PionModel(root: root, messenger: nil, isScripted: true)
        reopened.start()
        XCTAssertEqual(reopened.viewedPatchFiles(patch), ["x"])
        XCTAssertEqual(reopened.attachmentFileURL(patch), model.fileURL(patch))
    }
}
