import HubLink
import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

/// The sidebar's icon view hosted in a window that is never ordered onscreen.
@MainActor final class SidebarIconGridTests: HiddenViewTests {
    /// Every section shows all its pictures wherever the sidebar is scrolled: a section taller than the window
    /// once left the ones it first had offscreen as blank space.
    func testEverySectionShowsAllItsPicturesWhereverTheSidebarIsScrolled() async throws {
        let f = try fixture()
        useIcons()
        let group = try f.group()
        f.store.markConversationRead(group.id)
        for index in 0..<14 { _ = try f.runtime.agent("Bot \(index)") }
        f.store.reload()
        f.store.setPinned(true, conversationID: f.directA.id)

        let window = try XCTUnwrap(host(SidebarView().environment(f.store)).window)
        window.setContentSize(.init(width: 320, height: 400))
        try await settle(window)
        let scrollView = try XCTUnwrap(descendant(NSScrollView.self, of: window.contentView!))
        let bots = Set(f.store.sidebarSections(.standard).bots.map { f.store.title(for: $0) })
        XCTAssertEqual(bots.count, 15)

        let documentHeight = try XCTUnwrap(scrollView.documentView).frame.height
        XCTAssertGreaterThan(documentHeight, scrollView.contentView.bounds.height)
        for y in [documentHeight - scrollView.contentView.bounds.height, 0] {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            try await settle(window)
            let shown = shownTitles(in: window)
            XCTAssertEqual(shown.intersection(bots), bots, "scrolled to \(y)")
            XCTAssertTrue(shown.contains(f.store.title(for: group)))
        }
    }

    /// Right-clicking a picture opens the menu for that bot, not the first one in its section.
    func testRightClickingAPictureOpensItsOwnMenu() async throws {
        let f = try fixture()
        useIcons()
        let window = try XCTUnwrap(host(SidebarView().environment(f.store)).window)
        window.setContentSize(.init(width: 320, height: 400))
        try await settle(window)
        let bots = f.store.sidebarSections(.standard).bots
        XCTAssertEqual(bots.count, 2)

        for bot in bots.reversed() {
            let title = f.store.title(for: bot)
            let picture = try XCTUnwrap(elements(window.contentView!).first { labels($0).contains { $0.hasPrefix(title + ",") } },
                "No picture for \(title)")
            let frame = try XCTUnwrap(attribute(picture, NSAccessibility.Attribute(rawValue: "AXFrame")) as? NSRect
                ?? (picture.responds(to: NSSelectorFromString("accessibilityFrame")) ? picture.value(forKey: "accessibilityFrame") as? NSRect : nil))
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            let target = try XCTUnwrap(window.contentView?.hitTest(point))
            var view: NSView? = target, menu: NSMenu?
            while let current = view, menu == nil { menu = current.menu(for: event); view = current.superview }
            let pin = try XCTUnwrap(menu?.items.first { $0.title == "Pin" }, "No Pin for \(title)")
            menu?.performActionForItem(at: menu!.index(of: pin))
            try await settle(window)
            XCTAssertTrue(f.store.isPinned(bot.id), "Pin from \(title)'s menu pinned \(bots.filter { f.store.isPinned($0.id) }.map { f.store.title(for: $0) })")
            for other in bots { f.store.setPinned(false, conversationID: other.id) }
            try await settle(window)
        }
    }

    /// A bot waiting on the person, such as for sign-in, stays in its section, as in the list; its picture says why.
    func testABotWaitingOnThePersonStaysInItsSection() async throws {
        let f = try fixture()
        useIcons()
        let ada = try f.runtime.start(f.a)
        try f.runtime.start(f.b)
        ada.transition(.failed, failure: .authenticationRequired)
        let pause = try XCTUnwrap(f.store.pauseSummary(for: f.directA))

        let window = try XCTUnwrap(host(SidebarView().environment(f.store)).window)
        window.setContentSize(.init(width: 320, height: 400))
        try await settle(window)
        let texts = elements(window.contentView!).flatMap(labels)
        XCTAssertFalse(texts.contains("Needs You"))
        XCTAssertTrue(texts.contains("Bots"))
        XCTAssertTrue(texts.contains { $0.hasPrefix("Ada, \(pause)") }, "\(texts)")
        XCTAssertEqual(Set(f.store.sidebarSections(.standard).bots.map(\.id)), [f.directA.id, f.directB.id])
    }

    private func useIcons() {
        let previous = UserDefaults.standard.string(forKey: ConversationListStyle.key)
        UserDefaults.standard.set(ConversationListStyle.icons.rawValue, forKey: ConversationListStyle.key)
        addTeardownBlock { UserDefaults.standard.set(previous, forKey: ConversationListStyle.key) }
    }

    private func descendant<V: NSView>(_ type: V.Type, of root: NSView) -> V? {
        var pending = [root]
        while let view = pending.popLast() {
            if let match = view as? V { return match }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The conversations whose pictures the sidebar holds, read from each picture's label.
    private func shownTitles(in window: NSWindow) -> Set<String> {
        Set(elements(window.contentView!).flatMap(labels).filter { $0.contains(", ") }.map { String($0.prefix { $0 != "," }) })
    }
}
