import AppKit
import BrowserBridge

/// Watch this fixture's activation rather than requiring the user to keep the
/// same application frontmost throughout a background test.
@MainActor final class BrowserFocusProbe {
    private var activated = NSApp.isActive
    private var observer: NSObjectProtocol?
    init() {
        let pid = ProcessInfo.processInfo.processIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == pid else { return }
            MainActor.assumeIsolated { self?.activated = true }
        }
    }
    func verify() throws {
        guard !activated, NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw BrowserError("Browser fixture activated itself.") }
    }
    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer); self.observer = nil }
    }
}
