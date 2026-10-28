import Darwin
import XCTest
import NoodleCore
import NoodleMCP

final class MCPProgramSessionTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func script(_ body: String, named: String = "tool") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + named)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func launch(executable: URL, arguments: [String] = [], directory: URL, secret: String = "secret-value") -> MCPProgramLaunch {
        var environment = MCPProgramRecord.minimalEnvironment(user: NSUserName(), temporaryDirectory: directory.path)
        environment["OPENAPI_MCP_HEADERS"] = secret
        return MCPProgramLaunch(executable: executable, arguments: arguments, environment: environment,
                                 workingDirectory: directory, secrets: [secret])
    }

    func testProgramKeepsArgumentsSeparateAndHidesTheSecret() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try script("""
        printf '%s\\n' "$#" > argv.txt
        printf '%s\\n' "$1" >> argv.txt
        printf '%s\\n' "USER=$USER" >> argv.txt
        if [ -z "${HOME+x}" ]; then printf '%s\\n' "HOME=unset" >> argv.txt; else printf '%s\\n' "HOME=set" >> argv.txt; fi
        printf '%s\\n' "SECRET=$OPENAPI_MCP_HEADERS" >> argv.txt
        echo '{"jsonrpc":"2.0","method":"ping"}'
        echo "leaked $OPENAPI_MCP_HEADERS" >&2
        sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: executable) }
        let session = try MCPProgramSession(launch: launch(executable: executable, arguments: ["hello world"], directory: root))
        defer { session.stop() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("argv.txt").path) {
            try await Task.sleep(for: .milliseconds(40))
        }
        let argv = try String(contentsOf: root.appendingPathComponent("argv.txt"), encoding: .utf8)
        XCTAssertEqual(argv.components(separatedBy: "\n").prefix(2), ["1", "hello world"])
        XCTAssertTrue(argv.contains("USER=\(NSUserName())"))
        XCTAssertTrue(argv.contains("HOME=unset"))
        XCTAssertTrue(argv.contains("SECRET=secret-value"))
        XCTAssertFalse(session.standardError().contains("secret-value"))
        XCTAssertTrue(session.standardError().contains("[redacted]"))
        XCTAssertTrue(session.hasMessage())
        XCTAssertFalse(root.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    func testPlainStdoutClosesTheProgram() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try script("echo hello from the program\n")
        defer { try? FileManager.default.removeItem(at: executable) }
        let session = try MCPProgramSession(launch: launch(executable: executable, directory: root))
        defer { session.stop() }
        for _ in 0..<50 where session.protocolError() == nil && session.isRunning {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertTrue(session.protocolError()?.contains("other than an MCP message") == true)
        XCTAssertFalse(session.isRunning)
    }

    func testHungStartTimesOutAndRemovalLeavesNoProcess() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try MCPProgramSession(launch: launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], directory: root))
        let pid = session.processIdentifier
        let hung = await session.stopIfHung(after: 0.3)
        XCTAssertTrue(hung)
        for _ in 0..<20 where session.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(session.isRunning)
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testParentExitStopsTheProgram() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try MCPProgramSession(launch: launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], directory: root),
                                             parentProcessID: 1, parentPollSeconds: 0.05)
        let pid = session.processIdentifier
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(session.isRunning)
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testCrashesRestartThenFailAndIdleStops() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try script("exit 1\n")
        defer { try? FileManager.default.removeItem(at: executable) }
        let supervisor = MCPProgramSupervisor()
        await supervisor.setPause { _ in 0.02 }
        let id = UUID()
        let made = launch(executable: executable, directory: root)
        await supervisor.prepare(id) { try MCPProgramSession(launch: made) }
        _ = try await supervisor.start(id)
        for _ in 0..<100 {
            if await supervisor.failureMessage(id) != nil { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        let message = await supervisor.failureMessage(id)
        let stillRunning = await supervisor.isRunning(id)
        XCTAssertEqual(message, MCPProgramSupervisor.failedText)
        XCTAssertFalse(stillRunning)

        let sleeper = MCPProgramSupervisor()
        let sleepID = UUID()
        let sleepLaunch = launch(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], directory: root)
        await sleeper.prepare(sleepID) { try MCPProgramSession(launch: sleepLaunch) }
        let running = try await sleeper.start(sleepID)
        await sleeper.noteUse(sleepID, at: Date(timeIntervalSince1970: 0))
        await sleeper.stopIfIdle(sleepID, at: Date(timeIntervalSince1970: MCPProgramRecord.idleSeconds))
        for _ in 0..<20 where running.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(running.isRunning)
        await sleeper.stopAll()
    }
}

private extension MCPProgramSupervisor {
    func setPause(_ pause: @escaping @Sendable (Int) -> TimeInterval) {
        self.pause = pause
    }
}
