import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class LongTextTests: HiddenViewTests {
    func testLongTextIncludesDocumentsAndManyShortLinesButNotOrdinaryMessages() {
        XCTAssertFalse(LongTextPolicy.requiresPreview("A short reply.\nWith a second line."))
        XCTAssertFalse(LongTextPolicy.requiresPreview(String(repeating: "é", count: 1_200)))
        XCTAssertTrue(LongTextPolicy.requiresPreview(String(repeating: "é", count: 1_201)))
        XCTAssertFalse(LongTextPolicy.requiresPreview(Array(repeating: "line", count: 12).joined(separator: "\r\n")))
        XCTAssertTrue(LongTextPolicy.requiresPreview(Array(repeating: "line", count: 13).joined(separator: "\r\n")))
    }

    func testLargePasteAttachesExactTextToMountedConversationAndSendsWithDraft() async throws {
        let f = try fixture(), store = f.store
        store.selectedConversationID = f.directA.id
        store.setDraft("Review this document", for: f.directB.id)
        let chat = host(ConversationWindowView(conversationID: f.directB.id).environment(store))
        var editor: ComposerTextView?
        try await wait {
            editor = self.elements(chat).compactMap { $0 as? ComposerTextView }.first
            return editor?.pasteAttachments != nil
        }
        let input = try XCTUnwrap(editor)
        input.setSelectedRange(NSRange(location: 7, length: 4))
        let text = "  # Research 👩🏽‍💻\r\n" + String(repeating: "Résumé — 日本語\n", count: 140) + "\nEnd of document  "
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString(text, forType: .string))
        XCTAssertTrue(input.readSelection(from: board, type: .string))
        XCTAssertEqual(input.string, "Review this document")
        XCTAssertEqual(input.selectedRange(), NSRange(location: 7, length: 4))
        XCTAssertEqual(store.draft(for: f.directB.id), "Review this document")
        XCTAssertTrue(store.pendingAttachments(for: f.directA.id).isEmpty)
        let attachment = try XCTUnwrap(store.pendingAttachments(for: f.directB.id).first)
        XCTAssertEqual(store.pendingAttachments(for: f.directB.id).count, 1)
        XCTAssertEqual(attachment.originalFilename, "Pasted Text.txt")
        XCTAssertEqual(attachment.mediaType, "text/plain")
        XCTAssertEqual(try Data(contentsOf: store.attachmentFileURL(attachment)), Data(text.utf8))
        XCTAssertEqual(board.string(forType: .string), text)
        store.sendDraft(to: f.directB.id)
        let sent = try XCTUnwrap(store.messages(for: f.directB).last)
        XCTAssertEqual(sent.body, "Review this document")
        XCTAssertEqual(sent.attachments, [attachment.id])
        XCTAssertEqual(try Data(contentsOf: store.attachmentFileURL(attachment)), Data(text.utf8))
        XCTAssertNil(store.errorMessage)
    }

    func testShortPastesStillReplaceSelectedTextAndFilesKeepPriority() throws {
        let f = try fixture()
        let input = ComposerScrollView().editor
        input.pasteAttachments = { f.store.importAttachmentsFromPasteboard(into: f.directA.id, pasteboard: $0) }
        input.string = "Before old after"
        input.setSelectedRange(NSRange(location: 7, length: 3))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString("new", forType: .string))
        XCTAssertTrue(input.readSelection(from: board, type: .string))
        XCTAssertEqual(input.string, "Before new after")
        XCTAssertTrue(f.store.pendingAttachments(for: f.directA.id).isEmpty)

        let file = f.repository.rootURL.appendingPathComponent("Original.txt")
        try Data("Original attachment".utf8).write(to: file)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([file as NSURL]))
        XCTAssertTrue(board.setString(String(repeating: "fallback ", count: 200), forType: .string))
        XCTAssertTrue(input.readSelection(from: board, type: .fileURL))
        XCTAssertEqual(f.store.pendingAttachments(for: f.directA.id).map(\.originalFilename), ["Original.txt"])
        XCTAssertEqual(input.string, "Before new after")
    }

    func testFailedTextAttachmentPreservesDraftAndClipboardForRetry() throws {
        let f = try fixture()
        let directory = f.repository.attachmentsDirectory(conversationID: f.directA.id)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try Data("Block attachment directory creation".utf8).write(to: directory)
        let input = ComposerScrollView().editor
        input.string = "Keep this draft"
        input.pasteAttachments = { f.store.importAttachmentsFromPasteboard(into: f.directA.id, pasteboard: $0) }
        let text = String(repeating: "Long text with exact whitespace.\n", count: 60)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertTrue(board.setString(text, forType: .string))
        XCTAssertTrue(input.readSelection(from: board, type: .string))
        XCTAssertEqual(input.string, "Keep this draft")
        XCTAssertEqual(board.string(forType: .string), text)
        XCTAssertNotNil(f.store.errorMessage)
        XCTAssertTrue(f.store.pendingAttachments(for: f.directA.id).isEmpty)
    }

    func testLongUserAndAgentMessagesStayCompactAndReaderOpensAndCloses() async throws {
        let f = try fixture()
        NSApplication.shared.setActivationPolicy(.accessory)
        let text = "**Document heading**\n" + String(repeating: "This is a longer paragraph of the document.\n", count: 80) + "Final paragraph."
        for author in [MessageAuthor.user, .agent(f.a.id)] {
            let message = ChatMessage(conversationID: f.directA.id, author: author, body: text, delivery: .delivered)
            let bubble = host(MessageBubble(message: message, hasConversationBackground: false,
                selectedAttachmentID: .constant(nil), previewAttachment: { _ in }, showAgentProfile: nil)
                .padding().environment(f.store))
            let window = try XCTUnwrap(bubble.window)
            window.appearance = NSAppearance(named: author == .user ? .aqua : .darkAqua)
            window.setFrameOrigin(.init(x: 80, y: 80))
            window.setContentSize(.init(width: 700, height: 300))
            window.orderFront(nil)
            let readMore = try await control("Read full message", in: bubble)
            XCTAssertLessThan(bubble.fittingSize.height, 250)
            try snapshot(bubble, name: author == .user ? "user-preview" : "agent-preview")
            press(readMore)
            var reader: NSView?
            try await wait {
                reader = NSApp.windows.filter { $0.isVisible && $0 !== window }
                    .compactMap(\.contentView).first { self.hasControl("Copy message", in: $0) }
                return reader != nil
            }
            let content = try XCTUnwrap(reader)
            XCTAssertTrue(elements(content).contains { labels($0).contains { $0.contains("Final paragraph.") } })
            XCTAssertLessThan(bubble.fittingSize.height, 250)
            XCTAssertTrue(elements(content).contains { attribute($0, .role) as? String == "AXScrollArea" })
            try snapshot(content, name: author == .user ? "reader-light" : "reader-dark")
            let close = try await control("Close", in: content)
            press(close)
            try await wait { content.window?.isVisible != true }
            window.close()
        }
        let short = host(MessageText(message: ChatMessage(conversationID: f.directA.id, author: .user,
                                                         body: "An ordinary reply", delivery: .delivered)))
        XCTAssertFalse(hasControl("Read full message", in: short))
    }

    private func snapshot(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["NOODLE_LONG_TEXT_SCREENSHOTS"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let foreground = NSImage(size: view.bounds.size)
        foreground.addRepresentation(bitmap)
        // Cached native views leave material backgrounds transparent. Supply the
        // window's appearance color so light and dark text are both inspectable.
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
            foreground.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero,
                            operation: .sourceOver, fraction: 1)
        }
        image.unlockFocus()
        let rendered = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(rendered.representation(using: .png, properties: [:])).write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
