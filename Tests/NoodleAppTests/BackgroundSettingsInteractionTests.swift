import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class BackgroundSettingsInteractionTests: HiddenViewTests {
    func testBotAndGroupBackgroundsStayPendingUntilOuterSave() async throws {
        for isGroup in [false, true] {
            let f = try fixture()
            let conversation = isGroup ? try f.group() : f.directA
            let editor = hostEditor(f, conversation: conversation)
            let window = try XCTUnwrap(editor.window)
            window.orderFront(nil) // AppKit requires an ordered window to present a sheet; it stays offscreen.

            var picker = try await backgroundPicker(in: editor)
            press(try await control("Forest", in: picker))
            press(try await control("Cancel", in: picker))
            try await wait { window.sheets.isEmpty }
            let save = try await control("Save", in: editor)
            if isGroup { XCTAssertFalse(enabled(save)) }

            picker = try await backgroundPicker(in: editor)
            press(try await control("Ocean", in: picker))
            press(try await control("Apply", in: picker))
            try await wait { window.sheets.isEmpty }
            XCTAssertTrue(f.store.background(for: conversation).isDefault)
            XCTAssertTrue(try f.repository.loadBackground(conversationID: conversation.id).isDefault)
            try await wait { self.enabled(save) }

            // Reopening uses the pending selection. Cancelling another choice keeps it.
            picker = try await backgroundPicker(in: editor)
            let ocean = try await control("Ocean", in: picker)
            let apply = try await control("Apply", in: picker)
            XCTAssertEqual(attribute(ocean, .value) as? String, "Selected")
            XCTAssertFalse(enabled(apply))
            press(try await control("Dusk", in: picker))
            press(try await control("Cancel", in: picker))
            try await wait { window.sheets.isEmpty }
            press(try await control("Save", in: editor))
            try await wait { f.store.background(for: conversation).preset == .ocean }
            XCTAssertEqual(try f.repository.loadBackground(conversationID: conversation.id).preset, .ocean)
            XCTAssertTrue(f.store.background(for: f.directB).isDefault)
            window.close()
        }
    }

    func testOuterCancelDiscardsBotAndGroupBackgroundDrafts() async throws {
        for isGroup in [false, true] {
            let f = try fixture()
            let conversation = isGroup ? try f.group() : f.directA
            try await f.store.setBackground(.init(preset: .sunset), imageData: nil, for: conversation)
            let editor = hostEditor(f, conversation: conversation)
            let window = try XCTUnwrap(editor.window)
            window.orderFront(nil)
            let picker = try await backgroundPicker(in: editor)
            press(try await control("Forest", in: picker))
            press(try await control("Apply", in: picker))
            try await wait { window.sheets.isEmpty }
            press(try await control("Cancel", in: editor))
            XCTAssertEqual(f.store.background(for: conversation).preset, .sunset)
            XCTAssertEqual(try f.repository.loadBackground(conversationID: conversation.id).preset, .sunset)
            window.close()
            let reopened = hostEditor(f, conversation: conversation)
            let reopenedWindow = try XCTUnwrap(reopened.window)
            reopenedWindow.orderFront(nil)
            let reopenedPicker = try await backgroundPicker(in: reopened)
            let sunset = try await control("Sunset", in: reopenedPicker)
            XCTAssertEqual(attribute(sunset, .value) as? String, "Selected")
            press(try await control("Cancel", in: reopenedPicker))
            try await wait { reopenedWindow.sheets.isEmpty }
            reopenedWindow.close()
        }
    }

    func testFailedOuterSaveKeepsBackgroundDraftForRetry() async throws {
        let f = try fixture(), conversation = f.directA
        try await f.store.setBackground(.init(preset: .sunset), imageData: nil, for: conversation)
        let editor = hostEditor(f, conversation: conversation)
        let window = try XCTUnwrap(editor.window)
        window.orderFront(nil)
        let picker = try await backgroundPicker(in: editor)
        press(try await control("Forest", in: picker))
        press(try await control("Apply", in: picker))
        try await wait { window.sheets.isEmpty }

        let configuration = f.repository.storage(for: f.a.id).configuration
        let original = try Data(contentsOf: configuration)
        try FileManager.default.removeItem(at: configuration)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        press(try await control("Save", in: editor))
        try await wait { f.store.errorMessage != nil }
        XCTAssertEqual(f.store.background(for: conversation).preset, .sunset)
        XCTAssertEqual(try f.repository.loadBackground(conversationID: conversation.id).preset, .sunset)
        try FileManager.default.removeItem(at: configuration)
        try original.write(to: configuration)
        press(try await control("Save", in: editor))
        try await wait { f.store.background(for: conversation).preset == .forest }
        XCTAssertEqual(try f.repository.loadBackground(conversationID: conversation.id).preset, .forest)
        window.close()
    }

    func testStandalonePickerStillAppliesDirectly() async throws {
        let f = try fixture()
        let picker = host(ConversationBackgroundSheet(conversation: f.directA).environment(f.store))
        press(try await control("Forest", in: picker))
        XCTAssertTrue(f.store.background(for: f.directA).isDefault)
        press(try await control("Apply", in: picker))
        try await wait { f.store.background(for: f.directA).preset == .forest }
        XCTAssertEqual(try f.repository.loadBackground(conversationID: f.directA.id).preset, .forest)
    }

    private func hostEditor(_ fixture: StoreFixture, conversation: BotConversation) -> NSView {
        if conversation.kind == .group {
            return host(GroupInfoSheet(conversation: conversation).environment(fixture.store))
        }
        return host(EditBotSheet(agent: fixture.a).environment(fixture.store))
    }

    private func backgroundPicker(in editor: NSView) async throws -> NSView {
        let window = try XCTUnwrap(editor.window)
        press(try await control("Conversation Background", in: editor))
        try await wait { !window.sheets.isEmpty }
        return try XCTUnwrap(window.sheets.first?.contentView)
    }
}
