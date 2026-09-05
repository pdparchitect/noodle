import XCTest
@testable import SuperBotCore

final class SharedInboxTests: XCTestCase {
    private var root: URL!
    private var inbox: SharedInbox!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("superbot-sharing-tests-\(UUID())")
        inbox = SharedInbox(rootURL: root.appendingPathComponent("Sharing"))
        repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Repository"))
        try repository.prepare()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testCatalogueContainsDestinationsWithoutConversationHistory() throws {
        let destination = ShareDestination(id: UUID(), name: "Build Bot", isGroup: false)
        try inbox.saveDestinations([destination])
        XCTAssertEqual(try inbox.loadDestinations(), [destination])
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    func testStagingPublishAndAcknowledgement() throws {
        let id = UUID()
        let draft = try inbox.draftDirectory(id)
        try Data("PDF fixture".utf8).write(to: draft.appendingPathComponent("Report.pdf"))
        XCTAssertTrue(try inbox.pending().isEmpty, "Drafts must not be delivered")
        let request = SharedRequest(id: id, conversationID: UUID(), body: "Review this", filenames: ["Report.pdf"])
        try inbox.publish(request)
        XCTAssertEqual(try inbox.pending().map(\.id), [id])
        XCTAssertEqual(try Data(contentsOf: inbox.files(for: request)[0]), Data("PDF fixture".utf8))
        try inbox.acknowledge(id)
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    func testRejectsTraversalAndSymlinkAttachments() throws {
        let id = UUID()
        let draft = try inbox.draftDirectory(id)
        let secret = root.appendingPathComponent("private.txt")
        try Data("Not shared".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: draft.appendingPathComponent("link.txt"), withDestinationURL: secret)
        for filename in ["../private.txt", secret.path, "link.txt", "request.json", ".", ".."] {
            XCTAssertThrowsError(try inbox.publish(SharedRequest(id: id, conversationID: UUID(),
                body: "Should fail", filenames: [filename])), filename)
        }
        XCTAssertTrue(try inbox.pending().isEmpty)
    }

    func testCancelledDraftDoesNotDeletePublishedRequest() throws {
        let id = UUID()
        try inbox.publish(SharedRequest(id: id, conversationID: UUID(), body: "Text", filenames: []))
        inbox.cancelDraft(id)
        XCTAssertEqual(try inbox.pending().count, 1)
    }

    func testDeliveryCopiesAttachmentsAndIsIdempotentAfterRestart() throws {
        let bot = try repository.createAgent(named: "Builder")
        let id = UUID()
        let draft = try inbox.draftDirectory(id)
        try Data("Hello".utf8).write(to: draft.appendingPathComponent("Notes.txt"))
        let request = SharedRequest(id: id, conversationID: bot.conversation.id,
            body: "Summarize\n\nhttps://example.com/article", filenames: ["Notes.txt"])
        try inbox.publish(request)
        let files = try inbox.files(for: request)
        let first = try repository.sendSharedMessage(request, files: files)
        let second = try repository.sendSharedMessage(request, files: files)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.body, request.body)
        XCTAssertEqual(try repository.loadMessages(conversationID: bot.conversation.id).count, 1)
        XCTAssertEqual(try repository.loadAttachments(conversationID: bot.conversation.id).count, 1)
        try inbox.acknowledge(id)
        let attachment = try XCTUnwrap(repository.loadAttachments(conversationID: bot.conversation.id).first)
        XCTAssertEqual(try Data(contentsOf: repository.attachmentFileURL(attachment)), Data("Hello".utf8))
    }

    func testFailedDeliveryRetainsRequestAndRollsBackImports() throws {
        let bot = try repository.createAgent(named: "Builder")
        let id = UUID()
        let draft = try inbox.draftDirectory(id)
        try Data("Hello".utf8).write(to: draft.appendingPathComponent("Notes.txt"))
        let request = SharedRequest(id: id, conversationID: bot.conversation.id, body: "Review", filenames: ["Notes.txt", "Missing.pdf"])
        XCTAssertThrowsError(try repository.sendSharedMessage(request,
            files: [draft.appendingPathComponent("Notes.txt"), draft.appendingPathComponent("Missing.pdf")]))
        XCTAssertTrue(try repository.loadMessages(conversationID: bot.conversation.id).isEmpty)
        XCTAssertTrue(try repository.loadAttachments(conversationID: bot.conversation.id).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.appendingPathComponent("Notes.txt").path))
    }
}
