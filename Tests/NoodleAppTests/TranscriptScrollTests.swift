import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

/// The transcript's opening position, hosted in windows that are never ordered onscreen.
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
    private func eventually(seconds: Double = 15, _ predicate: () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(seconds))
        while true {
            for root in roots where root.window != nil { root.layoutSubtreeIfNeeded(); root.displayIfNeeded() }
            if predicate() { return true }
            guard ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
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
