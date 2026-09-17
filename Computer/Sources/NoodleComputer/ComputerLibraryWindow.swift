import AppKit
import SwiftUI

/// Document opens reuse the mounted library instead of asking SwiftUI to
/// present its scene again. Settings and Focus Window are separate windows.
@MainActor final class ComputerLibraryWindow {
    weak var host: ComputerLibraryWindowHost.View?

    @discardableResult func focus() -> Bool {
        guard let host, !host.isClosed, let window = host.window else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }
}

struct ComputerLibraryWindowHost: NSViewRepresentable {
    let library: ComputerLibraryWindow

    func makeNSView(context: Context) -> View { View(library: library) }
    func updateNSView(_ view: View, context: Context) {}

    final class View: NSView {
        let library: ComputerLibraryWindow
        private(set) var isClosed = false

        init(library: ComputerLibraryWindow) {
            self.library = library
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if library.host === self { library.host = nil }
            guard let window else { return }
            isClosed = false
            library.host = self
            NotificationCenter.default.addObserver(self, selector: #selector(closed),
                name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(opened),
                name: NSWindow.didBecomeKeyNotification, object: window)
        }

        @objc private func closed() { isClosed = true }
        @objc private func opened() { isClosed = false }
    }
}
