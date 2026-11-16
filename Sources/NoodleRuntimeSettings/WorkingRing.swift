import AppKit
import SwiftUI

/// An arc that turns around a working bot's picture. Core Animation turns it in the render server, so any
/// number of working bots cost the main thread nothing per frame, and a picture moved as the ring appears,
/// as a toolbar places its items, takes the ring with it. It holds still under Reduce Motion.
public struct WorkingRing: NSViewRepresentable {
    let lineWidth: CGFloat
    let color: NSColor
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A dynamic `color` follows the appearance.
    public init(lineWidth: CGFloat, color: NSColor = .controlAccentColor) {
        self.lineWidth = lineWidth
        self.color = color
    }

    public func makeNSView(context: Context) -> RingView { RingView() }

    public func updateNSView(_ view: RingView, context: Context) {
        _ = colorScheme
        view.configure(lineWidth: lineWidth, color: color, turning: !reduceMotion)
    }

    public final class RingView: NSView {
        private let arc = CAShapeLayer()
        private var color = NSColor.controlAccentColor

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            arc.fillColor = nil
            arc.lineCap = .round
            arc.strokeEnd = 0.28
            layer?.addSublayer(arc)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override public func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(lineWidth: CGFloat, color: NSColor, turning: Bool) {
            self.color = color
            arc.lineWidth = lineWidth
            applyColor()
            if turning, arc.animation(forKey: "turn") == nil {
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                // Clockwise: negative in a layer's flipped-up coordinates.
                turn.fromValue = 0
                turn.toValue = -2 * Double.pi
                turn.duration = 1.1
                turn.repeatCount = .infinity
                turn.isRemovedOnCompletion = false
                arc.add(turn, forKey: "turn")
            } else if !turning {
                arc.removeAnimation(forKey: "turn")
            }
            needsLayout = true
        }

        override public func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyColor()
        }

        private func applyColor() {
            effectiveAppearance.performAsCurrentDrawingAppearance { arc.strokeColor = color.cgColor }
        }

        override public func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.frame = bounds
            let inset = arc.lineWidth / 2
            arc.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            CATransaction.commit()
        }
    }
}
