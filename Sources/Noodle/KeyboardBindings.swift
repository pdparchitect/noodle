import AppKit
import SwiftUI
import Observation
import NoodleCore

@MainActor @Observable final class KeyboardBindings {
    static let shared = KeyboardBindings()
    static let defaultsKey = "Noodle.keyboardShortcuts.v1"
    private let defaults: UserDefaults
    private var preferences: KeyboardShortcutPreferences
    var recordingAction: NoodleShortcut?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = KeyboardShortcutPreferences(data: defaults.data(forKey: Self.defaultsKey))
    }
    func binding(for action: NoodleShortcut) -> KeyBinding? { preferences.binding(for: action) }
    func label(for action: NoodleShortcut) -> String { binding(for: action)?.displayName ?? "Not set" }
    func help(_ title: String, for action: NoodleShortcut) -> String {
        binding(for: action).map { "\(title) (\($0.displayName))" } ?? title
    }
    var isDefault: Bool { preferences.isDefault }
    func isModified(_ action: NoodleShortcut) -> Bool { preferences.isModified(action) }
    func set(_ binding: KeyBinding?, for action: NoodleShortcut) throws {
        try preferences.set(binding, for: action)
        persist()
    }
    func reset(_ action: NoodleShortcut) throws { try set(action.defaultBinding, for: action) }
    func resetAll() { preferences.resetAll(); recordingAction = nil; persist() }
    private func persist() {
        if preferences.isDefault { defaults.removeObject(forKey: Self.defaultsKey) }
        else { defaults.set(try? JSONEncoder().encode(preferences), forKey: Self.defaultsKey) }
    }
    func matches(_ action: NoodleShortcut, event: NSEvent) -> Bool {
        guard recordingAction == nil, let binding = binding(for: action) else { return false }
        return binding == Self.binding(from: event)
    }
    static func binding(from event: NSEvent) -> KeyBinding? {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let key: String
        switch event.keyCode {
        case 36, 76: key = "\r"
        case 48: key = "\t"
        case 49: key = " "
        case 51: key = "\u{8}"
        case 53: key = "\u{1b}"
        default:
            // Honor layouts with a separate Command layer, such as Dvorak-
            // QWERTY. Shift and Option remain part of the stored modifier mask.
            let layoutModifiers = event.modifierFlags.intersection(.command)
            guard let characters = event.characters(byApplyingModifiers: layoutModifiers) ?? event.charactersIgnoringModifiers,
                  characters.count == 1 else { return nil }
            key = characters
        }
        var modifiers: KeyBinding.Modifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        return KeyBinding(key, modifiers: modifiers)
    }
    func shortcut(for action: NoodleShortcut) -> KeyboardShortcut? {
        guard recordingAction == nil, let binding = binding(for: action) else { return nil }
        var modifiers: EventModifiers = []
        if binding.modifiers.contains(.command) { modifiers.insert(.command) }
        if binding.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if binding.modifiers.contains(.option) { modifiers.insert(.option) }
        if binding.modifiers.contains(.control) { modifiers.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(Character(binding.key)), modifiers: modifiers)
    }
}

private struct AppShortcutModifier: ViewModifier {
    let action: NoodleShortcut
    func body(content: Content) -> some View {
        content.keyboardShortcut(KeyboardBindings.shared.shortcut(for: action))
    }
}

extension View {
    func appShortcut(_ action: NoodleShortcut) -> some View { modifier(AppShortcutModifier(action: action)) }
}
