import AppKit
import SwiftUI

public extension View {
    /// Fit a settings tab to its content, but never taller than the screen can
    /// show below the menu bar and above the Dock; taller content scrolls.
    func settingsContentSize(width: CGFloat) -> some View {
        modifier(ScreenBoundSettingsContent(width: width))
    }
}

extension View {
    func settingsContentSize(width: CGFloat, maxHeight: CGFloat?) -> some View {
        SettingsContentHeight(maxHeight: maxHeight) { frame(width: width) }
    }
}

private struct ScreenBoundSettingsContent: ViewModifier {
    let width: CGFloat
    @State private var maxHeight: CGFloat? = SettingsScreenObserver.availableHeight(in: nil)

    func body(content: Content) -> some View {
        content
            .settingsContentSize(width: width, maxHeight: maxHeight)
            .background {
                SettingsScreenObserver { height in
                    if maxHeight != height { maxHeight = height }
                }
            }
    }
}

/// Reports the content's ideal height, capped, and lays it out in what it is given
/// so a Form or ScrollView inside scrolls instead of running off the screen.
struct SettingsContentHeight: Layout {
    var maxHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, maxHeight ?? .infinity))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct SettingsScreenObserver: NSViewRepresentable {
    let onChange: (CGFloat?) -> Void

    /// The screen's visible height minus the window's title bar and toolbar.
    @MainActor static func availableHeight(in window: NSWindow?) -> CGFloat? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        let chrome = window.map { $0.frame.height - $0.contentLayoutRect.height } ?? 0
        return max(screen.visibleFrame.height - chrome, 200)
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((CGFloat?) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard window != nil else { return }
            // Moving to another display, or the Dock or menu bar changing size.
            for name in [NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated { self?.report() }
                })
            }
            // Attachment occurs inside SwiftUI layout; defer the state change.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        private func report() {
            guard let window else { return }
            onChange?(SettingsScreenObserver.availableHeight(in: window))
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
