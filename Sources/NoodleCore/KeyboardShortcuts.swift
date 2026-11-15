import Foundation
import ProductIdentity

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
        // Shift alone, or no modifier, would take ordinary typing.
        guard key.count == 1, key == key.lowercased(), modifiers.rawValue & ~15 == 0,
              !modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        let scalar = key.unicodeScalars.first!.value
        return scalar >= 0x20 || ["\r", "\t", "\u{8}"].contains(key)
    }

    public var reservedAction: String? {
        let standard: [String: String] = ["q": "Quit", "w": "Close Window", "h": "Hide", "m": "Minimize",
            ",": "Settings", "c": "Copy", "x": "Cut", "v": "Paste", "z": "Undo", "a": "Select All",
            "o": "Open", "\t": "Switch Applications", " ": "Spotlight"]
        if modifiers == .command, ("1"..."9").contains(key) { return "Spaces" }
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
    case newBot, newGroup, searchConversations, recordVoice, call, capture, annotateSelection, annotateRegion, saveAnnotation
    case chooseConversation, showUsage, stopBot
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .newBot: "New Bot"
        case .newGroup: "New Group"
        case .searchConversations: "Search Conversations"
        case .recordVoice: "Record / Stop Voice Message"
        case .call: "Call / End Call"
        case .capture: "Capture"
        case .annotateSelection: "Add Annotation"
        case .annotateRegion: "Annotate Region"
        case .saveAnnotation: "Save Annotation Comment"
        case .chooseConversation: "Choose Conversation"
        case .showUsage: "Usage"
        case .stopBot: "Stop Bot"
        }
    }
    public var summary: String {
        switch self {
        case .newBot: "Create a bot."
        case .newGroup: "Create a group conversation."
        case .searchConversations: "Focus the conversation search field."
        case .recordVoice: "Start or stop recording in the current chat."
        case .call: "Call the bot in the current chat, or end the call in progress."
        case .capture: "Open the window picker or focus the existing capture preview."
        case .annotateSelection: "Comment on selected conversation or preview text; select a region for images."
        case .annotateRegion: "Mark a region of the \(ProductIdentity.current.name) window, an attachment preview, or a live capture."
        case .saveAnnotation: "Save a new annotation or an unsent comment edit."
        case .chooseConversation: "From any app, pick a bot or group to float over your work."
        case .showUsage: "Show token usage, cost and disk space for every bot."
        case .stopBot: "End the turn the bot in the current chat is working on."
        }
    }
    public var defaultBinding: KeyBinding {
        switch self {
        case .newBot: KeyBinding("n")
        case .newGroup: KeyBinding("n", modifiers: [.command, .shift])
        case .searchConversations: KeyBinding("f")
        case .recordVoice: KeyBinding("d", modifiers: [.command, .shift])
        case .call: KeyBinding("c", modifiers: [.command, .shift])
        case .capture: KeyBinding("s", modifiers: [.command, .shift])
        case .annotateSelection: KeyBinding("a", modifiers: [.command, .shift])
        case .annotateRegion: KeyBinding("r", modifiers: [.command, .shift])
        case .saveAnnotation: KeyBinding("\r")
        case .chooseConversation: KeyBinding(" ", modifiers: [.control, .option])
        case .showUsage: KeyBinding("u", modifiers: [.command, .shift])
        case .stopBot: KeyBinding(".")
        }
    }
}

/// A shortcut an app offers: what it is called and does, and its key until the person changes it. It is
/// known by its id, so code shared between apps finds an app's own version of a shortcut by name.
public struct ShortcutDefinition: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let defaultBinding: KeyBinding

    public init(id: String, title: String, summary: String, defaultBinding: KeyBinding) {
        self.id = id
        self.title = title
        self.summary = summary
        self.defaultBinding = defaultBinding
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension NoodleShortcut {
    public var definition: ShortcutDefinition {
        ShortcutDefinition(id: rawValue, title: title, summary: summary, defaultBinding: defaultBinding)
    }

    /// Noodle's shortcuts.
    public static var catalog: [ShortcutDefinition] { allCases.map(\.definition) }
}

/// Noodle's shortcuts by name, as code shared with other apps asks for them.
extension ShortcutDefinition {
    public static var newBot: Self { NoodleShortcut.newBot.definition }
    public static var newGroup: Self { NoodleShortcut.newGroup.definition }
    public static var searchConversations: Self { NoodleShortcut.searchConversations.definition }
    public static var recordVoice: Self { NoodleShortcut.recordVoice.definition }
    public static var call: Self { NoodleShortcut.call.definition }
    public static var capture: Self { NoodleShortcut.capture.definition }
    public static var annotateSelection: Self { NoodleShortcut.annotateSelection.definition }
    public static var annotateRegion: Self { NoodleShortcut.annotateRegion.definition }
    public static var saveAnnotation: Self { NoodleShortcut.saveAnnotation.definition }
    public static var chooseConversation: Self { NoodleShortcut.chooseConversation.definition }
    public static var showUsage: Self { NoodleShortcut.showUsage.definition }
    public static var stopBot: Self { NoodleShortcut.stopBot.definition }
}

/// The person's changes to an app's shortcuts. A missing override uses the default; an explicit nil disables
/// the shortcut. A shortcut not in the app's list has no key.
public struct KeyboardShortcutPreferences: Codable, Equatable, Sendable {
    private struct Override: Codable, Equatable, Sendable { let binding: KeyBinding? }
    private var overrides: [String: Override] = [:]
    /// The app's shortcuts; not saved, so each launch reads its own.
    private var catalog: [ShortcutDefinition] = NoodleShortcut.catalog

    private enum CodingKeys: String, CodingKey { case overrides }

    public init(catalog: [ShortcutDefinition] = NoodleShortcut.catalog) { self.catalog = catalog }
    public init(data: Data?, catalog: [ShortcutDefinition] = NoodleShortcut.catalog) {
        self.init(catalog: catalog)
        guard let data, var stored = try? JSONDecoder().decode(Self.self, from: data) else { return }
        stored.catalog = catalog
        let known = Set(catalog.map(\.id))
        stored.overrides = stored.overrides.filter { known.contains($0.key) }
        var seen = Set<KeyBinding>()
        for action in catalog {
            if let binding = stored.binding(for: action) {
                guard binding.isValid, binding.reservedAction == nil, seen.insert(binding).inserted else { return }
            }
        }
        self = stored
    }

    public static func == (a: Self, b: Self) -> Bool { a.overrides == b.overrides }

    /// This app's own version of the shortcut.
    private func own(_ action: ShortcutDefinition) -> ShortcutDefinition? { catalog.first { $0.id == action.id } }

    public func binding(for action: ShortcutDefinition) -> KeyBinding? {
        guard let action = own(action) else { return nil }
        if let override = overrides[action.id] { return override.binding }
        return action.defaultBinding
    }
    public var isDefault: Bool { overrides.isEmpty }
    public func isModified(_ action: ShortcutDefinition) -> Bool { overrides[action.id] != nil }
    public mutating func set(_ binding: KeyBinding?, for action: ShortcutDefinition) throws {
        guard let action = own(action) else { return }
        if let binding {
            guard binding.isValid else { throw ShortcutError.invalid }
            if let reserved = binding.reservedAction { throw ShortcutError.reserved(reserved) }
            if let other = catalog.first(where: { $0 != action && self.binding(for: $0) == binding }) {
                throw ShortcutError.conflict(other.title)
            }
        }
        if binding == action.defaultBinding { overrides[action.id] = nil }
        else { overrides[action.id] = Override(binding: binding) }
    }
    public mutating func reset(_ action: ShortcutDefinition) throws {
        guard let action = own(action) else { return }
        try set(action.defaultBinding, for: action)
    }
    public mutating func resetAll() { overrides = [:] }
}

public enum ShortcutError: LocalizedError {
    /// `conflict` names the shortcut that already has the key.
    case invalid, reserved(String), conflict(String)
    public var errorDescription: String? {
        switch self {
        case .invalid: "Choose a key with Command (⌘), Control (⌃) or Option (⌥)."
        case .reserved(let action): "That shortcut is used by \(action)."
        case .conflict(let title): "Already assigned to \(title). Change or clear that shortcut first."
        }
    }
}
