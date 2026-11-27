#if os(Windows)
import Foundation
import NoodleCore
@testable import ServerCore
import XCTest

/// What a bot's sandbox lets its harness reach on Windows, tried for real: its workspace to write, its package to
/// read, and nothing of the server's data or the server account's home. Ending the harness ends its tools.
@MainActor final class RestrictedTokenSandboxTests: XCTestCase {
    private var root: URL!
    private var workspace: URL { root.appendingPathComponent("Agents/a/workspace", isDirectory: true) }
    private var package: URL { root.appendingPathComponent("Agents/a", isDirectory: true) }
    private var other: URL { root.appendingPathComponent("Agents/b/workspace", isDirectory: true) }
    private let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
    private var shell: URL { URL(fileURLWithPath: system).appendingPathComponent("System32/cmd.exe") }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodled-sandbox-\(UUID().uuidString)")
        for folder in [workspace, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("package".utf8).write(to: package.appendingPathComponent("bot.json"))
        try Data("other".utf8).write(to: other.appendingPathComponent("secret.txt"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs `command` through cmd.exe in the bot's sandbox, with `readable` granted besides its own folders, and
    /// returns its status and output.
    private func run(_ command: String, readable: [URL] = []) throws -> (status: Int32, output: String) {
        let sandbox = RestrictedTokenSandbox()
        var policy = HarnessSandbox.policy(workspace: workspace, program: shell)
        policy.readable += readable.map(\.path)
        let plan = try sandbox.launch(policy: policy, program: shell,
                                      command: ["/d", "/c", command],
                                      environment: try sandbox.environment(provider: .claudeCode, workspace: workspace))
        let launcher = WindowsHarnessLauncher()
        var output = Data(), status: Int32?, closed = 0
        _ = try launcher.run(plan, received: { data, _ in output.append(data) }, closed: { closed += 1 },
                             exited: { status = $0 })
        let deadline = Date().addingTimeInterval(20)
        while (status == nil || closed < 2) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return (try XCTUnwrap(status, "the harness did not end"), String(decoding: output, as: UTF8.self))
    }

    func testTheWorkspaceIsWritableAndThePackageReadable() throws {
        let written = try run("echo made> made.txt && type ..\\bot.json")
        XCTAssertEqual(written.status, 0, written.output)
        XCTAssertTrue(written.output.contains("package"), written.output)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("made.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "made")
        let package = try run("echo changed> ..\\bot.json")
        XCTAssertNotEqual(package.status, 0, "the package is read-only")
    }

    /// The server makes the bot's private folders, such as its harness's home, owner-only; the bot still works in
    /// them, as on Linux, where it runs as the server's account.
    func testPrivateFoldersTheServerMakesInTheWorkspaceStayTheBots() throws {
        _ = try run("exit 0")
        _ = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.codex", create: true)
        let result = try run("echo kept> .noodle\\home\\.codex\\made.txt && type .noodle\\home\\.codex\\made.txt")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("kept"), result.output)
    }

    /// The server's data around the bot is its account's alone. Bots are not kept from each other on Windows.
    func testTheServersDataAndTheAccountsHomeAreOutOfReach() throws {
        let data = try run("type \"\(RestrictedTokenSandbox.native(other.appendingPathComponent("secret.txt")))\"")
        XCTAssertNotEqual(data.status, 0, data.output)
        XCTAssertFalse(data.output.contains("other"), data.output)
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("noodled-home-\(UUID().uuidString).txt")
        try Data("home".utf8).write(to: home)
        defer { try? FileManager.default.removeItem(at: home) }
        let homeRead = try run("type \"\(RestrictedTokenSandbox.native(home))\"")
        XCTAssertNotEqual(homeRead.status, 0, homeRead.output)
        XCTAssertFalse(homeRead.output.contains("home"), homeRead.output)
    }

    /// A harness installed in the account's own folders, as Codex is by winget, runs its helper programs from
    /// there. The bot passes through the folders above its own, though it may not look in them.
    func testTheBotRunsProgramsFromAHarnessInstalledInTheAccountsFolders() throws {
        let install = root.appendingPathComponent("Install", isDirectory: true)
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        let tool = install.appendingPathComponent("tool.exe")
        try FileManager.default.copyItem(atPath: system + #"\System32\whoami.exe"#, toPath: tool.path)
        let result = try run(RestrictedTokenSandbox.native(tool) + " /logonid", readable: [install])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("S-1-5-5-"), result.output)
        XCTAssertNotEqual(try run("dir " + RestrictedTokenSandbox.native(root)).status, 0, "the folders above are passed through, not shown")
    }

    func testTheHarnessesStatusComesBack() throws {
        XCTAssertEqual(try run("exit 3").status, 3)
    }

    /// A tool the harness leaves running would otherwise keep its output open, and the bot would never be
    /// reported gone.
    func testToolsLeftRunningEndWithTheHarness() throws {
        let start = Date()
        let result = try run("start /b \"\" \"\(shell.path)\" /d /c \"ping -n 30 127.0.0.1 > nul\" & exit 0")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    /// The real Codex, started as the server starts a bot's, answers from its sandbox. It needs no sign-in to
    /// answer `initialize`; set NOODLED_TEST_CODEX to its executable to run this.
    func testCodexAnswersFromItsSandbox() throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLED_TEST_CODEX"] else {
            throw XCTSkip("Set NOODLED_TEST_CODEX to a Codex executable.")
        }
        let sandbox = RestrictedTokenSandbox()
        var command = try HarnessSandbox.command(provider: .codex, workspace: workspace, sessionID: nil, resumeSession: false,
                                                 model: nil, effort: nil)
        command.environment.merge(try sandbox.environment(provider: .codex, workspace: workspace)) { _, isolation in isolation }
        try FileManager.default.createDirectory(at: HarnessSandbox.home(workspace: workspace).appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        let codex = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let plan = try sandbox.launch(policy: HarnessSandbox.policy(workspace: workspace, program: codex), program: codex,
                                      command: command.arguments, environment: command.environment)
        let launcher = WindowsHarnessLauncher()
        var output = Data(), errors = Data(), status: Int32?
        _ = try launcher.run(plan, received: { data, isError in isError ? errors.append(data) : output.append(data) },
                             closed: {}, exited: { status = $0 })
        launcher.write(Data(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"noodle","title":"Noodle","version":"0"},"capabilities":{"experimentalApi":true}}}"#.utf8 + [10]))
        let deadline = Date().addingTimeInterval(30)
        while !String(decoding: output, as: UTF8.self).contains(#""id":1"#), status == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        launcher.kill()
        let answer = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(answer.contains(#""id":1"#) && answer.contains("result"),
                      "status \(status.map(String.init) ?? "running"); output: \(answer); errors: \(String(decoding: errors, as: UTF8.self))")
    }

    func testCommandLinesSplitBackIntoTheSameArguments() {
        XCTAssertEqual(RestrictedTokenSandbox.quote("plain"), "plain")
        XCTAssertEqual(RestrictedTokenSandbox.quote("two words"), "\"two words\"")
        XCTAssertEqual(RestrictedTokenSandbox.quote(""), "\"\"")
        XCTAssertEqual(RestrictedTokenSandbox.quote(#"say "hi""#), #""say \"hi\"""#)
        XCTAssertEqual(RestrictedTokenSandbox.quote(#"C:\a b\"#), #""C:\a b\\""#)
    }
}
#endif
