import AppKit
import BrowserBridge
import WebKit

/// Tab-local input. No event is posted to the window server and NSCursor is
/// never changed. WebKit performs its own hit testing and hover.
@MainActor final class BrowserPointer {
    private unowned let web: WKWebView
    let overlay = BrowserPointerView(frame: .zero)
    private(set) var position: CGPoint?
    private(set) var pressed = false
    private weak var pressedView: NSView?
    private weak var eventView: NSView?
    private var pulseTask: Task<Void, Never>?
    private var pulsing = false
    private var eventNumber = 0

    init(web: WKWebView) {
        self.web = web
        overlay.frame = web.bounds
        overlay.autoresizingMask = [.width, .height]
        web.addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    var state: BrowserPointerState {
        .init(x: Double(position?.x ?? 0), y: Double(position?.y ?? 0), visible: position != nil, pressed: pressed)
    }

    func move(to point: CGPoint) throws {
        guard web.bounds.contains(point), web.window != nil else { throw BrowserError("Pointer is outside the browser viewport.") }
        // WebKit limits ordinary moves in inactive windows to scrollbar hit
        // testing. A local drag-motion event takes its full pointer path without
        // changing the desktop's pressed buttons or producing a mouse-down.
        try send(.leftMouseDragged, at: point)
        position = point
        display()
    }

    func down(count: Int = 1) throws {
        guard !pressed else { throw BrowserError("Mouse is already pressed.") }
        guard let position else { throw BrowserError("Move the mouse to a target before pressing it.") }
        pressedView = hit(at: position)
        try send(.leftMouseDown, at: position, count: count)
        pressed = true
        display()
    }

    func up(count: Int = 1) throws {
        guard pressed, let position else { throw BrowserError("Mouse is not pressed.") }
        defer { pressed = false; pressedView = nil; pulse() }
        try send(.leftMouseUp, at: position, count: count)
    }

    func reset() {
        pulseTask?.cancel(); pulseTask = nil; pulsing = false
        if position != nil {
            let outside = CGPoint(x: -100, y: -100)
            try? send(.leftMouseDragged, at: outside)
            if pressed { try? send(.leftMouseUp, at: outside) }
        }
        pressed = false; pressedView = nil; position = nil; display()
    }

    private func pulse() {
        pulseTask?.cancel(); pulsing = true; display()
        pulseTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            self?.pulsing = false; self?.display()
        }
    }

    private func local(_ point: CGPoint) -> CGPoint {
        web.isFlipped ? point : CGPoint(x: point.x, y: web.bounds.height - point.y)
    }
    private func hit(at point: CGPoint) -> NSView { web.hitTest(local(point)) ?? web }
    private func send(_ type: NSEvent.EventType, at point: CGPoint, count: Int = 0) throws {
        guard let window = web.window else { throw BrowserError("Browser viewport is unavailable.") }
        eventNumber += 1
        let location = web.convert(local(point), to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: location,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: eventNumber, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)
        else { throw BrowserError("Could not create browser mouse input.") }
        let candidate = hit(at: point)
        let receiver = pressedView ?? (candidate === web ? eventView ?? web : candidate)
        eventView = receiver
        switch type {
        case .leftMouseDown: receiver.mouseDown(with: event)
        case .leftMouseDragged: receiver.mouseDragged(with: event)
        case .leftMouseUp: receiver.mouseUp(with: event)
        default: break
        }
    }

    private func display() {
        overlay.position = position; overlay.pressed = pressed || pulsing; overlay.needsDisplay = true
    }

    /// WKWebView snapshots contain page pixels, not AppKit overlay subviews.
    func annotate(_ image: NSImage, state: BrowserPointerState, viewport: CGSize) -> NSImage {
        guard state.visible else { return image }
        let result = NSImage(size: image.size)
        result.lockFocusFlipped(true)
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let point = CGPoint(x: state.x * image.size.width / viewport.width, y: state.y * image.size.height / viewport.height)
        BrowserPointerView.drawMarker(at: point, pressed: state.pressed)
        result.unlockFocus()
        return result
    }
}

/// A cyan target with a small diamond distinguishes agent input from the user's
/// system cursor. It never participates in hit testing or accessibility focus.
@MainActor final class BrowserPointerView: NSView {
    var position: CGPoint?
    var pressed = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        if let position { Self.drawMarker(at: position, pressed: pressed) }
    }
    static func drawMarker(at point: CGPoint, pressed: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 4; shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
        let colour = NSColor(calibratedRed: 0.02, green: 0.78, blue: 0.96, alpha: 1)
        let ring = NSBezierPath(ovalIn: NSRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
        colour.withAlphaComponent(pressed ? 0.65 : 0.15).setFill(); ring.fill()
        NSColor.white.setStroke(); ring.lineWidth = 4; ring.stroke()
        colour.setStroke(); ring.lineWidth = 2; ring.stroke()
        let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5))
        colour.setFill(); dot.fill()
        let diamond = NSBezierPath()
        diamond.move(to: NSPoint(x: point.x + 14, y: point.y + 6))
        diamond.line(to: NSPoint(x: point.x + 19, y: point.y + 11))
        diamond.line(to: NSPoint(x: point.x + 14, y: point.y + 16))
        diamond.line(to: NSPoint(x: point.x + 9, y: point.y + 11)); diamond.close()
        NSColor.white.setStroke(); diamond.lineWidth = 2; diamond.stroke(); colour.setFill(); diamond.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
