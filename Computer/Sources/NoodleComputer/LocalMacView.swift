import AppKit
import ComputerCore
import LocalMacCore
import SwiftUI

struct NewLocalMacView: View {
    @ObservedObject var store: ComputerStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("StartNewComputersAutomatically") private var startNewComputersAutomatically = true
    @State private var name = "My Local Mac"
    @State private var appearance = ComputerAppearance()
    @State private var failure: String?
    private var creating: Bool { store.creationStatus != nil }
    private var draft: Computer {
        var computer = Computer(name: name, kind: .localMac)
        computer.appearance = appearance
        return computer
    }
    private var canCreate: Bool { !creating && (try? draft.validate()) != nil }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .foregroundStyle(.blue).disabled(creating)
                Spacer()
                Text("New Local Mac").font(.headline)
                Spacer()
                Button("Create") {
                    Task {
                        let computer = draft
                        if await store.create(computer, source: nil) {
                            dismiss()
                            if startNewComputersAutomatically,
                               let session = store.sessions.first(where: { $0.id == computer.id }) {
                                await store.start(session)
                            }
                        } else {
                            failure = store.creationWasCancelled ? nil : store.error
                            store.error = nil
                        }
                    }
                }.keyboardShortcut(.defaultAction).disabled(!canCreate)
                    .foregroundStyle(canCreate ? Color.blue : .secondary)
            }.buttonStyle(.plain).padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    ComputerIconButton(appearance: $appearance, symbol: ComputerKind.localMac.symbol)
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled().lineLimit(1)
                }.padding(12).background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12))
                Text("A separate account on this Mac, with its own desktop and files. It shares this Mac’s operating system, storage and network.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Administrator approval and desktop permissions are required on first use. Stopping keeps the account and its files.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ComputerAppearanceRow(appearance: $appearance)
                if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }.padding(20).disabled(creating)
        }.frame(width: 520).noodleSheetSizing(animated: true)
            .interactiveDismissDisabled(creating)
    }
}

struct LocalMacDesktopView: View {
    @ObservedObject var runtime: LocalMacComputer
    var active = true
    var body: some View {
        VStack(spacing: 0) {
            if let status = runtime.status,
               !status.screenCapture || !status.accessibility || status.setupRunning || status.detail != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if !status.screenCapture || !status.accessibility {
                        Text("Allow Screen Recording and Accessibility for Noodle Local Mac Desktop.")
                        HStack {
                            Button("Screen Recording…") { openPrivacy("Privacy_ScreenCapture") }
                            Button("Accessibility…") { openPrivacy("Privacy_Accessibility") }
                            Button("Show Desktop Helper") { NSWorkspace.shared.activateFileViewerSelecting([LocalMacSetup.desktopApp]) }
                        }
                        Text("Add this helper using the + button in System Settings. Stop and start the computer after granting access.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if status.setupRunning {
                        Text("Account setup has been prepared. Stop and start this computer to open its desktop.")
                    }
                    if let detail = status.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
            }
            LocalMacSurface(runtime: runtime, active: active).background(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { if runtime.image == nil { ProgressView("Waiting for desktop…").allowsHitTesting(false) } }
            if let error = runtime.error {
                HStack { Text(error).font(.caption).textSelection(.enabled); Spacer(); Button("Dismiss") { runtime.error = nil } }.padding(8)
            }
        }.task {
            while !Task.isCancelled {
                await runtime.refreshStatus()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}

private struct LocalMacSurface: NSViewRepresentable {
    @ObservedObject var runtime: LocalMacComputer
    var active: Bool
    func makeNSView(context: Context) -> LocalMacImageView {
        let view = LocalMacImageView(); view.runtime = runtime
        view.setAccessibilityElement(true); view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Local Mac desktop")
        return view
    }
    func updateNSView(_ view: LocalMacImageView, context: Context) {
        view.runtime = runtime; view.active = active; view.needsDisplay = true
    }
}

enum LocalMacPointerEvent {
    static func make(_ event: NSEvent, kind: LocalMacInput.Kind, point: CGPoint, rect: CGRect, clamp: Bool = false) -> LocalMacInput? {
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        var input = LocalMacInput(kind)
        input.x = min(1, max(0, (point.x - rect.minX) / rect.width))
        input.y = min(1, max(0, (point.y - rect.minY) / rect.height))
        input.flags = event.cgEvent?.flags.rawValue ?? 0
        // These AppKit properties are specific to the native event type.
        if kind == .scroll { input.scroll = event.scrollingDeltaY }
        else {
            input.button = min(2, event.buttonNumber)
            input.clickCount = min(10, max(0, event.clickCount))
        }
        return input
    }
}

private final class LocalMacImageView: NSView {
    weak var runtime: LocalMacComputer?
    var active = true { didSet { if !active && oldValue { releaseInput() } } }
    private var heldButtons: Set<Int> = []
    private var interacting = false
    private var keyMonitor: Any?
    private var focusObserver: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        guard let window else { releaseInput(); return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.active, self.window?.isKeyWindow == true,
                  self.window?.firstResponder === self else { return event }
            // A local event monitor sees Command shortcuts before app menus do.
            if event.type == .keyDown, event.keyCode == 53,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] {
                self.window?.makeFirstResponder(nil); return nil
            }
            self.key(event, kind: event.type == .flagsChanged ? .flagsChanged : event.type == .keyUp ? .keyUp : .keyDown)
            return nil
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in self?.releaseInput() }
    }
    private func releaseInput() {
        heldButtons.removeAll()
        guard interacting else { return }
        interacting = false; runtime?.send(LocalMacInput(.reset))
    }
    override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var imageRect: CGRect {
        let size = runtime?.image?.size ?? NSSize(width: 1280, height: 800)
        let scale = min(bounds.width / max(1, size.width), bounds.height / max(1, size.height))
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        runtime?.image?.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    private func pointer(_ event: NSEvent, kind: LocalMacInput.Kind) {
        guard active else { return }
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        guard let input = LocalMacPointerEvent.make(event, kind: kind, point: point, rect: rect, clamp: !heldButtons.isEmpty) else { return }
        if kind == .down { heldButtons.insert(input.button) }
        else if kind == .up { heldButtons.remove(input.button) }
        interacting = true
        runtime?.send(input)
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, kind: .down) }
    override func mouseUp(with event: NSEvent) { pointer(event, kind: .up) }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, kind: .down) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, kind: .up) }
    override func mouseMoved(with event: NSEvent) { pointer(event, kind: .move) }
    override func mouseDragged(with event: NSEvent) { pointer(event, kind: .move) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event, kind: .move) }
    override func otherMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, kind: .down) }
    override func otherMouseUp(with event: NSEvent) { pointer(event, kind: .up) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event, kind: .move) }
    override func scrollWheel(with event: NSEvent) { pointer(event, kind: .scroll) }
    private func key(_ event: NSEvent, kind: LocalMacInput.Kind) {
        guard active else { return }
        interacting = true
        var input = LocalMacInput(kind); input.key = event.keyCode; input.flags = event.cgEvent?.flags.rawValue ?? 0
        runtime?.send(input)
    }
    override func keyDown(with event: NSEvent) { key(event, kind: .keyDown) }
    override func keyUp(with event: NSEvent) { key(event, kind: .keyUp) }
    override func flagsChanged(with event: NSEvent) { key(event, kind: .flagsChanged) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard active, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        key(event, kind: .keyDown); return true
    }
}
