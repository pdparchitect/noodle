import XCTest
@testable import NoodleCore

final class RestrictedClaudeSandboxTests: XCTestCase {
    func testNativeClaudeToolsAndResumeInsideProductionSandbox() throws {
        let realHome = HarnessStorage.userHome
        let installed = realHome.appendingPathComponent(".local/bin/claude")
        guard FileManager.default.isExecutableFile(atPath: installed.path) else { throw XCTSkip("Claude is not installed") }
        guard let applicationPath = ProcessInfo.processInfo.environment["NOODLE_TEST_CLI_APPLICATION"] else {
            throw XCTSkip("Build Tests/build-sandbox-cli-fixture.sh and set NOODLE_TEST_CLI_APPLICATION")
        }
        let executable = try ClaudeExecutableTrust.executable(at: installed.path, home: realHome)
        let application = URL(fileURLWithPath: applicationPath)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-claude-sandbox-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let messenger = application.appendingPathComponent("Contents/Helpers/messenger")
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"), launcherExecutableURL: messenger)
        let agent = try repository.createAgent(named: "Claude sandbox fixture", harnessIdentifier: "claude-code").agent
        let workspace = repository.directory(for: agent)
        let temporary = workspace.appendingPathComponent(".noodle/tmp")
        let oauth: [String: Any] = ["accessToken": "offline-fixture", "refreshToken": "offline-refresh",
            "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            "scopes": ["user:inference", "user:profile", "user:sessions:claude_code"],
            "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"]
        try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: root.appendingPathComponent("Home"),
            secret: { _, _ in try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]) })
        let policy = try RestrictedAgentSandbox.profile(provider: .claudeCode, workspace: workspace, repository: repository.rootURL,
            home: realHome, executable: executable, application: application, temporary: temporary)
        let policyFile = root.appendingPathComponent("cloud.sb")
        try policy.write(to: policyFile, atomically: true, encoding: .utf8)
        let outside = root.appendingPathComponent("outside-marker.txt")
        try Data("OUTSIDE_PRIVATE_MARKER".utf8).write(to: outside)
        let session = UUID()
        let metadata: [String: Any] = ["workspace": workspace.path, "home": RestrictedHarnessStorage.home(workspace: workspace).path,
            "temporary": temporary.path, "executable": executable.path, "policy": policyFile.path,
            "outside": outside.path, "configuration": repository.storage(for: agent.id).configuration.path,
            "messenger": messenger.path, "session": session.uuidString.lowercased(),
            "environment": try RestrictedAgentSandbox.environment(provider: .claudeCode, home: realHome, workspace: workspace),
            "arguments": try ClaudeLaunch.arguments(sessionID: session, resumeSession: false, model: "sonnet", effort: nil, restricted: true),
            "resumeArguments": try ClaudeLaunch.arguments(sessionID: session, resumeSession: true, model: "sonnet", effort: nil, restricted: true)]
        try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("fixture.json"))
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("claude-sandbox-probe.py")
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, root.path]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let details = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, details)
        XCTAssertTrue(details.contains("PASS: native startup"), details)
    }

    func testLaunchValidationAndPrivateEnvironment() throws {
        XCTAssertThrowsError(try ClaudeLaunch.arguments(sessionID: nil, resumeSession: false, model: nil, effort: nil, restricted: true))
        XCTAssertThrowsError(try ClaudeLaunch.arguments(sessionID: UUID(), resumeSession: false, model: "--settings", effort: nil, restricted: true))
        XCTAssertThrowsError(try ClaudeLaunch.arguments(sessionID: UUID(), resumeSession: false, model: nil, effort: "unknown", restricted: true))
        let id = UUID()
        let normal = try ClaudeLaunch.arguments(sessionID: id, resumeSession: false, model: nil, effort: nil, restricted: false)
        let restricted = try ClaudeLaunch.arguments(sessionID: id, resumeSession: false, model: nil, effort: nil, restricted: true)
        XCTAssertEqual(restricted, normal + ["--settings", #"{"sandbox":{"enabled":false}}"#])
        let workspace = URL(fileURLWithPath: "/fixture/bot/workspace"), home = URL(fileURLWithPath: "/fixture/home")
        let environment = try RestrictedAgentSandbox.environment(provider: .claudeCode, home: home, workspace: workspace)
        XCTAssertEqual(environment["HOME"], workspace.path + "/.noodle/home")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], workspace.path + "/.noodle/home/.claude")
        XCTAssertEqual(environment["CLAUDE_CODE_TMPDIR"], workspace.path + "/.noodle/tmp")
        XCTAssertThrowsError(try RestrictedAgentSandbox.environment(provider: .claudeCode, home: home))
    }
}
