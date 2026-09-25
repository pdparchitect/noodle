import AppKit

/// Shared by Applet and embedded in native noodlets. Plays a noodlet's window full screen on
/// another display, such as a TV added through AirPlay. Full screen needs a normal, resizable
/// window without size limits, so casting lifts what the manifest set, and leaving full screen
/// puts it all back. A window the manifest fixed in size keeps that size on the new screen, on
/// a stage that scales it to fit.
@MainActor final class NoodletCast {
    /// macOS only lets people add an AirPlay display themselves, from Displays settings.
    static let displaysSettings = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!
    let window: NSWindow
    var changed: (() -> Void)?
    private var saved: (styleMask: NSWindow.StyleMask, minSize: CGSize, maxSize: CGSize, level: NSWindow.Level, behavior: NSWindow.CollectionBehavior, frame: CGRect)?
    private var stage: NoodletStage?
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
        if !window.styleMask.contains(.resizable) || window.contentMinSize == window.contentMaxSize, let content = window.contentView {
            let size = window.contentRect(forFrameRect: window.frame).size
            keepingFocus {
                stage = NoodletStage(content, size: size)
                window.contentView = stage
            }
        }
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
        if let stage {
            self.stage = nil
            keepingFocus { window.contentView = stage.release() }
        }
        window.styleMask = saved.styleMask
        window.contentMinSize = saved.minSize
        window.contentMaxSize = saved.maxSize
        window.level = saved.level
        window.collectionBehavior = saved.behavior
        window.setFrame(saved.frame, display: true)
        changed?()
    }

    /// Moving the content between views drops keyboard focus, which a game needs back.
    private func keepingFocus(_ move: () -> Void) {
        let responder = window.firstResponder
        move()
        if let responder { window.makeFirstResponder(responder) }
    }
}

/// Lays the content out at its own size and scales it up as far as it fits without stretching,
/// centred on black. Scaling through bounds keeps it sharp and clicks landing where they should.
@MainActor final class NoodletStage: NSView {
    private let content: NSView
    private let size: CGSize
    private let mask: NSView.AutoresizingMask
    private let scaler = NSView()

    init(_ content: NSView, size: CGSize) {
        self.content = content
        self.size = size
        mask = content.autoresizingMask
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        scaler.autoresizesSubviews = false
        content.removeFromSuperview()
        content.autoresizingMask = []
        content.frame = CGRect(origin: .zero, size: size)
        scaler.addSubview(content)
        addSubview(scaler)
        fit()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Hands the content back as it came, ready to be a window's content view again.
    func release() -> NSView {
        content.removeFromSuperview()
        content.autoresizingMask = mask
        return content
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fit()
    }

    private func fit() {
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        scaler.frame = CGRect(x: (bounds.width - fitted.width) / 2, y: (bounds.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
        scaler.setBoundsSize(size)
    }
}
