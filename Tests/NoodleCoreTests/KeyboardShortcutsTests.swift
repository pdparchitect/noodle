import XCTest
@testable import NoodleCore

final class KeyboardShortcutsTests: XCTestCase {
    func testDefaultsAreValidAndUnique() throws {
        let preferences = KeyboardShortcutPreferences()
        var seen = Set<KeyBinding>()
        for action in NoodleShortcut.allCases {
            let binding = try XCTUnwrap(preferences.binding(for: action))
            XCTAssertTrue(binding.isValid, action.title)
            XCTAssertNil(binding.reservedAction, action.title)
            XCTAssertTrue(seen.insert(binding).inserted, action.title)
        }
        XCTAssertEqual(preferences.binding(for: .annotateSelection)?.displayName, "⇧⌘A")
        XCTAssertEqual(preferences.binding(for: .saveAnnotation)?.displayName, "⌘↩")
    }

    func testOverridesDisabledBindingsAndResetSurviveRoundTrip() throws {
        var preferences = KeyboardShortcutPreferences()
        let custom = KeyBinding("K", modifiers: [.control, .option])
        try preferences.set(custom, for: .annotateSelection)
        try preferences.set(nil, for: .recordVoice)
        let data = try JSONEncoder().encode(preferences)
        var reloaded = KeyboardShortcutPreferences(data: data)
        XCTAssertEqual(reloaded, preferences)
        XCTAssertEqual(reloaded.binding(for: .annotateSelection), custom)
        XCTAssertNil(reloaded.binding(for: .recordVoice))
        XCTAssertEqual(reloaded.binding(for: .newBot), NoodleShortcut.newBot.defaultBinding)
        XCTAssertTrue(reloaded.isModified(.recordVoice))
        try reloaded.reset(.annotateSelection)
        XCTAssertEqual(reloaded.binding(for: .annotateSelection), NoodleShortcut.annotateSelection.defaultBinding)
        XCTAssertNil(reloaded.binding(for: .recordVoice))
        reloaded.resetAll()
        XCTAssertTrue(reloaded.isDefault)
        XCTAssertEqual(reloaded, KeyboardShortcutPreferences())
    }

    func testConflictsAndReservedCommandsDoNotChangePreferences() throws {
        var preferences = KeyboardShortcutPreferences()
        for binding in [NoodleShortcut.annotateRegion.defaultBinding, KeyBinding("q"), KeyBinding("a"),
                        KeyBinding(","), KeyBinding("z", modifiers: [.command, .shift]),
                        KeyBinding("4", modifiers: [.command, .shift]), KeyBinding("x", modifiers: [])] {
            XCTAssertThrowsError(try preferences.set(binding, for: .annotateSelection))
            XCTAssertTrue(preferences.isDefault)
        }
        // A cleared shortcut may be reassigned, but restoring the old action
        // must not silently create two handlers for the same key.
        try preferences.set(nil, for: .annotateRegion)
        try preferences.set(NoodleShortcut.annotateRegion.defaultBinding, for: .annotateSelection)
        XCTAssertThrowsError(try preferences.reset(.annotateRegion))
        XCTAssertNil(preferences.binding(for: .annotateRegion))
        XCTAssertEqual(preferences.binding(for: .annotateSelection), NoodleShortcut.annotateRegion.defaultBinding)
        XCTAssertEqual(KeyboardShortcutPreferences(data: try JSONEncoder().encode(preferences)), preferences)
        preferences.resetAll()
        XCTAssertTrue(preferences.isDefault)
    }

    func testCorruptAndConflictingSavedPreferencesUseSafeDefaults() throws {
        for json in ["garbage", "{}", #"{"overrides":{"annotateSelection":{"binding":{"key":"","modifiers":1}}}}"#] {
            XCTAssertTrue(KeyboardShortcutPreferences(data: Data(json.utf8)).isDefault)
        }
        // Construct corrupted persisted data through JSON, outside validated setters.
        let defaultData = try JSONEncoder().encode(NoodleShortcut.annotateRegion.defaultBinding)
        let object = try JSONSerialization.jsonObject(with: defaultData)
        let bad = try JSONSerialization.data(withJSONObject: ["overrides": ["annotateSelection": ["binding": object]]])
        XCTAssertTrue(KeyboardShortcutPreferences(data: bad).isDefault)
    }
}
