#if os(macOS)
import AppKit
#endif
import GameController
import Observation

/// A game controller in hand, playing the keys a game declared: the d-pad and left stick steer
/// its first pad, the right stick its second, and buttons go by position from the one under the thumb.
@MainActor @Observable public final class HardwareGamepad {
    /// What the controller in hand has, or nil with none. A connected controller counts once it
    /// is used: the simulator always lists a virtual one, and a paired one may be in a drawer.
    public private(set) var controller: GamepadController?
    /// Whether a controller is connected, used yet or not.
    public private(set) var hasController = false
    @ObservationIgnored private var connectedController: GamepadController?
    @ObservationIgnored private var gamepad: Gamepad?
    @ObservationIgnored private var onKey: (GamepadKeyChange) -> Void = { _ in }
    @ObservationIgnored private var connected: GCController?
    /// What each stick and button holds, so a d-pad and a stick steering the same pad add up.
    @ObservationIgnored private var held: [String: Set<String>] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    /// Where the controller in hand comes from; tests hand over a virtual one.
    @ObservationIgnored var available: () -> GCController? = { GCController.current ?? GCController.controllers().first }
    /// The one game each controller plays: it has a single set of handlers, and a Mac may have several games open.
    private static var players: [ObjectIdentifier: Player] = [:]
    private struct Player { weak var gamepad: HardwareGamepad? }

    public enum MenuInput: Equatable, Sendable { case up, down, left, right, choose, back }

    /// What the View button does (Create on PlayStation, − on Switch), which games played with
    /// keys leave free. The home button is no use: the system always takes it.
    @ObservationIgnored public var onView: (() -> Void)?
    /// While set, the controller steers this menu instead of the game, whose keys are let go.
    @ObservationIgnored public var menu: ((MenuInput) -> Void)? {
        didSet {
            if menu != nil { set([:]) }
            pointing = [:]
        }
    }
    /// Where each stick and d-pad points in the menu, so holding one moves once.
    @ObservationIgnored private var pointing: [String: MenuInput] = [:]

    public init() {}

    public func attach(_ gamepad: Gamepad, onKey: @escaping (GamepadKeyChange) -> Void) {
        prepare(gamepad, onKey: onKey)
        if observers.isEmpty {
            let center = NotificationCenter.default
            for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.connect() }
                })
            }
        }
        connect()
    }

    #if os(macOS)
    /// On a Mac, plays only while `window` is the key one, and lets go of whatever it holds as
    /// the window goes to the back.
    public func attach(_ gamepad: Gamepad, in window: NSWindow, onKey: @escaping (GamepadKeyChange) -> Void) {
        prepare(gamepad, onKey: onKey)
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.play() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopPlaying() }
            },
        ]
        if window.isKeyWindow { play() }
    }

    private func play() {
        guard let gamepad else { return }
        attach(gamepad, onKey: onKey)
    }
    #endif

    public func detach() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        stopPlaying()
    }

    private func stopPlaying() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        use(nil)
    }

    func prepare(_ gamepad: Gamepad, onKey: @escaping (GamepadKeyChange) -> Void) {
        self.gamepad = gamepad
        self.onKey = onKey
    }

    /// What the connected controller has, taking over once it is used; nil gives the screen back.
    func offer(_ next: GamepadController?) {
        set([:])
        connectedController = next
        controller = nil
        hasController = next != nil
    }

    private func connect() { use(available()) }

    private func use(_ next: GCController?) {
        if let connected, connected !== next { release(connected) }
        connected = next
        guard let next, let gamepad else { offer(nil); return }
        if let other = Self.players[ObjectIdentifier(next)]?.gamepad, other !== self { other.yield() }
        Self.players[ObjectIdentifier(next)] = Player(gamepad: self)
        let pads = gamepad.pads
        func steer(_ source: String, pad index: Int) -> GCControllerDirectionPadValueChangedHandler? {
            { [weak self] _, x, y in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.menu != nil {
                        if index == 0 { self.point(source, x: x, y: y) }
                    } else if index < pads.count {
                        self.set(source, pads[index].held(x: x, y: y))
                    }
                }
            }
        }
        func press(_ source: String, _ key: String?, menu input: MenuInput? = nil) -> GCControllerButtonValueChangedHandler? {
            { [weak self] _, _, pressed in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let menu = self.menu {
                        if pressed, let input { menu(input) }
                    } else if let key {
                        self.set(source, pressed ? [key] : [])
                    }
                }
            }
        }
        var buttons: [GCControllerButtonInput]
        if let full = next.extendedGamepad {
            full.dpad.valueChangedHandler = steer("dpad", pad: 0)
            full.leftThumbstick.valueChangedHandler = steer("left stick", pad: 0)
            full.rightThumbstick.valueChangedHandler = steer("right stick", pad: 1)
            buttons = [full.buttonA, full.buttonB, full.buttonX, full.buttonY, full.leftShoulder, full.rightShoulder,
                       full.leftTrigger, full.rightTrigger]
            full.buttonMenu.valueChangedHandler = press("menu", gamepad.menu, menu: .back)
            full.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
                MainActor.assumeIsolated { if pressed { self?.onView?() } }
            }
            offer(GamepadController(pads: 2, buttons: buttons.indices.map(String.init), menu: true))
        } else if let remote = next.microGamepad {
            remote.dpad.valueChangedHandler = steer("dpad", pad: 0)
            buttons = [remote.buttonA, remote.buttonX]
            remote.buttonMenu.valueChangedHandler = press("menu", gamepad.menu, menu: .back)
            offer(GamepadController(pads: 1, buttons: buttons.indices.map(String.init), menu: true))
        } else {
            offer(nil)
            return
        }
        for (index, button) in buttons.enumerated() {
            let input: MenuInput? = index == 0 ? .choose : index == 1 ? .back : nil
            button.pressedChangedHandler = press("button \(index)", index < gamepad.buttons.count ? gamepad.buttons[index].key : nil,
                                                 menu: input)
        }
    }

    /// Moves the menu once each time a stick or d-pad turns to a new way.
    private func point(_ source: String, x: Float, y: Float) {
        let way: MenuInput? = max(abs(x), abs(y)) < 0.5 ? nil : abs(x) > abs(y) ? (x < 0 ? .left : .right) : (y > 0 ? .up : .down)
        guard pointing[source] != way else { return }
        pointing[source] = way
        if let way { menu?(way) }
    }

    /// Another game took the controller: lets go of what this one held, leaving the handlers to it.
    private func yield() {
        connected = nil
        offer(nil)
    }

    private func release(_ old: GCController) {
        guard Self.players[ObjectIdentifier(old)]?.gamepad === self else { return }
        Self.players[ObjectIdentifier(old)] = nil
        if let full = old.extendedGamepad {
            [full.dpad, full.leftThumbstick, full.rightThumbstick].forEach { $0.valueChangedHandler = nil }
            [full.buttonA, full.buttonB, full.buttonX, full.buttonY, full.leftShoulder, full.rightShoulder, full.leftTrigger,
             full.rightTrigger].forEach { $0.pressedChangedHandler = nil }
            full.buttonMenu.valueChangedHandler = nil
            full.buttonOptions?.pressedChangedHandler = nil
        } else if let remote = old.microGamepad {
            remote.dpad.valueChangedHandler = nil
            [remote.buttonA, remote.buttonX].forEach { $0.pressedChangedHandler = nil }
            remote.buttonMenu.valueChangedHandler = nil
        }
    }

    func set(_ source: String, _ keys: Set<String>) {
        if !keys.isEmpty, controller == nil { controller = connectedController }
        var next = held
        next[source] = keys
        set(next)
    }

    private func set(_ next: [String: Set<String>]) {
        let before = held.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        held = next
        let after = next.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        GamepadKeyChange.changes(from: before, to: after).forEach(onKey)
    }
}
