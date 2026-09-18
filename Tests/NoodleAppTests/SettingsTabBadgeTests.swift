import AppKit
import XCTest
@testable import Noodle

@MainActor final class SettingsTabBadgeTests: XCTestCase {
    private final class Tabs: NSObject, NSToolbarDelegate {
        let identifiers = ["General", "Companions"].map { NSToolbarItem.Identifier($0) }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = identifier.rawValue
            return item
        }
    }

    func testBadgeFollowsTheCountAndIsRestoredAfterBeingCleared() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Toolbar item badges need macOS 26") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tabs = Tabs()
        let toolbar = NSToolbar(identifier: "SettingsTabBadgeTests")
        toolbar.delegate = tabs
        window.toolbar = toolbar
        let companions = try XCTUnwrap(toolbar.items.first { $0.label == "Companions" })
        let general = try XCTUnwrap(toolbar.items.first { $0.label == "General" })

        let view = SettingsTabBadge.BadgeView()
        view.label = "Companions"
        view.count = 2
        window.contentView?.addSubview(view)
        XCTAssertEqual(companions.badge?.text, NSItemBadge.count(2).text)
        XCTAssertNil(general.badge)

        // SwiftUI clears the badge when it updates its tab items.
        companions.badge = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(companions.badge?.text, NSItemBadge.count(2).text)

        view.count = 0
        view.apply()
        XCTAssertNil(companions.badge)

        view.removeFromSuperview()
        companions.badge = .count(9)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(companions.badge?.text, NSItemBadge.count(9).text, "A removed view must stop managing the badge")
    }
}
