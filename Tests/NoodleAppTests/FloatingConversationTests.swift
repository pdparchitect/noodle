import AppKit
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class FloatingConversationTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "noodle-floating-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testFloatingConversationsPersistAcrossLaunches() {
        let defaults = defaults()
        let id = UUID()
        let floating = FloatingConversations(defaults: defaults)
        XCTAssertFalse(floating.contains(id))
        floating.set(true, for: id)
        XCTAssertTrue(FloatingConversations(defaults: defaults).contains(id))
        floating.set(false, for: id)
        XCTAssertFalse(FloatingConversations(defaults: defaults).contains(id))
    }

    func testRetainDropsDeletedConversations() {
        let defaults = defaults()
        let kept = UUID(), deleted = UUID()
        let floating = FloatingConversations(defaults: defaults)
        floating.set(true, for: kept); floating.set(true, for: deleted)
        floating.retain([kept])
        let restored = FloatingConversations(defaults: defaults)
        XCTAssertTrue(restored.contains(kept))
        XCTAssertFalse(restored.contains(deleted))
    }

    func testPresentingWithoutAnOpenWindowOpensASeparateWindow() {
        let registry = ConversationWindowRegistry()
        var opened: [UUID] = []
        registry.restoreWindows { opened.append($0) }
        let id = UUID()
        registry.present(id)
        XCTAssertEqual(opened, [id])
    }

    func testMenuCommandsResolveTheConversationShownInAWindow() {
        let registry = ConversationWindowRegistry()
        let id = UUID()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = ConversationWindowHost.Probe(registry: registry)
        host.conversationID = id
        window.contentView = host
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        XCTAssertEqual(registry.conversationID(in: window), id)
        XCTAssertNil(registry.conversationID(in: other))
        XCTAssertNil(registry.conversationID(in: nil))
        window.close()
        XCTAssertNil(registry.conversationID(in: window))
    }

    func testFloatingPanelCanShowOverFullScreenAppsWithoutActivatingNoodle() {
        let panel = FloatingConversationPanel.make(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
        // Only a non-activating panel may join another app's full-screen Space.
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]))
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.canBecomeKey)
        // An attachment preview makes its host window main; AppKit throws if the host refuses,
        // and that exception leaves every click in the app dead.
        XCTAssertTrue(panel.canBecomeMain)
        // See-through, with the close button as its only window control.
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertEqual(panel.standardWindowButton(.closeButton)?.isHidden, false)
        XCTAssertEqual(panel.standardWindowButton(.miniaturizeButton)?.isHidden, true)
        XCTAssertEqual(panel.standardWindowButton(.zoomButton)?.isHidden, true)
        XCTAssertEqual(panel.contentMinSize, FloatingConversationPanel.minimumSize)
        // The chat view draws the centred title, so the native one would repeat it.
        XCTAssertEqual(panel.titleVisibility, .hidden)
    }

    func testFloatingPanelRunsTheVoiceShortcutItselfBecauseItIsNotAScene() throws {
        let bindings = KeyboardBindings(defaults: defaults())
        let panel = FloatingConversationPanel.make(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
        panel.bindings = bindings
        var toggles = 0, enabled = true
        func press(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            return panel.performKeyEquivalent(with: event)
        }
        // Nothing mounted yet: the shortcut is not the panel's to take.
        XCTAssertFalse(try press("d", code: 2, flags: [.command, .shift]))
        panel.commands.voiceRecording = VoiceRecordingCommand(phase: { .idle }, isSending: { !enabled }, toggle: { toggles += 1 })
        XCTAssertTrue(try press("d", code: 2, flags: [.command, .shift]))
        XCTAssertEqual(toggles, 1)
        // A rebound shortcut is honoured, and the old one is released.
        try bindings.set(KeyBinding("d", modifiers: [.command, .control]), for: .recordVoice)
        XCTAssertTrue(try press("d", code: 2, flags: [.command, .control]))
        XCTAssertEqual(toggles, 2)
        XCTAssertFalse(try press("d", code: 2, flags: [.command, .shift]))
        enabled = false
        _ = try press("d", code: 2, flags: [.command, .control])
        XCTAssertEqual(toggles, 2, "A disabled command must not run")
    }

    func testKeepingOneFloatReplacesTheOpenOneInItsExactPlaceAndIsOffByDefault() {
        let defaults = defaults()
        let floating = FloatingConversations(defaults: defaults)
        XCTAssertFalse(floating.keepsOne, "Several floats stay allowed unless the user asks for one")
        let panels = FloatingConversationPanels(floating: floating, isTerminating: { false }) { _, _ in NSView() }
        let first = UUID(), second = UUID(), third = UUID()
        let opened = panels.show(first, frame: NSRect(x: 100, y: 100, width: 420, height: 560), present: { _ in })
        // The user moves and resizes it; the next float must land exactly there.
        let placed = NSRect(x: 310, y: 220, width: 500, height: 640)
        opened.setFrame(placed, display: false)
        defaults.set(true, forKey: FloatingConversations.keepsOneDefaultsKey)
        XCTAssertTrue(floating.keepsOne)
        let replacement = panels.show(second, frame: NSRect(x: 900, y: 50, width: 420, height: 560), present: { _ in })
        XCTAssertEqual(replacement.frame, placed)
        XCTAssertEqual(panels.openIDs, [second])
        XCTAssertFalse(floating.contains(first))
        XCTAssertTrue(floating.contains(second))
        // Asking for the one that is open keeps it where it is.
        XCTAssertTrue(panels.show(second, frame: nil, present: { _ in }) === replacement)
        XCTAssertEqual(replacement.frame, placed)
        // Turning the setting off allows several again.
        defaults.set(false, forKey: FloatingConversations.keepsOneDefaultsKey)
        panels.show(third, frame: NSRect(x: 900, y: 50, width: 420, height: 560), present: { _ in })
        XCTAssertEqual(panels.openIDs, [second, third])
    }

    func testOnePanelPerConversationAndClosingReturnsItToNormalMode() {
        let floating = FloatingConversations(defaults: defaults())
        var terminating = false
        let panels = FloatingConversationPanels(floating: floating, isTerminating: { terminating }) { _, _ in NSView() }
        let id = UUID(), kept = UUID()
        let panel = panels.show(id, frame: NSRect(x: 0, y: 0, width: 420, height: 560), present: { _ in })
        XCTAssertTrue(floating.contains(id))
        XCTAssertTrue(panels.show(id, frame: nil, present: { _ in }) === panel)
        panel.close()
        XCTAssertFalse(floating.contains(id))
        XCTAssertNil(panels.panel(for: id))
        // Quitting closes panels too; those float again on the next launch.
        let quitting = panels.show(kept, frame: nil, present: { _ in })
        terminating = true
        quitting.close()
        XCTAssertTrue(floating.contains(kept))
    }

    func testPanelCannotBeResizedBelowItsMinimumWhateverTheHostedViewAllows() {
        let panels = FloatingConversationPanels(floating: FloatingConversations(defaults: defaults()), isTerminating: { false }) { _, _ in NSView() }
        let panel = panels.show(UUID(), frame: nil, present: { _ in })
        // A hosted SwiftUI view can reset the window's own minimum, so the delegate holds it.
        panel.contentMinSize = .zero; panel.minSize = .zero
        let minimum = panel.frameRect(forContentRect: NSRect(origin: .zero, size: FloatingConversationPanel.minimumSize)).size
        XCTAssertEqual(panels.windowWillResize(panel, to: NSSize(width: 40, height: 30)), minimum)
        XCTAssertEqual(panels.windowWillResize(panel, to: NSSize(width: 900, height: 30)), NSSize(width: 900, height: minimum.height))
        XCTAssertEqual(panels.windowWillResize(panel, to: NSSize(width: 900, height: 700)), NSSize(width: 900, height: 700))
    }

    func testCompactFrameKeepsTopRightCornerOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = FloatingConversationPanel.compactFrame(from: NSRect(x: 600, y: 50, width: 760, height: 810), visible: visible)
        XCTAssertEqual(frame.size, FloatingConversationPanel.compactSize)
        XCTAssertEqual(frame.maxX, 1360)
        XCTAssertEqual(frame.maxY, 860)
        let landed = FloatingConversationPanel.landingFrame(near: NSPoint(x: 1430, y: 5), visible: visible)
        XCTAssertTrue(visible.contains(landed))
    }

    func testPickerListsOpenFloatsFirstThenRecentActivityAndFiltersByTitle() {
        let old = AgentPickerItem(id: UUID(), title: "Designer", lastActivity: Date(timeIntervalSince1970: 10), isFloating: false)
        let recent = AgentPickerItem(id: UUID(), title: "Coder", lastActivity: Date(timeIntervalSince1970: 20), isFloating: false)
        let open = AgentPickerItem(id: UUID(), title: "Writer", lastActivity: Date(timeIntervalSince1970: 1), isFloating: true)
        XCTAssertEqual(AgentPickerItem.visible([old, recent, open], filter: "").map(\.title), ["Writer", "Coder", "Designer"])
        XCTAssertEqual(AgentPickerItem.visible([old, recent, open], filter: "des").map(\.title), ["Designer"])
    }

    func testNewFloatingPanelsAreStaggeredSoTheyDoNotHideEachOther() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let first = NSRect(x: 500, y: 200, width: 420, height: 560)
        XCTAssertEqual(FloatingConversationPanel.staggered(first, avoiding: [], visible: visible), first)
        let second = FloatingConversationPanel.staggered(first, avoiding: [first], visible: visible)
        XCTAssertNotEqual(second.origin, first.origin)
        let third = FloatingConversationPanel.staggered(first, avoiding: [first, second], visible: visible)
        XCTAssertEqual(Set([first.origin.x, second.origin.x, third.origin.x]).count, 3)
        XCTAssertTrue(visible.contains(third))
        // The controller applies it: two panels asked for the same spot end up apart.
        let panels = FloatingConversationPanels(floating: FloatingConversations(defaults: defaults()), isTerminating: { false }) { _, _ in NSView() }
        let a = panels.show(UUID(), frame: first, present: { _ in })
        let b = panels.show(UUID(), frame: first, present: { _ in })
        XCTAssertNotEqual(a.frame.origin, b.frame.origin)
    }

    func testSystemWideHotKeyTranslatesABindingForCarbon() {
        XCTAssertEqual(GlobalHotKey.keyCode(for: " "), 49)
        XCTAssertEqual(GlobalHotKey.keyCode(for: "\r"), 36)
        XCTAssertEqual(GlobalHotKey.modifiers(for: [.control, .option]), 0x1000 | 0x0800)
        XCTAssertEqual(GlobalHotKey.modifiers(for: [.command, .shift, .control]), 0x0100 | 0x0200 | 0x1000)
        // Letters depend on the keyboard layout; whatever code is found must type that letter.
        if let code = GlobalHotKey.keyCode(for: "a") { XCTAssertEqual(GlobalHotKey.character(for: code), "a") }
    }

    func testPickerFitsItsRowsExactlyUpToThree() {
        let one = AgentPickerLayout.height(items: 1)
        XCTAssertEqual(AgentPickerLayout.height(items: 4), one)
        // An empty result keeps one row for its message.
        XCTAssertEqual(AgentPickerLayout.height(items: 0), one)
        let step = AgentPickerLayout.tileHeight + AgentPickerLayout.spacing
        XCTAssertEqual(AgentPickerLayout.height(items: 5), one + step)
        XCTAssertEqual(AgentPickerLayout.height(items: 9), one + 2 * step)
        // More than three rows scroll; the panel never shows part of a fourth.
        XCTAssertEqual(AgentPickerLayout.height(items: 13), one + 2 * step)
        XCTAssertEqual(AgentPickerLayout.height(items: 200), one + 2 * step)
        // Rows that fit must not scroll at all, or the grid rubber-bands when it appears.
        XCTAssertFalse(AgentPickerLayout.scrolls(items: 0))
        XCTAssertFalse(AgentPickerLayout.scrolls(items: 12))
        XCTAssertTrue(AgentPickerLayout.scrolls(items: 13))
        // The panel hangs from a fixed top edge, so the search field opens in the same place.
        let frame = AgentPickerLayout.frame(NSRect(x: 100, y: 300, width: 560, height: one), items: 9)
        XCTAssertEqual(frame.maxY, 300 + one)
        XCTAssertEqual(frame.height, one + 2 * step)
    }

    func testPickerAppearsWithoutTheModalPanelPopAnimation() {
        // Left to AppKit, a modal-level panel pops in with an overshoot that reads as a wobble.
        XCTAssertEqual(AgentPickerController.shared.makePanel().animationBehavior, .none)
    }

    func testPickerHeightIsChosenOnceWhenItOpensAndNeverChangesWhileFiltering() {
        let model = AgentPickerModel()
        let items = (0..<9).map { AgentPickerItem(id: UUID(), title: "Bot \($0)", lastActivity: Date(timeIntervalSince1970: Double($0)), isFloating: false) }
        model.filter = "stale"
        model.selection = 3
        model.present(items)
        XCTAssertEqual(model.filter, "")
        XCTAssertEqual(model.selection, 0)
        XCTAssertEqual(model.height, AgentPickerLayout.height(items: 9))
        model.filter = "Bot 1"
        XCTAssertEqual(model.visible.count, 1)
        XCTAssertEqual(model.height, AgentPickerLayout.height(items: 9), "Filtering must not resize the panel")
        model.present(Array(items.prefix(2)))
        XCTAssertEqual(model.height, AgentPickerLayout.height(items: 2))
    }

    func testPickerSelectionMovesWithinGrid() {
        XCTAssertEqual(AgentPickerItem.move(0, by: .right, count: 5, columns: 4), 1)
        XCTAssertEqual(AgentPickerItem.move(3, by: .right, count: 5, columns: 4), 4)
        XCTAssertEqual(AgentPickerItem.move(4, by: .right, count: 5, columns: 4), 4)
        XCTAssertEqual(AgentPickerItem.move(0, by: .down, count: 5, columns: 4), 4)
        XCTAssertEqual(AgentPickerItem.move(1, by: .down, count: 5, columns: 4), 1)
        XCTAssertEqual(AgentPickerItem.move(4, by: .up, count: 5, columns: 4), 0)
        XCTAssertEqual(AgentPickerItem.move(0, by: .left, count: 5, columns: 4), 0)
    }
}
