import AppKit
import Combine
import SwiftUI

public extension View {
    /// Avoid macOS 27's indicator flash while a fitted settings window changes size.
    @ViewBuilder
    func settingsScrollIndicators<Selection: Equatable>(selection: Selection) -> some View {
        if #available(macOS 27.0, *) {
            modifier(SettingsScrollIndicators(selection: selection))
        } else {
            self
        }
    }
}

private struct SettingsScrollIndicators<Selection: Equatable>: ViewModifier {
    let selection: Selection
    @Environment(\.verticalScrollIndicatorVisibility) private var verticalVisibility
    @Environment(\.horizontalScrollIndicatorVisibility) private var horizontalVisibility
    @State private var previousSelection: Selection?
    @State private var suppressIndicators = true
    @State private var isLiveResizing = false
    @State private var resizeRevision = 0

    func body(content: Content) -> some View {
        content
            // The selection comparison hides indicators in the very update that
            // switches tabs, before the window emits its first resize notification.
            // Hidden preserves the gutter for users who always show scrollbars.
            // Set the environment explicitly: on macOS 27, switching the
            // scrollIndicators modifier back to automatic can retain hidden.
            .environment(\.verticalScrollIndicatorVisibility,
                suppressIndicators || previousSelection != selection ? .hidden : verticalVisibility)
            .environment(\.horizontalScrollIndicatorVisibility,
                suppressIndicators || previousSelection != selection ? .hidden : horizontalVisibility)
            .background {
                SettingsResizeObserver { event in
                    switch event {
                    case .resize: break
                    case .liveResizeStarted: isLiveResizing = true
                    case .liveResizeEnded: isLiveResizing = false
                    }
                    suppressUntilSettled()
                }
            }
            .onChange(of: selection, initial: true) { _, selection in
                previousSelection = selection
                suppressUntilSettled()
            }
            .task(id: resizeRevision) {
                // Debounce every resize, including async content changes and
                // rapid tab switches. Never restore halfway through a live drag.
                guard !isLiveResizing else { return }
                do { try await Task.sleep(for: .milliseconds(350)) }
                catch { return }
                suppressIndicators = false
            }
    }

    private func suppressUntilSettled() {
        suppressIndicators = true
        resizeRevision &+= 1
    }
}

private enum SettingsResizeEvent {
    case resize, liveResizeStarted, liveResizeEnded
}

private struct SettingsResizeObserver: NSViewRepresentable {
    let onResize: (SettingsResizeEvent) -> Void

    func makeNSView(context: Context) -> ResizeView {
        let view = ResizeView()
        view.onResize = onResize
        return view
    }

    func updateNSView(_ view: ResizeView, context: Context) {
        view.onResize = onResize
    }

    static func dismantleNSView(_ view: ResizeView, coordinator: ()) {
        view.observers.removeAll()
        view.onResize = nil
    }

    final class ResizeView: NSView {
        var onResize: ((SettingsResizeEvent) -> Void)?
        var observers = Set<AnyCancellable>()

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.removeAll()
            guard let window else { return }
            let events: [(Notification.Name, SettingsResizeEvent)] = [
                (NSWindow.didResizeNotification, .resize),
                (NSWindow.willStartLiveResizeNotification, .liveResizeStarted),
                (NSWindow.didEndLiveResizeNotification, .liveResizeEnded)
            ]
            for (notification, event) in events {
                NotificationCenter.default.publisher(for: notification, object: window)
                    .sink { [weak self] _ in self?.onResize?(event) }
                    .store(in: &observers)
            }
            // Attachment occurs inside SwiftUI layout; defer the state change.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.onResize?(window.inLiveResize ? .liveResizeStarted : .liveResizeEnded)
            }
        }
    }
}
