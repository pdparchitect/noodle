import AppKit
import Observation

/// Shows an app's error over the window in front, on top of any sheet it has, until OK.
/// A SwiftUI alert cannot: the window under a sheet is never key, and showing an alert
/// takes key from its own window, which dismissed it before anyone saw it.
@MainActor final class StoreErrorAlert {
    private let title: String
    /// Read while observed, so a new error shows as it is set.
    private let message: () -> String?
    private let clear: () -> Void
    /// The button that fixes this error, when there is one.
    private let link: (String) -> (title: String, url: URL)?
    /// The alert for this message closed, so its button is no longer wanted.
    private let linkUsed: (String) -> Void
    private let window: @MainActor () -> NSWindow?
    private let open: (URL) -> Void
    private var alert: NSAlert?
    private var keyObserver: NSObjectProtocol?

    /// The window in front, even while the app is in the background. None yet while the app
    /// itself is being made: NSApp is still nil then, and an error from the first load waits.
    static func frontWindow() -> NSWindow? {
        guard let app = NSApp else { return nil }
        return app.keyWindow ?? app.mainWindow ?? app.orderedWindows.first { $0.isVisible && $0.canBecomeMain }
    }

    init(title: String, message: @escaping () -> String?, clear: @escaping () -> Void,
         link: @escaping (String) -> (title: String, url: URL)? = { _ in nil }, linkUsed: @escaping (String) -> Void = { _ in },
         window: @escaping @MainActor () -> NSWindow? = StoreErrorAlert.frontWindow,
         open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.title = title
        self.message = message
        self.clear = clear
        self.link = link
        self.linkUsed = linkUsed
        self.window = window
        self.open = open
        // An error that arrived with no window open is shown once one is.
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.show(self?.message()) }
        }
        observe()
    }

    private func observe() {
        let current = withObservationTracking { message() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        show(current)
    }

    private func show(_ text: String?) {
        guard let text else {
            if let sheet = alert?.window, let parent = sheet.sheetParent { parent.endSheet(sheet) }
            return
        }
        if let alert { alert.informativeText = text; return }
        guard var parent = window() else { return }
        while let sheet = parent.attachedSheet { parent = sheet }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        let fix = link(text)
        if let fix { alert.addButton(withTitle: fix.title) }
        self.alert = alert
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self else { return }
            self.alert = nil
            if let fix, response == .alertSecondButtonReturn { self.open(fix.url) }
            linkUsed(alert.informativeText)
            if message() == alert.informativeText { clear() } else { show(message()) }
        }
    }
}
