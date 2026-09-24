import AppKit

/// Shared by Applet and embedded in native noodlets. Plays a noodlet's window full screen on
/// another display, such as a TV added through AirPlay. Full screen needs a normal, resizable
/// window without size limits, so casting lifts what the manifest set, and leaving full screen
/// puts it all back.
@MainActor final class NoodletCast {
    /// macOS only lets people add an AirPlay display themselves, from Displays settings.
    static let displaysSettings = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!
    let window: NSWindow
    var changed: (() -> Void)?
    private var saved: (styleMask: NSWindow.StyleMask, minSize: CGSize, maxSize: CGSize, level: NSWindow.Level, behavior: NSWindow.CollectionBehavior, frame: CGRect)?
    private var observer: NSObjectProtocol?

    init(_ window: NSWindow) {
        self.window = window
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bringBack() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var canCast: Bool { !(window is NSPanel) }
    var isCasting: Bool { saved != nil }

    /// Full screen follows the display the window is on, so the window moves there first.
    func play(on screen: NSScreen) {
        guard canCast, !isCasting, !window.styleMask.contains(.fullScreen) else { return }
        lift(onto: screen)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.toggleFullScreen(nil)
    }

    func lift(onto screen: NSScreen) {
        saved = (window.styleMask, window.contentMinSize, window.contentMaxSize, window.level, window.collectionBehavior, window.frame)
        window.styleMask.insert(.resizable)
        window.contentMinSize = CGSize(width: 120, height: 120)
        window.contentMaxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        window.level = .normal
        window.collectionBehavior.remove(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.fullScreenPrimary)
        let visible = screen.visibleFrame
        let size = CGSize(width: min(window.frame.width, visible.width), height: min(window.frame.height, visible.height))
        window.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height), display: false)
        changed?()
    }

    /// Leaves full screen first; its notification brings the rest back.
    func bringBack() {
        guard let saved else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil); return }
        self.saved = nil
        window.styleMask = saved.styleMask
        window.contentMinSize = saved.minSize
        window.contentMaxSize = saved.maxSize
        window.level = saved.level
        window.collectionBehavior = saved.behavior
        window.setFrame(saved.frame, display: true)
        changed?()
    }
}
