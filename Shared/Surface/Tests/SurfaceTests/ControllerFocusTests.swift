#if os(macOS)
import AppKit
import GameController
@testable import Surface
import Testing

/// A Mac may have several games open, and the controller in hand plays only the one in front.
/// A virtual controller stands in for a real one: its handlers fire as a real one's do.
@MainActor struct ControllerFocusTests {
    private let game = Gamepad(pads: [Gamepad.Pad(left: "left", right: "right")], buttons: [Gamepad.Button(key: "space")])

    @Test func aControllerPlaysOnlyWhileItsWindowIsKey() async throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let window = Self.window()
        var changes: [GamepadKeyChange] = []
        let hardware = HardwareGamepad()
        hardware.available = { controller }
        hardware.attach(game, in: window) { changes.append($0) }

        pad.buttonA.setValue(1)
        await Self.settle()
        #expect(changes.isEmpty)

        pad.buttonA.setValue(0)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        pad.buttonA.setValue(1)
        await Self.settle { changes.count == 1 }
        #expect(changes == [GamepadKeyChange(key: "space", pressed: true)])

        // A key held as the window goes to the back is let go, or the game would keep it down.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(changes.last == GamepadKeyChange(key: "space", pressed: false))
        pad.buttonA.setValue(0)
        pad.leftThumbstick.setValueForXAxis(-1, yAxis: 0)
        await Self.settle()
        #expect(changes.count == 2)
        hardware.detach()
    }

    @Test func theGameInFrontTakesTheControllerOver() async throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let first = Self.window(), second = Self.window()
        var firstChanges: [GamepadKeyChange] = [], secondChanges: [GamepadKeyChange] = []
        let firstGame = HardwareGamepad(), secondGame = HardwareGamepad()
        firstGame.available = { controller }
        secondGame.available = { controller }
        firstGame.attach(game, in: first) { firstChanges.append($0) }
        secondGame.attach(game, in: second) { secondChanges.append($0) }

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: first)
        pad.buttonA.setValue(1)
        await Self.settle { firstChanges.count == 1 }

        // AppKit may tell the new key window before the old one, so the old one going to the
        // back must not take the controller away again.
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: second)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: first)
        #expect(firstChanges == [GamepadKeyChange(key: "space", pressed: true), GamepadKeyChange(key: "space", pressed: false)])

        pad.buttonA.setValue(0)
        pad.buttonA.setValue(1)
        await Self.settle { secondChanges.count == 1 }
        #expect(secondChanges == [GamepadKeyChange(key: "space", pressed: true)])
        #expect(firstChanges.count == 2)
        firstGame.detach()
        secondGame.detach()
    }

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
    }

    /// Controller handlers arrive on the main queue: waits for `done`, or a moment for nothing to arrive.
    private static func settle(until done: () -> Bool = { false }) async {
        for _ in 0..<40 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
#endif
