#if os(macOS)
import Foundation
import NoodleCore
@testable import ServerCore
import XCTest

/// What Seatbelt is told on a Mac: a bot's harness reads the system, its package and the harness's installation,
/// writes only its workspace, and sees nothing else of the server's data or the admin's home.
final class SeatbeltSandboxTests: XCTestCase {
    private let data = URL(fileURLWithPath: "/Users/admin/Library/Application Support/Noodle Server/Data")
    private var workspace: URL { data.appendingPathComponent("Agents/0a/workspace") }
    private var package: URL { data.appendingPathComponent("Agents/0a") }
    private let program = URL(fileURLWithPath: "/Users/admin/.local/share/claude/versions/2.1.0")

    private func plan() -> HarnessLaunchPlan {
        SeatbeltSandbox().launch(policy: HarnessSandbox.policy(workspace: workspace, program: program), program: program,
                                 command: ["-p", "--verbose"], environment: ["HOME": "/home/x", "A": "1"])
    }

    /// sandbox-exec applies the profile and becomes the harness, in its workspace, with only its own environment.
    /// Nothing ends the harness's tools with it, so its whole process group is ended.
    func testTheHarnessRunsUnderSandboxExecInItsWorkspace() throws {
        let plan = plan()
        XCTAssertEqual(plan.executable.path, "/usr/bin/sandbox-exec")
        XCTAssertEqual(plan.arguments.first, "-p")
        XCTAssertEqual(Array(plan.arguments.dropFirst(2)), [program.path, "-p", "--verbose"])
        XCTAssertEqual(plan.environment, ["HOME": "/home/x", "A": "1"])
        XCTAssertEqual(plan.directory, workspace)
        XCTAssertTrue(plan.endsGroup)
    }

    /// The profile is the one Noodle's Agent Host gives a restricted bot.
    func testOnlyTheWorkspaceIsWritable() {
        let profile = plan().arguments[1]
        XCTAssertTrue(profile.hasPrefix("(version 1)\n(deny default)"), profile)
        XCTAssertTrue(profile.contains("(allow file-write*\n  (subpath \"\(workspace.path)\"))"), profile)
        XCTAssertTrue(profile.contains("(subpath \"\(package.path)\")"), profile)
        XCTAssertTrue(profile.contains("(subpath \"/Users/admin/.local/share/claude/versions\")"), profile)
        for hidden in [data.path, "/Users", "/Users/admin", data.appendingPathComponent("Agents").path] {
            XCTAssertFalse(profile.contains("(subpath \"\(hidden)\")"), hidden)
        }
    }

    /// A bot finds the developer tools as Noodle's own bots on a Mac do.
    func testABotFindsTheDeveloperToolsAsNoodlesOwnDo() throws {
        let claude = try HarnessSandbox.command(provider: .claudeCode, workspace: workspace, sessionID: UUID(),
                                                resumeSession: false, model: nil, effort: nil)
        XCTAssertEqual(claude.environment["PATH"],
                       RestrictedAgentSandbox.searchPath(home: workspace.appendingPathComponent(".noodle/home")))
    }

    /// Codex gets the system's public certificates in a file it can read, as Noodle's own restricted Codex does;
    /// Claude Code needs nothing more.
    func testCodexGetsTheSystemsCertificates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodled-\(UUID())").resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let workspace = repository.directory(for: try repository.createAgent(named: "Alfred", harnessIdentifier: "codex").agent)
        XCTAssertEqual(try SeatbeltSandbox().environment(provider: .claudeCode, workspace: workspace), [:])
        let environment = try SeatbeltSandbox().environment(provider: .codex, workspace: workspace)
        let certificates = try XCTUnwrap(environment["CODEX_CA_CERTIFICATE"])
        XCTAssertTrue(certificates.hasPrefix(AgentStorageLayout(workspace: workspace).package.path + "/"), certificates)
        XCTAssertTrue(try String(contentsOfFile: certificates, encoding: .utf8).hasPrefix("-----BEGIN CERTIFICATE-----"))
    }
}
#endif
