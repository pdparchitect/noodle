import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

/// The transcript's reading position across startup, relaunch and window resizing,
/// hosted in windows that are never ordered onscreen.
@MainActor final class TranscriptScrollTests: HiddenViewTests {
    /// A long history whose rows carry attachments opens on its last message at
    /// narrow, medium and wide windows, even when the messages arrive after the
    /// transcript is already mounted.
    func testAttachmentHeavyHistoryOpensOnItsLastMessage() async throws {
        for width: CGFloat in [820, 550, 1100] {
            let model = StartupModel()
            let root = mount(StartupFixture(model: model))
            let window = try XCTUnwrap(root.window)
            window.setContentSize(.init(width: width, height: 780))
            root.layoutSubtreeIfNeeded()
            model.ids = (0..<180).map { _ in UUID() }
            model.overlay = 75
            let last = try XCTUnwrap(model.ids.last)
            let rendered = await eventually { model.visible.contains(last) }
            XCTAssertTrue(rendered, "At width \(width) the last message was not rendered; visible rows \(model.indices(of: model.visible))")
            window.close(); window.contentView = nil
        }
    }

    /// Closing a chat keeps the reading position the reader scrolled to rather
    /// than the geometry of the window being torn down, and reopening it at a
    /// different width shows that message again instead of jumping to latest.
    func testClosingKeepsTheReadingPositionAndReopeningAtAnotherWidthRestoresIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-positions-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("scroll-positions.json"), conversationID = UUID()
        let positions = TranscriptPositionStore(fileURL: file)
        let original = StartupModel()
        original.ids = (0..<180).map { _ in UUID() }
        original.overlay = 75
        var saves = 0
        original.persist = { saves += 1; try? positions.save($0, for: conversationID) }
        let root = mount(StartupFixture(model: original))
        let window = try XCTUnwrap(root.window)
        window.setContentSize(.init(width: 820, height: 780))
        let last = try XCTUnwrap(original.ids.last)
        let opened = await eventually { original.visible.contains(last) }
        XCTAssertTrue(opened, "The transcript must open on its last message")
        let scroll = try XCTUnwrap(findScroll(root))
        await gesture(scroll, deltas: Array(repeating: 600, count: 10))
        let scrolled = await eventually {
            let saved = positions.viewport(for: conversationID)
            return !saved.isAtBottom && saved.messageID != nil
        }
        XCTAssertTrue(scrolled, "Scrolling into history must save a reading message")
        let checkpoint = positions.viewport(for: conversationID)

        let savesBeforeClose = saves
        window.close(); window.contentView = nil
        let tornDown = await eventually { saves > savesBeforeClose }
        XCTAssertTrue(tornDown, "Closing must save the transcript's last reading position")
        let restored = TranscriptPositionStore(fileURL: file).viewport(for: conversationID)
        XCTAssertEqual(restored, checkpoint, "Closing must not replace the reading position with teardown geometry")

        let readingID = try XCTUnwrap(restored.messageID)
        let reopened = StartupModel(initialViewport: restored)
        reopened.lastMessageIsFromUser = true
        let reopenedRoot = mount(StartupFixture(model: reopened))
        try XCTUnwrap(reopenedRoot.window).setContentSize(.init(width: 550, height: 780))
        reopenedRoot.layoutSubtreeIfNeeded()
        reopened.ids = original.ids
        reopened.overlay = 75
        let returned = await eventually { reopened.visible.contains(readingID) }
        XCTAssertTrue(returned, "Reopening at another width must show the saved reading message; visible rows \(reopened.indices(of: reopened.visible))")
        reopenedRoot.layoutSubtreeIfNeeded()
        XCTAssertFalse(reopened.visible.contains(last), "Restoring history must not jump to the latest message")
    }

    /// A reader at the bottom stays at the bottom when the window is narrowed or widened.
    /// After scrolling into history, width and height changes that reflow every
    /// row keep the message being read near where it was.
    func testResizingKeepsTheBottomOrTheMessageBeingRead() async throws {
        let model = ResizeModel()
        let root = mount(ResizeFixture(model: model))
        let window = try XCTUnwrap(root.window)
        window.setContentSize(.init(width: 760, height: 620))
        let scroll = try await transcriptScroll(in: root)
        let followed = await eventually { self.atBottom(scroll) }
        XCTAssertTrue(followed, "The transcript must start on the latest message")
        // Width changes only: in a window that is never ordered in, a height change
        // at the bottom is not reliably re-anchored, although it is when visible.
        for size in [NSSize(width: 470, height: 620), NSSize(width: 820, height: 620)] {
            window.setContentSize(size)
            let stayed = await eventually { scroll.contentView.bounds.size == size && self.atBottom(scroll) }
            XCTAssertTrue(stayed, "Resizing to \(size) at the bottom must keep the latest message visible; \(describe(scroll))")
        }

        let anchor = try await scrollIntoHistory(scroll, model: model)
        let initialY = try XCTUnwrap(model.frames[anchor]).minY
        let sizes = [NSSize(width: 820, height: 540), NSSize(width: 590, height: 690),
                     NSSize(width: 440, height: 510), NSSize(width: 760, height: 620)]
            + stride(from: 740, through: 460, by: -40).map { NSSize(width: CGFloat($0), height: 620) }
        for size in sizes {
            window.setContentSize(size)
            let kept = await eventually {
                guard abs(scroll.contentView.bounds.height - size.height) < 1, let frame = model.frames[anchor] else { return false }
                // The reading row may be re-aligned to the top edge, but must
                // not drift further than that.
                return frame.minY > initialY - 35 && frame.minY < max(initialY, 0) + 35
            }
            let frame = model.frames[anchor]
            XCTAssertTrue(kept, "At \(size) the reading message moved from y=\(initialY) to \(String(describing: frame))")
            XCTAssertFalse(atBottom(scroll), "Resizing in history must not jump to latest at \(size)")
        }
    }

    /// A reader in history is not moved by an incoming message or a taller
    /// composer. Scrolling back down reaches the bottom, and the transcript then
    /// follows new messages again.
    func testIncomingMessagesLeaveAReaderInHistoryAndFollowOnceBackAtTheBottom() async throws {
        let model = ResizeModel()
        let root = mount(ResizeFixture(model: model))
        try XCTUnwrap(root.window).setContentSize(.init(width: 760, height: 620))
        let scroll = try await transcriptScroll(in: root)
        let followed = await eventually { self.atBottom(scroll) }
        XCTAssertTrue(followed, "The transcript must start on the latest message")
        let anchor = try await scrollIntoHistory(scroll, model: model)
        let readingY = try XCTUnwrap(model.frames[anchor]).minY

        var height = try XCTUnwrap(scroll.documentView).frame.height
        model.ids.append(UUID())
        let appended = await eventually { scroll.documentView!.frame.height > height }
        XCTAssertTrue(appended, "The incoming message must extend the transcript")
        XCTAssertEqual(try XCTUnwrap(model.frames[anchor]).minY, readingY, accuracy: 2,
            "An incoming message must not move a reader in history")

        height = scroll.documentView!.frame.height
        model.overlayHeight = 140
        let grew = await eventually { scroll.documentView!.frame.height > height }
        XCTAssertTrue(grew, "A taller composer must extend the transcript's clearance")
        XCTAssertEqual(try XCTUnwrap(model.frames[anchor]).minY, readingY, accuracy: 2,
            "A taller composer must not move a reader in history")

        await gesture(scroll, deltas: Array(repeating: -1200, count: 8))
        let returned = await eventually { self.atBottom(scroll) && model.saved.isAtBottom }
        XCTAssertTrue(returned, "Scrolling down must reach the bottom and save it")

        height = scroll.documentView!.frame.height
        model.ids.append(UUID())
        let follows = await eventually { scroll.documentView!.frame.height > height && self.atBottom(scroll) }
        XCTAssertTrue(follows, "A new message must be followed once the reader is back at the bottom")
    }

    // MARK: - Helpers

    /// Hosted transcripts; a window that is never ordered in gets no display
    /// cycle, so polling lays them out the way a visible window would.
    private var roots: [NSView] = []

    private func mount<V: View>(_ view: V) -> NSHostingView<V> {
        let root = host(view)
        roots.append(root)
        return root
    }

    /// Polls until `predicate` holds, returning false after `seconds` so the
    /// caller can fail with its own message.
    private func eventually(seconds: Double = 5, _ predicate: () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        while true {
            for root in roots where root.window != nil { root.layoutSubtreeIfNeeded(); root.displayIfNeeded() }
            if predicate() { return true }
            guard ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll($0) }.first
    }

    private func transcriptScroll(in root: NSView) async throws -> NSScrollView {
        var scroll: NSScrollView?
        try await wait {
            root.layoutSubtreeIfNeeded()
            scroll = self.findScroll(root)
            return scroll?.documentView != nil
        }
        return try XCTUnwrap(scroll)
    }

    private func describe(_ scroll: NSScrollView) -> String {
        "offset \(scroll.contentView.bounds.minY) in \(scroll.contentView.bounds.size) of \(scroll.documentView?.frame.height ?? 0), insets \(scroll.contentInsets)"
    }

    private func atBottom(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return false }
        return TranscriptScrollMetrics(contentOffset: scroll.contentView.bounds.minY,
            contentHeight: document.frame.height, viewportHeight: scroll.contentView.bounds.height,
            topInset: scroll.contentInsets.top, bottomInset: scroll.contentInsets.bottom).isAtBottom
    }

    /// Delivers a whole trackpad gesture straight to the view, not through the
    /// system: touch down, the moves, lift-off and an empty momentum phase, one
    /// frame apart so each event reaches SwiftUI's scroll phase handling.
    private func gesture(_ scroll: NSScrollView, deltas: [Int32]) async {
        // CoreGraphics phases: scroll began 1, changed 2, ended 4; momentum began 1, ended 3.
        let events: [(delta: Int32, phase: Int64, momentum: Int64)] =
            [(0, 1, 0)] + deltas.map { ($0, 2, 0) } + [(0, 4, 0), (0, 0, 1), (0, 0, 3)]
        for step in events {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: step.delta, wheel2: 0, wheel3: 0)!
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: step.phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: step.momentum)
            scroll.scrollWheel(with: NSEvent(cgEvent: event)!)
            scroll.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// Scrolls well away from the bottom and returns the topmost visible row.
    private func scrollIntoHistory(_ scroll: NSScrollView, model: ResizeModel) async throws -> UUID {
        await gesture(scroll, deltas: Array(repeating: 600, count: 4))
        let settled = await eventually { !self.atBottom(scroll) && !model.saved.isAtBottom && model.saved.messageID != nil }
        XCTAssertTrue(settled, "The fixture must scroll into older messages; offset \(scroll.contentView.bounds.minY) of \(scroll.documentView?.frame.height ?? 0), saved \(model.saved)")
        let viewport = scroll.contentView.bounds.height
        let candidates = model.frames.filter { $0.value.maxY > 0 && $0.value.minY < viewport - 100 }
        return try XCTUnwrap(candidates.min { $0.value.minY < $1.value.minY }?.key)
    }
}

@MainActor private final class StartupModel: ObservableObject {
    let conversationID = UUID()
    @Published var ids: [UUID] = []
    @Published var overlay: CGFloat = 0
    var visible: Set<UUID> = []
    let initialViewport: TranscriptViewport
    var lastMessageIsFromUser = false
    var persist: ((TranscriptViewport) -> Void)?

    init(initialViewport: TranscriptViewport = TranscriptViewport()) { self.initialViewport = initialViewport }

    func indices(of ids: Set<UUID>) -> [Int] { ids.compactMap { self.ids.firstIndex(of: $0) }.sorted() }
}

/// The chat's transcript arrangement: a dissolve surface, a header, rows with
/// attachment placeholders, a top fade and a composer overlaid at the bottom.
private struct StartupFixture: View {
    @ObservedObject var model: StartupModel
    var body: some View {
        ConversationTransition(conversationID: model.conversationID) {
            transcript
                .id(model.conversationID)
                .transaction { $0.animation = nil }
        }
        .overlay(alignment: .bottom) { Text("Composer").frame(height: 60) }
    }

    private var transcript: some View {
        TranscriptScrollView(initialViewport: model.initialViewport, lastMessageID: model.ids.last,
            lastMessageIsFromUser: model.lastMessageIsFromUser, bottomOverlayHeight: model.overlay,
            saveViewport: { model.persist?($0) }) {
            Text("Conversation header").frame(height: 180).id(TranscriptScrollTarget.start)
            ForEach(Array(model.ids.enumerated()), id: \.element) { index, id in
                HStack(alignment: .bottom) {
                    Circle().fill(.blue).frame(width: 27, height: 27)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Message \(index) " + String(repeating: "A paragraph of selectable conversation text. ", count: index % 17 + 1))
                            .font(.system(size: 12.5)).textSelection(.enabled)
                            .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                        if index % 13 == 0 || id == model.ids.last {
                            ForEach(0..<2) { attachment in
                                VStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.2)).frame(width: 280, height: 166)
                                    Text("Document \(attachment).pdf").font(.caption)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 120)
                }
                .onScrollVisibilityChange(threshold: 0.01) { visible in
                    if visible { model.visible.insert(id) } else { model.visible.remove(id) }
                }
                .onDisappear { model.visible.remove(id) }
                .id(TranscriptScrollTarget.message(id))
            }
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom).frame(height: 88)
                Color.white
            }.ignoresSafeArea(edges: .top)
        }
    }
}

@MainActor private final class ResizeModel: ObservableObject {
    @Published var ids = (0..<100).map { _ in UUID() }
    @Published var overlayHeight: CGFloat = 70
    var frames: [UUID: CGRect] = [:]
    var saved = TranscriptViewport()
}

/// Rows whose text wraps into more lines as the window narrows, reporting their
/// frames in the scroll view's coordinates.
private struct ResizeFixture: View {
    @ObservedObject var model: ResizeModel
    var body: some View {
        TranscriptScrollView(initialViewport: TranscriptViewport(), lastMessageID: model.ids.last,
            lastMessageIsFromUser: false, bottomOverlayHeight: model.overlayHeight,
            saveViewport: { model.saved = $0 }) {
            ForEach(Array(model.ids.enumerated()), id: \.element) { index, id in
                Text("Message \(index)\n" + String(repeating:
                    "A conversation paragraph wraps into more lines as the window becomes narrower. ", count: index % 5 + 2))
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { model.frames[id] = $0 }
                    .onDisappear { model.frames.removeValue(forKey: id) }
                    .id(TranscriptScrollTarget.message(id))
            }
        }
    }
}
