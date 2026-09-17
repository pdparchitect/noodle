import AppKit
import XCTest
@testable import NoodleSettingsUI

@MainActor final class WindowFocusGuardTests: XCTestCase {
    func testFirstClickFocusesAndConsumesItsDragAndReleaseThenAllowsNextClick() throws {
        let window = fixture()
        var focuses = 0
        let guarder = WindowFocusGuard { target in
            XCTAssertTrue(target === window)
            focuses += 1
            window.hasKey = true
        }
        XCTAssertNil(guarder.filter(try mouse(.leftMouseDown, window), applicationActive: true))
        XCTAssertEqual(focuses, 1)
        XCTAssertNil(guarder.filter(try mouse(.leftMouseDragged, window), applicationActive: true))
        // The release can arrive without a window if the pointer leaves it.
        XCTAssertNil(guarder.filter(try mouse(.leftMouseUp, nil), applicationActive: true))
        let second = try mouse(.leftMouseDown, window)
        XCTAssertTrue(guarder.filter(second, applicationActive: true) === second)
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseUp, window), applicationActive: true))
        XCTAssertEqual(focuses, 1)
    }

    func testInactiveApplicationAndAnotherWindowBothRequireFocus() throws {
        let first = fixture(), second = fixture()
        first.hasKey = true
        var focused: [NSWindow] = []
        let guarder = WindowFocusGuard { focused.append($0) }
        XCTAssertNil(guarder.filter(try mouse(.leftMouseDown, first), applicationActive: false))
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseDown, first), applicationActive: true))
        XCTAssertNil(guarder.filter(try mouse(.leftMouseDown, second), applicationActive: true))
        XCTAssertEqual(focused, [first, second])
    }

    func testActivationBeforeDispatchDoesNotLetTheActivatingClickThrough() throws {
        let window = fixture()
        window.hasKey = true
        var focuses = 0
        let guarder = WindowFocusGuard { _ in focuses += 1 }
        guarder.start()
        defer { guarder.stop() }
        let pending = try mouse(.leftMouseDown, window)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertNil(guarder.filter(pending, applicationActive: true))
        // A later click after keyboard / programmatic activation acts normally.
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseDown, window), applicationActive: true))
        XCTAssertEqual(focuses, 1)
    }

    func testWindowBecomingKeyBeforeDispatchStillConsumesTheFirstClick() throws {
        let window = fixture()
        let guarder = WindowFocusGuard { _ in }
        guarder.start()
        defer { guarder.stop() }
        let pending = try mouse(.leftMouseDown, window)
        window.hasKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertNil(guarder.filter(pending, applicationActive: true))
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseDown, window), applicationActive: true))
    }

    func testSuppressionIsPerButtonAndRecoversFromMissingRelease() throws {
        let window = fixture()
        let guarder = WindowFocusGuard { _ in window.hasKey = true }
        XCTAssertNil(guarder.filter(try mouse(.rightMouseDown, window), applicationActive: true))
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseUp, window), applicationActive: true))
        XCTAssertNil(guarder.filter(try mouse(.rightMouseDragged, window), applicationActive: true))
        XCTAssertNil(guarder.filter(try mouse(.rightMouseUp, window), applicationActive: true))
        window.hasKey = false
        XCTAssertNil(guarder.filter(try mouse(.otherMouseDown, window), applicationActive: true))
        XCTAssertNil(guarder.filter(try mouse(.otherMouseUp, window), applicationActive: true))
        window.hasKey = false
        XCTAssertNil(guarder.filter(try mouse(.leftMouseDown, window), applicationActive: true))
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseDown, window), applicationActive: true))
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseUp, window), applicationActive: true))
    }

    func testTitlebarHiddenWindowsAndNonKeyPanelsPassThrough() throws {
        let window = fixture()
        let guarder = WindowFocusGuard { _ in XCTFail("Should not focus") }
        let titlebar = NSPoint(x: 150, y: window.contentLayoutRect.maxY + 8)
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseDown, window, point: titlebar), applicationActive: false))
        window.orderOut(nil)
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseDown, window), applicationActive: false))
        let panel = NSPanel(contentRect: .init(x: -10000, y: -10000, width: 300, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.orderBack(nil)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseDown, panel), applicationActive: false))
    }

    func testFocusedNonactivatingPanelDoesNotNeedApplicationActivation() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = FocusFixturePanel(contentRect: .init(x: -10000, y: -10000, width: 300, height: 200),
                                       styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }
        window.hasKey = true
        let guarder = WindowFocusGuard { _ in XCTFail("An already focused panel should stay nonactivating") }
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseDown, window), applicationActive: false))
    }

    func testTransientBorderlessPanelCanActWithoutTakingKeyFocus() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let panel = FocusFixturePanel(contentRect: .init(x: -10000, y: -10000, width: 300, height: 200),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.orderBack(nil)
        defer { panel.close() }
        let guarder = WindowFocusGuard { _ in XCTFail("Transient controls must not take focus from their parent") }
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertNotNil(guarder.filter(try mouse(.leftMouseDown, panel), applicationActive: true))
    }

    func testInactiveParentFocusesItsSheet() throws {
        let window = fixture(), sheet = fixture()
        window.beginSheet(sheet)
        defer { window.endSheet(sheet) }
        var target: NSWindow?
        let guarder = WindowFocusGuard { target = $0 }
        XCTAssertNil(guarder.filter(try mouse(.leftMouseDown, window), applicationActive: false))
        XCTAssertTrue(target === sheet)
    }

    func testMonitorStopsClickThroughButDirectAgentDispatchBypassesIt() throws {
        let window = fixture()
        let guarder = WindowFocusGuard { _ in }
        guarder.start()
        guarder.start()
        defer { guarder.stop() }
        NSApp.sendEvent(try mouse(.leftMouseDown, window))
        NSApp.sendEvent(try mouse(.leftMouseUp, window))
        XCTAssertEqual(window.delivered, [])
        // Browser and native noodlet agents dispatch directly to the window or
        // responder. They must continue to work without focusing the host app.
        window.sendEvent(try mouse(.leftMouseDown, window))
        XCTAssertEqual(window.delivered, [.leftMouseDown])
        guarder.stop()
        NSApp.sendEvent(try mouse(.leftMouseDown, window))
        XCTAssertEqual(window.delivered, [.leftMouseDown, .leftMouseDown])
    }

    func testRealAppKitDispatchFocusesBeforeAViewThatAcceptsFirstMouseCanAct() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let panel = InputFixturePanel(contentRect: .init(x: -10000, y: -10000, width: 300, height: 200),
                                      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let content = ClickThroughView(frame: .init(x: 0, y: 0, width: 300, height: 200))
        panel.contentView = content
        panel.orderBack(nil)
        let guarder = WindowFocusGuard()
        guarder.start()
        defer { guarder.stop(); panel.close() }
        XCTAssertFalse(panel.isKeyWindow)
        NSApp.sendEvent(try mouse(.leftMouseDown, panel))
        NSApp.sendEvent(try mouse(.leftMouseUp, panel))
        XCTAssertTrue(panel.isKeyWindow)
        XCTAssertEqual(content.clicks, 0)
        XCTAssertEqual(content.releases, 0)
        NSApp.sendEvent(try mouse(.leftMouseDown, panel))
        NSApp.sendEvent(try mouse(.leftMouseUp, panel))
        XCTAssertEqual(content.clicks, 1)
        XCTAssertEqual(content.releases, 1)
    }

    private func fixture(style: NSWindow.StyleMask = [.titled, .resizable]) -> FocusFixtureWindow {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = FocusFixtureWindow(contentRect: .init(x: -10000, y: -10000, width: 300, height: 200),
                                        styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        addTeardownBlock { @MainActor in window.close() }
        return window
    }

    private func mouse(_ type: NSEvent.EventType, _ window: NSWindow?, point: NSPoint = .init(x: 80, y: 80)) throws -> NSEvent {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        // NSEvent.mouseEvent initializes buttonNumber to zero even for right /
        // other events. Give the fixture the button number of physical input.
        let button: Int64
        switch type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: button = 1
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp: button = 2
        default: return event
        }
        let cgEvent = try XCTUnwrap(event.cgEvent)
        cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }
}

private final class FocusFixtureWindow: NSWindow {
    var hasKey = false
    var delivered: [NSEvent.EventType] = []
    override var isKeyWindow: Bool { hasKey }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func sendEvent(_ event: NSEvent) { delivered.append(event.type) }
}

private final class FocusFixturePanel: NSPanel {
    var hasKey = false
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { hasKey }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class InputFixturePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class ClickThroughView: NSView {
    var clicks = 0
    var releases = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicks += 1 }
    override func mouseUp(with event: NSEvent) { releases += 1 }
}
