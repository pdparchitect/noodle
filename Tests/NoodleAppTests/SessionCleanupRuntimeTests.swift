import Foundation
import NoodleCore
import SQLite3
import XCTest
@testable import Noodle
@testable import NoodleRuntime

/// Harnesses that can delete their own sessions do it over their running connection, only while idle, and only
/// for a bot whose harness keeps its sessions in the bot's own home.
@MainActor final class SessionCleanupRuntimeTests: XCTestCase {
    private let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
    private var old: Date { cutoff.addingTimeInterval(-86_400) }
    private var recent: Date { cutoff.addingTimeInterval(86_400) }

    private func fixture() throws -> HarnessRuntimeFixture {
        let f = try HarnessRuntimeFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }

    private func codexHome(_ f: HarnessRuntimeFixture, threads: [(String, Date)]) throws -> URL {
        let codex = f.workspace.appendingPathComponent(".noodle/home/.codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(codex.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL)", nil, nil, nil), SQLITE_OK)
        for (id, date) in threads {
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('\(id)', \(Int(date.timeIntervalSince1970)))", nil, nil, nil), SQLITE_OK)
        }
        try Data().write(to: codex.appendingPathComponent("thread_history_1.sqlite"))
        return codex
    }

    private func requested(_ wire: HarnessWire, _ method: String, _ key: String) -> [String] {
        wire.writes.filter { $0["method"] as? String == method }.compactMap { ($0["params"] as? [String: Any])?[key] as? String }
    }

    /// Codex deletes threads its list leaves out too, so the old ones come from its state database; it refuses to
    /// delete any while its archive folder is missing; and its history file shrinks only after a vacuum, which runs
    /// as a command inside the bot's own sandbox.
    func testCodexDeletesOldThreadsOtherThanItsOwnThenVacuumsItsHistory() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire, extended: false)
        p.start(); try await f.openCodex(wire)
        let codex = try codexHome(f, threads: [("old-one", old), ("fixture-thread", old), ("old-two", old), ("recent", recent)])
        var finished = false
        XCTAssertTrue(p.cleanUpSessions(before: cutoff) { finished = true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: codex.appendingPathComponent("archived_sessions").path))
        try await f.wait { wire.count("thread/delete") == 1 }
        try wire.reply("thread/delete", error: ["code": -32603, "message": "failed to delete thread"])
        try await f.wait { wire.count("thread/delete") == 2 }
        try wire.reply("thread/delete")
        try await f.wait { wire.count("command/exec") == 1 }
        XCTAssertEqual(Set(requested(wire, "thread/delete", "threadId")), ["old-one", "old-two"])
        let exec = try XCTUnwrap(wire.last("command/exec")["params"] as? [String: Any])
        XCTAssertEqual(exec["command"] as? [String], ["/usr/bin/sqlite3", codex.appendingPathComponent("thread_history_1.sqlite").path,
                                                      "PRAGMA incremental_vacuum;"])
        XCTAssertEqual((exec["sandboxPolicy"] as? [String: Any])?["type"] as? String, "externalSandbox")
        XCTAssertFalse(finished)
        try wire.reply("command/exec", result: ["exitCode": 0, "stdout": "", "stderr": ""])
        try await f.wait { finished }
        XCTAssertEqual(p.snapshot.phase, .ready)
        XCTAssertTrue(p.canReceiveHeartbeat)
    }

    func testCodexCleanupWaitsForIdleAndLeavesAnUnrestrictedBotsThreads() async throws {
        let f = try fixture()
        _ = try codexHome(f, threads: [("old-one", old)])
        let unrestricted = HarnessWire(), extended = f.codex(unrestricted, extended: true)
        extended.start(); try await f.openCodex(unrestricted)
        var finished = false
        XCTAssertTrue(extended.cleanUpSessions(before: cutoff) { finished = true })
        XCTAssertTrue(finished)
        extended.stop()
        let wire = HarnessWire(), p = f.codex(wire, extended: false)
        p.start(); try await f.openCodex(wire)
        p.notify(); try wire.reply("turn/start", result: ["turn": ["id": "turn-one"]])
        try await f.wait { p.snapshot.phase == .working }
        XCTAssertFalse(p.cleanUpSessions(before: cutoff) { XCTFail("A busy harness does not start a cleanup") })
        await f.drain()
        XCTAssertEqual(unrestricted.count("thread/delete") + wire.count("thread/delete"), 0)
    }

    func testACPHarnessDeletesOldSessionsInItsWorkspaceWhenItCanDeleteSessions() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.acp(wire, provider: .openCode, extended: false)
        p.start()
        try await f.openACP(wire, provider: .openCode, agentCapabilities: ["sessionCapabilities": ["list": [:], "delete": [:]]])
        let date = ISO8601DateFormatter()
        var finished = false
        XCTAssertTrue(p.cleanUpSessions(before: cutoff) { finished = true })
        try await f.wait { wire.count("session/list") == 1 }
        XCTAssertEqual((try wire.last("session/list")["params"] as? [String: Any])?["cwd"] as? String, f.workspace.path)
        try wire.reply("session/list", result: ["sessions": [
            ["sessionId": "old-one", "cwd": f.workspace.path, "updatedAt": date.string(from: old)],
            ["sessionId": "fixture-session", "cwd": f.workspace.path, "updatedAt": date.string(from: old)],
            ["sessionId": "recent", "cwd": f.workspace.path, "updatedAt": date.string(from: recent)],
            ["sessionId": "elsewhere", "cwd": "/elsewhere", "updatedAt": date.string(from: old)],
            ["sessionId": "undated", "cwd": f.workspace.path]
        ], "nextCursor": "page-two"])
        try await f.wait { wire.count("session/list") == 2 }
        XCTAssertEqual((try wire.last("session/list")["params"] as? [String: Any])?["cursor"] as? String, "page-two")
        try wire.reply("session/list", result: ["sessions": [["sessionId": "old-two", "updatedAt": "2027-01-14T08:00:00.250Z"]]])
        try await f.wait { wire.count("session/delete") == 1 }
        try wire.reply("session/delete", error: ["code": -32603, "message": "Session is busy"])
        try await f.wait { wire.count("session/delete") == 2 }
        try wire.reply("session/delete")
        try await f.wait { finished }
        XCTAssertEqual(Set(requested(wire, "session/delete", "sessionId")), ["old-one", "old-two"])
        XCTAssertEqual(p.snapshot.phase, .ready)
        XCTAssertTrue(p.isAlive)
    }

    func testACPHarnessWithoutSessionDeletionOrOnUnrestrictedAccessDeletesNothing() async throws {
        for (provider, extended, capabilities) in [(HarnessProvider.copilot, false, ["sessionCapabilities": ["list": [:], "close": [:]]]),
                                                   (.openCode, true, ["sessionCapabilities": ["list": [:], "delete": [:]]])] {
            let f = try fixture(), wire = HarnessWire(), p = f.acp(wire, provider: provider, extended: extended)
            p.start(); try await f.openACP(wire, provider: provider, agentCapabilities: capabilities)
            var finished = false
            XCTAssertTrue(p.cleanUpSessions(before: cutoff) { finished = true })
            XCTAssertTrue(finished)
            await f.drain()
            XCTAssertEqual(wire.count("session/list"), 0, "\(provider)")
        }
    }

    /// The first cleanup comes a while after launch and then once a day. A bot's running harness is asked once it
    /// is idle, and what another harness left in its home is cleaned up too.
    func testCoordinatorCleansUpAfterLaunchThenDailyAndAsksBusyHarnessesAgain() async throws {
        let f = try RuntimeCoordinatorFixture(); addTeardownBlock { @MainActor in f.cleanUp() }
        let agent = try f.agent(harness: .codex)
        let process = try f.start(agent)
        let workspace = f.repository.directory(forAgentID: agent.id)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".noodle/home/.codex"), withIntermediateDirectories: true)
        let transcript = workspace
            .appendingPathComponent(".noodle/home/.claude/projects/-workspace/77777777-7777-4777-8777-777777777777.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: transcript)
        try FileManager.default.setAttributes([.modificationDate: f.clock.date.addingTimeInterval(-8 * 86_400)], ofItemAtPath: transcript.path)
        process.cleansUpSessions = false

        f.runtime.checkSessionCleanup(repository: f.repository)
        f.clock.date.addTimeInterval(9 * 60)
        f.runtime.checkSessionCleanup(repository: f.repository)
        await Task.yield()
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path))

        f.clock.date.addTimeInterval(60)
        f.runtime.checkSessionCleanup(repository: f.repository)
        try await f.clock.waitUntil { !FileManager.default.fileExists(atPath: transcript.path) }
        XCTAssertTrue(process.sessionCleanups.isEmpty, "Busy, so asked again later")
        process.cleansUpSessions = true
        // Checked each second, as the app does, until the busy harness is asked again.
        try await f.clock.waitUntil { f.runtime.checkSessionCleanup(repository: f.repository); return !process.sessionCleanups.isEmpty }
        XCTAssertEqual(process.sessionCleanups, [f.clock.date.addingTimeInterval(-HarnessSessionCleanup.retention)])

        f.clock.date.addTimeInterval(60 * 60)
        f.runtime.checkSessionCleanup(repository: f.repository)
        await Task.yield()
        XCTAssertEqual(process.sessionCleanups.count, 1)
        f.clock.date.addTimeInterval(24 * 60 * 60)
        f.runtime.checkSessionCleanup(repository: f.repository)
        try await f.clock.waitUntil { process.sessionCleanups.count == 2 }
    }
}
