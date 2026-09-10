import AppKit
import SwiftUI

/// The visual input padding belongs to the editor too. Apply outside glass so
/// its material cannot consume padding clicks before they reach the focus action.
struct ComposerFocusSurface: ViewModifier {
    let cornerRadius: CGFloat
    let controlsWidth: CGFloat
    let focus: () -> Void

    func body(content: Content) -> some View {
        content.overlay {
            ComposerPaddingFocusTarget(cornerRadius: cornerRadius, controlsWidth: controlsWidth, focus: focus)
                .accessibilityHidden(true)
        }
    }
}

private struct ComposerPaddingFocusTarget: NSViewRepresentable {
    let cornerRadius: CGFloat
    let controlsWidth: CGFloat
    let focus: () -> Void
    func makeNSView(context: Context) -> ComposerPaddingFocusView { ComposerPaddingFocusView() }
    func updateNSView(_ view: ComposerPaddingFocusView, context: Context) {
        view.cornerRadius = cornerRadius; view.controlsWidth = controlsWidth; view.focus = focus
    }
}

private final class ComposerPaddingFocusView: NSView {
    var cornerRadius: CGFloat = 18
    var controlsWidth: CGFloat = 65
    var focus: (() -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func editor(in root: NSView) -> NSTextView? {
        if let text = root as? ComposerTextView, let scroll = text.enclosingScrollView,
           bounds.intersects(convert(scroll.bounds, from: scroll)) { return text }
        for child in root.subviews { if let found = editor(in: child) { return found } }
        return nil
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHidden, NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).contains(local),
              let root = window?.contentView, let text = editor(in: root), let scroll = text.enclosingScrollView else { return nil }
        // Only unused padding is intercepted. Native text selection, scrollbars,
        // send and microphone controls keep their own event handling.
        guard !convert(scroll.bounds, from: scroll).contains(local),
              !NSRect(x: bounds.maxX - controlsWidth, y: bounds.maxY - 36,
                      width: controlsWidth, height: 36).contains(local) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        if let root = window?.contentView, let text = editor(in: root) { window?.makeFirstResponder(text) }
        focus?()
    }
}
