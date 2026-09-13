import XCTest
@testable import NoodleCore

/// Opt-in account-backed verification in a disposable repository. Never opens
/// or changes the user's Noodle bots. Each test uses two small model turns.
final class RestrictedACPLiveTests: XCTestCase {
    func testFXMessengerAndResumeInsideSandbox() throws { try check(.fx) }
    func testGrokMessengerAndResumeInsideSandbox() throws { try check(.grokBuild) }

    private func check(_ provider: HarnessProvider) throws {
        guard ProcessInfo.processInfo.environment["NOODLE_TEST_RESTRICTED_ACP"] == "1" else {
            throw XCTSkip("Set NOODLE_TEST_RESTRICTED_ACP=1 to use installed accounts for sandboxed Messenger and resume checks.")
        }
        let home = HarnessStorage.userHome
        let path = home.appendingPathComponent(provider == .fx ? ".local/bin/fx" : ".grok/bin/grok").path
        let executable = try provider == .fx
            ? FxExecutableTrust.executable(at: path, home: home)
            : GrokExecutableTrust.executable(at: path, home: home)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let messenger = project.appendingPathComponent(".build/debug/NoodleMessenger")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-restricted-acp-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: messenger)
        let bot = try repository.createAgent(named: "Restricted ACP fixture", harnessIdentifier: provider.rawValue)
        let workspace = repository.directory(for: bot.agent)
        let broker = MessengerBroker(repository: repository)
        try broker.start(agents: [bot.agent])
        defer { broker.stop() }
        try RestrictedHarnessStorage.prepare(provider: provider, workspace: workspace, loginHome: home)
        let temporary = workspace.appendingPathComponent(".noodle/tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let profile = try RestrictedAgentSandbox.profile(provider: provider, workspace: workspace, repository: root,
            home: home, executable: executable, application: project, temporary: temporary)
        var environment = try RestrictedAgentSandbox.environment(provider: provider, home: home, workspace: workspace)
        environment["USER"] = NSUserName()
        environment["LOGNAME"] = NSUserName()
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TMPDIR"] = temporary.path
        let arguments = provider == .fx ? ["acp"] : ["agent", "--no-leader", "stdio"]
        func connect() throws -> ACPWireFixture {
            let wire = try ACPWireFixture(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), workspace: workspace,
                arguments: ["-p", profile, executable.path] + arguments, environment: environment)
            do {
                _ = try wire.request("initialize", FxProtocol.initializeParameters)
                if provider == .grokBuild { _ = try wire.request("authenticate", ["methodId": "cached_token"]) }
                return wire
            } catch { wire.stop(); throw error }
        }
        func enqueue(_ marker: String) throws {
            try repository.append(ChatMessage(conversationID: bot.conversation.id, author: .user,
                body: "Sandbox integration test: read .agents/skills/messenger/SKILL.md and reply through Messenger with exactly \(marker). Use only the Messenger skill and its CLI. Do not do any other work.", delivery: .queued))
        }
        let firstMarker = "Restricted \(provider.rawValue) works"
        try enqueue(firstMarker)
        let first = try connect()
        defer { first.stop() }
        let opened = try first.request("session/new", ["cwd": workspace.path, "mcpServers": []])
        let session = try XCTUnwrap(opened["sessionId"] as? String)
        _ = try first.request("session/prompt", ["sessionId": session,
            "prompt": [["type": "text", "text": AgentWakeReason.inboxChanged.eventText]]])
        XCTAssertTrue(try repository.loadMessages(conversationID: bot.conversation.id).contains {
            $0.author == .agent(bot.agent.id) && $0.body.contains(firstMarker)
        }, "Restricted \(provider.displayName) did not send its Messenger reply. \(first.diagnostics)")
        first.stop()

        let resumedMarker = "Restricted \(provider.rawValue) resumed"
        try enqueue(resumedMarker)
        let second = try connect()
        defer { second.stop() }
        _ = try second.request("session/load", ["sessionId": session, "cwd": workspace.path, "mcpServers": []])
        _ = try second.request("session/prompt", ["sessionId": session,
            "prompt": [["type": "text", "text": AgentWakeReason.runtimeRecovered.eventText]]])
        XCTAssertTrue(try repository.loadMessages(conversationID: bot.conversation.id).contains {
            $0.author == .agent(bot.agent.id) && $0.body.contains(resumedMarker)
        }, "Restricted \(provider.displayName) did not resume its Messenger session. \(second.diagnostics)")
    }
}
