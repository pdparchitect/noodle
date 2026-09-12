import AppKit
import SwiftUI

/// A toolbar has its own hosting view, so focus is handed to the native field
/// when it joins the window rather than relying on the file pane's focus scope.
struct AppletSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = ToolbarSearchTextField()
        field.placeholderString = "Search"
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search noodlets")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if focused, let window = field.window, window.firstResponder !== field.currentEditor() {
            window.makeFirstResponder(field)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context)
        -> NSSize?
    {
        // Center the native text and field editor together in the search capsule.
        NSSize(width: proposal.width ?? 120, height: nsView.intrinsicContentSize.height)
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppletSearchField
        init(_ parent: AppletSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector)
            -> Bool
        {
            guard command == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.onCancel()
            return true
        }
    }
}

private final class ToolbarSearchTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
