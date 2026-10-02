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

    @MainActor func testReopenedWindowIsReattached() async throws {
        let controller = ConversationAnnotationController()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        let hostingView = NSHostingView(rootView: ConversationAnnotationHost(controller: controller,
            conversationID: UUID(), title: "Reopen", save: { _, _, _, _ in }))
        window.contentView = hostingView
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(controller.window === window)

        window.close()
        XCTAssertNil(controller.window)
        // The main window keeps its views while closed and is shown again on reopen.
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(controller.window === window, "Annotations must work again after the window is reopened")
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

    func testWebLinkAnnotationSavesItsSourceAsALinkAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-note-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Reviewer")
        let page = try XCTUnwrap(URL(string: "https://example.com/page"))
        let (source, raw) = try WebLinkPreview.source(for: page, conversationID: bot.conversation.id)
        XCTAssertEqual(source.url, page)
        let note = AttachmentAnnotation(source: source, quote: "Heading", comment: "Look here")
        let saved = try ConversationAnnotationContent.save(note, content: Data(note.textRepresentation.utf8),
            source: source, sourceData: raw, repository: repository)
        XCTAssertEqual(saved.source.url, page)
        XCTAssertEqual(saved.source.originalFilename, "example.com.webloc")
        XCTAssertEqual(saved.attachment.annotation?.sourceAttachmentID, saved.source.id)
        XCTAssertEqual(try repository.loadAttachments(conversationID: bot.conversation.id).first { $0.id == saved.source.id }?.url, page)
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

/// A test process cannot activate, so no window ever becomes key on its own.
private final class KeyedWindow: NSWindow {
    override var isKeyWindow: Bool { isVisible }
}

@MainActor final class ConversationAnnotationShortcutTests: HiddenViewTests {
    func testShortcutsAndMenuWorkAfterTheMainWindowIsClosedAndReopened() async throws {
        let f = try fixture()
        try f.repository.append(ChatMessage(conversationID: f.directA.id, author: .agent(f.a.id),
            body: "Annotate me", delivery: .delivered))
        f.store.refreshTranscripts()
        f.store.selectedConversationID = f.directA.id
        let window = KeyedWindow(contentRect: .init(x: -10000, y: -10000, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSHostingView(rootView: RootView().environment(f.store))
        window.contentView = root
        defer { window.close(); window.contentView = nil }
        window.orderFront(nil)
        try await wait { self.elements(root).contains { $0 is ComposerTextView } }

        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let controller = try XCTUnwrap(allViews(root)
            .compactMap { ($0 as? ConversationAnnotationHost.Host)?.controller }.first)
        let menu = AnnotationCommandsState.shared
        func assertAvailable(_ moment: String) async throws {
            try await wait { controller.canAnnotate && menu.conversationEnabled && menu.conversationOwner === controller }
            // The real dispatch path: local event monitors run inside sendEvent.
            let regionShortcut = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "R", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
            XCTAssertTrue(KeyboardBindings.shared.matches(.annotateRegion, event: regionShortcut))
            NSApp.sendEvent(regionShortcut)
            XCTAssertFalse(controller.canAnnotate, "⇧⌘R must start a region annotation \(moment)")
            XCTAssertFalse(menu.conversationEnabled, "A running annotation disables the menu items")
            // Stop before the window capture, which needs Screen Recording access.
            controller.cancel()
            XCTAssertTrue(controller.canAnnotate)
        }

        try await assertAvailable("on first open")
        window.close()
        try await wait { !menu.conversationEnabled }
        // Reopening Noodle shows the same main window with the views it kept.
        window.orderFront(nil)
        try await assertAvailable("after the window is reopened")
    }

    func testHubLiveViewsCanBeAnnotatedIntoTheirConversation() throws {
        let f = try fixture()
        let panels = HubSurfacePanels()
        try assertAnnotatable(HubSurfaceTarget(conversationID: f.directA.id, attachmentID: UUID(), title: "Board"),
                              in: panels, store: f.store)
        try assertAnnotatable(HubSurfaceTarget(conversationID: f.directA.id, attachmentID: UUID(), title: "Board",
                                               noodlet: true), in: panels, store: f.store)
    }

    private func assertAnnotatable(_ target: HubSurfaceTarget, in panels: HubSurfacePanels, store: NoodleStore) throws {
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        panels.open(target, store: store)
        let panel = try XCTUnwrap(panels.panel(for: target))
        let controller = try XCTUnwrap(panels.annotations(for: target))
        XCTAssertTrue(controller.window === panel)
        XCTAssertEqual(controller.conversationID, target.conversationID)
        let button = try XCTUnwrap(allViews(try XCTUnwrap(panel.contentView))
            .compactMap { $0 as? NSButton }.first { $0.title == "Annotate…" }, "The header offers Annotate…")
        XCTAssertTrue(button.target === controller)
        XCTAssertEqual(button.action, #selector(ConversationAnnotationController.startRegion))
        panel.close()
        XCTAssertNil(panels.annotations(for: target), "Closing the panel ends its annotations")
    }
}
