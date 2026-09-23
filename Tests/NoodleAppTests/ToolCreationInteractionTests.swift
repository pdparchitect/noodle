import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntimeSettings

@MainActor final class ToolCreationInteractionTests: HiddenViewTests {
    private func mcpFixture() throws -> MCPControllerFixture {
        let f = try MCPControllerFixture(credentialFailure: false, removed: nil)
        addTeardownBlock { @MainActor in f.controller.start(agents: []); try? FileManager.default.removeItem(at: f.root) }
        return f
    }
    private func preset(_ name: String, in view: NSView) async throws -> NSObject {
        edit(try await textField("Search tools", in: view), text: name)
        return try await control("Add \(name) and sign in", in: view)
    }

    func testCatalogueSearchUsesNamesDescriptionsAndShowsEmptyResults() async throws {
        var selected: [ToolDefinition] = []
        let view = host(ToolCatalogView(onSelect: { selected.append($0) }, onCustomMCP: {}, onCancel: {}))
        let search = try await textField("Search tools", in: view)
        edit(search, text: "  PIPELINES  ")
        press(try await control("Add Buildkite and sign in", in: view))
        XCTAssertEqual(selected.map(\.id), ["buildkite"])
        edit(search, text: "no-such-fixture-service")
        _ = try await control("No matching tools. You can add a custom MCP below.", in: view)
        edit(search, text: "")
        _ = try await control("Add Apollo and sign in", in: view)
        try await wait { !self.hasControl("No matching tools. You can add a custom MCP below.", in: view) }
    }

    func testCatalogueCustomAndCancelCallbacksAndInlineError() async throws {
        var custom = 0, cancelled = 0
        let view = host(ToolCatalogView(onSelect: { _ in XCTFail("No preset chosen") },
            onCustomMCP: { custom += 1 }, onCancel: { cancelled += 1 }, error: "Fixture save failed"))
        _ = try await control("Fixture save failed", in: view)
        press(try await control("Custom MCP…", in: view)); XCTAssertEqual(custom, 1)
        press(try await control("Cancel", in: view)); XCTAssertEqual(cancelled, 1)
    }

    func testPresetAddsOneSavedAccountAndDefersConnectionDespiteRepeatedClicks() async throws {
        let f = try mcpFixture(); var added: [UUID] = [], connected: [MCPConnectionRecord] = []
        let view = host(ToolCreationSheet(controller: f.controller, onAdded: { added.append($0) }, onConnect: { connected.append($0) }))
        let button = try await preset("Notion", in: view)
        press(button); press(button)
        XCTAssertEqual(added.count, 1); XCTAssertTrue(connected.isEmpty)
        try await wait { connected.count == 1 }
        let saved = try XCTUnwrap(f.controller.registry.connections.first)
        let definition = try XCTUnwrap(ToolCatalog.entries.first { $0.id == "notion" })
        XCTAssertEqual(saved.name, definition.name); XCTAssertEqual(saved.description, definition.summary)
        XCTAssertEqual(saved.instructions, definition.defaultInstructions)
        XCTAssertEqual(added, [saved.id]); XCTAssertEqual(connected, [saved])
        XCTAssertEqual(try MCPRegistry.load(root: f.root).connections, [saved])
        XCTAssertTrue(f.controller.registry.assignments.isEmpty)
    }

    func testSeparatePresetCreationsRemainIndependentAccounts() async throws {
        let f = try mcpFixture(); var connected = 0
        for _ in 0..<2 {
            let view = host(ToolCreationSheet(controller: f.controller, onConnect: { _ in connected += 1 }))
            press(try await preset("Notion", in: view))
        }
        try await wait { connected == 2 }
        let accounts = try MCPRegistry.load(root: f.root).connections
        XCTAssertEqual(accounts.map(\.name), ["Notion", "Notion 2"])
        XCTAssertEqual(Set(accounts.map(\.id)).count, 2)
        XCTAssertEqual(Set(accounts.map(\.skillName)).count, 2)
        XCTAssertEqual(accounts[0].endpoint, accounts[1].endpoint)
    }

    func testRegistryFailureReenablesSelectionAndRetrySavesOnce() async throws {
        let f = try mcpFixture(); var added: [UUID] = [], connected = 0
        try FileManager.default.createDirectory(at: f.registryURL, withIntermediateDirectories: true)
        let view = host(ToolCreationSheet(controller: f.controller, onAdded: { added.append($0) }, onConnect: { _ in connected += 1 }))
        let button = try await preset("Notion", in: view); press(button)
        XCTAssertTrue(added.isEmpty); XCTAssertTrue(f.controller.registry.connections.isEmpty)
        try await wait { self.enabled(button) }
        try FileManager.default.removeItem(at: f.registryURL)
        press(button)
        try await wait { connected == 1 }
        XCTAssertEqual(added.count, 1); XCTAssertEqual(try MCPRegistry.load(root: f.root).connections.count, 1)
    }

    func testWorkspaceRefreshRetryKeepsTheOriginallySavedPresetAccount() async throws {
        let f = try mcpFixture(); f.controller.start(agents: [f.a])
        let file = f.repository.directory(for: f.a).appendingPathComponent(".agents/skills/messenger/SKILL.md")
        let bytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var added: [UUID] = [], connected: [MCPConnectionRecord] = []
        let view = host(ToolCreationSheet(controller: f.controller, onAdded: { added.append($0) }, onConnect: { connected.append($0) }))
        press(try await preset("Notion", in: view))
        let original = try XCTUnwrap(f.controller.registry.connections.first)
        XCTAssertTrue(added.isEmpty); XCTAssertTrue(connected.isEmpty)
        try FileManager.default.removeItem(at: file); try bytes.write(to: file)
        press(try await preset("Notion", in: view))
        try await wait { connected.count == 1 }
        XCTAssertEqual(try MCPRegistry.load(root: f.root).connections, [original])
        XCTAssertEqual(added, [original.id]); XCTAssertEqual(connected, [original])
    }

    func testSwitchingPresetsAfterFailuresDoesNotLoseEachRetryIdentity() async throws {
        let f = try mcpFixture(); f.controller.start(agents: [f.a])
        let file = f.repository.directory(for: f.a).appendingPathComponent(".agents/skills/messenger/SKILL.md")
        let bytes = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var connected: [MCPConnectionRecord] = []
        let view = host(ToolCreationSheet(controller: f.controller, onConnect: { connected.append($0) }))
        press(try await preset("Notion", in: view)); press(try await preset("Buildkite", in: view))
        let original = f.controller.registry.connections
        XCTAssertEqual(original.count, 2); XCTAssertTrue(connected.isEmpty)
        try FileManager.default.removeItem(at: file); try bytes.write(to: file)
        press(try await preset("Notion", in: view))
        try await wait { connected.count == 1 }
        XCTAssertEqual(try MCPRegistry.load(root: f.root).connections, original)
        XCTAssertEqual(connected.first?.id, original.first?.id)
    }

    func testCustomEditorBackAndCancelDoNotCreateAnAccount() async throws {
        let f = try mcpFixture()
        let view = host(ToolCreationSheet(controller: f.controller, onConnect: { _ in XCTFail("No connection requested") }))
        press(try await control("Custom MCP…", in: view))
        edit(try await textField("e.g. Notion — Work", in: view), text: "Abandoned")
        press(try await control("Back", in: view))
        _ = try await textField("Search tools", in: view)
        press(try await control("Cancel", in: view))
        XCTAssertTrue(f.controller.registry.connections.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.registryURL.path))
    }

    func testCustomCreationRoutesSavedIdentityAndConnectionThroughTheSheet() async throws {
        let f = try mcpFixture(); var added: [UUID] = [], connected: [MCPConnectionRecord] = []
        let view = host(ToolCreationSheet(controller: f.controller, onAdded: { added.append($0) }, onConnect: { connected.append($0) }))
        press(try await control("Custom MCP…", in: view))
        edit(try await textField("e.g. Notion — Work", in: view), text: "Custom fixture")
        edit(try await textField("https://…", in: view), text: "https://example.com/mcp")
        press(try await control("Add & Connect", in: view))
        try await wait { connected.count == 1 }
        XCTAssertEqual(added, connected.map(\.id))
        XCTAssertEqual(try MCPRegistry.load(root: f.root).connections, connected)
    }
}
