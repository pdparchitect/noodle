import Foundation

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
    public static let namedKeys = ["left", "right", "up", "down", "space", "enter", "tab", "escape", "backspace", "shift", "control", "alt"]
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
        // A pad may share keys with a button or the other pad, as a trigger giving gas while the stick steers.
        for pad in pads where Set(pad.keys).count != pad.keys.count { throw fail("A pad needs a different key for each direction.") }
        let pressed = buttons.map(\.key) + [menu].compactMap { $0 }
        guard Set(pressed).count == pressed.count else { throw fail("Each button and the menu need their own key.") }
    }
}
