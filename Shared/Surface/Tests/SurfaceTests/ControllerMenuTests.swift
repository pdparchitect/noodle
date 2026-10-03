import GameController
@testable import Surface
import Testing

/// While a game plays on a TV, the controller's View button opens Noodle's menu, and the
/// controller steers the menu instead of the game until it closes.
@MainActor struct ControllerMenuTests {
    private let game = Gamepad(pads: [Gamepad.Pad(left: "left", right: "right")], buttons: [Gamepad.Button(key: "space")])

    @Test func theViewButtonAsksForTheMenu() async throws {
        let controller = GCController.withExtendedGamepad()
        let view = try #require(controller.extendedGamepad?.buttonOptions)
        var asked = 0
        let hardware = HardwareGamepad()
        hardware.available = { controller }
        hardware.attach(game) { _ in }
        hardware.onView = { asked += 1 }

        view.setValue(1)
        await Self.settle { asked == 1 }
        #expect(asked == 1)
        hardware.detach()
    }

    /// A game reading controllers itself declares no keys, and still gets the menu.
    @Test func aGameWithoutKeysStillGetsTheViewButton() async throws {
        let controller = GCController.withExtendedGamepad()
        let view = try #require(controller.extendedGamepad?.buttonOptions)
        var asked = 0, keys = 0
        let hardware = HardwareGamepad()
        hardware.available = { controller }
        hardware.attach(Gamepad()) { _ in keys += 1 }
        hardware.onView = { asked += 1 }

        controller.extendedGamepad?.buttonA.setValue(1)
        view.setValue(1)
        await Self.settle { asked == 1 }
        #expect(asked == 1)
        #expect(keys == 0)
        hardware.detach()
    }

    @Test func theMenuTakesTheControllerFromTheGame() async throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        var keys: [GamepadKeyChange] = [], moves: [HardwareGamepad.MenuInput] = []
        let hardware = HardwareGamepad()
        hardware.available = { controller }
        hardware.attach(game) { keys.append($0) }

        pad.buttonA.setValue(1)
        await Self.settle { keys.count == 1 }
        // A key held as the menu opens is let go, or the game would keep it down.
        hardware.menu = { moves.append($0) }
        #expect(keys.last == GamepadKeyChange(key: "space", pressed: false))
        pad.buttonA.setValue(0)

        pad.dpad.setValueForXAxis(0, yAxis: -1)
        pad.dpad.setValueForXAxis(0, yAxis: 0)
        pad.leftThumbstick.setValueForXAxis(1, yAxis: 0)
        pad.buttonA.setValue(1)
        pad.buttonB.setValue(1)
        await Self.settle { moves.count == 4 }
        #expect(moves == [.down, .right, .choose, .back])
        #expect(keys.count == 2)

        // Closed, the controller plays the game again.
        hardware.menu = nil
        pad.buttonA.setValue(0)
        pad.buttonA.setValue(1)
        await Self.settle { keys.count == 3 }
        #expect(keys.last == GamepadKeyChange(key: "space", pressed: true))
        hardware.detach()
    }

    /// Controller handlers arrive on the main queue: waits for `done`, or a moment for nothing to arrive.
    private static func settle(until done: () -> Bool = { false }) async {
        for _ in 0..<40 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
