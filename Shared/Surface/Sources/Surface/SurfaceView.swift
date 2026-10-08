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

/// Shows a surface's live video and turns what the person does over it into controls, with the
/// pixels it shows the surface at whenever that changes.
public struct SurfaceView: View {
    let feed: SurfaceFeed
    let send: (SurfaceControl) -> Void

    public init(feed: SurfaceFeed, send: @escaping (SurfaceControl) -> Void) {
        self.feed = feed
        self.send = send
    }

    public var body: some View {
        SurfaceCanvas(feed: feed, send: send).background(.black)
    }
}

/// Decodes packets into the layer, starting at a key frame and whenever the stream's format changes.
/// Video has key frames only when someone asks, so a display that cannot go on asks for one itself.
@MainActor final class SurfaceDisplay {
    let layer = AVSampleBufferDisplayLayer()
    /// Asks the companion for a key frame.
    var needsKeyFrame: (() -> Void)?
    private var format: CMVideoFormatDescription?
    /// Frames until the next key frame build on a picture the layer does not have.
    private var waiting = true
    private var asked = false

    init() { layer.videoGravity = .resizeAspect }

    func show(_ packet: SurfacePacket) {
        let renderer = layer.sampleBufferRenderer
        // As after the app was in the background on iPhone.
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            wait()
        }
        if packet.keyFrame, let next = SurfaceSamples.format(packet) {
            if let format, !CMFormatDescriptionEqual(format, otherFormatDescription: next) { renderer.flush() }
            format = next
            (waiting, asked) = (false, false)
        }
        guard !waiting, let format, let sample = SurfaceSamples.sample(packet, format: format) else { return wait() }
        renderer.enqueue(sample)
    }

    private func wait() {
        waiting = true
        guard !asked else { return }
        asked = true
        needsKeyFrame?()
    }
}

#if os(macOS)
import AppKit

private struct SurfaceCanvas: NSViewRepresentable {
    let feed: SurfaceFeed
    let send: (SurfaceControl) -> Void

    func makeNSView(context: Context) -> SurfaceNSView { SurfaceNSView(feed: feed) }

    func updateNSView(_ view: SurfaceNSView, context: Context) { view.control = send }
}

final class SurfaceNSView: NSView {
    /// Where controls go. Whoever that is learns the view's size and the last frame it has shown,
    /// or none, which also says it will say what it shows.
    var control: (SurfaceControl) -> Void = { _ in } {
        didSet {
            reported = nil
            reportSize()
            control(.shown(sequence: shown))
        }
    }
    private let feed: SurfaceFeed
    private let display = SurfaceDisplay()
    private var reported: CGSize?
    private var shown: UInt64 = 0

    private func send(_ input: SurfaceInput) { control(.input(input)) }

    private func reportSize() {
        let pixels = convertToBacking(bounds).size
        guard pixels.width > 0, pixels.height > 0, pixels != reported else { return }
        reported = pixels
        control(.view(width: pixels.width, height: pixels.height))
    }

    init(feed: SurfaceFeed) {
        self.feed = feed
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(display.layer)
        feed.show = { [weak self, display] packet in
            display.show(packet)
            // The Hub measures how late video arrives by it.
            self?.shown = packet.sequence
            self?.control(.shown(sequence: packet.sequence))
        }
        display.needsKeyFrame = { [weak self] in self?.control(.keyFrame) }
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        display.layer.frame = bounds
        reportSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reportSize()
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
    let send: (SurfaceControl) -> Void

    func makeUIView(context: Context) -> SurfaceUIView { SurfaceUIView(feed: feed) }

    func updateUIView(_ view: SurfaceUIView, context: Context) { view.control = send }
}

/// Taps click and a finger drag scrolls, as in Safari; touch and hold drags, two fingers zoom,
/// and the keyboard types into what is focused.
final class SurfaceUIView: UIView, UIKeyInput {
    /// Where controls go. Whoever that is learns the view's size and the last frame it has shown,
    /// or none, which also says it will say what it shows.
    var control: (SurfaceControl) -> Void = { _ in } {
        didSet {
            reported = nil
            reportSize()
            control(.shown(sequence: shown))
        }
    }
    private let feed: SurfaceFeed
    private let display = SurfaceDisplay()
    private var reported: CGSize?
    private var shown: UInt64 = 0
    private var touches = SurfaceTouches()
    /// Where the fingers of a pinch were last, to move the picture with them.
    private var pinched: CGPoint?

    private func send(_ input: SurfaceInput) { control(.input(input)) }

    private func reportSize() {
        let pixels = touches.pixels(bounds.size, screen: window?.screen.scale ?? traitCollection.displayScale)
        guard pixels.width > 0, pixels.height > 0, pixels != reported else { return }
        reported = pixels
        control(.view(width: pixels.width, height: pixels.height))
    }

    init(feed: SurfaceFeed) {
        self.feed = feed
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        layer.addSublayer(display.layer)
        feed.show = { [weak self, display] packet in
            display.show(packet)
            // The Hub measures how late video arrives by it.
            self?.shown = packet.sequence
            self?.control(.shown(sequence: packet.sequence))
        }
        display.needsKeyFrame = { [weak self] in self?.control(.keyFrame) }
        feed.keyboard = { [weak self] in self?.toggleKeyboard() }
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pan))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(hold)))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch)))
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        place()
        reportSize()
    }

    /// Lays the picture where the zoom puts it, following the fingers without animating.
    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.layer.frame = touches.zoomed ? touches.frame(feed.size, in: bounds.size) : bounds
        CATransaction.commit()
    }

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    func insertText(_ text: String) { send(text == "\n" ? .key(.enter) : .text(text)) }
    func deleteBackward() { send(.key(.backspace)) }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        touches.tap(gesture.location(in: self), surface: feed.size, view: bounds.size).forEach(send)
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let moved = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        touches.scroll(gesture.location(in: self), by: moved, surface: feed.size, view: bounds.size).forEach(send)
    }

    @objc private func hold(_ gesture: UILongPressGestureRecognizer) {
        let phase: SurfaceTouches.Hold
        switch gesture.state {
        case .began: phase = .began
        case .changed: phase = .moved
        case .ended, .cancelled, .failed: phase = .ended
        default: return
        }
        touches.hold(phase, at: gesture.location(in: self), surface: feed.size, view: bounds.size).forEach(send)
    }

    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began, .changed:
            let moved = pinched.map { CGPoint(x: point.x - $0.x, y: point.y - $0.y) } ?? .zero
            touches.zoom(by: gesture.scale, around: point, moved: moved, surface: feed.size, view: bounds.size)
            gesture.scale = 1
            pinched = point
            place()
        default:
            pinched = nil
            // Once the fingers are off, so the stream does not start again at every step of a pinch.
            reportSize()
        }
    }

    /// Shows or hides the keyboard, which types into whatever the person tapped.
    func toggleKeyboard() { if isFirstResponder { resignFirstResponder() } else { becomeFirstResponder() } }
}
#endif

/// A small notice for the top trailing corner of a surface while it is starting or not responding.
/// It only says so; clicks go through to whatever is under it.
public struct SurfaceNoticeView: View {
    private let notice: SurfaceNotice?

    public init(_ notice: SurfaceNotice?) { self.notice = notice }

    public var body: some View {
        ZStack {
            if let notice {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(notice.title)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
                .transition(.opacity)
            }
        }
        .animation(.default, value: notice)
        .allowsHitTesting(false)
    }
}
