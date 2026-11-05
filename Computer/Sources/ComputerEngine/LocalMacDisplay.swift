import AppKit
import LocalMacCore
import SwiftUI

public struct LocalMacSurface: NSViewRepresentable {
    @ObservedObject var runtime: LocalMacComputer
    var active: Bool
    var previewID: UUID?
    /// The memberwise initializer, which Swift keeps internal unless written out.
    public init(runtime: LocalMacComputer, active: Bool, previewID: UUID? = nil) {
        self.runtime = runtime; self.active = active; self.previewID = previewID
    }
    public func makeNSView(context: Context) -> LocalMacImageView {
        let view = LocalMacImageView(); view.runtime = runtime; view.previewID = previewID
        view.setAccessibilityElement(true); view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(previewID != nil ? "Application window" : "Local Mac desktop")
        return view
    }
    public func updateNSView(_ view: LocalMacImageView, context: Context) {
        view.runtime = runtime; view.previewID = previewID; view.active = active; view.needsDisplay = true
    }
}

enum LocalMacPointerEvent {
    static func make(_ event: NSEvent, kind: LocalMacInput.Kind, point: CGPoint, rect: CGRect, clamp: Bool = false) -> LocalMacInput? {
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        var input = LocalMacInput(kind)
        input.x = min(1, max(0, (point.x - rect.minX) / rect.width))
        input.y = min(1, max(0, (point.y - rect.minY) / rect.height))
        input.flags = event.cgEvent?.flags.rawValue ?? 0
        // These AppKit properties are specific to the native event type.
        if kind == .scroll { input.scroll = event.scrollingDeltaY }
        else {
            input.button = min(2, event.buttonNumber)
            input.clickCount = min(10, max(0, event.clickCount))
        }
        return input
    }
}

public final class LocalMacImageView: NSView {
    weak var runtime: LocalMacComputer?
    var previewID: UUID?
    private var displayedImage: NSImage?
    private var displayedGeometry: LocalMacWindowFrame?
    var active = true { didSet { if !active && oldValue { releaseInput() } } }
    private var heldButtons: Set<Int> = []
    private var interacting = false
    private var keyMonitor: Any?
    private var focusObserver: NSObjectProtocol?
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver); self.focusObserver = nil }
        guard let window else { releaseInput(); return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.active, self.window?.isKeyWindow == true,
                  self.window?.firstResponder === self else { return event }
            // A local event monitor sees Command shortcuts before app menus do.
            if event.type == .keyDown, event.keyCode == 53,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] {
                self.window?.makeFirstResponder(nil); return nil
            }
            self.key(event, kind: event.type == .flagsChanged ? .flagsChanged : event.type == .keyUp ? .keyUp : .keyDown)
            return nil
        }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in self?.releaseInput() }
    }
    private func releaseInput() {
        heldButtons.removeAll()
        guard interacting else { return }
        interacting = false
        var reset = LocalMacInput(.reset); reset.previewID = previewID
        runtime?.send(reset)
    }
    public override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }
    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var imageRect: CGRect {
        let size = displayedImage?.size ?? NSSize(width: 1280, height: 800)
        let scale = min(bounds.width / max(1, size.width), bounds.height / max(1, size.height))
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    public override func draw(_ dirtyRect: NSRect) {
        let frame = previewID.flatMap { runtime?.windowPreviews[$0] }
        displayedImage = previewID != nil ? frame?.image : runtime?.image
        displayedGeometry = frame?.geometry
        NSColor.black.setFill(); bounds.fill()
        displayedImage?.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
    // Match VZVirtualMachineView: the desktop blurs while its window is being
    // resized and sharpens again once the new size settles.
    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        guard previewID == nil, let blur = CIFilter(name: "CIGaussianBlur") else { return }
        blur.setValue(12, forKey: kCIInputRadiusKey)
        wantsLayer = true; layerUsesCoreImageFilters = true
        contentFilters = [blur]
    }
    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard !contentFilters.isEmpty else { return }
        let fade = CATransition(); fade.type = .fade; fade.duration = 0.25
        layer?.add(fade, forKey: "sharpen")
        contentFilters = []
    }
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    private func pointer(_ event: NSEvent, kind: LocalMacInput.Kind) {
        guard active else { return }
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        guard let input = LocalMacPointerEvent.make(event, kind: kind, point: point, rect: rect, clamp: !heldButtons.isEmpty) else { return }
        if kind == .down { heldButtons.insert(input.button) }
        else if kind == .up { heldButtons.remove(input.button) }
        interacting = true
        send(input)
    }
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, kind: .down) }
    public override func mouseUp(with event: NSEvent) { pointer(event, kind: .up) }
    public override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, kind: .down) }
    public override func rightMouseUp(with event: NSEvent) { pointer(event, kind: .up) }
    public override func mouseMoved(with event: NSEvent) { pointer(event, kind: .move) }
    public override func mouseDragged(with event: NSEvent) { pointer(event, kind: .move) }
    public override func rightMouseDragged(with event: NSEvent) { pointer(event, kind: .move) }
    public override func otherMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, kind: .down) }
    public override func otherMouseUp(with event: NSEvent) { pointer(event, kind: .up) }
    public override func otherMouseDragged(with event: NSEvent) { pointer(event, kind: .move) }
    public override func scrollWheel(with event: NSEvent) { pointer(event, kind: .scroll) }
    private func key(_ event: NSEvent, kind: LocalMacInput.Kind) {
        guard active else { return }
        interacting = true
        var input = LocalMacInput(kind); input.key = event.keyCode; input.flags = event.cgEvent?.flags.rawValue ?? 0
        send(input)
    }
    private func send(_ input: LocalMacInput) {
        var input = input
        if let previewID {
            guard let geometry = displayedGeometry, geometry.previewID == previewID,
                  runtime?.windowPreviews[previewID] != nil else { return }
            input.previewID = geometry.previewID; input.geometryID = geometry.geometryID
        }
        runtime?.send(input)
    }
    func activateWindow() {
        guard active, previewID != nil, window?.isKeyWindow == true else { return }
        interacting = true
        send(LocalMacInput(.activate))
    }
    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { activateWindow() }
        return accepted
    }
    public override func keyDown(with event: NSEvent) { key(event, kind: .keyDown) }
    public override func keyUp(with event: NSEvent) { key(event, kind: .keyUp) }
    public override func flagsChanged(with event: NSEvent) { key(event, kind: .flagsChanged) }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard active, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        key(event, kind: .keyDown); return true
    }
}
