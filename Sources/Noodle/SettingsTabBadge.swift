import AppKit
import SwiftUI

/// Keeps a count badge on the Settings toolbar tab with this label. SwiftUI's
/// `badge` does not reach Settings tabs, and SwiftUI clears a badge set on its
/// toolbar items whenever it updates them, so the badge is restored before the
/// run loop next sleeps. Toolbar item badges need macOS 26.
struct SettingsTabBadge: NSViewRepresentable {
    let label: String
    let count: Int

    func makeNSView(context: Context) -> BadgeView { BadgeView() }

    func updateNSView(_ view: BadgeView, context: Context) {
        view.label = label
        view.count = count
        view.apply()
    }

    final class BadgeView: NSView {
        var label = ""
        var count = 0
        private var observer: CFRunLoopObserver?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                self.observer = nil
            }
            guard window != nil else { return }
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
            apply()
        }

        func apply() {
            guard #available(macOS 26.0, *),
                  let item = window?.toolbar?.items.first(where: { $0.label == label }) else { return }
            let badge = count > 0 ? NSItemBadge.count(count) : nil
            if item.badge?.text != badge?.text { item.badge = badge }
        }
    }
}
