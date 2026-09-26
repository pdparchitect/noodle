import AVFoundation
import SwiftUI

/// Where a live view's packets arrive. The view hands them straight to the display layer,
/// without redrawing SwiftUI for every frame.
@MainActor public final class SurfaceFeed {
    /// The surface's size in points, once the first packet says it.
    public private(set) var size: CGSize = .zero
    public private(set) var hasPicture = false
    fileprivate var show: ((SurfacePacket) -> Void)?
    fileprivate var keyboard: (() -> Void)?
    public var onFirstPicture: (() -> Void)?

    public init() {}

    /// Shows or hides the phone's keyboard, which types into whatever the person tapped.
    public func toggleKeyboard() { keyboard?() }

    public func receive(_ packets: [SurfacePacket]) {
        for packet in packets {
            size = packet.size
            show?(packet)
            if !hasPicture, packet.keyFrame { hasPicture = true; onFirstPicture?() }
        }
    }
}

/// Shows a surface's live video and turns what the person does over it into `SurfaceInput`.
public struct SurfaceView: View {
    let feed: SurfaceFeed
    let send: (SurfaceInput) -> Void

    public init(feed: SurfaceFeed, send: @escaping (SurfaceInput) -> Void) {
        self.feed = feed
        self.send = send
    }

    public var body: some View {
        SurfaceCanvas(feed: feed, send: send).background(.black)
    }
}

/// Decodes packets into the layer, starting at a key frame and whenever the stream's format changes.
@MainActor private final class SurfaceDisplay {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?

    init() { layer.videoGravity = .resizeAspect }

    func show(_ packet: SurfacePacket) {
        if packet.keyFrame, let next = SurfaceSamples.format(packet) {
            if let format, !CMFormatDescriptionEqual(format, otherFormatDescription: next) { layer.sampleBufferRenderer.flush() }
            format = next
        }
        guard let format, let sample = SurfaceSamples.sample(packet, format: format) else { return }
        if layer.sampleBufferRenderer.status == .failed { layer.sampleBufferRenderer.flush() }
        layer.sampleBufferRenderer.enqueue(sample)
    }
}

#if os(macOS)
import AppKit

private struct SurfaceCanvas: NSViewRepresentable {
    let feed: SurfaceFeed
    let send: (SurfaceInput) -> Void

    func makeNSView(context: Context) -> SurfaceNSView { SurfaceNSView(feed: feed) }

    func updateNSView(_ view: SurfaceNSView, context: Context) { view.send = send }
}

final class SurfaceNSView: NSView {
    var send: (SurfaceInput) -> Void = { _ in }
    private let feed: SurfaceFeed
    private let display = SurfaceDisplay()

    init(feed: SurfaceFeed) {
        self.feed = feed
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(display.layer)
        feed.show = { [display] in display.show($0) }
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        display.layer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func pointer(_ phase: SurfaceInput.Phase, _ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = SurfaceGeometry.surfacePoint(point, in: bounds.size, surface: feed.size) else { return }
        send(.pointer(phase, x: target.x, y: target.y, clickCount: max(1, event.clickCount)))
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(.down, event) }
    override func mouseDragged(with event: NSEvent) { pointer(.drag, event) }
    override func mouseUp(with event: NSEvent) { pointer(.up, event) }
    override func mouseMoved(with event: NSEvent) { pointer(.move, event) }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = SurfaceGeometry.surfacePoint(point, in: bounds.size, surface: feed.size) else { return }
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        send(.scroll(x: target.x, y: target.y, dx: -event.scrollingDeltaX * scale, dy: -event.scrollingDeltaY * scale))
    }

    override func keyDown(with event: NSEvent) {
        let keys: [UInt16: SurfaceInput.Key] = [36: .enter, 76: .enter, 48: .tab, 53: .escape, 51: .backspace, 49: .space,
                                                123: .left, 124: .right, 126: .up, 125: .down]
        if let key = keys[event.keyCode] { send(.key(key)) }
        else if let text = event.characters, !text.isEmpty, !event.modifierFlags.contains(.command) { send(.text(text)) }
        else { super.keyDown(with: event) }
    }
}
#else
import UIKit

private struct SurfaceCanvas: UIViewRepresentable {
    let feed: SurfaceFeed
    let send: (SurfaceInput) -> Void

    func makeUIView(context: Context) -> SurfaceUIView { SurfaceUIView(feed: feed) }

    func updateUIView(_ view: SurfaceUIView, context: Context) { view.send = send }
}

/// Taps click and a finger drag scrolls, as in Safari; the keyboard types into what is focused.
final class SurfaceUIView: UIView, UIKeyInput {
    var send: (SurfaceInput) -> Void = { _ in }
    private let feed: SurfaceFeed
    private let display = SurfaceDisplay()

    init(feed: SurfaceFeed) {
        self.feed = feed
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(display.layer)
        feed.show = { [display] in display.show($0) }
        feed.keyboard = { [weak self] in self?.toggleKeyboard() }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan)))
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        display.layer.frame = bounds
    }

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    func insertText(_ text: String) { send(text == "\n" ? .key(.enter) : .text(text)) }
    func deleteBackward() { send(.key(.backspace)) }

    private func target(_ gesture: UIGestureRecognizer) -> CGPoint? {
        SurfaceGeometry.surfacePoint(gesture.location(in: self), in: bounds.size, surface: feed.size)
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard let point = target(gesture) else { return }
        send(.pointer(.down, x: point.x, y: point.y))
        send(.pointer(.up, x: point.x, y: point.y))
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard let point = target(gesture) else { return }
        let moved = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        let scale = feed.size.width / max(1, SurfaceGeometry.fitted(feed.size, in: bounds.size).width)
        send(.scroll(x: point.x, y: point.y, dx: -moved.x * scale, dy: -moved.y * scale))
    }

    /// Shows or hides the keyboard, which types into whatever the person tapped.
    func toggleKeyboard() { if isFirstResponder { resignFirstResponder() } else { becomeFirstResponder() } }
}
#endif
