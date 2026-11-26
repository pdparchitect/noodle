import Foundation
import NoodleCore
import SQLite3
import XCTest
@testable import Noodle
@testable import NoodleRuntime

/// The daily cleanup goes through every bot and every harness whose sessions are in its home, whatever harness it
/// uses now, and each harness cleans up its own way.
@MainActor final class HarnessSessionCleanerTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }

    private func home(_ f: RuntimeCoordinatorFixture, _ agent: AgentRecord) -> URL {
        f.repository.directory(forAgentID: agent.id).appendingPathComponent(".noodle/home")
    }

    private func pointer(_ f: RuntimeCoordinatorFixture, _ agent: AgentRecord, _ name: String, _ json: String) throws {
        let runtime = f.repository.storage(for: agent.id).runtime
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: runtime.appendingPathComponent(name))
    }

    private func aged(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// A Codex home with the given threads in its state database, and history last written at `written`.
    @discardableResult
    private func codex(_ f: RuntimeCoordinatorFixture, _ agent: AgentRecord, threads: [(String, Date)], written: Date) throws -> URL {
        let codex = home(f, agent).appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(codex.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL)", nil, nil, nil), SQLITE_OK)
        for (id, date) in threads {
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('\(id)', \(Int(date.timeIntervalSince1970)))", nil, nil, nil), SQLITE_OK)
        }
        sqlite3_close(db)
        for name in ["thread_history_1.sqlite", "auth.json"] { try Data("x".utf8).write(to: codex.appendingPathComponent(name)) }
        for name in ["sessions", "state_5.sqlite", "thread_history_1.sqlite", "auth.json"] { try aged(codex.appendingPathComponent(name), written) }
        return codex
    }

    private func requested(_ wire: HarnessWire, _ method: String, _ key: String) -> [String] {
        wire.writes.filter { $0["method"] as? String == method }.compactMap { ($0["params"] as? [String: Any])?[key] as? String }
    }

    func testABotWithNothingRunningHasCodexStartedBrieflyToDeleteItsOldThreadsButTheOneItPointsAt() async throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode)
        let old = f.clock.date.addingTimeInterval(-8 * 86_400), recent = f.clock.date.addingTimeInterval(-86_400)
        let codex = try codex(f, agent, threads: [("old-one", old), ("kept-thread", old), ("recent", recent)], written: old)
        try pointer(f, agent, "codex-runtime.json", #"{"version":9,"threadID":"kept-thread"}"#)

        let cleanup = Task { await f.runtime.cleanUpSessions(repository: f.repository) }
        try await f.clock.waitUntil { f.wires.first?.count("initialize") == 1 }
        let wire = try XCTUnwrap(f.wires.first)
        XCTAssertEqual(wire.launches.first?.0, .codex)
        XCTAssertEqual(wire.launches.first?.1, false, "Always restricted: the bot's own home, never the person's")
        try wire.reply("initialize")
        try await f.clock.waitUntil { wire.count("thread/delete") == 1 }
        XCTAssertEqual(wire.count("initialized"), 1)
        XCTAssertEqual(wire.count("thread/start") + wire.count("thread/resume"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: codex.appendingPathComponent("archived_sessions").path))
        try wire.reply("thread/delete")
        try await f.clock.waitUntil { wire.count("command/exec") == 1 }
        try wire.reply("command/exec", result: ["exitCode": 0])
        await cleanup.value
        XCTAssertEqual(requested(wire, "thread/delete", "threadId"), ["old-one"])
        XCTAssertEqual(wire.stopCalls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: codex.appendingPathComponent("state_5.sqlite").path))
    }

    func testCodexThatCannotStartHasItsHistoryRemovedOnceUntouchedForAWeek() async throws {
        let f = try fixture(), agent = try f.agent(harness: .codex)
        f.connectFailure = CocoaError(.fileNoSuchFile)
        let old = f.clock.date.addingTimeInterval(-8 * 86_400)
        let codex = try codex(f, agent, threads: [("old-one", old)], written: f.clock.date)
        await f.runtime.cleanUpSessions(repository: f.repository)
        XCTAssertTrue(FileManager.default.fileExists(atPath: codex.appendingPathComponent("state_5.sqlite").path), "Written this week")

        for name in ["sessions", "state_5.sqlite", "thread_history_1.sqlite"] { try aged(codex.appendingPathComponent(name), old) }
        await f.runtime.cleanUpSessions(repository: f.repository)
        for name in ["sessions", "state_5.sqlite", "thread_history_1.sqlite"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: codex.appendingPathComponent(name).path), name)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: codex.appendingPathComponent("auth.json").path))
    }

    /// Starting Codex for a bot running another harness would stop that harness, and Codex is not using this home,
    /// so what Codex left behind goes as files.
    func testCodexLeftBehindByABotNowOnAnotherHarnessIsRemovedWithoutStartingCodex() async throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode)
        try f.start(agent)
        let old = f.clock.date.addingTimeInterval(-8 * 86_400)
        let codex = try codex(f, agent, threads: [("old-one", old)], written: old)
        await f.runtime.cleanUpSessions(repository: f.repository)
        XCTAssertTrue(f.wires.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: codex.appendingPathComponent("state_5.sqlite").path))
    }

    func testABotWithNothingRunningHasOpenCodeStartedBrieflyWhenItCanDeleteSessions() async throws {
        for canDelete in [true, false] {
            let f = try fixture(), agent = try f.agent(harness: .openCode)
            try FileManager.default.createDirectory(at: home(f, agent).appendingPathComponent(".local/share/opencode"), withIntermediateDirectories: true)
            try pointer(f, agent, "opencode-runtime.json", #"{"sessionID":"kept-session","previousSessionIDs":[]}"#)
            let old = ISO8601DateFormatter().string(from: f.clock.date.addingTimeInterval(-8 * 86_400))

            let cleanup = Task { await f.runtime.cleanUpSessions(repository: f.repository) }
            try await f.clock.waitUntil { f.wires.first?.count("initialize") == 1 }
            let wire = try XCTUnwrap(f.wires.first)
            XCTAssertEqual(wire.launches.first?.0, .openCode)
            XCTAssertEqual(wire.launches.first?.1, false)
            let capabilities: [String: Any] = canDelete ? ["list": [:], "delete": [:]] : ["list": [:]]
            try wire.reply("initialize", result: ["protocolVersion": 1, "agentCapabilities": ["sessionCapabilities": capabilities]])
            if canDelete {
                try await f.clock.waitUntil { wire.count("session/list") == 1 }
                try wire.reply("session/list", result: ["sessions": [["sessionId": "old-one", "updatedAt": old],
                                                                    ["sessionId": "kept-session", "updatedAt": old]]])
                try await f.clock.waitUntil { wire.count("session/delete") == 1 }
                try wire.reply("session/delete")
            }
            await cleanup.value
            XCTAssertEqual(requested(wire, "session/delete", "sessionId"), canDelete ? ["old-one"] : [])
            XCTAssertEqual(wire.count("session/new") + wire.count("session/load"), 0)
            XCTAssertEqual(wire.stopCalls, 1)
        }
    }

    /// While a harness runs for the bot outside its runtime, the bot does not start: its start would stop it.
    func testABotDoesNotStartWhileItsHarnessRunsBrieflyForCleanup() async throws {
        let f = try fixture(), agent = try f.agent(harness: .codex)
        let old = f.clock.date.addingTimeInterval(-8 * 86_400)
        try codex(f, agent, threads: [("old-one", old)], written: old)
        let cleanup = Task { await f.runtime.cleanUpSessions(repository: f.repository) }
        try await f.clock.waitUntil { f.wires.first?.count("initialize") == 1 }
        f.runtime.start(agent: agent, repository: f.repository)
        XCTAssertTrue(f.factory.processes.isEmpty)
        let wire = try XCTUnwrap(f.wires.first)
        try wire.reply("initialize", error: ["message": "refused"])
        await cleanup.value
        f.runtime.start(agent: agent, repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 1)
    }

    func testClaudeCleanupRemovesWhatItSyncedFromTheAccount() async throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode)
        let synced = home(f, agent).appendingPathComponent(".claude/skills/synced/org_account/pdf/SKILL.md")
        try FileManager.default.createDirectory(at: synced.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: synced)
        try FileManager.default.createDirectory(at: home(f, agent).appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        await f.runtime.cleanUpSessions(repository: f.repository)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home(f, agent).appendingPathComponent(".claude/skills/synced").path))
    }

    func testFXSessionsLeftInABotsHomeAreSwept() async throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode)
        let log = home(f, agent).appendingPathComponent(".fx/sessions/v2/u0tI_G7qmV7o/log.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: log)
        for url in [log, log.deletingLastPathComponent()] { try aged(url, f.clock.date.addingTimeInterval(-8 * 86_400)) }
        await f.runtime.cleanUpSessions(repository: f.repository)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.deletingLastPathComponent().path))
    }

    /// The temporary folder is Noodle's, not a harness's, so it is swept for every bot whatever harnesses it has used.
    func testEveryBotsTemporaryFilesUntouchedForAWeekGo() async throws {
        let f = try fixture(), agent = try f.agent(harness: .codex)
        let scratch = f.repository.directory(forAgentID: agent.id).appendingPathComponent(".noodle/tmp/scratch.txt")
        try FileManager.default.createDirectory(at: scratch.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: scratch)
        try aged(scratch, f.clock.date.addingTimeInterval(-8 * 86_400))
        await f.runtime.cleanUpSessions(repository: f.repository)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }
}
