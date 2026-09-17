import AppKit
import LocalMacCore
import SwiftUI

struct LocalMacWindowPreview {
    let id = UUID()
    let window: LocalMacWindow
    var image: NSImage?
    var geometry: LocalMacWindowFrame?
    var error: String?
}

struct LocalMacFocusWindowButton: View {
    @ObservedObject var runtime: LocalMacComputer
    var enabled: Bool
    var body: some View {
        Button {
            guard enabled else { return }
            Task { await runtime.openWindowPreview() }
        } label: {
            Label("Focus Window", systemImage: "macwindow.on.rectangle")
        }
        .disabled(!enabled || !runtime.isConnected || runtime.status?.focusedWindow == nil || runtime.status?.canControl != true ||
                  runtime.status?.displayID == nil || runtime.windowPreview != nil)
        .help(runtime.status?.focusedWindow.map { "Focus Window: \($0.label)" } ?? "Focus Window")
    }
}

private struct LocalMacWindowPreviewContent: View {
    @ObservedObject var runtime: LocalMacComputer
    var body: some View {
        LocalMacSurface(runtime: runtime, active: runtime.windowPreview?.geometry != nil, preview: true)
            .background(.black)
            .overlay {
                if let error = runtime.windowPreview?.error {
                    Text(error).multilineTextAlignment(.center).padding(24)
                } else if runtime.windowPreview?.image == nil {
                    ProgressView("Opening window…").allowsHitTesting(false)
                }
            }
    }
}

/// The panel belongs to its viewer window and closes when that viewer disappears.
/// A separate stream/image never replaces the desktop or its saved screenshots.
struct LocalMacWindowPreviewPresenter: NSViewRepresentable {
    @ObservedObject var runtime: LocalMacComputer
    var active: Bool
    func makeCoordinator() -> Coordinator { Coordinator(runtime: runtime) }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) {
        context.coordinator.sync(parent: view.window, active: active)
    }
    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) { coordinator.dismiss() }

    final class Anchor: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindowChange?(window) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let runtime: LocalMacComputer
        private(set) var panel: NSPanel?
        private var previewID: UUID?
        private var sized = false
        private weak var observedParent: NSWindow?
        private var parentCloseObserver: NSObjectProtocol?
        init(runtime: LocalMacComputer) { self.runtime = runtime }
        func attach(to window: NSWindow?) { sync(parent: window, active: window != nil) }
        func sync(parent: NSWindow?, active: Bool) {
            guard active, let parent, let preview = runtime.windowPreview else { dismiss(); return }
            if observedParent !== parent {
                if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
                observedParent = parent
                parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                    object: parent, queue: .main) { [weak self] _ in
                    self?.dismiss(); self?.runtime.closeWindowPreview()
                }
            }
            if previewID != preview.id {
                dismiss()
                previewID = preview.id
                let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.title = preview.window.label
                panel.minSize = NSSize(width: 320, height: 220)
                panel.contentView = NSHostingView(rootView: LocalMacWindowPreviewContent(runtime: runtime))
                panel.delegate = self
                self.panel = panel
                parent.addChildWindow(panel, ordered: .above)
                panel.setFrameOrigin(CGPoint(x: parent.frame.midX - panel.frame.width / 2, y: parent.frame.midY - panel.frame.height / 2))
                panel.makeKeyAndOrderFront(nil)
            }
            if !sized, let geometry = preview.geometry, let panel {
                sized = true
                let screen = parent.screen?.visibleFrame ?? parent.frame
                let width = max(480, geometry.bounds.width), height = max(300, geometry.bounds.height)
                let scale = min(1, screen.width * 0.85 / width, screen.height * 0.85 / height)
                panel.setContentSize(NSSize(width: width * scale, height: height * scale))
                panel.setFrameOrigin(CGPoint(x: screen.midX - panel.frame.width / 2, y: screen.midY - panel.frame.height / 2))
                if let surface = findSurface(panel.contentView) { panel.makeFirstResponder(surface) }
            }
        }
        private func findSurface(_ view: NSView?) -> LocalMacImageView? {
            if let surface = view as? LocalMacImageView { return surface }
            return view?.subviews.lazy.compactMap { self.findSurface($0) }.first
        }
        func dismiss() {
            guard let panel else { return }
            self.panel = nil; previewID = nil; sized = false
            panel.delegate = nil
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
        func windowWillClose(_ notification: Notification) {
            if let panel { panel.parent?.removeChildWindow(panel) }
            panel = nil; previewID = nil; sized = false
            runtime.closeWindowPreview()
        }
        deinit { if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) } }
    }
}
