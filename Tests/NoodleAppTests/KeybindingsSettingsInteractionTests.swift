import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class KeybindingsSettingsInteractionTests: HiddenViewTests {
    func testAChangedShortcutOffersItsOwnResetAndUnchangedOnesDoNot() async throws {
        let suite = "noodle-keybindings-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let bindings = KeyboardBindings(defaults: defaults)
        try bindings.set(KeyBinding("k", modifiers: .option), for: .capture)
        let settings = host(KeybindingsSettingsView(bindings: bindings).preferredColorScheme(.dark))
        let window = try XCTUnwrap(settings.window)
        window.setContentSize(.init(width: 680, height: 620))
        window.orderFront(nil)

        let reset = try await control("Reset Capture to ⇧⌘S", in: settings)
        XCTAssertFalse(hasControl("Reset New Bot to ⌘N", in: settings))
        press(reset)
        try await wait { !bindings.isModified(.capture) }
        XCTAssertEqual(bindings.binding(for: .capture), NoodleShortcut.capture.defaultBinding)
        try await wait { !self.hasControl("Reset Capture to ⇧⌘S", in: settings) }
    }
}
