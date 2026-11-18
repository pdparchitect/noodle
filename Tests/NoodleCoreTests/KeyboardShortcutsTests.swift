import XCTest
@testable import NoodleCore

final class KeyboardShortcutsTests: XCTestCase {
    func testDefaultsAreValidAndUnique() throws {
        let preferences = KeyboardShortcutPreferences()
        var seen = Set<KeyBinding>()
        for action in NoodleShortcut.catalog {
            let binding = try XCTUnwrap(preferences.binding(for: action))
            XCTAssertTrue(binding.isValid, action.title)
            XCTAssertNil(binding.reservedAction, action.title)
            XCTAssertTrue(seen.insert(binding).inserted, action.title)
        }
        XCTAssertEqual(preferences.binding(for: .annotateSelection)?.displayName, "⇧⌘A")
        XCTAssertEqual(preferences.binding(for: .capture), KeyBinding("s", modifiers: [.command, .shift]))
        XCTAssertEqual(preferences.binding(for: .saveAnnotation)?.displayName, "⌘↩")
        XCTAssertEqual(preferences.binding(for: .call)?.displayName, "⇧⌘C")
    }

    func testAnyShortcutMayUseOptionAloneButNeverShiftOrNoModifier() throws {
        var preferences = KeyboardShortcutPreferences()
        XCTAssertEqual(preferences.binding(for: .chooseConversation)?.displayName, "⌃⌥Space")
        // Option-Space takes the non-breaking space from every app, so it is a choice, not the default.
        let optionSpace = KeyBinding(" ", modifiers: .option)
        try preferences.set(optionSpace, for: .chooseConversation)
        let optionK = KeyBinding("k", modifiers: .option)
        try preferences.set(optionK, for: .capture)
        XCTAssertThrowsError(try preferences.set(KeyBinding("j", modifiers: []), for: .newBot))
        XCTAssertThrowsError(try preferences.set(KeyBinding("j", modifiers: .shift), for: .newBot))
        // Saved Option-only shortcuts must survive a relaunch.
        let restored = KeyboardShortcutPreferences(data: try JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.binding(for: .chooseConversation), optionSpace)
        XCTAssertEqual(restored.binding(for: .capture), optionK)
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
        for binding in [NoodleShortcut.annotateRegion.defaultBinding, NoodleShortcut.capture.defaultBinding, KeyBinding("q"), KeyBinding("a"),
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

    func testCaptureCanBeReboundAndCleared() throws {
        var preferences = KeyboardShortcutPreferences()
        let custom = KeyBinding("s", modifiers: [.command, .option])
        try preferences.set(custom, for: .capture)
        XCTAssertEqual(KeyboardShortcutPreferences(data: try JSONEncoder().encode(preferences)).binding(for: .capture), custom)
        try preferences.set(nil, for: .capture)
        XCTAssertNil(KeyboardShortcutPreferences(data: try JSONEncoder().encode(preferences)).binding(for: .capture))
    }

    /// Another app on Noodle's core keeps its own list: its defaults, titles and conflicts, and no key for a
    /// shortcut it does not have, while code shared with Noodle finds the ones it does by name.
    func testAnAppsOwnListGivesItsDefaultsAndConflicts() throws {
        let open = ShortcutDefinition(id: "openCase", title: "Open Case", summary: "Open a case.",
                                      defaultBinding: KeyBinding("n"))
        let capture = ShortcutDefinition(id: ShortcutDefinition.capture.id, title: "Capture Evidence", summary: "Capture a window.",
                                         defaultBinding: KeyBinding("e", modifiers: [.command, .option]))
        var preferences = KeyboardShortcutPreferences(catalog: [open, capture])
        XCTAssertEqual(preferences.binding(for: open), KeyBinding("n"))
        XCTAssertEqual(preferences.binding(for: .capture), KeyBinding("e", modifiers: [.command, .option]), "Found by name")
        XCTAssertNil(preferences.binding(for: .newBot), "Not in this app's list")
        XCTAssertThrowsError(try preferences.set(KeyBinding("n"), for: .capture)) { error in
            XCTAssertEqual(error.localizedDescription, "Already assigned to Open Case. Change or clear that shortcut first.")
        }
        try preferences.set(KeyBinding("k", modifiers: [.command, .option]), for: open)
        let restored = KeyboardShortcutPreferences(data: try JSONEncoder().encode(preferences), catalog: [open, capture])
        XCTAssertEqual(restored.binding(for: open), KeyBinding("k", modifiers: [.command, .option]))
        XCTAssertTrue(restored.isModified(open))
    }

    /// Choose Conversation with Context starts on a double tap of ⌘. Only the shortcuts that work from any
    /// app take a double tap, of one modifier, and it survives a relaunch.
    func testOnlyAnyAppShortcutsTakeADoubleTapOfOneModifier() throws {
        var preferences = KeyboardShortcutPreferences()
        let command = KeyBinding.doubleTap(.command)
        XCTAssertEqual(preferences.binding(for: .chooseConversationWithContext), command)
        XCTAssertEqual(command.displayName, "⌘⌘")
        XCTAssertTrue(command.isDoubleTap)
        XCTAssertFalse(KeyBinding(" ", modifiers: [.control, .option]).isDoubleTap)
        XCTAssertFalse(KeyBinding.doubleTap([.command, .shift]).isValid, "One modifier at a time")
        XCTAssertThrowsError(try preferences.set(KeyBinding.doubleTap(.option), for: .newBot), "Menus cannot show a double tap")
        XCTAssertThrowsError(try preferences.set(command, for: .chooseConversation)) { error in
            XCTAssertEqual(error.localizedDescription,
                "Already assigned to Choose Conversation with Context. Change or clear that shortcut first.")
        }
        try preferences.set(KeyBinding.doubleTap(.option), for: .chooseConversation)
        try preferences.set(KeyBinding("k", modifiers: [.control, .option]), for: .chooseConversationWithContext)
        let restored = KeyboardShortcutPreferences(data: try JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.binding(for: .chooseConversation), KeyBinding.doubleTap(.option))
        XCTAssertEqual(restored.binding(for: .chooseConversationWithContext), KeyBinding("k", modifiers: [.control, .option]))
        // A double tap saved for a menu command, outside the validated setter, falls back to the defaults.
        let saved = #"{"overrides":{"newBot":{"binding":{"key":"","modifiers":4}}}}"#
        XCTAssertTrue(KeyboardShortcutPreferences(data: Data(saved.utf8)).isDefault)
    }

    /// Two quick taps of one modifier on its own, with no key pressed in between, and nothing else.
    func testADoubleTapIsTwoQuickTapsOfOneModifierAlone() {
        func taps(_ steps: [(KeyBinding.Modifiers, Int, TimeInterval)]) -> [KeyBinding.Modifiers] {
            var detector = ModifierDoubleTap()
            return steps.compactMap { detector.update(held: $0.0, keyPresses: $0.1, at: $0.2) }
        }
        XCTAssertEqual(taps([(.command, 0, 0), ([], 0, 0.1), (.command, 0, 0.2), ([], 0, 0.3)]), [.command])
        XCTAssertEqual(taps([(.option, 0, 0), ([], 0, 0.1), (.option, 0, 0.2), ([], 0, 0.3)]), [.option])
        // ⌘C then ⌘V.
        XCTAssertEqual(taps([(.command, 0, 0), ([], 1, 0.1), (.command, 1, 0.2), ([], 2, 0.3)]), [])
        // A key between the taps.
        XCTAssertEqual(taps([(.command, 0, 0), ([], 0, 0.1), (.command, 1, 0.2), ([], 1, 0.3)]), [])
        // Too slow, or held too long.
        XCTAssertEqual(taps([(.command, 0, 0), ([], 0, 0.1), (.command, 0, 1.0), ([], 0, 1.1)]), [])
        XCTAssertEqual(taps([(.command, 0, 0), ([], 0, 0.8), (.command, 0, 0.9), ([], 0, 1.0)]), [])
        // Two different modifiers.
        XCTAssertEqual(taps([(.command, 0, 0), ([], 0, 0.1), (.option, 0, 0.2), ([], 0, 0.3)]), [])
        // Letting go of ⌘ while ⌥ stays down after ⌘⌥ is not a tap of ⌥.
        XCTAssertEqual(taps([(.command, 0, 0), ([.command, .option], 0, 0.05), (.option, 0, 0.1), ([], 0, 0.15),
                             (.option, 0, 0.2), ([], 0, 0.25)]), [])
        // A third tap starts over instead of firing again.
        XCTAssertEqual(taps([(.command, 0, 0), ([], 0, 0.1), (.command, 0, 0.2), ([], 0, 0.3),
                             (.command, 0, 0.4), ([], 0, 0.5)]), [.command])
    }
}
