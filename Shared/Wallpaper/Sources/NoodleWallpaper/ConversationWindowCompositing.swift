import AppKit
import SwiftUI

/// The suite's wallpaper and native sidebar glass share one transparent window.
public struct ConversationWindowCompositing: NSViewRepresentable {
    public init() {}
    public final class View: NSView {
        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
        public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    public func makeNSView(context: Context) -> View { View() }
    public func updateNSView(_ view: View, context: Context) {}
}
