#if os(Linux)
import Foundation
import NoodleCore
@testable import ServerCore
import XCTest

/// A bot's harness run for real under bubblewrap: it talks over its pipes, sees only its own bot, and
/// everything it started ends when it is stopped. Skipped where bubblewrap cannot make a sandbox.
@MainActor final class SandboxedHarnessTests: XCTestCase {
    private var root: URL!
    private var workspace: URL!
    private var output = Data()
    private var errors = Data()
    private var exited: Int32?

    override func setUp() async throws {
        if let problem = HarnessSandbox().problem() { throw XCTSkip(problem) }

        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodled-\(UUID())").resolvingSymlinksInPath()
        let layout = AgentStorageLayout(package: root.appendingPathComponent("Agents/\(UUID().uuidString.lowercased())"))
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.runtime, withIntermediateDirectories: true)
        workspace = layout.workspace
        try Data("the server's secret".utf8).write(to: root.appendingPathComponent("access.json"))
        let other = root.appendingPathComponent("Agents/other/workspace")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("another bot's secret".utf8).write(to: other.appendingPathComponent("memory.md"))
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A stand-in for Claude Code, installed in its own folder like the admin's.
    private func harness(_ script: String) throws -> URL {
        let folder = root.appendingPathComponent("Install/claude", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let program = folder.appendingPathComponent("claude")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        return program
    }

    private func start(_ program: URL, provider: HarnessProvider = .claudeCode) async throws -> SandboxedHarnessConnection {
        let connection = SandboxedHarnessConnection(workspace: workspace)
        connection.onData = { [unowned self] data, isError in isError ? errors.append(data) : output.append(data) }
        connection.onExit = { [unowned self] in exited = $0 }
        addTeardownBlock { @MainActor in connection.invalidate() }
        let failure: String? = await withCheckedContinuation { continuation in
            connection.startHarness(provider: provider, agentID: UUID(), executablePath: program.path, extendedAccess: false,
                                    appsEnabled: false, sessionID: UUID(), resumeSession: false, modelIdentifier: nil,
                                    effortIdentifier: nil) { _, error in continuation.resume(returning: error) }
        }
        if let failure { throw HarnessSetupError(failure) }
        return connection
    }

    private func waitForExit(within seconds: Double = 10) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(seconds)
        while exited == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        return try XCTUnwrap(exited, "the harness did not exit; output: \(String(decoding: output, as: UTF8.self)) errors: \(String(decoding: errors, as: UTF8.self))")
    }

    private var text: String { String(decoding: output, as: UTF8.self) }

    func testTheHarnessTalksOverItsPipesFromItsWorkspace() async throws {
        let connection = try await start(try harness("""
        echo "cwd=$(pwd)"
        echo "home=$HOME"
        echo "args=$*"
        read line
        echo "got=$line"
        echo oops >&2
        exit 3
        """))
        connection.write(Data("hello\n".utf8))
        let status = try await waitForExit()
        XCTAssertEqual(status, 3)
        XCTAssertTrue(text.contains("cwd=\(workspace.path)\n"), text)
        XCTAssertTrue(text.contains("home=\(workspace.path)/.noodle/home\n"), text)
        XCTAssertTrue(text.contains("--input-format stream-json"), text)
        XCTAssertTrue(text.contains("got=hello\n"), text)
        XCTAssertEqual(String(decoding: errors, as: UTF8.self), "oops\n")
    }

    func testTheHarnessSeesOnlyItsOwnBot() async throws {
        _ = try await start(try harness("""
        cat \(root.path)/access.json 2>/dev/null || echo "no access"
        cat \(root.path)/Agents/other/workspace/memory.md 2>/dev/null || echo "no other bot"
        touch ../agent.json 2>/dev/null || echo "package read-only"
        echo kept > notes.md && echo "workspace writable"
        ls /home 2>/dev/null | grep -q . && echo "home visible" || echo "no home"
        """))
        let status = try await waitForExit()
        XCTAssertEqual(status, 0)
        XCTAssertEqual(text, "no access\nno other bot\npackage read-only\nworkspace writable\nno home\n")
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("notes.md"), encoding: .utf8), "kept\n")
    }

    /// Tools a harness leaves running in the background end with it.
    func testStoppingEndsEverythingTheHarnessStarted() async throws {
        let connection = try await start(try harness("""
        (while true; do date +%s%N > beat; sleep 0.05; done) &
        echo started
        exec cat
        """))
        let beat = workspace.appendingPathComponent("beat")
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: beat.path), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let stopped = await withCheckedContinuation { continuation in connection.stop { continuation.resume(returning: $0) } }
        XCTAssertTrue(stopped)
        let last = try Data(contentsOf: beat)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try Data(contentsOf: beat), last, "a background tool kept running")
    }

    func testOnlyClaudeCodeAndCodexRun() async throws {
        do {
            _ = try await start(try harness("exit 0"), provider: .grokBuild)
            XCTFail("Grok Build started")
        } catch {
            XCTAssertEqual(error.localizedDescription, "noodled runs only Claude Code and Codex.")
        }
    }
}
#endif
