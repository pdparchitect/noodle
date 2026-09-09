import AppKit
import SwiftUI

extension View {
    // Without an explicit preference, WindowGroup can create another chat window
    // even when the application delegate has already consumed an OAuth URL.
    func reuseWindowForExternalEvents(perform action: @escaping (URL) -> Void) -> some View {
        onOpenURL(perform: action)
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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
