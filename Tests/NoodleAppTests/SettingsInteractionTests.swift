import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

/// Uses the native accessibility/event interfaces of this test process only.
/// No external accessibility permission or real harness account is needed.
@MainActor final class SettingsInteractionTests: HiddenViewTests {
    func testEditorSaveButtonPersistsEditedName() async throws {
        let f = try fixture(), editor = host(EditBotSheet(agent: f.a).environment(f.store))
        let field = try await nameField(in: editor, name: f.a.displayName)
        edit(field, text: "Renamed through UI")
        press(try await control("Save", in: editor))
        try await wait { f.store.agents.first { $0.id == f.a.id }?.displayName == "Renamed through UI" }
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.a.id }?.displayName, "Renamed through UI")
    }

    func testEditorFailedSaveKeepsChangesAndRetryPersistsWithoutDuplicate() async throws {
        let f = try fixture(), process = try f.runtime.start(f.a)
        let editor = host(EditBotSheet(agent: f.a).environment(f.store))
        let field = try await nameField(in: editor, name: f.a.displayName)
        edit(field, text: "Retained edit")
        let configuration = f.repository.storage(for: f.a.id).configuration
        let original = try Data(contentsOf: configuration)
        try FileManager.default.removeItem(at: configuration)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        press(try await control("Save", in: editor))
        try await wait { f.store.errorMessage != nil }
        XCTAssertEqual(field.stringValue, "Retained edit"); XCTAssertEqual(process.stops, 0)
        XCTAssertEqual(f.store.agents.first { $0.id == f.a.id }?.displayName, f.a.displayName)
        try FileManager.default.removeItem(at: configuration); try original.write(to: configuration)
        press(try await control("Save", in: editor))
        try await wait { f.store.agents.first { $0.id == f.a.id }?.displayName == "Retained edit" }
        XCTAssertEqual(try f.repository.loadAgents().count, 2)
    }

    func testEditorRejectsBlankNameAndCancelDoesNotPersistDraft() async throws {
        let f = try fixture(), editor = host(EditBotSheet(agent: f.a).environment(f.store))
        let field = try await nameField(in: editor, name: f.a.displayName)
        edit(field, text: "  ")
        let save = try await control("Save", in: editor)
        try await wait { !self.enabled(save) }
        edit(field, text: "Cancelled edit")
        press(try await control("Cancel", in: editor))
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.a.id }?.displayName, f.a.displayName)
    }
}
