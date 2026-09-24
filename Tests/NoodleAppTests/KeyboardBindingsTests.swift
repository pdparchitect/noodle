import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class KeyboardBindingsTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "com.pdparchitect.noodle.keybindings-tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    /// Menus and preview windows read the same bindings: a rebind takes over at once, persists, pauses
    /// while a shortcut is being recorded, and a cleared or reset binding stops matching.
    func testBindingsFollowRebindsRecordingAndResets() throws {
        let bindings = KeyboardBindings(defaults: defaults)
        let original = key(0, "A", flags: [.command, .shift, .capsLock])
        XCTAssertTrue(bindings.matches(.annotateSelection, event: original), "Caps Lock is ignored")
        let changed = key(40, "k", flags: [.command, .option])
        let custom = try XCTUnwrap(KeyboardBindings.binding(from: changed))
        try bindings.set(custom, for: .annotateSelection)
        XCTAssertTrue(bindings.matches(.annotateSelection, event: changed))
        XCTAssertFalse(bindings.matches(.annotateSelection, event: original))
        XCTAssertEqual(bindings.shortcut(for: .annotateSelection)?.key, KeyEquivalent(Character(custom.key)))
        XCTAssertEqual(bindings.shortcut(for: .annotateSelection)?.modifiers, [.command, .option])
        XCTAssertEqual(KeyboardBindings(defaults: defaults).binding(for: .annotateSelection), custom)

        bindings.recordingAction = .newBot
        XCTAssertFalse(bindings.matches(.annotateSelection, event: changed))
        XCTAssertNil(bindings.shortcut(for: .annotateSelection))
        bindings.recordingAction = nil

        try bindings.set(nil, for: .annotateSelection)
        XCTAssertFalse(bindings.matches(.annotateSelection, event: changed))
        XCTAssertNil(bindings.shortcut(for: .annotateSelection))
        let mouse = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertFalse(bindings.matches(.annotateSelection, event: mouse), "Two missing bindings are not a match")
        bindings.resetAll()
        XCTAssertNil(defaults.object(forKey: KeyboardBindings.defaultsKey))
    }

    /// The recorder saves a new key, refuses a conflicting one and keeps the old binding, cancels on Escape,
    /// clears on Delete, and lets keys through once its window is no longer key.
    func testShortcutRecorderSavesRefusesCancelsAndClears() throws {
        let bindings = KeyboardBindings(defaults: defaults)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var error: String?
        let recorder = ShortcutRecorderButton(action: .newBot, bindings: bindings) { error = $0 }
        window.contentView = recorder
        defer { recorder.stopRecording(); window.close() }
        let changed = key(40, "k", flags: [.command, .option])
        let custom = try XCTUnwrap(KeyboardBindings.binding(from: changed))

        recorder.startRecording()
        XCTAssertEqual(bindings.recordingAction, .newBot)
        XCTAssertNil(recorder.captureKey(changed), "A recorded key is consumed")
        XCTAssertEqual(bindings.binding(for: .newBot), custom)
        XCTAssertNil(bindings.recordingAction)
        XCTAssertNil(error)

        recorder.startRecording()
        XCTAssertNil(recorder.captureKey(key(3, "f", flags: .command)))
        XCTAssertNotNil(error, "A conflict is explained")
        XCTAssertEqual(bindings.recordingAction, .newBot, "and recording continues")
        XCTAssertEqual(bindings.binding(for: .newBot), custom)
        XCTAssertNil(recorder.captureKey(key(53, "\u{1b}", flags: [])))
        XCTAssertNil(bindings.recordingAction, "Escape cancels")

        recorder.startRecording()
        XCTAssertNil(recorder.captureKey(key(51, "\u{8}", flags: [])))
        XCTAssertNil(bindings.binding(for: .newBot), "Delete clears")

        recorder.startRecording()
        let passing = key(0, "a", flags: [])
        XCTAssertTrue(recorder.eventMonitorHandler()(passing) === passing)
        XCTAssertNil(bindings.recordingAction, "Recording stops when its window is not key")
    }
}
