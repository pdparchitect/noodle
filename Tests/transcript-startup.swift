import AppKit
import SwiftUI
import NoodleCore

@MainActor final class StartupModel: ObservableObject {
    let conversationID = UUID()
    @Published var ids: [UUID] = []
    @Published var overlay: CGFloat = 0
    var visible: Set<UUID> = []
    var saved = TranscriptViewport()
    let initialViewport: TranscriptViewport
    var lastMessageIsFromUser = false
    var persist: ((TranscriptViewport) -> Void)?

    init(initialViewport: TranscriptViewport = TranscriptViewport()) {
        self.initialViewport = initialViewport
    }
}

struct StartupFixture: View {
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
            saveViewport: { model.saved = $0; model.persist?($0) }) {
            Text("Conversation header").frame(height: 180).id(TranscriptScrollTarget.start)
            ForEach(model.ids, id: \.self) { id in
                let index = model.ids.firstIndex(of: id)!
                HStack(alignment: .bottom) {
                    Circle().fill(.blue).frame(width: 27, height: 27)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Message \(index) " + String(repeating: "A paragraph of selectable conversation text. ", count: index % 17 + 1))
                            .font(.system(size: 12.5)).textSelection(.enabled)
                            .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                        if index % 13 == 0 || id == model.ids.last {
                            ForEach(0..<2) { attachment in
                                VStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 12).fill(.gray.opacity(0.2))
                                        .frame(width: 280, height: 166)
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
                .transition(.move(edge: .bottom).combined(with: .opacity))
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

@main enum TranscriptStartupChecks {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { fatalError("Startup checks timed out") }
        Task { @MainActor in
            @MainActor func makeWindow(_ model: StartupModel, width: CGFloat) -> NSWindow {
                let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: 780),
                    styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: StartupFixture(model: model))
                window.makeKeyAndOrderFront(nil)
                return window
            }
            @MainActor func findScroll(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { findScroll($0) }.first
            }
            @MainActor func wheel(_ scroll: NSScrollView, delta: Int32, phase: Int64) {
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                    wheel1: delta, wheel2: 0, wheel3: 0)!
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                scroll.scrollWheel(with: NSEvent(cgEvent: event)!)
            }
            for width: CGFloat in [820, 550, 1100] {
                let model = StartupModel()
                let window = makeWindow(model, width: width)
                try? await Task.sleep(for: .milliseconds(50))
                model.ids = (0..<180).map { _ in UUID() }
                model.overlay = 75
                try? await Task.sleep(for: .milliseconds(800))
                print("Initial width \(width): \(model.visible.count) visible messages; last visible=\(model.visible.contains(model.ids.last!))")
                precondition(model.visible.contains(model.ids.last!), "Attachment-heavy history must render its last message without scrolling")
                window.close()
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-startup-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("scroll-positions.json"), conversationID = UUID()
            let positions = TranscriptPositionStore(fileURL: file)
            let original = StartupModel()
            original.ids = (0..<180).map { _ in UUID() }
            original.overlay = 75
            original.persist = { try! positions.save($0, for: conversationID) }
            let originalWindow = makeWindow(original, width: 820)
            try? await Task.sleep(for: .milliseconds(800))
            let scroll = findScroll(originalWindow.contentView!)!
            wheel(scroll, delta: 0, phase: 1)
            for _ in 0..<10 {
                wheel(scroll, delta: 600, phase: 2)
                try? await Task.sleep(for: .milliseconds(100))
            }
            wheel(scroll, delta: 0, phase: 4)
            try? await Task.sleep(for: .milliseconds(1000))
            let checkpoint = positions.viewport(for: conversationID)
            print("Checkpoint index=\(checkpoint.messageID.flatMap { original.ids.firstIndex(of: $0) } as Any), visible=\(original.visible.compactMap { original.ids.firstIndex(of: $0) }.sorted()), offset=\(checkpoint.offset)")
            precondition(!checkpoint.isAtBottom && checkpoint.messageID != nil, "Scrolling must persist a reading message")
            originalWindow.close()

            let relaunchedPositions = TranscriptPositionStore(fileURL: file)
            let restored = relaunchedPositions.viewport(for: conversationID)
            precondition(restored == checkpoint, "Closing must not replace the saved reading position with teardown geometry")
            let relaunched = StartupModel(initialViewport: restored)
            relaunched.lastMessageIsFromUser = true
            let restoredWindow = makeWindow(relaunched, width: 550)
            try? await Task.sleep(for: .milliseconds(50))
            relaunched.ids = original.ids
            relaunched.overlay = 75
            try? await Task.sleep(for: .milliseconds(1000))
            print("Restored visible=\(relaunched.visible.compactMap { relaunched.ids.firstIndex(of: $0) }.sorted())")
            precondition(relaunched.visible.contains(restored.messageID!), "Relaunch at a different width must restore the saved reading message without scrolling")
            precondition(!relaunched.visible.contains(relaunched.ids.last!), "Restoring history must not jump to latest")
            restoredWindow.close()

            let remaining = original.ids.filter { $0 != restored.messageID }
            let fallback = StartupModel(initialViewport: restored.restored(availableMessageIDs: Set(remaining)))
            fallback.ids = remaining
            fallback.overlay = 75
            let fallbackWindow = makeWindow(fallback, width: 820)
            try? await Task.sleep(for: .milliseconds(800))
            precondition(fallback.visible.contains(remaining.last!), "A removed reading message must fall back to visible latest content")
            fallbackWindow.close()

            let switchingWindow = makeWindow(original, width: 820)
            let switchingHost = switchingWindow.contentView as! NSHostingView<StartupFixture>
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<5 {
                for model in [relaunched, original] {
                    model.visible.removeAll()
                    switchingHost.rootView = StartupFixture(model: model)
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
            precondition(original.visible.contains(original.ids.last!), "Rapid navigation must settle on the latest selected transcript")
            relaunched.visible.removeAll()
            switchingHost.rootView = StartupFixture(model: relaunched)
            try? await Task.sleep(for: .milliseconds(300))
            precondition(relaunched.visible.contains(restored.messageID!), "A dissolve must preserve the returning conversation's reading position")
            switchingWindow.close()
            print("Transcript startup checks passed: attachment-heavy initial rendering, delayed loading, persisted reading position, changed-width relaunch, deleted-message fallback and rapid conversation switching")
            exit(0)
        }
        app.run()
    }
}
