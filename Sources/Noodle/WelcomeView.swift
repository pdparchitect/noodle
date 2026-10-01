import AppKit
import SwiftUI
import NoodleBrand
import NoodleWallpaper

/// The first launch, in the main window: the wordmark writes itself, then lifts to make room
/// for setting up an account.
struct WelcomeView: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        WordmarkWelcome(centred: true, continuesItself: true) {
            FirstBotSetupSheet(setup: store.harnessSetup, runtime: store.runtime)
        }
        // Flat: there is no title bar content for a header shade to set apart.
        .background {
            ConversationWallpaper(background: store.background(for: nil))
                .ignoresSafeArea()
        }
        .background(WelcomeCloseGuard { store.finishFirstBotSetup() })
        // The main window keeps its toolbar, and with it its shape, while the welcome fills it.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// While the welcome shows, the window's close button asks first, and closing counts as Not Now.
/// It borrows the button's action rather than the window's delegate, which SwiftUI owns.
private struct WelcomeCloseGuard: NSViewRepresentable {
    let leave: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window, leave: leave) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.leave = leave }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator: NSObject {
        var leave: @MainActor () -> Void = {}
        private weak var button: NSButton?
        private weak var originalTarget: AnyObject?
        private var originalAction: Selector?

        func attach(to window: NSWindow?, leave: @escaping @MainActor () -> Void) {
            guard button == nil, let button = window?.standardWindowButton(.closeButton) else { return }
            self.leave = leave
            self.button = button
            originalTarget = button.target
            originalAction = button.action
            button.target = self
            button.action = #selector(confirmClose(_:))
        }

        func detach() {
            guard let button else { return }
            button.target = originalTarget
            button.action = originalAction
            self.button = nil
        }

        @objc private func confirmClose(_ sender: NSButton) {
            guard let window = sender.window else { return }
            let alert = NSAlert()
            alert.messageText = "Leave the welcome?"
            alert.informativeText = "You can come back to it from Help > Welcome."
            alert.addButton(withTitle: "Leave")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                self.detach()
                self.leave()
                window.performClose(nil)
            }
        }
    }
}
