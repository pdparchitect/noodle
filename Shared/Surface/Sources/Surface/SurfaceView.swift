import SwiftUI

/// Shows a surface's latest frame and turns what the person does over it into `SurfaceInput`.
public struct SurfaceView: View {
    let frame: SurfaceFrame?
    let send: (SurfaceInput) -> Void

    public init(frame: SurfaceFrame?, send: @escaping (SurfaceInput) -> Void) {
        self.frame = frame
        self.send = send
    }

    public var body: some View {
        SurfaceCanvas(frame: frame, send: send)
            .background(.black)
    }
}

#if os(macOS)
import AppKit

private struct SurfaceCanvas: NSViewRepresentable {
    let frame: SurfaceFrame?
    let send: (SurfaceInput) -> Void

    func makeNSView(context: Context) -> SurfaceNSView { SurfaceNSView() }

    func updateNSView(_ view: SurfaceNSView, context: Context) {
        view.send = send
        view.show(frame)
    }
}

final class SurfaceNSView: NSView {
    var send: (SurfaceInput) -> Void = { _ in }
    private var frameSize: CGSize = .zero
    private var picture: CGImage?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func show(_ frame: SurfaceFrame?) {
        guard let frame else { return }
        frameSize = frame.size
        picture = frame.cgImage
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let picture, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = SurfaceGeometry.fitted(frameSize, in: bounds.size)
        context.saveGState()
        // The view is flipped; draw the picture upright.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(picture, in: CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func pointer(_ phase: SurfaceInput.Phase, _ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = SurfaceGeometry.surfacePoint(point, in: bounds.size, surface: frameSize) else { return }
        send(.pointer(phase, x: target.x, y: target.y, clickCount: max(1, event.clickCount)))
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(.down, event) }
    override func mouseDragged(with event: NSEvent) { pointer(.drag, event) }
    override func mouseUp(with event: NSEvent) { pointer(.up, event) }
    override func mouseMoved(with event: NSEvent) { pointer(.move, event) }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = SurfaceGeometry.surfacePoint(point, in: bounds.size, surface: frameSize) else { return }
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
    let frame: SurfaceFrame?
    let send: (SurfaceInput) -> Void

    func makeUIView(context: Context) -> SurfaceUIView { SurfaceUIView() }

    func updateUIView(_ view: SurfaceUIView, context: Context) {
        view.send = send
        view.show(frame)
    }
}

final class SurfaceUIView: UIView {
    var send: (SurfaceInput) -> Void = { _ in }
    private let picture = UIImageView()
    private var frameSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        picture.contentMode = .scaleAspectFit
        addSubview(picture)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan)))
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        picture.frame = bounds
    }

    func show(_ frame: SurfaceFrame?) {
        guard let frame, let image = frame.cgImage else { return }
        frameSize = frame.size
        picture.image = UIImage(cgImage: image)
    }

    private func target(_ gesture: UIGestureRecognizer) -> CGPoint? {
        SurfaceGeometry.surfacePoint(gesture.location(in: self), in: bounds.size, surface: frameSize)
    }

    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard let point = target(gesture) else { return }
        send(.pointer(.down, x: point.x, y: point.y))
        send(.pointer(.up, x: point.x, y: point.y))
    }

    /// A finger drag scrolls the page, as it would in Safari.
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard let point = target(gesture) else { return }
        let moved = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        let scale = frameSize.width / max(1, SurfaceGeometry.fitted(frameSize, in: bounds.size).width)
        send(.scroll(x: point.x, y: point.y, dx: -moved.x * scale, dy: -moved.y * scale))
    }
}
#endif
