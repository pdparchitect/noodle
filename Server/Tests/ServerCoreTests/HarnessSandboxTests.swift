import Foundation
import NoodleCore
@testable import ServerCore
import XCTest

/// What bubblewrap is told: a bot's harness sees the system, its own workspace to write in, its package to read,
/// and the harness's installation, and nothing else of the server's data or the admin's home.
final class HarnessSandboxTests: XCTestCase {
    private let data = URL(fileURLWithPath: "/var/lib/noodled")
    private var workspace: URL { data.appendingPathComponent("Agents/0a/workspace") }
    private var package: URL { data.appendingPathComponent("Agents/0a") }

    private func arguments(program: String = "/home/admin/.local/share/claude/versions/2.1.0") -> [String] {
        HarnessSandbox().arguments(workspace: workspace, program: URL(fileURLWithPath: program),
                                   command: ["-p", "--verbose"], environment: ["HOME": "/home/x", "A": "1"])
    }

    /// Each `flag source destination` triple, as bubblewrap reads them.
    private func mounts(_ flag: String, in arguments: [String]) -> [String] {
        arguments.indices.dropLast(2).filter { arguments[$0] == flag }.map { arguments[$0 + 1] }
    }

    func testOnlyTheWorkspaceIsWritable() {
        let arguments = arguments()
        XCTAssertEqual(mounts("--bind", in: arguments), [workspace.path])
        XCTAssertTrue(mounts("--ro-bind", in: arguments).contains(package.path))
        let everything = mounts("--bind", in: arguments) + mounts("--ro-bind", in: arguments) + mounts("--ro-bind-try", in: arguments)
        XCTAssertFalse(everything.contains { data.path.hasPrefix($0) || $0 == data.path }, "the server's data is out of sight")
        XCTAssertFalse(everything.contains { $0 == "/" || $0 == "/home" || $0 == "/root" || $0 == "/var" })
    }

    /// The installation is the program's folder, or the folder above a `bin`, read-only.
    func testTheHarnessInstallationIsReadOnly() {
        XCTAssertTrue(mounts("--ro-bind", in: arguments()).contains("/home/admin/.local/share/claude/versions"))
        let npm = arguments(program: "/opt/node/lib/node_modules/@openai/codex/bin/codex.js")
        XCTAssertTrue(mounts("--ro-bind", in: npm).contains("/opt/node/lib/node_modules/@openai/codex"))
    }

    func testTheHarnessRunsAloneInItsWorkspaceWithOnlyItsEnvironment() throws {
        let arguments = arguments()
        for flag in ["--unshare-all", "--share-net", "--die-with-parent", "--new-session", "--clearenv"] {
            XCTAssertTrue(arguments.contains(flag), flag)
        }
        let chdir = try XCTUnwrap(arguments.firstIndex(of: "--chdir"))
        XCTAssertEqual(arguments[chdir + 1], workspace.path)
        let setenv = arguments.indices.dropLast(2).filter { arguments[$0] == "--setenv" }.map { "\(arguments[$0 + 1])=\(arguments[$0 + 2])" }
        XCTAssertEqual(setenv, ["A=1", "HOME=/home/x"])
        let separator = try XCTUnwrap(arguments.firstIndex(of: "--"))
        XCTAssertEqual(Array(arguments[(separator + 1)...]), ["/home/admin/.local/share/claude/versions/2.1.0", "-p", "--verbose"])
    }

    /// Claude Code runs with its own sandbox off, since bubblewrap is around it, and without updating itself;
    /// both harnesses keep their settings and logins in the bot's private home.
    func testEachHarnessKeepsItsAccountInTheBotsPrivateHome() throws {
        let session = UUID()
        let claude = try HarnessSandbox.command(provider: .claudeCode, workspace: workspace, sessionID: session,
                                                resumeSession: false, model: nil, effort: nil)
        let home = workspace.appendingPathComponent(".noodle/home").path
        XCTAssertEqual(claude.environment["HOME"], home)
        XCTAssertEqual(claude.environment["CLAUDE_CONFIG_DIR"], home + "/.claude")
        XCTAssertEqual(claude.environment["DISABLE_AUTOUPDATER"], "1")
        XCTAssertEqual(claude.environment["CLAUDE_CODE_ENTRYPOINT"], "noodle")
        XCTAssertEqual(claude.environment["NOODLE_WORKSPACE"], workspace.path)
        XCTAssertTrue(claude.arguments.contains(session.uuidString.lowercased()))
        let settings = try XCTUnwrap(claude.arguments.firstIndex(of: "--settings"))
        XCTAssertTrue(claude.arguments[settings + 1].contains("\"sandbox\":{\"enabled\":false}"))

        let codex = try HarnessSandbox.command(provider: .codex, workspace: workspace, sessionID: nil,
                                               resumeSession: false, model: nil, effort: nil)
        XCTAssertEqual(codex.environment["HOME"], home)
        XCTAssertEqual(codex.environment["CODEX_HOME"], home + "/.codex")
        XCTAssertEqual(codex.arguments, ["app-server", "--disable", "apps"])

        XCTAssertThrowsError(try HarnessSandbox.command(provider: .grokBuild, workspace: workspace, sessionID: nil,
                                                        resumeSession: false, model: nil, effort: nil))
    }
}
