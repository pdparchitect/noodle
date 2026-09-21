import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class TranscriptLayoutTests: XCTestCase {
    // A main-queue timeout cannot detect a main-thread SwiftUI layout loop.
    private func watchdog() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 30)
        timer.setEventHandler {
            FileHandle.standardError.write(Data("FAIL: transcript layout test exceeded 30 seconds (possible main-thread layout hang)\n".utf8))
            _exit(1)
        }
        timer.resume()
        return timer
    }

    private func imageFile(width: Int, height: Int) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-layout-\(UUID()).png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.systemOrange.setFill()
        NSRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }

    private func attachment(file: URL, annotated: Bool) -> ConversationAttachment {
        let source = ConversationAttachment(conversationID: UUID(), originalFilename: "Screenshot.png",
            storedFilename: file.lastPathComponent, mediaType: "image/png", byteCount: 1)
        guard annotated else { return source }
        return ConversationAttachment(conversationID: source.conversationID, originalFilename: "Annotation.png",
            storedFilename: file.lastPathComponent, mediaType: "image/png", byteCount: 1,
            annotation: AttachmentAnnotation(source: source, comment: "Look at this region",
                region: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
    }

    private func window<Content: View>(_ content: Content, width: CGFloat = 760) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: width, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.orderFront(nil)
        return window
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }

    private func waitForThumbnail(_ file: URL) async throws {
        for _ in 0..<200 {
            if AttachmentThumbnailCache.shared.object(forKey: file as NSURL) != nil {
                try await settle()
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The real thumbnail loader did not complete")
    }

    func testLoadingImageAndRegionAnnotationThumbnailsPreservesRowHeight() async throws {
        let timeout = watchdog()
        defer { timeout.cancel() }
        for annotated in [false, true] {
            for (width, height) in [(800, 400), (400, 800)] {
                let file = try imageFile(width: width, height: height)
                let model = ThumbnailLayoutModel()
                let window = window(ThumbnailLayoutFixture(model: model,
                    attachment: attachment(file: file, annotated: annotated), file: file))
                defer { window.close(); window.contentView = nil }
                try await settle()
                let initialHeight = model.height
                XCTAssertGreaterThan(initialHeight, 0)
                XCTAssertNil(AttachmentThumbnailCache.shared.object(forKey: file as NSURL))
                model.shouldLoad = true
                try await waitForThumbnail(file)
                XCTAssertEqual(model.height, initialHeight, accuracy: 1,
                    "Loading a \(width)x\(height) \(annotated ? "region annotation" : "image") must not resize its transcript row")
                model.shouldLoad = false
                try await settle()
                model.shouldLoad = true
                try await settle()
                XCTAssertEqual(model.height, initialHeight, accuracy: 1, "Revisiting a cached thumbnail must keep the same height")
            }
        }
    }

    func testTextAndLegacyAnnotationsDoNotReserveAnImageTheyCannotLoad() async throws {
        let timeout = watchdog()
        defer { timeout.cancel() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("missing-annotation-\(UUID()).pdf")
        let source = attachment(file: file, annotated: false)
        for note in [AttachmentAnnotation(source: source, quote: "Selected text", comment: "A text note"),
                     AttachmentAnnotation(source: source, comment: "An older note",
                         region: .init(x: 0, y: 0, width: 1, height: 1), version: 1)] {
            let annotation = ConversationAttachment(conversationID: source.conversationID,
                originalFilename: "Annotation", storedFilename: file.lastPathComponent,
                mediaType: note.mediaType, byteCount: 1, annotation: note)
            let model = ThumbnailLayoutModel()
            let window = window(ThumbnailLayoutFixture(model: model, attachment: annotation, file: file))
            defer { window.close(); window.contentView = nil }
            try await settle()
            let initialHeight = model.height
            XCTAssertGreaterThan(initialHeight, 0)
            XCTAssertLessThan(initialHeight, 190, "Text-only and legacy notes should remain compact")
            model.shouldLoad = true
            try await settle()
            XCTAssertEqual(model.height, initialHeight, accuracy: 1)
            XCTAssertNil(AttachmentThumbnailCache.shared.object(forKey: file as NSURL))
        }
    }

    func testThumbnailLoadingDuringScrollAndIncomingMessagesKeepsTranscriptResponsive() async throws {
        let timeout = watchdog()
        defer { timeout.cancel() }
        let file = try imageFile(width: 800, height: 500)
        let model = TranscriptLayoutModel(rows: (0..<120).map { _ in attachment(file: file, annotated: true) }, file: file)
        let window = window(TranscriptLayoutFixture(model: model))
        defer { window.close(); window.contentView = nil }
        try await settle()
        let scroll = try XCTUnwrap(findScroll(window.contentView!))
        XCTAssertTrue(atBottom(scroll))
        // Load thumbnails during an active gesture; app rows begin loading only
        // after visibility changes, unlike the old fixed-rectangle fixture.
        wheel(scroll, delta: 0, phase: 1)
        wheel(scroll, delta: 240, phase: 2)
        model.shouldLoad = true
        try await waitForThumbnail(file)
        for step in 0..<20 {
            wheel(scroll, delta: step < 10 ? 180 : -180, phase: 2)
            if step.isMultiple(of: 4) {
                model.rows.append(attachment(file: file, annotated: true))
                model.overlayHeight = step.isMultiple(of: 8) ? 130 : 70
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        wheel(scroll, delta: 0, phase: 4)
        try await settle()
        XCTAssertFalse(model.visible.isEmpty)
        // History remains navigable after loading, reflow, and appends.
        wheel(scroll, delta: 0, phase: 1)
        for _ in 0..<10 {
            wheel(scroll, delta: 500, phase: 2)
            try await Task.sleep(for: .milliseconds(30))
        }
        wheel(scroll, delta: 0, phase: 4)
        try await settle()
        XCTAssertFalse(atBottom(scroll))
        XCTAssertFalse(model.saved.isAtBottom)
        let readingID = try XCTUnwrap(model.saved.messageID)
        model.rows.append(attachment(file: file, annotated: true))
        try await settle()
        XCTAssertTrue(model.visible.contains(readingID), "An incoming reply must leave the reading message visible")
        for width: CGFloat in [440, 820, 550, 760] {
            window.setContentSize(.init(width: width, height: 620))
            try await settle()
            XCTAssertTrue(model.visible.contains(readingID), "Resizing must preserve the reading message")
        }
        wheel(scroll, delta: 0, phase: 1)
        for _ in 0..<20 {
            wheel(scroll, delta: -800, phase: 2)
            try await Task.sleep(for: .milliseconds(30))
        }
        wheel(scroll, delta: 0, phase: 4)
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(atBottom(scroll))
        XCTAssertTrue(model.saved.isAtBottom)
        model.rows.append(attachment(file: file, annotated: true))
        try await settle()
        XCTAssertTrue(atBottom(scroll), "Following latest must still work after the gesture ends")
    }

    func testFullChatWithMixedRowsSurvivesScrollingResizingAndConversationSwitches() async throws {
        let timeout = watchdog()
        defer { timeout.cancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-chat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Layout Bot")
        let other = try repository.createGroup(named: "Other Chat", participantIDs: [bot.agent.id], existingAgents: [bot.agent])
        let file = try imageFile(width: 640, height: 480)
        let data = try Data(contentsOf: file)
        let source = try repository.importAttachment(from: file, into: bot.conversation.id, mediaType: "image/png")
        for index in 0..<160 {
            var attachments: [UUID] = []
            if index.isMultiple(of: 4) || index == 159 {
                let note = AttachmentAnnotation(source: source, comment: "Check region \(index)",
                    region: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
                let saved = try repository.importAttachment(data: data, originalFilename: "Region \(index).png",
                    into: bot.conversation.id, mediaType: "image/png", annotation: note)
                attachments = [saved.id]
            } else if index.isMultiple(of: 7) { attachments = [source.id] }
            try repository.append(ChatMessage(conversationID: bot.conversation.id,
                author: index.isMultiple(of: 3) ? .user : .agent(bot.agent.id),
                body: String(repeating: "Paragraph **\(index)** with selectable text and `inline code`.\n", count: index % 13 + 1),
                delivery: .delivered, attachmentIDs: attachments))
        }
        let suite = "transcript-chat-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(homeDirectory: root,
            applicationsDirectory: root, executableSearchDirectories: [], applicationBundleURL: root), defaults: defaults)
        let store = NoodleStore(repository: repository, runtime: runtime, connectsServices: false)
        defer { store.stopMonitoring() }
        XCTAssertTrue(store.storageReady, store.errorMessage ?? "Storage failed")
        store.selectedConversationID = bot.conversation.id
        let window = window(FullTranscriptLayoutFixture(store: store))
        defer { window.close(); window.contentView = nil }
        try await settle()
        for round in 0..<4 {
            let scroll = try XCTUnwrap(findScroll(window.contentView!))
            wheel(scroll, delta: 0, phase: 1)
            for step in 0..<10 {
                wheel(scroll, delta: step < 6 ? 450 : -150, phase: 2)
                window.setContentSize(.init(width: CGFloat([440, 820, 550, 760][step % 4]), height: 620))
                if step.isMultiple(of: 3) {
                    try repository.append(ChatMessage(conversationID: bot.conversation.id, author: .agent(bot.agent.id),
                        body: "Incoming reply \(round)-\(step)", delivery: .delivered))
                    store.refreshTranscripts()
                    store.setDraft(String(repeating: "Draft line\n", count: step + 1), for: bot.conversation.id)
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            wheel(scroll, delta: 0, phase: 4)
            try await settle()
            XCTAssertTrue(scroll.documentView!.frame.height.isFinite)
            XCTAssertGreaterThan(scroll.documentView!.frame.height, scroll.contentView.bounds.height)
            store.selectedConversationID = other.id
            try await Task.sleep(for: .milliseconds(40))
            store.selectedConversationID = bot.conversation.id
            try await settle()
        }
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.messages(for: bot.conversation).count, 176)
        XCTAssertTrue(store.draft(for: other.id).isEmpty)
        XCTAssertFalse(store.draft(for: bot.conversation.id).isEmpty)
    }

    /// A mounted chat with twelve linked messages; `body` runs once the first layout has settled.
    private func withLinkedChat(_ body: (NoodleStore, WorkspaceRepository, (agent: AgentRecord, conversation: BotConversation), NSWindow) async throws -> Void) async throws {
        let timeout = watchdog()
        defer { timeout.cancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-typing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let bot = try repository.createAgent(named: "Typing Bot")
        for index in 0..<12 {
            try repository.append(ChatMessage(conversationID: bot.conversation.id,
                author: index.isMultiple(of: 2) ? .user : .agent(bot.agent.id),
                body: "Message **\(index)** with a link https://example.com/\(UUID())", delivery: .delivered))
        }
        let suite = "transcript-typing-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(homeDirectory: root,
            applicationsDirectory: root, executableSearchDirectories: [], applicationBundleURL: root), defaults: defaults)
        let store = NoodleStore(repository: repository, runtime: runtime, connectsServices: false)
        defer { store.stopMonitoring() }
        XCTAssertTrue(store.storageReady, store.errorMessage ?? "Storage failed")
        store.selectedConversationID = bot.conversation.id
        let window = window(FullTranscriptLayoutFixture(store: store))
        defer { window.close(); window.contentView = nil }
        try await settle()
        try await body(store, repository, (bot.agent, bot.conversation), window)
    }

    func testReevaluatedTranscriptRowsDoNotDetectTheirLinksAgain() async throws {
        try await withLinkedChat { store, repository, bot, _ in
            let scanned = TranscriptRenderProbe.linkScans, rendered = TranscriptRenderProbe.bubbleBodies
            XCTAssertGreaterThan(scanned, 0, "The rows must have looked for a link to preview")
            try repository.append(ChatMessage(conversationID: bot.conversation.id, author: .agent(bot.agent.id),
                body: "A reply without a link", delivery: .delivered))
            store.refreshTranscripts()
            try await settle()
            XCTAssertGreaterThan(TranscriptRenderProbe.bubbleBodies, rendered + 1, "The new message must re-evaluate rows")
            XCTAssertLessThanOrEqual(TranscriptRenderProbe.linkScans - scanned, 2,
                "Only the new message may be scanned for links")
        }
    }

    func testTypingInTheComposerDoesNotReevaluateTranscriptRows() async throws {
        try await withLinkedChat { store, _, bot, window in
        func editor(in view: NSView?) -> ComposerTextView? {
            if let editor = view as? ComposerTextView { return editor }
            return view?.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        let composer = try XCTUnwrap(editor(in: window.contentView))
        // The first character swaps the send control; later ones change only the draft.
        composer.insertText("H", replacementRange: composer.selectedRange())
        try await settle()
        let rendered = TranscriptRenderProbe.bubbleBodies
        XCTAssertGreaterThan(rendered, 0, "The transcript must have rendered its rows")
        for character in "ello there" {
            composer.insertText(String(character), replacementRange: composer.selectedRange())
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settle()
        XCTAssertEqual(store.draft(for: bot.conversation.id), "Hello there")
        XCTAssertEqual(TranscriptRenderProbe.bubbleBodies, rendered,
            "Typing re-evaluated \(TranscriptRenderProbe.bubbleBodies - rendered) transcript rows")
        }
    }

    private func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll($0) }.first
    }

    private func atBottom(_ scroll: NSScrollView) -> Bool {
        TranscriptScrollMetrics(contentOffset: scroll.contentView.bounds.minY,
            contentHeight: scroll.documentView!.frame.height, viewportHeight: scroll.contentView.bounds.height,
            topInset: scroll.contentInsets.top, bottomInset: scroll.contentInsets.bottom).isAtBottom
    }

    private func wheel(_ scroll: NSScrollView, delta: Int32, phase: Int64) {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: delta, wheel2: 0, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        scroll.scrollWheel(with: NSEvent(cgEvent: event)!)
    }
}

@MainActor private final class ThumbnailLayoutModel: ObservableObject {
    @Published var shouldLoad = false
    var height: CGFloat = 0
}

private struct ThumbnailLayoutFixture: View {
    @ObservedObject var model: ThumbnailLayoutModel
    let attachment: ConversationAttachment
    let file: URL
    var body: some View {
        AttachmentInlinePreview(attachment: attachment, fileURL: file, shouldLoad: model.shouldLoad,
            isSelected: false, select: {}, preview: {})
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.height = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor private final class TranscriptLayoutModel: ObservableObject {
    @Published var rows: [ConversationAttachment]
    @Published var shouldLoad = false
    @Published var overlayHeight: CGFloat = 70
    let file: URL
    var visible: Set<UUID> = []
    var saved = TranscriptViewport()
    init(rows: [ConversationAttachment], file: URL) { self.rows = rows; self.file = file }
}

private struct TranscriptLayoutFixture: View {
    @ObservedObject var model: TranscriptLayoutModel
    var body: some View {
        TranscriptScrollView(initialViewport: TranscriptViewport(), lastMessageID: model.rows.last?.id,
            lastMessageIsFromUser: false, bottomOverlayHeight: model.overlayHeight,
            saveViewport: { model.saved = $0 }) {
            ForEach(model.rows) { attachment in
                TranscriptAttachmentRow(model: model, attachment: attachment)
                    .id(TranscriptScrollTarget.message(attachment.id))
            }
        }
    }
}

private struct TranscriptAttachmentRow: View {
    @ObservedObject var model: TranscriptLayoutModel
    let attachment: ConversationAttachment
    @State private var visible = false
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("A selectable message with a marked screenshot.").textSelection(.enabled)
                AttachmentInlinePreview(attachment: attachment, fileURL: model.file,
                    shouldLoad: visible && model.shouldLoad, isSelected: false, select: {}, preview: {})
            }
            Spacer(minLength: 120)
        }
        .onScrollVisibilityChange(threshold: 0.01) {
            visible = $0
            if $0 { model.visible.insert(attachment.id) } else { model.visible.remove(attachment.id) }
        }
        .onDisappear { model.visible.remove(attachment.id) }
    }
}

private struct FullTranscriptLayoutFixture: View {
    let store: NoodleStore
    @State private var preview = AttachmentPreviewController()
    var body: some View {
        if let conversation = store.selectedConversation {
            ChatView(conversation: conversation, attachmentPreview: preview)
                .environment(store)
        }
    }
}
