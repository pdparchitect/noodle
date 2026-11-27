#if os(Windows)
import Foundation
import NoodleCore
@testable import ServerCore
import XCTest

/// What a bot's sandbox lets its harness do on Windows, tried for real: write in its workspace and nowhere else, and
/// end with everything it started.
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

    /// A bot writes only where it works: not in the account's home nor in another bot's folder. It still reads
    /// what the account can, for now, on Windows.
    func testWritesStayInTheWorkspace() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("noodled-home-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNotEqual(try run("echo written> " + RestrictedTokenSandbox.native(home)).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        let neighbour = other.appendingPathComponent("written.txt")
        XCTAssertNotEqual(try run("echo written> " + RestrictedTokenSandbox.native(neighbour)).status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: neighbour.path))
    }

    func testTheHarnessesStatusComesBack() throws {
        XCTAssertEqual(try run("exit 3").status, 3)
    }

    /// A tool the harness leaves running would otherwise keep its output open, and the bot would never be
    /// reported gone. The tool's own output shows it started. The command has no quotes: cmd.exe would get them
    /// escaped as other programs expect, and not understand them.
    func testToolsLeftRunningEndWithTheHarness() throws {
        let start = Date()
        let result = try run("start /b ping -n 30 127.0.0.1 & ping -n 2 127.0.0.1 > nul & exit 0")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("127.0.0.1"), "the tool never started: \(result.output)")
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
