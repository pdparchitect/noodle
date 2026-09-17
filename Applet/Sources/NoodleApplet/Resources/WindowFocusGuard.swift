import AppKit

/// Shared by the suite through NoodleSettingsUI and embedded in native noodlets.
/// Intercept physical app events before SwiftUI, WebKit, or custom views can
/// accept first mouse. Direct window/responder dispatch used by agents bypasses
/// this monitor and never activates a background window.
@MainActor public final class WindowFocusGuard: NSObject {
    public static let shared = WindowFocusGuard()

    private var monitor: Any?
    private var suppressedButtons: Set<Int> = []
    private let focusedAt = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    private var activatedAt: TimeInterval = 0
    private let focus: @MainActor (NSWindow) -> Void

    init(focus: @escaping @MainActor (NSWindow) -> Void = WindowFocusGuard.focusWindow) {
        self.focus = focus
        super.init()
    }

    public func start() {
        guard monitor == nil else { return }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged
        ]) { [weak self] event in
            guard let self else { return event }
            return self.filter(event, applicationActive: NSApp.isActive)
        }
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        NotificationCenter.default.removeObserver(self)
        suppressedButtons.removeAll()
        focusedAt.removeAllObjects()
        activatedAt = 0
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        focusedAt.setObject(NSNumber(value: ProcessInfo.processInfo.systemUptime), forKey: window)
    }

    @objc private func applicationBecameActive(_ notification: Notification) {
        activatedAt = ProcessInfo.processInfo.systemUptime
    }

    func filter(_ event: NSEvent, applicationActive: Bool) -> NSEvent? {
        switch event.type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return suppressedButtons.remove(event.buttonNumber) == nil ? event : nil
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return suppressedButtons.contains(event.buttonNumber) ? nil : event
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A missing mouse-up (for example after switching apps) must not
            // swallow the next independent click.
            suppressedButtons.remove(event.buttonNumber)
        default:
            return event
        }

        guard let window = event.window, window.isVisible, window.canBecomeKey,
              window.styleMask.contains(.titled) || window.isSheet,
              window.contentLayoutRect.contains(event.locationInWindow) else { return event }
        // Preserve native title-bar dragging, resizing, and window buttons.
        // Menus, popovers, and non-key panels retain their AppKit behavior; a
        // transient popover need not become key to serve its focused parent.
        let nonactivating = window.styleMask.contains(.nonactivatingPanel)
        let hasFocus = window.isKeyWindow && (applicationActive || nonactivating)
        // AppKit may activate the application / restore its key window before
        // delivering the mouse-down that caused it. Compare event time with the
        // notifications so that this click still only focuses the window.
        let focusTime = max(focusedAt.object(forKey: window)?.doubleValue ?? 0,
                            nonactivating ? 0 : activatedAt)
        guard !hasFocus || event.timestamp < focusTime else { return event }

        suppressedButtons.insert(event.buttonNumber)
        var target = window
        while let sheet = target.attachedSheet { target = sheet }
        focus(target)
        return nil
    }

    private static func focusWindow(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        if !window.styleMask.contains(.nonactivatingPanel) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
