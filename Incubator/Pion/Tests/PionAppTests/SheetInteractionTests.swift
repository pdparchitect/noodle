import AppKit
import SwiftUI
import XCTest

@MainActor final class SheetInteractionTests: XCTestCase {
    func testReturnIsNotAWindowWideSaveShortcutWhileEditingMultilineText() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var saves = 0
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: VStack {
            TextField("Description", text: .constant("First line"), axis: .vertical)
            SheetHeader(heading: "Edit Group", title: "Save", enabled: true) { saves += 1 }
        })
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        defer { window.close(); window.contentView = nil }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        XCTAssertFalse(window.performKeyEquivalent(with: event), "Return belongs to the focused field, not the sheet's Save action")
        XCTAssertEqual(saves, 0)
        XCTAssertFalse(window.isVisible)
    }
}
