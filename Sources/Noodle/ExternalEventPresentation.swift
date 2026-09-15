import AppKit
import SwiftUI

/// Main app state belongs to one window; separate conversations use their own group.
struct MainWindowScene<Content: View>: Scene {
    @ViewBuilder var content: () -> Content
    var onOpenURL: (URL) -> Void

    var body: some Scene {
        Window("Noodle", id: "main") {
            content()
                .onOpenURL(perform: onOpenURL)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
    }
}

@MainActor final class ExternalEventReturnWindow {
    private weak var window: NSWindow?

    func capture() {
        let window = NSApp.keyWindow
        self.window = window?.sheetParent ?? window
    }

    func restore() {
        let target = window
        window = nil
        // Let SwiftUI finish routing the external event to the existing scene
        // before bringing the originating Settings window back to the front.
        DispatchQueue.main.async { [weak target] in
            guard let target, NSApp.windows.contains(where: { $0 === target }) else { return }
            if target.isMiniaturized { target.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            target.makeKeyAndOrderFront(nil)
        }
    }

    func clear() { window = nil }
}
