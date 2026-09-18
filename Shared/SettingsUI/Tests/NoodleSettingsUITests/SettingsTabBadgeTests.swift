import AppKit
import XCTest
@testable import NoodleSettingsUI

@MainActor final class SettingsTabBadgeTests: XCTestCase {
    private final class Tabs: NSObject, NSToolbarDelegate {
        let identifiers = ["General", "Harness", "Companions"].map { NSToolbarItem.Identifier($0) }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = identifier.rawValue
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            // Settings tabs are clickable, which is what makes AppKit give them buttons.
            item.target = self
            item.action = #selector(select(_:))
            return item
        }
        func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
        @objc func select(_ sender: Any?) {}
    }

    private func badges(in window: NSWindow) -> [SettingsTabBadge.CountView] {
        var found: [SettingsTabBadge.CountView] = []
        func collect(_ view: NSView) {
            if let badge = view as? SettingsTabBadge.CountView { found.append(badge) }
            view.subviews.forEach(collect)
        }
        window.contentView?.superview.map(collect)
        return found
    }

    func testBadgesSitOnTheirTabsFollowTheCountsAndLeaveWithTheView() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Tab badges are only laid out for macOS 26") }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 480, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tabs = Tabs()
        let toolbar = NSToolbar(identifier: "SettingsTabBadgeTests")
        toolbar.delegate = tabs
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        // The toolbar only builds its buttons once the window is ordered in (still offscreen).
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let buttons = SettingsTabBadge.BadgeView.tabButtons(in: window)
        XCTAssertEqual(Set(buttons.keys), ["General", "Harness", "Companions"])
        let positions = ["General", "Harness", "Companions"].compactMap { buttons[$0] }.map { $0.convert($0.bounds, to: nil).minX }
        XCTAssertEqual(positions, positions.sorted(), "Buttons pair with items in leading-to-trailing order")

        let view = SettingsTabBadge.BadgeView()
        view.counts = ["Harness": 2, "Companions": 12, "General": 0, "Missing": 4]
        window.contentView?.addSubview(view)
        let shown = badges(in: window)
        XCTAssertEqual(shown.count, 2)
        let harness = try XCTUnwrap(shown.first { $0.superview === buttons["Harness"] })
        let companions = try XCTUnwrap(shown.first { $0.superview === buttons["Companions"] })
        XCTAssertEqual(harness.accessibilityLabel(), "2")
        XCTAssertEqual(harness.frame.size, NSSize(width: 12, height: 12))
        XCTAssertGreaterThan(companions.frame.width, 12, "Two digits widen the badge")
        let button = try XCTUnwrap(buttons["Harness"])
        XCTAssertEqual(harness.frame.maxX, button.bounds.maxX)
        XCTAssertEqual(button.isFlipped ? harness.frame.minY : harness.frame.maxY, button.isFlipped ? 0 : button.bounds.maxY)
        XCTAssertNil(harness.hitTest(NSPoint(x: 1, y: 1)), "Clicks pass through to the tab")

        // An unchanged count keeps the same view, so nothing is redrawn or rebuilt.
        view.counts["Harness"] = 3
        view.apply()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(badges(in: window).contains { $0 === harness })
        XCTAssertEqual(harness.accessibilityLabel(), "3")

        view.counts["Harness"] = 0
        view.apply()
        XCTAssertEqual(badges(in: window).count, 1)
        // A badge removed behind our back returns before the run loop sleeps.
        companions.removeFromSuperview()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(badges(in: window).count, 1)

        view.removeFromSuperview()
        XCTAssertTrue(badges(in: window).isEmpty)
    }
}
