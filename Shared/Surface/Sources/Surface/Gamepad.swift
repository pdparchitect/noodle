import SwiftUI

/// The keys a game listens for, as its noodlet declares them: up to two pads of directions,
/// buttons from most to least important, and the key that pauses it. Each viewer shows them its
/// own way, on a controller or on the screen, and the game only ever sees its keys.
public struct Gamepad: Codable, Equatable, Sendable {
    public struct Pad: Codable, Equatable, Sendable {
        public var left, right, up, down: String?
        /// Shown on a touch screen as a thumbstick rather than a d-pad; it presses the same keys.
        public var stick: Bool
        public init(left: String? = nil, right: String? = nil, up: String? = nil, down: String? = nil, stick: Bool = false) {
            self.left = left
            self.right = right
            self.up = up
            self.down = down
            self.stick = stick
        }
        public var keys: [String] { [left, right, up, down].compactMap { $0 } }

        enum CodingKeys: String, CodingKey { case left, right, up, down, stick }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            left = try c.decodeIfPresent(String.self, forKey: .left)
            right = try c.decodeIfPresent(String.self, forKey: .right)
            up = try c.decodeIfPresent(String.self, forKey: .up)
            down = try c.decodeIfPresent(String.self, forKey: .down)
            stick = try c.decodeIfPresent(Bool.self, forKey: .stick) ?? false
        }

        /// Only a stick says so, so a d-pad reads the same to viewers that know no sticks.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(left, forKey: .left)
            try c.encodeIfPresent(right, forKey: .right)
            try c.encodeIfPresent(up, forKey: .up)
            try c.encodeIfPresent(down, forKey: .down)
            if stick { try c.encode(stick, forKey: .stick) }
        }

        /// The keys a stick or d-pad at `x`, `y` holds, each -1...1 with up positive.
        public func held(x: Float, y: Float) -> Set<String> {
            GamepadLayout.directions(at: CGPoint(x: 1 + CGFloat(x), y: 1 - CGFloat(y)), in: CGRect(x: 0, y: 0, width: 2, height: 2), pad: self)
        }
    }

    public struct Button: Codable, Equatable, Sendable {
        public var key: String
        public var label: String?
        public init(key: String, label: String? = nil) {
            self.key = key
            self.label = label
        }
    }

    public var pads: [Pad]
    public var buttons: [Button]
    public var menu: String?

    public init(pads: [Pad] = [], buttons: [Button] = [], menu: String? = nil) {
        self.pads = pads
        self.buttons = buttons
        self.menu = menu
    }

    enum CodingKeys: String, CodingKey { case pads, buttons, menu }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pads = try c.decodeIfPresent([Pad].self, forKey: .pads) ?? []
        buttons = try c.decodeIfPresent([Button].self, forKey: .buttons) ?? []
        menu = try c.decodeIfPresent(String.self, forKey: .menu)
    }

    /// Named keys a live view can press, plus lowercase letters and digits.
    public static let namedKeys = ["left", "right", "up", "down", "space", "enter", "tab", "escape", "backspace"]
    /// As many as a modern controller has: four face buttons and four shoulders.
    public static let maxButtons = 8

    public struct Invalid: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public func validate() throws {
        func fail(_ message: String) -> Invalid { Invalid(message: message) }
        guard !pads.isEmpty || !buttons.isEmpty || menu != nil else { throw fail("Controls need a pad, a button or a menu key.") }
        guard pads.count <= 2 else { throw fail("Controls can have at most two pads.") }
        guard buttons.count <= Self.maxButtons else { throw fail("Controls can have at most \(Self.maxButtons) buttons.") }
        for pad in pads where pad.keys.isEmpty { throw fail("A pad needs at least one direction.") }
        for button in buttons {
            guard let label = button.label else { continue }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 12 else { throw fail("Button labels must be 1 to 12 characters.") }
        }
        let keys = pads.flatMap(\.keys) + buttons.map(\.key) + [menu].compactMap { $0 }
        for key in keys {
            let single = key.count == 1 && key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            guard single || Self.namedKeys.contains(key) else {
                throw fail("Unknown key \(key.prefix(20)). Use a lowercase letter, a digit or \(Self.namedKeys.joined(separator: ", ")).")
            }
        }
        guard Set(keys).count == keys.count else { throw fail("Each key can be used only once.") }
    }

    /// Where each key goes on `controller`: pads to its sticks, buttons by position from the one
    /// under the thumb, and whatever it has no room for onto the screen.
    public func mapped(to controller: GamepadController) -> [String: GamepadSlot] {
        var slots: [String: GamepadSlot] = [:]
        for (index, pad) in pads.enumerated() {
            for key in pad.keys { slots[key] = index < controller.pads ? .pad(index) : .screen }
        }
        for (index, button) in buttons.enumerated() {
            slots[button.key] = index < controller.buttons.count ? .button(controller.buttons[index]) : .screen
        }
        if let menu {
            slots[menu] = controller.menu ? .menu
                : buttons.count < controller.buttons.count ? .button(controller.buttons[buttons.count]) : .screen
        }
        return slots
    }
}

extension Gamepad {
    /// What stays on the screen beside `controller`: the pads, buttons and menu it has no room
    /// for, or nil when it takes everything.
    public func onScreen(with controller: GamepadController) -> Gamepad? {
        let slots = mapped(to: controller)
        let rest = Gamepad(pads: pads.filter { slots[$0.keys[0]] == .screen }, buttons: buttons.filter { slots[$0.key] == .screen },
                           menu: menu.flatMap { slots[$0] == .screen ? $0 : nil })
        return rest == Gamepad() ? nil : rest
    }
}

/// What a controller has: how many separate directional controls, its buttons in the order the
/// thumb reaches them (bottom, right, left, top, then shoulders), and whether it has a menu button.
public struct GamepadController: Equatable, Sendable {
    public var pads: Int
    public var buttons: [String]
    public var menu: Bool
    public init(pads: Int, buttons: [String], menu: Bool) {
        self.pads = pads
        self.buttons = buttons
        self.menu = menu
    }
}

public enum GamepadSlot: Equatable, Sendable {
    case pad(Int), button(String), menu, screen
}

/// A key going down or coming up.
public struct GamepadKeyChange: Equatable, Sendable {
    public var key: String
    public var pressed: Bool
    public init(key: String, pressed: Bool) {
        self.key = key
        self.pressed = pressed
    }

    /// Releases come first, so sliding a thumb across never holds opposite directions at once.
    public static func changes(from old: Set<String>, to new: Set<String>) -> [Self] {
        old.subtracting(new).sorted().map { Self(key: $0, pressed: false) } + new.subtracting(old).sorted().map { Self(key: $0, pressed: true) }
    }
}

/// Where the controls go on a touch screen: the first pad under the left thumb with the menu
/// above it, the second pad under the right thumb, and the buttons nearest the right thumb in
/// order of importance.
public struct GamepadLayout: Equatable {
    public enum Control: Hashable { case pad(Int), button(Int), menu }

    public static let margin: CGFloat = 16
    static let spacing: CGFloat = 12
    static let menuSize = CGSize(width: 64, height: 44)

    public private(set) var frames: [Control: CGRect] = [:]

    /// `size` is the whole screen; `safeArea` is what iOS keeps clear of the notch and home bar.
    public init(_ gamepad: Gamepad, in size: CGSize, safeArea: EdgeInsets) {
        let width = size.width - safeArea.leading - safeArea.trailing, height = size.height - safeArea.top - safeArea.bottom
        // Before a view has its size there is no room, and no controls.
        guard width > 2 * Self.margin, height > 2 * Self.margin else { return }
        let area = CGRect(x: safeArea.leading, y: safeArea.top, width: width, height: height)
        let inner = area.insetBy(dx: Self.margin, dy: Self.margin)
        let spacing = Self.spacing
        let padSize = min(max(min(inner.width, inner.height) * 0.36, 120), 170)
        let buttonSize = min(max(padSize * 0.42, 52), 72)

        var left = inner.minX
        if !gamepad.pads.isEmpty {
            let pad = CGRect(x: inner.minX, y: inner.maxY - padSize, width: padSize, height: padSize)
            frames[.pad(0)] = pad
            left = pad.maxX + spacing
            if gamepad.menu != nil {
                frames[.menu] = CGRect(origin: CGPoint(x: inner.minX, y: pad.minY - spacing - Self.menuSize.height), size: Self.menuSize)
            }
        } else if gamepad.menu != nil {
            frames[.menu] = CGRect(origin: CGPoint(x: inner.minX, y: inner.maxY - Self.menuSize.height), size: Self.menuSize)
            left += Self.menuSize.width + spacing
        }

        var thumb = CGPoint(x: area.maxX, y: area.maxY)
        var grids: [(right: CGFloat, bottom: CGFloat, width: CGFloat)] = [(inner.maxX, inner.maxY, inner.maxX - left)]
        if gamepad.pads.count > 1 {
            let pad = CGRect(x: inner.maxX - padSize, y: inner.maxY - padSize, width: padSize, height: padSize)
            frames[.pad(1)] = pad
            thumb = CGPoint(x: pad.midX, y: pad.midY)
            // Beside the pad with the first row level with it, or stacked above it: whichever
            // leaves more of the screen free above.
            grids = [(pad.minX - spacing, pad.midY + buttonSize / 2, pad.minX - spacing - left), (inner.maxX, pad.minY - spacing, padSize)]
        }

        let count = gamepad.buttons.count
        guard count > 0 else { return }
        let cells = grids.compactMap { grid -> [CGRect]? in
            let columns = min(count, 3, Int((grid.width + spacing) / (buttonSize + spacing)))
            guard columns > 0 else { return nil }
            return (0..<count).map { index in
                let row = CGFloat(index / columns), column = CGFloat(index % columns)
                return CGRect(x: grid.right - (column + 1) * buttonSize - column * spacing,
                              y: grid.bottom - (row + 1) * buttonSize - row * spacing, width: buttonSize, height: buttonSize)
            }
        }.max { ($0.map(\.minY).min() ?? 0) < ($1.map(\.minY).min() ?? 0) } ?? []
        func distance(_ cell: CGRect) -> CGFloat { hypot(cell.midX - thumb.x, cell.midY - thumb.y) }
        for (index, cell) in cells.sorted(by: { distance($0) < distance($1) }).enumerated() { frames[.button(index)] = cell }
        // Two side by side sit on a slant, as on a Nintendo pad, the main one higher.
        if count == 2, let first = frames[.button(0)], let second = frames[.button(1)], first.minY == second.minY {
            frames[.button(0)] = first.offsetBy(dx: 0, dy: -buttonSize * 0.45)
        }
    }

    /// The keys a thumb at `point` holds on a pad drawn in `frame`: eight ways, with a still middle.
    /// A pad with only left and right, or only up and down, ignores the other axis.
    public static func directions(at point: CGPoint, in frame: CGRect, pad: Gamepad.Pad) -> Set<String> {
        let dx = point.x - frame.midX, dy = point.y - frame.midY
        let rest = frame.width / 2 * 0.25
        let horizontal = pad.left != nil || pad.right != nil, vertical = pad.up != nil || pad.down != nil
        var held: [String?] = []
        if horizontal && !vertical {
            if abs(dx) > rest { held = [dx < 0 ? pad.left : pad.right] }
        } else if vertical && !horizontal {
            if abs(dy) > rest { held = [dy < 0 ? pad.up : pad.down] }
        } else if hypot(dx, dy) > rest {
            let sector = (Int((atan2(-dy, dx) / (.pi / 4)).rounded()) + 8) % 8
            let ways: [[String?]] = [[pad.right], [pad.right, pad.up], [pad.up], [pad.up, pad.left],
                                     [pad.left], [pad.left, pad.down], [pad.down], [pad.down, pad.right]]
            held = ways[sector]
        }
        return Set(held.compactMap { $0 })
    }

    /// How far a stick's knob travels from the middle, as a share of the stick's radius.
    public static let stickReach: CGFloat = 0.5

    /// Where a stick's knob sits, from the middle of `frame`, for a thumb at `point`: under the
    /// thumb as far as it reaches, and only along the axes the pad has.
    public static func knob(at point: CGPoint, in frame: CGRect, pad: Gamepad.Pad) -> CGPoint {
        let dx = pad.left != nil || pad.right != nil ? point.x - frame.midX : 0
        let dy = pad.up != nil || pad.down != nil ? point.y - frame.midY : 0
        let reach = frame.width / 2 * stickReach, distance = hypot(dx, dy)
        guard distance > reach else { return CGPoint(x: dx, y: dy) }
        return CGPoint(x: dx / distance * reach, y: dy / distance * reach)
    }
}

/// On-screen controls over a live view, kept to its safe area.
public struct GamepadOverlay: View {
    let gamepad: Gamepad
    let haptics: Bool
    let onKey: (GamepadKeyChange) -> Void

    public init(gamepad: Gamepad, haptics: Bool = false, onKey: @escaping (GamepadKeyChange) -> Void) {
        self.gamepad = gamepad
        self.haptics = haptics
        self.onKey = onKey
    }

    public var body: some View {
        // A reader spread over the whole screen reports no safe area, so it stays inside it; the
        // keyboard coming up leaves the controls where they are.
        GeometryReader { proxy in
            GamepadControls(gamepad: gamepad, layout: GamepadLayout(gamepad, in: proxy.size, safeArea: EdgeInsets()),
                            haptics: haptics, onKey: onKey)
        }
        .ignoresSafeArea(.keyboard)
    }
}

/// Draws `layout`; touches anywhere else go through to what is underneath.
public struct GamepadControls: View {
    let gamepad: Gamepad
    let layout: GamepadLayout
    let haptics: Bool
    let onKey: (GamepadKeyChange) -> Void
    @State private var held: [GamepadLayout.Control: Set<String>] = [:]
    /// Where the thumb is on each stick, for its knob.
    @State private var thumbs: [GamepadLayout.Control: CGPoint] = [:]
    /// The latest press to feel, counted so the same feel twice in a row still plays.
    @State private var felt = Felt()

    private struct Felt: Equatable {
        var count = 0
        var feedback: SensoryFeedback?
    }

    public init(gamepad: Gamepad, layout: GamepadLayout, haptics: Bool = false, onKey: @escaping (GamepadKeyChange) -> Void = { _ in }) {
        self.gamepad = gamepad
        self.layout = layout
        self.haptics = haptics
        self.onKey = onKey
    }

    /// What the thumb feels as `control` goes from holding `old` to `new`: a button clicks down
    /// and lighter back up, a pad ticks as it takes on another direction and lets go silently.
    public static func feel(for control: GamepadLayout.Control, from old: Set<String>, to new: Set<String>, enabled: Bool) -> SensoryFeedback? {
        guard enabled, old != new else { return nil }
        switch control {
        case .pad: return new.isEmpty ? nil : .selection
        case .button, .menu: return .impact(weight: new.isEmpty ? .light : .medium)
        }
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(layout.frames.keys), id: \.self) { control in
                if let frame = layout.frames[control] {
                    self.control(control, frame: frame)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
        }
        .sensoryFeedback(trigger: felt) { _, felt in felt.feedback }
    }

    @ViewBuilder private func control(_ control: GamepadLayout.Control, frame: CGRect) -> some View {
        let pressed = !(held[control] ?? []).isEmpty
        switch control {
        case .pad(let index):
            let pad = gamepad.pads[index], bounds = CGRect(origin: .zero, size: frame.size)
            Group {
                if pad.stick {
                    StickShape(pad: pad, held: held[control] ?? [],
                               knob: thumbs[control].map { GamepadLayout.knob(at: $0, in: bounds, pad: pad) } ?? .zero)
                } else {
                    PadShape(pad: pad, held: held[control] ?? [])
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                if pad.stick { thumbs[control] = drag.location }
                hold(control, GamepadLayout.directions(at: drag.location, in: bounds, pad: pad))
            }.onEnded { _ in
                thumbs[control] = nil
                hold(control, [])
            })
        case .button(let index):
            let button = gamepad.buttons[index]
            Circle().fill(GamepadControls.backing).overlay(Circle().fill(.white.opacity(pressed ? 0.45 : 0.2)))
                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1.5))
                .overlay(Text(button.label ?? button.key.uppercased()).font(.system(size: 13, weight: .semibold))
                    .minimumScaleFactor(0.6).lineLimit(1).padding(6).foregroundStyle(.white))
                .gesture(press(control, key: button.key))
        case .menu:
            Capsule().fill(GamepadControls.backing).overlay(Capsule().fill(.white.opacity(pressed ? 0.45 : 0.2)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 1.5))
                .overlay(Image(systemName: "line.3.horizontal").foregroundStyle(.white))
                .gesture(press(control, key: gamepad.menu ?? ""))
        }
    }

    /// Under each control, so its white reads over a light page as well as a dark one.
    static let backing = Color.black.opacity(0.25)

    private func press(_ control: GamepadLayout.Control, key: String) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { _ in hold(control, [key]) }.onEnded { _ in hold(control, []) }
    }

    private func hold(_ control: GamepadLayout.Control, _ keys: Set<String>) {
        let changes = GamepadKeyChange.changes(from: held[control] ?? [], to: keys)
        guard !changes.isEmpty else { return }
        if let feedback = Self.feel(for: control, from: held[control] ?? [], to: keys, enabled: haptics) {
            felt = Felt(count: felt.count + 1, feedback: feedback)
        }
        held[control] = keys
        changes.forEach(onKey)
    }
}

/// A d-pad cross with an arm and arrow for each direction it has, lit while held. The whole
/// square takes the thumb, so it can press diagonals between the arms.
private struct PadShape: View {
    let pad: Gamepad.Pad
    let held: Set<String>

    var body: some View {
        GeometryReader { proxy in
            let radius = proxy.size.width / 2
            let cross = PadCross(pad: pad)
            ZStack {
                cross.fill(GamepadControls.backing)
                cross.fill(.white.opacity(held.isEmpty ? 0.18 : 0.28))
                cross.stroke(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)).padding(0.75)
                PadArrows(pad: pad, held: held, radius: radius, size: 0.28, distance: 0.68)
            }
            .contentShape(Rectangle())
        }
    }
}

/// A thumbstick: a round well with an arrow for each direction it has, and a knob that follows
/// the thumb. The whole square takes the thumb, as on a d-pad.
private struct StickShape: View {
    let pad: Gamepad.Pad
    let held: Set<String>
    let knob: CGPoint

    var body: some View {
        GeometryReader { proxy in
            let radius = proxy.size.width / 2
            ZStack {
                Circle().fill(GamepadControls.backing)
                Circle().fill(.white.opacity(0.12))
                Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1.5)
                PadArrows(pad: pad, held: held, radius: radius, size: 0.2, distance: 0.8)
                Circle().fill(GamepadControls.backing).overlay(Circle().fill(.white.opacity(held.isEmpty ? 0.3 : 0.45)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
                    .frame(width: radius, height: radius)
                    .offset(x: knob.x, y: knob.y)
            }
            .contentShape(Rectangle())
        }
    }
}

/// An arrow for each direction a pad has, `distance` out from the middle, lit while held.
private struct PadArrows: View {
    let pad: Gamepad.Pad
    let held: Set<String>
    let radius, size, distance: CGFloat

    var body: some View {
        let arrows: [(String?, String, CGFloat, CGFloat)] = [(pad.up, "chevron.up", 0, -1), (pad.down, "chevron.down", 0, 1),
                                                             (pad.left, "chevron.left", -1, 0), (pad.right, "chevron.right", 1, 0)]
        ForEach(arrows, id: \.1) { key, symbol, x, y in
            if let key {
                Image(systemName: symbol).font(.system(size: radius * size, weight: .bold))
                    .foregroundStyle(.white.opacity(held.contains(key) ? 1 : 0.6))
                    .offset(x: x * radius * distance, y: y * radius * distance)
            }
        }
    }
}

/// The outline of a cross whose arms are a third of its width, leaving out the arms a pad lacks.
private struct PadCross: Shape {
    let pad: Gamepad.Pad

    func path(in rect: CGRect) -> Path {
        let w = rect.width, a = w / 3, b = w * 2 / 3
        var points = [CGPoint(x: a, y: a)]
        points += pad.up != nil ? [CGPoint(x: a, y: 0), CGPoint(x: b, y: 0), CGPoint(x: b, y: a)] : [CGPoint(x: b, y: a)]
        points += pad.right != nil ? [CGPoint(x: w, y: a), CGPoint(x: w, y: b), CGPoint(x: b, y: b)] : [CGPoint(x: b, y: b)]
        points += pad.down != nil ? [CGPoint(x: b, y: w), CGPoint(x: a, y: w), CGPoint(x: a, y: b)] : [CGPoint(x: a, y: b)]
        points += pad.left != nil ? [CGPoint(x: 0, y: b), CGPoint(x: 0, y: a)] : []
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x, y: rect.minY + $0.y) })
        path.closeSubpath()
        return path
    }
}
