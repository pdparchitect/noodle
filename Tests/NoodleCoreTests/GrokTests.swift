import XCTest
@testable import NoodleCore

final class GrokTests: XCTestCase {
    func testModelCataloguePreservesPerModelEffortsAndDefault() throws {
        let fixture: [String: Any] = ["_meta": ["modelState": [
            "currentModelId": "grok-4.6", "availableModels": [
                ["modelId": "grok-4.6", "name": "Grok 4.6", "_meta": ["reasoningEffort": "high", "reasoningEfforts": [
                    ["id": "high", "description": "Higher quality"], ["id": "xhigh"], ["id": "low"], ["id": "unknown"], ["id": "low"]]]],
                ["modelId": "grok-4.5", "name": "Grok 4.5", "_meta": ["reasoningEffort": "low", "reasoningEfforts": [["id": "low"]]]],
                ["modelId": "grok-4.6"], ["modelId": "--invalid"]
            ]
        ]]]
        let models = try GrokProtocol.models(from: fixture)
        XCTAssertEqual(models.map(\.id), ["grok-4.6", "grok-4.5"])
        XCTAssertTrue(models[0].isDefault)
        XCTAssertFalse(models[1].isDefault)
        XCTAssertEqual(models[0].supportedEfforts.map(\.id), ["high", "xhigh", "low"])
        XCTAssertEqual(models[1].supportedEfforts.map(\.id), ["low"])
        XCTAssertEqual(models[0].defaultEffort, "high")
        XCTAssertThrowsError(try GrokProtocol.models(from: [:]))
    }

    func testDiscoveryUsesOfficialInstallerPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(".grok/bin/grok")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let discovery = HarnessDiscovery(homeDirectory: root, applicationsDirectory: root, executableSearchDirectories: [], environment: [:])
        XCTAssertEqual(discovery.discover(.grokBuild).executablePath, executable.path)
        XCTAssertEqual(HarnessProvider.grokBuild.displayName, "Grok Build")
        XCTAssertThrowsError(try GrokExecutableTrust.executable(at: executable.path, home: root))
        XCTAssertThrowsError(try GrokExecutableTrust.executable(at: "/tmp/grok", home: root))
    }

    func testInspectionReportContainsNoAccountFields() throws {
        let report = GrokInspectionResult(executablePath: "/example/.grok/bin/grok", authenticated: true, models: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["executablePath", "authenticated", "models"])
    }

    func testHostDiscoveryHonorsNoHarnessSimulation() {
        var discovery = HarnessDiscovery(environment: ["NOODLE_SIMULATE_NO_HARNESSES": "1"])
        #if DEBUG
        XCTAssertFalse(discovery.allowsHostDiscovery(for: .grokBuild))
        discovery.checkExternalInstallationDuringSimulation(.grokBuild)
        XCTAssertTrue(discovery.allowsHostDiscovery(for: .grokBuild))
        #else
        XCTAssertTrue(discovery.allowsHostDiscovery(for: .grokBuild))
        #endif
    }
}

final class GrokLiveTests: XCTestCase {
    func testInstalledGrokMessengerAndSessionRecovery() throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_TEST_GROK_EXECUTABLE"],
              let messenger = ProcessInfo.processInfo.environment["NOODLE_TEST_MESSENGER_EXECUTABLE"] else {
            throw XCTSkip("Opt-in Grok test uses two small model turns in a disposable bot workspace.")
        }
        let executable = try GrokExecutableTrust.executable(at: path, home: HarnessStorage.userHome)
        let report = try GrokInspection.inspect(home: HarnessStorage.userHome, environment: ProcessInfo.processInfo.environment)
        XCTAssertTrue(report.authenticated)
        XCTAssertFalse(report.models.isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-grok-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: URL(fileURLWithPath: messenger))
        try repository.prepare()
        let bot = try repository.createAgent(named: "Grok Integration Fixture", harnessIdentifier: HarnessProvider.grokBuild.rawValue)
        let workspace = repository.directory(for: bot.agent)
        let args = ["agent", "--no-leader", "stdio"]
        func enqueue(_ body: String) throws {
            try repository.append(ChatMessage(conversationID: bot.conversation.id, author: .user, body: body, delivery: .queued))
        }
        try enqueue("Integration test: read .agents/skills/messenger/SKILL.md, then reply through Messenger with exactly Grok smoke ok. Do not do any other work or use other skills.")
        let first = try ACPWireFixture(executable: executable, workspace: workspace, arguments: args)
        defer { first.stop() }
        _ = try first.request("initialize", FxProtocol.initializeParameters)
        _ = try first.request("authenticate", ["methodId": "cached_token"])
        let opened = try first.request("session/new", ["cwd": workspace.path, "mcpServers": []])
        let session = try XCTUnwrap(opened["sessionId"] as? String)
        _ = try first.request("session/set_mode", ["sessionId": session, "modeId": "low"])
        _ = try first.request("session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": AgentWakeReason.inboxChanged.eventText]]])
        guard try repository.loadMessages(conversationID: bot.conversation.id).contains(where: { $0.author == .agent(bot.agent.id) && $0.body.contains("Grok smoke ok") }) else {
            throw HarnessSetupError("Grok did not reply through Messenger: \(first.diagnostics)")
        }
        first.stop()
        try enqueue("Integration test: reply through Messenger with exactly Grok resumed. Do not do any other work.")
        let second = try ACPWireFixture(executable: executable, workspace: workspace, arguments: args)
        defer { second.stop() }
        _ = try second.request("initialize", FxProtocol.initializeParameters)
        _ = try second.request("authenticate", ["methodId": "cached_token"])
        _ = try second.request("session/load", ["sessionId": session, "cwd": workspace.path, "mcpServers": []])
        let model = try XCTUnwrap(report.models.first?.id)
        _ = try second.request("session/set_model", ["sessionId": session, "modelId": model])
        _ = try second.request("session/set_mode", ["sessionId": session, "modeId": "low"])
        _ = try second.request("session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": AgentWakeReason.runtimeRecovered.eventText]]])
        XCTAssertTrue(try repository.loadMessages(conversationID: bot.conversation.id).contains { $0.author == .agent(bot.agent.id) && $0.body.contains("Grok resumed") })
    }
}
