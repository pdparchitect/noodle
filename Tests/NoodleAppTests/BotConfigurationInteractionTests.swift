import AppKit
import SwiftUI
import Observation
import XCTest
import NoodleCore
@testable import Noodle

@MainActor @Observable final class ConfigurationSelection {
    var harness = HarnessProvider.claudeCode.rawValue
    var model = "opus"
    var effort = "max"
    func binding(_ key: ReferenceWritableKeyPath<ConfigurationSelection, String>) -> Binding<String> {
        Binding(get: { self[keyPath: key] }, set: { self[keyPath: key] = $0 })
    }
}

@MainActor final class BotConfigurationInteractionTests: HiddenViewTests {
    private func fields(_ selection: ConfigurationSelection, fixture: StoreFixture) -> some View {
        AgentConfigurationFields(selectedHarnessIdentifier: selection.binding(\.harness),
            selectedModelIdentifier: selection.binding(\.model), selectedEffort: selection.binding(\.effort))
            .environment(fixture.store)
    }
    private func readyFixture() throws -> StoreFixture {
        let f = try fixture()
        f.runtime.runtime.refreshCapabilities()
        return f
    }

    func testChoosingAnotherHarnessClearsModelAndEffortWithoutSavingDraft() async throws {
        let f = try readyFixture(), selection = ConfigurationSelection()
        let editor = host(fields(selection, fixture: f))
        _ = try await control("Opus", in: editor)
        let chooser = host(HarnessChooser(installations: f.runtime.runtime.availableInstallations,
            selection: selection.binding(\.harness)))
        press(try await control("Codex", in: chooser))
        try await wait { selection.harness == "codex" && selection.model.isEmpty && selection.effort.isEmpty }
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.a.id }?.harnessIdentifier, f.a.harnessIdentifier)
        XCTAssertFalse(try XCTUnwrap(editor.window).isVisible)
    }

    func testChoosingModelReplacesUnsupportedEffortAndPreservesSupportedEffort() async throws {
        let f = try readyFixture(), selection = ConfigurationSelection()
        selection.model = ""; selection.effort = "unsupported"
        let editor = host(fields(selection, fixture: f))
        _ = try await control("Claude Code default", in: editor)
        let chooser = host(ModelChooser(providerName: "Claude Code", models: ClaudeCodeCapabilities.models,
            selection: selection.binding(\.model)))
        press(try await control("Opus", in: chooser))
        try await wait { selection.model == "opus" && selection.effort == "high" }
        selection.effort = "low"
        press(try await control("Sonnet", in: chooser))
        try await wait { selection.model == "sonnet" }
        XCTAssertEqual(selection.effort, "low")
        press(try await control("Claude Code default", in: chooser))
        try await wait { selection.model.isEmpty && selection.effort.isEmpty }
    }

    func testUnknownModelSelectionClearsEffort() async throws {
        let f = try readyFixture(), selection = ConfigurationSelection()
        let editor = host(fields(selection, fixture: f))
        _ = try await control("Opus", in: editor)
        selection.model = "removed-model"
        try await wait { selection.effort.isEmpty }
        _ = try await control("Claude Code default", in: editor)
    }

    func testModelSearchMatchesNameIdentifierAndDescriptionAndCanClear() async throws {
        let selection = ConfigurationSelection()
        let models = [
            HarnessModel(id: "alpha-id", displayName: "Alpha", description: "Fast coding", supportedEfforts: [], defaultEffort: "", isDefault: true),
            HarnessModel(id: "beta-id", displayName: "Béta", description: "Detailed analysis", supportedEfforts: [], defaultEffort: "", isDefault: false)
        ]
        let chooser = host(ModelChooser(providerName: "Fixture", models: models, selection: selection.binding(\.model)))
        let search = try await nameField(in: chooser, name: "")
        for query in ["  BETA  ", "beta-id", "DETAILED"] {
            edit(search, text: query)
            _ = try await control("Béta", in: chooser)
            try await wait { !self.hasControl("Alpha", in: chooser) }
        }
        press(try await control("Béta", in: chooser))
        XCTAssertEqual(selection.model, "beta-id")
        edit(search, text: "does-not-exist")
        try await wait { !self.hasControl("Alpha", in: chooser) && !self.hasControl("Béta", in: chooser) }
        press(try await control("Clear Search", in: chooser))
        _ = try await control("Alpha", in: chooser)
        XCTAssertEqual(search.stringValue, "")
    }

    func testCatalogueDefaultDoesNotOfferASyntheticModel() async throws {
        let selection = ConfigurationSelection(); selection.model = ""
        let chooser = host(ModelChooser(providerName: "Apple Intelligence", usesCatalogueDefault: true,
            models: ClaudeCodeCapabilities.models, selection: selection.binding(\.model)))
        _ = try await control("Sonnet", in: chooser)
        XCTAssertFalse(elements(chooser).contains { labels($0).contains("Apple Intelligence default") })
        press(try await control("Haiku", in: chooser))
        XCTAssertEqual(selection.model, "haiku")
    }

    func testEffortSliderWritesEachSupportedChoiceIncludingModelDefault() async throws {
        let selection = ConfigurationSelection()
        let view = host(EffortControl(model: ClaudeCodeCapabilities.models[0], selection: selection.binding(\.effort)))
        var slider: NSObject?
        try await wait {
            slider = self.elements(view).first { self.attribute($0, .role) as? String == "AXSlider" }
            return slider != nil
        }
        let control = try XCTUnwrap(slider)
        for expected in ["xhigh", "high", "medium", "low", ""] {
            _ = adjust(control, increasing: false)
            try await wait { selection.effort == expected }
        }
        for expected in ["low", "medium", "high", "xhigh", "max"] {
            _ = adjust(control, increasing: true)
            try await wait { selection.effort == expected }
        }

    }
    func testOpeningAndSavingExistingBotPreservesItsModelEffortAndWorkspace() async throws {
        let f = try fixture()
        let agent = try f.repository.updateAgent(f.a, displayName: f.a.displayName,
            harnessIdentifier: "claude-code", modelIdentifier: "opus", reasoningEffort: "low")
        f.runtime.runtime.authorizeSelectedHarness(agent)
        f.store.reload()
        let workspace = f.repository.directory(for: agent)
        let marker = workspace.appendingPathComponent("keep.txt")
        try Data("Existing work".utf8).write(to: marker)
        let editor = host(EditBotSheet(agent: agent).environment(f.store))
        press(try await control("Save", in: editor))
        try await wait { !f.runtime.factory.processes.isEmpty }
        let saved = try XCTUnwrap(f.repository.loadAgents().first { $0.id == agent.id })
        XCTAssertEqual(saved.harnessIdentifier, "claude-code")
        XCTAssertEqual(saved.modelIdentifier, "opus")
        XCTAssertEqual(saved.reasoningEffort, "low")
        XCTAssertEqual(f.repository.directory(for: saved), workspace)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "Existing work")
    }

    func testMissingHarnessDisablesSaveWithoutChangingConfiguration() async throws {
        let f = try fixture()
        let agent = try f.repository.updateAgent(f.a, displayName: f.a.displayName,
            harnessIdentifier: "muse", modelIdentifier: "remembered-model", reasoningEffort: "high")
        f.store.reload()
        let original = try Data(contentsOf: f.repository.storage(for: agent.id).configuration)
        let editor = host(EditBotSheet(agent: agent).environment(f.store))
        let save = try await control("Save", in: editor)
        XCTAssertFalse(enabled(save))
        edit(try await nameField(in: editor, name: agent.displayName), text: "Unsaved edit")
        let stillDisabled = try await control("Save", in: editor)
        XCTAssertFalse(enabled(stillDisabled))
        press(try await control("Cancel", in: editor))
        XCTAssertEqual(try Data(contentsOf: f.repository.storage(for: agent.id).configuration), original)
    }

    func testNewBotCreatesOnlyItsChosenNameAndDefaults() async throws {
        let f = try fixture()
        f.store.creationSheet = .bot
        let editor = host(NewBotSheet().environment(f.store).defaultAppStorage(f.runtime.defaults))
        edit(try await textField("Bot name", in: editor), text: "Created through editor")
        let create = try await control("Create", in: editor)
        try await wait { self.enabled(create) }
        press(create)
        try await wait { f.store.agents.count == 3 }
        let saved = try XCTUnwrap(f.store.agents.first { $0.displayName == "Created through editor" })
        XCTAssertEqual(saved.harnessIdentifier, "codex")
        XCTAssertNil(saved.modelIdentifier)
        XCTAssertNil(saved.reasoningEffort)
        XCTAssertEqual(f.store.selectedConversation?.participantIDs, [saved.id])
        XCTAssertNil(f.store.creationSheet)
        XCTAssertEqual(try f.repository.loadAgents().count, 3)
    }

}
