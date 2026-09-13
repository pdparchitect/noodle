import XCTest
@testable import NoodleCore

final class RestrictedMuseSandboxTests: XCTestCase {
    func testInstalledMuseCanCreateAndResumeIsolatedSessionsWithoutNetwork() throws {
        let realHome = HarnessStorage.userHome
        let installed = realHome.appendingPathComponent(".local/bin/muse")
        guard FileManager.default.isExecutableFile(atPath: installed.path) else { throw XCTSkip("Muse is not installed") }
        let executable = try MuseExecutableTrust.executable(at: installed.path, home: realHome)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-muse-sandbox-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("Home")
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        let bot = try repository.createAgent(named: "Muse sandbox fixture", harnessIdentifier: "muse")
        let workspace = repository.directory(for: bot.agent)
        let temporary = workspace.appendingPathComponent(".noodle/tmp")
        let account = try RestrictedAgentSandbox.accountDirectory(provider: .muse, home: RestrictedHarnessStorage.home(workspace: workspace))
        for directory in [account, temporary] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // Existing foreign personal context must not turn restricted startup
        // into a permission error or become part of this bot's instructions.
        for path in [".codex/AGENTS.md", ".claude/CLAUDE.md", ".agents/skills/private/SKILL.md"] {
            let file = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Private global instructions must stay outside the bot.\n".utf8).write(to: file)
        }
        let policy = try RestrictedAgentSandbox.profile(provider: .muse, workspace: workspace, repository: repository.rootURL,
            home: home, executable: executable, application: workspace, temporary: temporary) + "\n(deny network*)"
        var environment = try RestrictedAgentSandbox.environment(provider: .muse, home: home, workspace: workspace)
        environment["TMPDIR"] = temporary.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        func connect() throws -> ACPWireFixture {
            let wire = try ACPWireFixture(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), workspace: workspace,
                arguments: ["-p", policy, executable.path, "serve", "--disable-sandbox", "--trust-workspace"],
                environment: environment, requestTimeout: 15)
            do {
                let result = try wire.request("initialize", MuseProtocol.initialize)
                try MuseProtocol.validateInitialization(result, durable: true)
                let museHome = try XCTUnwrap(result["museHome"] as? String)
                XCTAssertTrue(URL(fileURLWithPath: museHome).resolvingSymlinksInPath().path.hasPrefix(workspace.resolvingSymlinksInPath().path + "/"))
                try wire.notify("initialized")
                return wire
            } catch { wire.stop(); throw error }
        }
        let first = try connect()
        defer { first.stop() }
        let opened = try first.request("session/start", ["commandId": MuseProtocol.commandID(),
            "workspaceRoot": workspace.path, "providerId": "echo"])
        let session = try XCTUnwrap((opened["session"] as? [String: Any])?["sessionId"] as? String)
        first.stop()
        let second = try connect()
        defer { second.stop() }
        let resumed = try second.request("session/resume", ["commandId": MuseProtocol.commandID(), "sessionId": session, "excludeItems": true])
        XCTAssertEqual((resumed["session"] as? [String: Any])?["sessionId"] as? String, session)
        XCTAssertEqual((resumed["session"] as? [String: Any])?["workspaceRoot"] as? String, workspace.path)
    }

    func testMuseStorageRequiresAWorkspaceAndPreservesAccountDiscovery() throws {
        let home = URL(fileURLWithPath: "/fixture/home"), workspace = URL(fileURLWithPath: "/fixture/bot/workspace")
        XCTAssertThrowsError(try RestrictedAgentSandbox.environment(provider: .muse, home: home))
        let environment = try RestrictedAgentSandbox.environment(provider: .muse, home: home, workspace: workspace)
        XCTAssertEqual(environment["HOME"], workspace.path + "/.noodle/home")
        XCTAssertEqual(environment["XDG_CONFIG_HOME"], workspace.path + "/.noodle/home/.config")
        XCTAssertEqual(environment["TBH_CREDENTIAL_BACKEND"], "file")
        for key in ["XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"] {
            XCTAssertTrue(try XCTUnwrap(environment[key]).hasPrefix(workspace.path + "/"))
        }
    }
}
