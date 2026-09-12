import AppletBridge
import NoodleCore
import XCTest

@testable import Noodle

@MainActor final class AppletBrokerTests: XCTestCase {
    func testCompanionInstallAndRemovalRefreshEveryHarnessWithoutRestart() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let application = root.appendingPathComponent("Noodle Applet.app")
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("repository"),
            launcherExecutableURL: root.appendingPathComponent("messenger"),
            discoverAppletApplication: { application })
        try repository.prepare()
        let helper = root.appendingPathComponent("noodlet")
        try Data("fixture".utf8).write(to: helper)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let agents = try HarnessProvider.allCases.map {
            try repository.createAgent(named: $0.rawValue, harnessIdentifier: $0.rawValue).agent
        }
        let controller = AppletController(repository: repository)
        controller.start(agents: agents)
        defer { controller.start(agents: []) }
        for agent in agents {
            let workspace = repository.directory(for: agent)
            XCTAssertFalse(manager.fileExists(atPath: workspace.appendingPathComponent(".agents/skills/applet").path))
            // Exercise native Claude discovery directories as well as shared skills.
            let claudeSkills = workspace.appendingPathComponent(".claude/skills")
            try manager.removeItem(at: claudeSkills)
            try manager.createDirectory(at: claudeSkills, withIntermediateDirectories: true)
            try Data("custom".utf8).write(to: claudeSkills.appendingPathComponent("custom.md"))
        }

        let executable = application.appendingPathComponent("Contents/MacOS/NoodleApplet")
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": AppletConnection.providerID,
            "CFBundleExecutable": "NoodleApplet"], format: .xml, options: 0)
            .write(to: application.appendingPathComponent("Contents/Info.plist"))
        try Data("fixture".utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        controller.refreshSkills()
        let laterAgent = try repository.createAgent(named: "New arrival").agent
        controller.start(agents: agents + [laterAgent])

        for agent in agents + [laterAgent] {
            let workspace = repository.directory(for: agent)
            XCTAssertTrue(manager.fileExists(atPath: workspace.appendingPathComponent(".agents/skills/applet/SKILL.md").path))
            XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: workspace.appendingPathComponent(".agents/skills/applet/noodlet").path), helper.path)
            XCTAssertTrue(try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8).contains("## Creative applets"))
        }

        // Preserve the fixture for a reinstall at the same canonical location.
        let backup = root.appendingPathComponent("removed.app")
        try manager.moveItem(at: application, to: backup)
        controller.refreshSkills()
        for agent in agents + [laterAgent] {
            let workspace = repository.directory(for: agent)
            XCTAssertFalse(manager.fileExists(atPath: workspace.appendingPathComponent(".agents/skills/applet").path))
            XCTAssertNil(try? manager.destinationOfSymbolicLink(atPath: workspace.appendingPathComponent(".claude/skills/applet").path))
            XCTAssertFalse(try String(contentsOf: workspace.appendingPathComponent("AGENTS.md"), encoding: .utf8).contains("## Creative applets"))
            XCTAssertFalse(try String(contentsOf: workspace.appendingPathComponent(".agents/managed-skills.json"), encoding: .utf8).contains("skills/applet"))
        }
        for agent in agents {
            XCTAssertEqual(try String(contentsOf: repository.directory(for: agent).appendingPathComponent(".claude/skills/custom.md"), encoding: .utf8), "custom")
        }
        try manager.moveItem(at: backup, to: application)
        controller.refreshSkills()
        for agent in agents + [laterAgent] {
            XCTAssertTrue(manager.fileExists(atPath: repository.directory(for: agent).appendingPathComponent(".claude/skills/applet/SKILL.md").path))
        }
        XCTAssertNil(controller.failure)
    }

    func testBrokerStampsIdentityAndRejectsRemovedAgents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let a = try repository.createAgent(named: "Applet A").agent
        let b = try repository.createAgent(named: "Applet B").agent
        let recorder = AppletRequestRecorder()
        let controller = AppletController(
            repository: repository, connection: { await recorder.respond($0) })
        controller.start(agents: [a, b])
        defer {
            controller.start(agents: [])
            try? FileManager.default.removeItem(at: root)
        }
        var request = AppletRequest(.list)
        request.owner = b.id.uuidString
        _ = try await controller.perform(
            AppletAgentEnvelope(token: "test", request: request), agent: a)
        let sent = await recorder.requests
        XCTAssertEqual(sent.first?.owner, a.id.uuidString.lowercased())
        controller.start(agents: [b])
        do {
            _ = try await controller.perform(
                AppletAgentEnvelope(token: "test", request: request), agent: a)
            XCTFail("Removed agent retained access")
        } catch {}
        let finalCount = await recorder.requests.count
        XCTAssertEqual(finalCount, 1)
    }
    func testBuildFailuresKeepSessionForDiagnostics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let agent = try repository.createAgent(named: "Builder").agent
        let id = UUID()
        let controller = AppletController(
            repository: repository,
            connection: { _ in
                var response = AppletResponse(error: "Compiler error")
                response.sessionID = id
                return response
            })
        controller.start(agents: [agent])
        defer {
            controller.start(agents: [])
            try? FileManager.default.removeItem(at: root)
        }
        let response = try await controller.perform(
            AppletAgentEnvelope(token: "test", request: AppletRequest(.build)), agent: agent)
        XCTAssertEqual(response.sessionID, id)
        XCTAssertEqual(response.error, "Compiler error")
    }
}
private actor AppletRequestRecorder {
    var requests: [AppletRequest] = []
    func respond(_ request: AppletRequest) -> AppletResponse {
        requests.append(request)
        return AppletResponse()
    }
}
