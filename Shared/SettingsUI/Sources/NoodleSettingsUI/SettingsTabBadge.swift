import AppKit
import SwiftUI

/// Shows count badges on the Settings toolbar tabs with these labels. SwiftUI's
/// `badge` does not reach Settings tabs, and SwiftUI clears `NSToolbarItem.badge`
/// on every update of the window, which makes AppKit rebuild its badge view and
/// flicker. These badges are our own views on the tabs' icon buttons, which
/// SwiftUI keeps across updates and never touches. Their size, colour and
/// top-trailing placement copy AppKit's toolbar item badge on macOS 26, the
/// only layout they have been matched against.
public struct SettingsTabBadge: NSViewRepresentable {
    let counts: [String: Int]

    public init(counts: [String: Int]) { self.counts = counts }

    public func makeNSView(context: Context) -> BadgeView { BadgeView() }

    public func updateNSView(_ view: BadgeView, context: Context) {
        view.counts = counts
        view.apply()
    }

    public final class BadgeView: NSView {
        var counts: [String: Int] = [:]
        private var badges: [String: CountView] = [:]
        private var observer: CFRunLoopObserver?

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                self.observer = nil
            }
            guard window != nil else {
                badges.values.forEach { $0.removeFromSuperview() }
                badges = [:]
                return
            }
            // The toolbar's buttons appear after this view; attach once they exist.
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
            apply()
        }

        func apply() {
            guard #available(macOS 26.0, *), let window else { return }
            var buttons: [String: NSButton]?
            for (label, count) in counts {
                guard count > 0 else {
                    badges.removeValue(forKey: label)?.removeFromSuperview()
                    continue
                }
                if let badge = badges[label], badge.window === window {
                    badge.count = count
                    continue
                }
                badges.removeValue(forKey: label)?.removeFromSuperview()
                if buttons == nil { buttons = Self.tabButtons(in: window) }
                guard let button = buttons?[label] else { continue }
                let badge = CountView(count: count)
                badge.attach(to: button)
                badges[label] = badge
            }
            for label in Array(badges.keys) where counts[label] == nil {
                badges.removeValue(forKey: label)?.removeFromSuperview()
            }
        }

        /// Toolbar items do not expose their views, so the titlebar's buttons are
        /// paired with the items in leading-to-trailing order. Any mismatch in
        /// number, such as an overflow button, leaves the tabs without badges.
        static func tabButtons(in window: NSWindow) -> [String: NSButton] {
            guard let items = window.toolbar?.visibleItems, let frame = window.contentView?.superview else { return [:] }
            let widgets = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton, .toolbarButton, .documentIconButton]
                .compactMap { window.standardWindowButton($0) }
            var found: [NSButton] = []
            func collect(_ view: NSView) {
                if let button = view as? NSButton, !button.isHidden, !widgets.contains(where: { $0 === button }) { found.append(button) }
                view.subviews.forEach(collect)
            }
            frame.subviews.filter { $0 !== window.contentView }.forEach(collect)
            guard found.count == items.count else { return [:] }
            found.sort { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            if window.windowTitlebarLayoutDirection == .rightToLeft { found.reverse() }
            return Dictionary(zip(items.map(\.label), found), uniquingKeysWith: { first, _ in first })
        }
    }

    final class CountView: NSView {
        private static let height: CGFloat = 12
        private static let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.white
        ]

        var count: Int {
            didSet { if count != oldValue { resize() } }
        }

        private var text: NSAttributedString { NSAttributedString(string: count.formatted(), attributes: Self.attributes) }

        init(count: Int) {
            self.count = count
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        func attach(to button: NSButton) {
            button.addSubview(self)
            resize()
        }

        /// Keeps the top-trailing corner on the button's top-trailing corner.
        private func resize() {
            setAccessibilityLabel(count.formatted())
            needsDisplay = true
            guard let button = superview else { return }
            let width = max(Self.height, ceil(text.size().width) + 4)
            let trailing = button.userInterfaceLayoutDirection == .rightToLeft
            frame = NSRect(x: trailing ? 0 : button.bounds.width - width,
                           y: button.isFlipped ? 0 : button.bounds.height - Self.height,
                           width: width, height: Self.height)
            autoresizingMask = [trailing ? .maxXMargin : .minXMargin, button.isFlipped ? .maxYMargin : .minYMargin]
        }

        // Clicks belong to the tab beneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }
    }
}
