import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class MCPSettingsInteractionTests: HiddenViewTests {
    private func mcpFixture() throws -> MCPControllerFixture {
        let f = try MCPControllerFixture(credentialFailure: false, removed: nil)
        addTeardownBlock { @MainActor in
            f.controller.start(agents: [])
            try? FileManager.default.removeItem(at: f.root)
        }
        return f
    }

    func testNewConnectionRequiresNameAndURLAndRejectsInvalidEndpoints() async throws {
        let f = try mcpFixture()
        let editor = host(MCPEditor(controller: f.controller,
            onSaved: { _ in XCTFail("Invalid connections must not save") },
            onConnect: { _ in XCTFail("Invalid connections must not connect") }))
        let save = try await control("Add & Connect", in: editor)
        XCTAssertFalse(enabled(save))
        let name = try await textField("e.g. Notion — Work", in: editor)
        let endpoint = try await textField("https://…", in: editor)
        edit(endpoint, text: "https://example.com/mcp"); edit(name, text: "  ")
        try await wait { !self.enabled(save) }
        edit(name, text: "Work")
        for invalid in ["http://example.com/mcp", "https://localhost/mcp", "https://user:password@example.com/mcp", "https://example.com/mcp#fragment"] {
            edit(endpoint, text: invalid)
            try await wait { self.enabled(save) }
            press(save)
            _ = try await control("Enter a public HTTPS server URL without credentials or a fragment.", in: editor)
            XCTAssertTrue(f.controller.registry.connections.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.registryURL.path))
        }
    }

    func testNewConnectionReturnsTheSavedIdentityAndConnectsAfterSaving() async throws {
        let f = try mcpFixture(), other = try f.account(name: "Work")
        try f.controller.save(other)
        var saved: [MCPConnectionRecord] = [], connected: [MCPConnectionRecord] = []
        let editor = host(MCPEditor(controller: f.controller, onSaved: { saved.append($0) },
            onConnect: { connected.append($0) }))
        edit(try await textField("e.g. Notion — Work", in: editor), text: "  Work  ")
        edit(try await textField("https://…", in: editor), text: " https://example.com/mcp ")
        press(try await control("Add & Connect", in: editor))
        XCTAssertEqual(saved.count, 1); XCTAssertTrue(connected.isEmpty)
        try await wait { connected.count == 1 }
        let current = try XCTUnwrap(f.controller.registry.connections.last)
        XCTAssertNotEqual(current.id, other.id)
        XCTAssertEqual(current.name, "Work")
        XCTAssertNotEqual(current.skillName, other.skillName)
        XCTAssertEqual(saved, [current]); XCTAssertEqual(connected, [current])
        XCTAssertEqual(try MCPRegistry.load(root: f.root), f.controller.registry)
        XCTAssertTrue(f.controller.registry.assignments.isEmpty)
    }

    func testEditingKeepsEndpointIdentityAssignmentsAndExistingTextWithoutConnecting() async throws {
        let f = try mcpFixture()
        var account = try f.account()
        account.description = "Account description"; account.instructions = "Existing user text"
        try f.controller.save(account); try f.controller.assign([account.id], to: f.a)
        var saved: MCPConnectionRecord?
        let editor = host(MCPEditor(controller: f.controller, existing: account,
            onSaved: { saved = $0 }, onConnect: { _ in XCTFail("Editing must not initiate sign-in") }))
        let endpoint = try await textField("https://…", in: editor)
        XCTAssertFalse(endpoint.isEnabled)
        edit(try await textField("e.g. Notion — Work", in: editor), text: " Renamed account ")
        press(try await control("Save", in: editor))
        let result = try XCTUnwrap(saved)
        XCTAssertEqual(result.id, account.id); XCTAssertEqual(result.endpoint, account.endpoint)
        XCTAssertEqual(result.name, "Renamed account")
        XCTAssertEqual(result.description, account.description); XCTAssertEqual(result.instructions, account.instructions)
        XCTAssertEqual(result.skillName, account.skillName)
        XCTAssertEqual(f.controller.selectedIDs(for: f.a), [account.id])
        XCTAssertTrue(f.controller.selectedIDs(for: f.b).isEmpty)
        XCTAssertEqual(try MCPRegistry.load(root: f.root).connections, [result])
    }

    func testFailedRegistrySaveRetainsDraftAndRetryCreatesOnlyOneConnection() async throws {
        let f = try mcpFixture()
        try FileManager.default.createDirectory(at: f.registryURL, withIntermediateDirectories: true)
        var saved = 0, connected = 0
        let editor = host(MCPEditor(controller: f.controller, onSaved: { _ in saved += 1 }, onConnect: { _ in connected += 1 }))
        let name = try await textField("e.g. Notion — Work", in: editor)
        edit(name, text: "Retried connection")
        edit(try await textField("https://…", in: editor), text: "https://example.com/mcp")
        press(try await control("Add & Connect", in: editor))
        XCTAssertEqual(saved, 0); XCTAssertEqual(connected, 0)
        XCTAssertTrue(f.controller.registry.connections.isEmpty)
        XCTAssertEqual(name.stringValue, "Retried connection")
        try FileManager.default.removeItem(at: f.registryURL)
        press(try await control("Add & Connect", in: editor))
        try await wait { connected == 1 }
        XCTAssertEqual(saved, 1); XCTAssertEqual(try MCPRegistry.load(root: f.root).connections.count, 1)
    }

    func testWorkspaceRefreshFailureRetriesTheSameConnectionWithoutDuplicatingIt() async throws {
        let f = try mcpFixture()
        f.controller.start(agents: [f.a])
        let file = f.repository.directory(for: f.a).appendingPathComponent(".agents/skills/messenger/SKILL.md")
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var saved = 0, connected = 0
        let editor = host(MCPEditor(controller: f.controller, onSaved: { _ in saved += 1 }, onConnect: { _ in connected += 1 }))
        let name = try await textField("e.g. Notion — Work", in: editor)
        edit(name, text: "Refresh retry")
        edit(try await textField("https://…", in: editor), text: "https://example.com/mcp")
        press(try await control("Add & Connect", in: editor))
        XCTAssertEqual(saved, 0); XCTAssertEqual(connected, 0)
        let first = try XCTUnwrap(f.controller.registry.connections.first)
        XCTAssertEqual(name.stringValue, "Refresh retry")
        try FileManager.default.removeItem(at: file); try original.write(to: file)
        press(try await control("Add & Connect", in: editor))
        try await wait { connected == 1 }
        XCTAssertEqual(saved, 1)
        XCTAssertEqual(try MCPRegistry.load(root: f.root).connections.map(\.id), [first.id])
    }

    func testCancelAndBackLeaveTheRegistryUnchanged() async throws {
        let f = try mcpFixture(), account = try f.account()
        try f.controller.save(account)
        let before = try Data(contentsOf: f.registryURL)
        let editor = host(MCPEditor(controller: f.controller, existing: account))
        edit(try await textField("e.g. Notion — Work", in: editor), text: "Cancelled edit")
        press(try await control("Cancel", in: editor))
        var back = 0
        let creation = host(MCPEditor(controller: f.controller, onBack: { back += 1 }))
        edit(try await textField("e.g. Notion — Work", in: creation), text: "Abandoned draft")
        press(try await control("Back", in: creation))
        XCTAssertEqual(back, 1); XCTAssertEqual(try Data(contentsOf: f.registryURL), before)
    }

    func testAssignmentSearchAddAndRemoveChangeOnlyTheDraft() async throws {
        let f = try mcpFixture(), first = try f.account(name: "Work"), second = try f.account(name: "Personal")
        try f.controller.save(first); try f.controller.save(second)
        try f.controller.assign([first.id], to: f.a)
        let before = try Data(contentsOf: f.registryURL), selection = MemberSelection()
        selection.ids = [first.id]
        let chooser = host(MCPConnectionChooser(controller: f.controller, selectedIDs: selection.idsBinding,
            search: selection.searchBinding, onNewTool: { XCTFail("No new tool requested") }, onDone: { selection.done += 1 }))
        let search = try await textField("Search connections", in: chooser)
        edit(search, text: "nobody")
        try await wait { !self.hasControl("Personal", in: chooser) }
        edit(search, text: "PERSON")
        let add = try await control("Personal", in: chooser)
        press(add); press(add)
        try await wait { selection.ids == [first.id, second.id] }
        try await wait { !self.hasControl("Personal", in: chooser) }
        press(try await control("Done", in: chooser)); XCTAssertEqual(selection.done, 1)
        let picker = host(MCPAssignmentPicker(controller: f.controller, selectedIDs: selection.idsBinding))
        let window = try XCTUnwrap(picker.window)
        func confirmation() async throws -> NSView {
            press(try await control("Remove Work from this bot", in: picker))
            try await wait { !window.sheets.isEmpty }
            let content = try XCTUnwrap(window.sheets.first?.contentView)
            _ = try await control("Remove “Work”?", in: content)
            XCTAssertEqual(selection.ids, [first.id, second.id], "The tool must stay until removal is confirmed")
            return content
        }
        press(try await control("Cancel", in: try await confirmation()))
        try await wait { window.sheets.isEmpty }
        XCTAssertEqual(selection.ids, [first.id, second.id], "Cancel must keep the tool")
        press(try await control("Remove Tool", in: try await confirmation()))
        try await wait { selection.ids == [second.id] }
        XCTAssertEqual(try Data(contentsOf: f.registryURL), before)
        XCTAssertEqual(f.controller.selectedIDs(for: f.a), [first.id])
    }

    func testEmptyChooserCanRequestCreationAndPickerShowsNoAssignments() async throws {
        let f = try mcpFixture(), selection = MemberSelection()
        var newTool = 0
        let chooser = host(MCPConnectionChooser(controller: f.controller, selectedIDs: selection.idsBinding,
            search: selection.searchBinding, onNewTool: { newTool += 1 }, onDone: {}))
        _ = try await control("No saved connections. Choose New Tool to add one.", in: chooser)
        press(try await control("New Tool…", in: chooser)); XCTAssertEqual(newTool, 1)
        let picker = host(MCPAssignmentPicker(controller: f.controller, selectedIDs: selection.idsBinding))
        _ = try await control("No tool connections assigned", in: picker)
        XCTAssertTrue(f.controller.registry.connections.isEmpty)
    }

    func testSettingsReflectSavedConnectionsAndSignInStatusWithoutConnecting() async throws {
        let f = try fixture()
        let settings = host(MCPSettingsView().environment(f.store))
        _ = try await control("No connections", in: settings)
        let account = try MCPConnectionRecord(name: "Saved tools", endpoint: URL(string: "https://example.com/mcp")!, description: "Fixture account")
        try f.store.mcp.save(account)
        _ = try await control("Saved tools", in: settings)
        _ = try await control("Sign-in required", in: settings)
        _ = try await control("Fixture account", in: settings)
        try await wait { !self.hasControl("No connections", in: settings) }
        XCTAssertNil(f.store.mcp.signingIn)
    }
}
