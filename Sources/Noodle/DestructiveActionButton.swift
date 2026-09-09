import AppKit
import SwiftUI

/// A system-rendered destructive button, including Tahoe's subdued red tint.
/// SwiftUI's bordered style currently drops that treatment outside alerts.
struct DestructiveActionButton: NSViewRepresentable {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.activate))
        button.bezelStyle = .push
        button.hasDestructiveAction = true
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.setContentHuggingPriority(.required, for: .horizontal)
        if #available(macOS 26.0, *) {
            button.bezelColor = .systemRed
            button.tintProminence = .secondary
            button.borderShape = .capsule
        }
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.title = title
        button.isEnabled = isEnabled
        if #unavailable(macOS 26.0) {
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.systemRed,
                .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ])
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.fittingSize
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }
}
