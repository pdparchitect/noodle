@testable import Surface
import Testing

/// A controller only takes over from the screen once someone plays with it: the simulator always
/// lists a virtual one, and a paired controller may be lying in a drawer.
@MainActor struct HardwareGamepadTests {
    private let game = Gamepad(pads: [Gamepad.Pad(left: "left", right: "right")], buttons: [Gamepad.Button(key: "space")], menu: "escape")
    private let pad = GamepadController(pads: 2, buttons: ["A", "B"], menu: true)

    @Test func aConnectedControllerLeavesTheScreenControlsUntilUsed() {
        var changes: [GamepadKeyChange] = []
        let hardware = HardwareGamepad()
        hardware.prepare(game) { changes.append($0) }
        hardware.offer(pad)
        #expect(hardware.controller == nil)

        hardware.set("button 0", ["space"])
        #expect(hardware.controller == pad)
        #expect(changes == [GamepadKeyChange(key: "space", pressed: true)])
    }

    @Test func aControllerGoingAwayGivesTheScreenBack() {
        let hardware = HardwareGamepad()
        hardware.prepare(game) { _ in }
        hardware.offer(pad)
        hardware.set("dpad", ["left"])
        hardware.offer(nil)
        #expect(hardware.controller == nil)
    }
}
