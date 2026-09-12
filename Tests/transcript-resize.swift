import AppKit
import SwiftUI
import NoodleCore

@MainActor final class TranscriptFixtureModel: ObservableObject {
    @Published var ids = (0..<100).map { _ in UUID() }
    @Published var overlayHeight: CGFloat = 70
    var frames: [UUID: CGRect] = [:]
    var saved = TranscriptViewport()
}

struct TranscriptResizeFixture: View {
    @ObservedObject var model: TranscriptFixtureModel
    var body: some View {
        TranscriptScrollView(initialViewport: TranscriptViewport(), lastMessageID: model.ids.last,
            lastMessageIsFromUser: false, bottomOverlayHeight: model.overlayHeight,
            saveViewport: { model.saved = $0 }) {
            ForEach(model.ids, id: \.self) { id in
                let index = model.ids.firstIndex(of: id)!
                Text("Message \(index)\n" + String(repeating:
                    "A conversation paragraph wraps into more lines as the window becomes narrower. ",
                    count: index % 5 + 2))
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    .onGeometryChange(for: CGRect.self) { proxy in proxy.frame(in: .scrollView) } action: {
                        model.frames[id] = $0
                    }
                    .onDisappear { model.frames.removeValue(forKey: id) }
                    .id(TranscriptScrollTarget.message(id))
            }
        }
    }
}

@main enum TranscriptResizeChecks {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = TranscriptFixtureModel()
        let window = NSWindow(contentRect: NSRect(x: 60, y: 80, width: 760, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Transcript Resize Tests"
        window.contentView = NSHostingView(rootView: TranscriptResizeFixture(model: model))
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { fatalError("Transcript resize checks timed out") }
        Task { @MainActor in
            func settle() async { try? await Task.sleep(for: .milliseconds(300)) }
            @MainActor func find(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            await settle()
            let scroll = find(window.contentView!)!
            @MainActor func atBottom() -> Bool {
                let inset = scroll.contentInsets
                return TranscriptScrollMetrics(contentOffset: scroll.contentView.bounds.minY,
                    contentHeight: scroll.documentView!.frame.height, viewportHeight: scroll.contentView.bounds.height,
                    topInset: inset.top, bottomInset: inset.bottom).isAtBottom
            }
            @MainActor func wheel(_ delta: Int32, phase: NSEvent.Phase) {
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                    wheel1: delta, wheel2: 0, wheel3: 0)!
                // CoreGraphics phases use different bits from NSEvent.Phase.
                let cgPhase: Int64 = phase == .began ? 1 : phase == .changed ? 2 : 4
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: cgPhase)
                let native = NSEvent(cgEvent: event)!
                precondition(native.phase == phase)
                scroll.scrollWheel(with: native)
            }
            precondition(atBottom(), "Transcript must initially follow the latest message")
            window.setContentSize(NSSize(width: 470, height: 540))
            await settle()
            precondition(atBottom(), "Resizing at the bottom must keep the latest message visible")
            wheel(0, phase: .began)
            wheel(2400, phase: .changed)
            await settle()
            wheel(0, phase: .ended)
            await settle()
            precondition(!atBottom() && !model.saved.isAtBottom, "Fixture must scroll into older messages")
            let candidates = model.frames.filter { $0.value.maxY > 0 && $0.value.minY < 500 }
            let anchor = candidates.min { $0.value.minY < $1.value.minY }!
            let initialY = anchor.value.minY
            print("Reading message \(model.ids.firstIndex(of: anchor.key)!), y=\(initialY)")
            for size in [NSSize(width: 820, height: 540), NSSize(width: 590, height: 690),
                         NSSize(width: 440, height: 510), NSSize(width: 760, height: 620)] {
                window.setContentSize(size)
                await settle()
                let frame = model.frames[anchor.key]!
                print("Resized to \(size): anchor y=\(frame.minY), height=\(frame.height)")
                precondition(frame.maxY > 0 && frame.minY < scroll.contentView.bounds.height,
                    "The message being read must remain visible during width/height reflow")
                precondition(abs(frame.minY - initialY) < 35, "The reading anchor must not jump within the viewport")
                precondition(!atBottom(), "Resizing older messages must not jump to latest")
            }
            // Small successive changes approximate dragging the window edge.
            for width in stride(from: 760, through: 460, by: -20) {
                window.setContentSize(NSSize(width: width, height: 620))
                try? await Task.sleep(for: .milliseconds(50))
                let frame = model.frames[anchor.key]!
                precondition(frame.maxY > 0 && frame.minY < 100,
                    "Live-style resizing must keep the reading message near the top")
            }
            await settle()
            let beforeAppend = model.frames[anchor.key]!.minY
            model.ids.append(UUID())
            await settle()
            precondition(abs(model.frames[anchor.key]!.minY - beforeAppend) < 2,
                "New incoming messages must not disturb a reader in history")
            model.overlayHeight = 140
            await settle()
            precondition(abs(model.frames[anchor.key]!.minY - beforeAppend) < 2,
                "Composer growth must not displace the reading anchor")
            wheel(0, phase: .began)
            for _ in 0..<8 {
                wheel(-1200, phase: .changed)
                await settle()
            }
            wheel(0, phase: .ended)
            try? await Task.sleep(for: .milliseconds(1000))
            precondition(atBottom(), "Scrolling down must still reach the bottom after resizing")
            precondition(model.saved.isAtBottom, "Wait for native rubber-banding to settle at the bottom")
            model.ids.append(UUID())
            await settle()
            precondition(atBottom(), "New messages must still follow when already at the bottom")

            @MainActor func atTop() -> Bool {
                let inset = scroll.contentInsets
                return TranscriptScrollMetrics(contentOffset: scroll.contentView.bounds.minY,
                    contentHeight: scroll.documentView!.frame.height, viewportHeight: scroll.contentView.bounds.height,
                    topInset: inset.top, bottomInset: inset.bottom).isAtTop
            }
            // SwiftUI builds no accessibility tree without a client, so click where the
            // bottom-anchored controls sit: 18 pt from the edge, 12 pt above the overlay.
            @MainActor func click(_ control: Int) {
                let point = NSPoint(x: window.contentView!.bounds.width - 33,
                                    y: model.overlayHeight + 27 + CGFloat(control) * 38)
                func event(_ type: NSEvent.EventType) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                // Queue the mouse-up first: a click on message text runs a nested
                // tracking loop that would otherwise wait for it forever.
                NSApp.postEvent(event(.leftMouseUp), atStart: false)
                window.sendEvent(event(.leftMouseDown))
            }
            let latest = 0, top = 1
            wheel(0, phase: .began)
            wheel(2400, phase: .changed)
            await settle()
            wheel(0, phase: .ended)
            await settle()
            click(top)
            try? await Task.sleep(for: .milliseconds(900))
            precondition(atTop() && !model.saved.isAtBottom, "Scroll to Top must reach and save the start")
            click(latest)
            try? await Task.sleep(for: .milliseconds(900))
            precondition(atBottom() && model.saved.isAtBottom, "Scroll to Latest must reach and save the bottom")
            model.ids.append(UUID())
            await settle()
            precondition(atBottom(), "Jumping to latest must resume following new messages")
            wheel(0, phase: .began)
            wheel(1200, phase: .changed)
            await settle()
            wheel(0, phase: .ended)
            try? await Task.sleep(for: .milliseconds(2600))
            click(top)
            click(latest)
            try? await Task.sleep(for: .milliseconds(900))
            precondition(!atTop() && !atBottom(), "Both controls must hide after scrolling stops")

            window.orderOut(nil)
            print("Transcript resize checks passed: message anchoring, width/height reflow, incoming messages, composer growth, follow-latest and jump controls")
            exit(0)
        }
        app.run()
    }
}
