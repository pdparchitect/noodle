import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

@MainActor final class AppleLocalModelsInteractionTests: HiddenViewTests {
    func testRemovalOpensBotHarnessSettingsAndRefreshesUsageAfterEditing() async throws {
        let fixture = try fixture()
        let storage = AppleLocalModelStore(repository: fixture.repository.rootURL)
        let source = fixture.runtime.root.appendingPathComponent("Qwen-test")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, text) in [
            "config.json": #"{"model_type":"qwen3","max_position_embeddings":32768}"#,
            "tokenizer_config.json": #"{"chat_template":"{{ messages }}"}"#,
            "tokenizer.json": "{}", "model.safetensors": "synthetic weights"
        ] {
            try Data(text.utf8).write(to: source.appendingPathComponent(name))
        }
        let model = try storage.importModel(from: source)
        func select(_ id: String, for agent: AgentRecord) throws {
            _ = try fixture.repository.updateAgent(agent, displayName: agent.displayName,
                harnessIdentifier: "apple", modelIdentifier: id, reasoningEffort: nil)
            fixture.store.reload()
        }
        try select(model.id, for: fixture.a)
        try select(model.id, for: fixture.b)
        let settings = host(Color.clear.sheet(isPresented: .constant(true)) {
            AppleLocalModelsView(checkSupport: { true }).environment(fixture.store)
        })
        let settingsWindow = try XCTUnwrap(settings.window)
        // The fixture window is positioned offscreen, but must be ordered for
        // AppKit to present Local Models and the nested bot editor as sheets.
        settingsWindow.orderFront(nil)
        try await wait { !settingsWindow.sheets.isEmpty }
        let window = try XCTUnwrap(settingsWindow.sheets.first)
        let view = try XCTUnwrap(window.contentView)
        defer {
            for sheet in window.sheets { window.endSheet(sheet) }
            settingsWindow.endSheet(window)
        }

        func popover(containing label: String) async throws -> NSView {
            var content: NSView?
            try await wait {
                content = NSApp.windows.filter { $0.isVisible && $0 !== settingsWindow && $0.sheetParent == nil }
                    .compactMap(\.contentView).first { self.hasControl(label, in: $0) }
                return content != nil
            }
            return try XCTUnwrap(content)
        }

        let remove = try await control("Remove", in: view)
        XCTAssertTrue(enabled(remove), "Assigned models must offer an explanation when clicked")
        let hover = attribute(remove, .help) as? String ?? ""
        for name in ["Ada", "Grace"] { XCTAssertTrue(hover.contains(name), hover) }
        press(remove)

        for agent in [fixture.a, fixture.b] {
            let expectedNames = agent.id == fixture.a.id ? ["Ada", "Grace"] : ["Grace"]
            let agents = try fixture.repository.loadAgents()
            let content = try await popover(containing: "Edit \(agent.displayName)")
            let text = elements(content).flatMap(labels).joined(separator: "\n")
            XCTAssertTrue(text.contains("Model in Use"), text)
            XCTAssertTrue(text.contains(model.name), text)
            XCTAssertTrue(text.contains("Choose another model"), text)
            for name in expectedNames { XCTAssertTrue(text.contains(name), text) }
            if expectedNames.count == 1 { XCTAssertFalse(text.contains("Ada"), text) }
            XCTAssertEqual(try storage.models(), [model])
            XCTAssertEqual(try fixture.repository.loadAgents(), agents, "Removal must not disconnect bots automatically")
            XCTAssertEqual(try String(contentsOf: storage.folder(id: model.id).appendingPathComponent("model.safetensors"), encoding: .utf8),
                           "synthetic weights")
            if let directory = ProcessInfo.processInfo.environment["NOODLE_MODEL_REMOVAL_SCREENSHOT_DIRECTORY"],
               expectedNames.count == 2, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("model-in-use.png"))
            }
            press(try await control("Edit \(agent.displayName)", in: content))
            try await wait { !window.sheets.isEmpty }
            var editor = try XCTUnwrap(window.sheets.first?.contentView)
            _ = try await nameField(in: editor, name: agent.displayName)
            _ = try await control("Apple Intelligence default", in: editor)
            XCTAssertFalse(hasControl("Delete Bot", in: editor), "The editor must start on the Harness tab")

            if agent.id == fixture.a.id {
                press(try await control("Cancel", in: editor))
                try await wait { window.sheets.isEmpty }
                XCTAssertEqual(try fixture.repository.loadAgents(), agents, "Cancel must preserve bot assignments")
                let returned = try await popover(containing: "Edit Ada")
                XCTAssertTrue(hasControl("Edit Grace", in: returned))
                press(try await control("Edit Ada", in: returned))
                try await wait { !window.sheets.isEmpty }
                editor = try XCTUnwrap(window.sheets.first?.contentView)
            }

            // The fixture has a local fake Codex harness, so exercise the real
            // editor's save path without launching a model or external service.
            press(try await control("Apple Intelligence", in: editor))
            let harnesses = try await popover(containing: "Codex")
            press(try await control("Codex", in: harnesses))
            let save = try await control("Save", in: editor)
            try await wait { self.enabled(save) }
            press(save)
            try await wait { window.sheets.isEmpty }
            let saved = try XCTUnwrap(fixture.repository.loadAgents().first { $0.id == agent.id })
            XCTAssertEqual(saved.harnessIdentifier, "codex")
            XCTAssertNil(saved.modelIdentifier)
            XCTAssertEqual(try storage.models(), [model], "Changing a bot must not remove the model automatically")
        }

        let unassigned = try await popover(containing: "Model Unassigned")
        XCTAssertTrue(hasControl("No bots use this model.", in: unassigned))
        press(try await control("Remove Model", in: unassigned))

        func confirmation() async throws -> NSView {
            try await wait { !window.sheets.isEmpty }
            let content = try XCTUnwrap(window.sheets.first?.contentView)
            _ = try await control("Remove Model?", in: content)
            let text = elements(content).flatMap(labels).joined(separator: "\n")
            XCTAssertTrue(text.contains(model.name), text)
            XCTAssertEqual(try storage.models(), [model], "The model must remain until removal is confirmed")
            return content
        }

        let cancelled = try await confirmation()
        press(try await control("Cancel", in: cancelled))
        try await wait { window.sheets.isEmpty }
        XCTAssertEqual(try storage.models(), [model], "Cancel must keep the model")
        XCTAssertTrue(try FileManager.default.fileExists(atPath: storage.folder(id: model.id).appendingPathComponent("model.safetensors").path))

        // Recheck assignments when the user confirms, including changes made
        // while the confirmation is already open.
        press(try await control("Remove", in: view))
        let reassigned = try await confirmation()
        try select(model.id, for: fixture.a)
        press(try await control("Remove", in: reassigned))
        try await wait { window.sheets.isEmpty }
        let usage = try await popover(containing: "Edit Ada")
        XCTAssertEqual(try storage.models(), [model], "A newly assigned model must not be removed")
        press(try await control("Close", in: usage))
        try select("default", for: fixture.a)

        press(try await control("Remove", in: view))
        let confirmed = try await confirmation()
        press(try await control("Remove", in: confirmed))
        try await wait { (try? storage.models().isEmpty) == true }
        try await wait { window.sheets.isEmpty }
        XCTAssertTrue(window.sheets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "The original model folder must remain")
    }
}
