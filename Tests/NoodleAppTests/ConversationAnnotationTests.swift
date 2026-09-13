import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

final class ConversationAnnotationTests: XCTestCase {
    @MainActor func testClosedWindowIsNotReattachedByARepresentableUpdate() async throws {
        let controller = ConversationAnnotationController()
        let id = UUID()
        func content(_ title: String) -> some View {
            ConversationAnnotationHost(controller: controller, conversationID: id,
                title: title, save: { _, _, _, _ in })
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hostingView = NSHostingView(rootView: content("Before close"))
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(controller.window === window)

        window.close()
        XCTAssertNil(controller.window)
        // Focus changes can ask SwiftUI to update before AppKit has cleared
        // the view's window pointer, including from inside NSWindow.dealloc.
        hostingView.rootView = content("Update during teardown")
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(controller.window, "A content update must not reattach a closed window")
        window.contentView = nil
    }

    @MainActor func testPendingAnnotationMountIsCancelledOnDetachAndReplacement() async throws {
        let first = ConversationAnnotationController(), second = ConversationAnnotationController()
        let host = ConversationAnnotationHost.Host(controller: first)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = host
        host.setController(second)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(first.window)
        XCTAssertTrue(second.window === window)

        host.setController(first)
        window.contentView = nil
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(first.window)
        XCTAssertNil(second.window)
    }

    @MainActor func testAnnotationHostSurvivesRepeatedFocusedWindowTeardown() async throws {
        for _ in 0..<30 {
            let controller = ConversationAnnotationController()
            autoreleasepool {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let hostingView = NSHostingView(rootView:
                    TextField("Draft", text: .constant("Focused editor"))
                        .background(ConversationAnnotationHost(controller: controller, conversationID: UUID(),
                            title: "Teardown", save: { _, _, _, _ in })))
                window.contentView = hostingView
                hostingView.layoutSubtreeIfNeeded()
                window.makeFirstResponder(hostingView)
                window.close()
            }
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertNil(controller.window)
        }
    }

    func testTextSnapshotPersistsMessageReferenceThroughEditingAndDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-note-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Reviewer")
        let message = ChatMessage(conversationID: bot.conversation.id, author: .agent(bot.agent.id),
            body: "A **specific** suggestion", delivery: .delivered)
        try repository.append(message)
        let raw = Data(message.body.utf8)
        let source = ConversationAttachment(conversationID: message.conversationID, originalFilename: "Message.txt",
            storedFilename: "Message.txt", mediaType: "text/plain", byteCount: Int64(raw.count))
        let note = AttachmentAnnotation(source: source, quote: "specific", comment: "Explain this",
            sourceMessageID: message.id)
        let saved = try ConversationAnnotationContent.save(note, content: Data(note.textRepresentation.utf8),
            source: source, sourceData: raw, repository: repository)
        XCTAssertNotEqual(saved.source.id, source.id)
        XCTAssertEqual(saved.attachment.annotation?.sourceAttachmentID, saved.source.id)
        XCTAssertEqual(saved.attachment.annotation?.sourceMessageID, message.id)
        XCTAssertEqual(try Data(contentsOf: repository.attachmentFileURL(saved.source)), raw)
        let savedNote = try XCTUnwrap(saved.attachment.annotation)
        XCTAssertEqual(try String(contentsOf: repository.attachmentFileURL(saved.attachment), encoding: .utf8), savedNote.textRepresentation)
        XCTAssertTrue(savedNote.textRepresentation.contains(message.id.uuidString))
        XCTAssertEqual(try repository.loadMessages(conversationID: message.conversationID).count, 1, "Save must not send")
        var drafts = ConversationDrafts()
        drafts.restoreAnnotations(try repository.loadAttachments(conversationID: message.conversationID),
            messages: [message], conversationID: message.conversationID)
        XCTAssertEqual(drafts[message.conversationID].attachments.map(\.id), [saved.attachment.id])
        let revised = savedNote.replacingComment("Explain this in detail")
        let edited = try repository.reviseAnnotationComment(saved.attachment, comment: revised.comment,
            content: Data(revised.textRepresentation.utf8))
        _ = try repository.sendUserMessage(conversationID: message.conversationID, body: "Review this", attachmentIDs: [edited.id])
        let delivery = try XCTUnwrap(repository.latestMessages(for: bot.agent.id, consuming: false).last)
        XCTAssertEqual(delivery.attachments.first?.annotation?.sourceMessageID, message.id)
        XCTAssertEqual(delivery.attachments.first?.annotation?.quote, "specific")
        XCTAssertEqual(delivery.attachments.first?.annotation?.comment, revised.comment)
    }

    func testInvalidMessageReferenceRollsBackSourceAndOldMetadataStillDecodes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-note-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let first = try repository.createAgent(named: "First")
        let second = try repository.createAgent(named: "Second")
        let message = ChatMessage(conversationID: second.conversation.id, author: .user, body: "Elsewhere", delivery: .delivered)
        try repository.append(message)
        let source = ConversationAttachment(conversationID: first.conversation.id, originalFilename: "Message.txt",
            storedFilename: "Message.txt", mediaType: "text/plain", byteCount: 1)
        for id in [message.id, UUID()] {
            let note = AttachmentAnnotation(source: source, quote: "Elsewhere", comment: "Wrong conversation", sourceMessageID: id)
            XCTAssertThrowsError(try ConversationAnnotationContent.save(note, content: Data(), source: source,
                sourceData: Data("Elsewhere".utf8), repository: repository))
            XCTAssertTrue(try repository.loadAttachments(conversationID: first.conversation.id).isEmpty)
        }
        let old = AttachmentAnnotation(source: source, quote: "Old quote", comment: "Old feedback")
        let wire = try JSONEncoder().encode(old)
        XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains("sourceMessageID"))
        XCTAssertEqual(try JSONDecoder().decode(AttachmentAnnotation.self, from: wire), old)
    }
}
