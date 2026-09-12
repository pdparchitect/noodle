import Foundation

public struct KeyBinding: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Self(rawValue: 1)
        public static let shift = Self(rawValue: 2)
        public static let option = Self(rawValue: 4)
        public static let control = Self(rawValue: 8)
    }
    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, modifiers: Modifiers = .command) {
        self.key = key.lowercased(); self.modifiers = modifiers
    }

    public var displayName: String {
        var prefix = ""
        for (modifier, symbol): (Modifiers, String) in [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")] {
            if modifiers.contains(modifier) { prefix += symbol }
        }
        let names = ["\r": "↩", "\t": "⇥", " ": "Space", "\u{1b}": "Esc", "\u{8}": "⌫", "\u{7f}": "⌫",
            "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→", "\u{f728}": "⌦"]
        let name: String
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1, (0xf704...0xf717).contains(scalar.value) {
            name = "F\(scalar.value - 0xf704 + 1)"
        } else { name = names[key] ?? key.uppercased() }
        return prefix + name
    }

    public var isValid: Bool {
        guard key.count == 1, key == key.lowercased(), modifiers.rawValue & ~15 == 0,
              !modifiers.intersection([.command, .control]).isEmpty else { return false }
        let scalar = key.unicodeScalars.first!.value
        return scalar >= 0x20 || ["\r", "\t", "\u{8}"].contains(key)
    }

    public var reservedAction: String? {
        let standard: [String: String] = ["q": "Quit", "w": "Close Window", "h": "Hide", "m": "Minimize",
            ",": "Settings", "c": "Copy", "x": "Cut", "v": "Paste", "z": "Undo", "a": "Select All",
            "o": "Open", "\t": "Switch Applications", " ": "Spotlight"]
        if modifiers == .command { return standard[key] }
        if modifiers == [.command, .shift] {
            if key == "z" { return "Redo" }
            if ["3", "4", "5", "6"].contains(key) { return "macOS Screenshots" }
            if key == "\t" { return "Switch Applications" }
        }
        if modifiers == [.command, .option], key == "h" { return "Hide Others" }
        if modifiers == [.command, .control], key == "q" { return "Lock Screen" }
        if modifiers == .control, key == " " { return "Switch Input Source" }
        return nil
    }
}

public enum NoodleShortcut: String, CaseIterable, Codable, Sendable, Identifiable {
    case newBot, newGroup, searchConversations, recordVoice, capture, annotateSelection, annotateRegion, saveAnnotation
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .newBot: "New Bot"
        case .newGroup: "New Group"
        case .searchConversations: "Search Conversations"
        case .recordVoice: "Record / Stop Voice Message"
        case .capture: "Capture"
        case .annotateSelection: "Add Annotation"
        case .annotateRegion: "Annotate Region"
        case .saveAnnotation: "Save Annotation Comment"
        }
    }
    public var summary: String {
        switch self {
        case .newBot: "Create a bot."
        case .newGroup: "Create a group conversation."
        case .searchConversations: "Focus the conversation search field."
        case .recordVoice: "Start or stop recording in the current chat."
        case .capture: "Open the window picker or focus the existing capture preview."
        case .annotateSelection: "Comment on selected preview text; select a region for images."
        case .annotateRegion: "Mark an attachment preview or freeze and annotate a live screen/window preview."
        case .saveAnnotation: "Save a new annotation or an unsent comment edit."
        }
    }
    public var defaultBinding: KeyBinding {
        switch self {
        case .newBot: KeyBinding("n")
        case .newGroup: KeyBinding("n", modifiers: [.command, .shift])
        case .searchConversations: KeyBinding("f")
        case .recordVoice: KeyBinding("d", modifiers: [.command, .shift])
        case .capture: KeyBinding("s", modifiers: [.command, .shift])
        case .annotateSelection: KeyBinding("a", modifiers: [.command, .shift])
        case .annotateRegion: KeyBinding("r", modifiers: [.command, .shift])
        case .saveAnnotation: KeyBinding("\r")
        }
    }
}

/// A missing override uses the default; an explicit nil disables the shortcut.
public struct KeyboardShortcutPreferences: Codable, Equatable, Sendable {
    private struct Override: Codable, Equatable, Sendable { let binding: KeyBinding? }
    private var overrides: [String: Override] = [:]
    public init() {}
    public init(data: Data?) {
        self.init()
        guard let data, var stored = try? JSONDecoder().decode(Self.self, from: data) else { return }
        stored.overrides = stored.overrides.filter { NoodleShortcut(rawValue: $0.key) != nil }
        var seen = Set<KeyBinding>()
        for action in NoodleShortcut.allCases {
            if let binding = stored.binding(for: action) {
                guard binding.isValid, binding.reservedAction == nil, seen.insert(binding).inserted else { return }
            }
        }
        self = stored
    }
    public func binding(for action: NoodleShortcut) -> KeyBinding? {
        if let override = overrides[action.rawValue] { return override.binding }
        return action.defaultBinding
    }
    public var isDefault: Bool { overrides.isEmpty }
    public func isModified(_ action: NoodleShortcut) -> Bool { overrides[action.rawValue] != nil }
    public mutating func set(_ binding: KeyBinding?, for action: NoodleShortcut) throws {
        if let binding {
            guard binding.isValid else { throw ShortcutError.invalid }
            if let reserved = binding.reservedAction { throw ShortcutError.reserved(reserved) }
            if let other = NoodleShortcut.allCases.first(where: { $0 != action && self.binding(for: $0) == binding }) {
                throw ShortcutError.conflict(other)
            }
        }
        if binding == action.defaultBinding { overrides[action.rawValue] = nil }
        else { overrides[action.rawValue] = Override(binding: binding) }
    }
    public mutating func reset(_ action: NoodleShortcut) throws { try set(action.defaultBinding, for: action) }
    public mutating func resetAll() { overrides = [:] }
}

public enum ShortcutError: LocalizedError {
    case invalid, reserved(String), conflict(NoodleShortcut)
    public var errorDescription: String? {
        switch self {
        case .invalid: "Choose a key with Command (⌘) or Control (⌃)."
        case .reserved(let action): "That shortcut is used by \(action)."
        case .conflict(let action): "Already assigned to \(action.title). Change or clear that shortcut first."
        }
    }
}
