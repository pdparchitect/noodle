import XCTest
import SQLite3
@testable import NoodleCore

final class HarnessSessionCleanupTests: XCTestCase {
    private var root: URL!
    private var workspace: URL { root.appendingPathComponent("workspace") }
    private var runtime: URL { root.appendingPathComponent("runtime") }
    private let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
    private var old: Date { cutoff.addingTimeInterval(-86_400) }
    private var recent: Date { cutoff.addingTimeInterval(86_400) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-cleanup-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func file(_ path: String, modified: Date, in base: URL? = nil) throws -> URL {
        let url = (base ?? workspace).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func age(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: workspace.appendingPathComponent(path).path)
    }

    private func exists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: workspace.appendingPathComponent(path).path, isDirectory: &isDirectory)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: workspace.appendingPathComponent(path).path)) != nil
    }

    func testKeptSessionsAreEveryPointerInTheRuntimeFolder() throws {
        try Data(#"{"version":1,"sessionID":"AC7E6C0E-6DDB-4C8F-970F-E89F6829219D"}"#.utf8)
            .write(to: runtime.appendingPathComponent("claude-runtime.json"))
        try Data(#"{"version":9,"threadID":"01a20970-6fc5-7a31-ad56-80b5c2fd72eb"}"#.utf8)
            .write(to: runtime.appendingPathComponent("codex-runtime.json"))
        try Data(#"{"sessionID":"grok-current","previousSessionIDs":["grok-before"]}"#.utf8)
            .write(to: runtime.appendingPathComponent("grok-runtime.json"))
        try Data("not json".utf8).write(to: runtime.appendingPathComponent("harness.lock"))
        XCTAssertEqual(HarnessSessionCleanup.keptSessions(runtime: runtime),
                       ["ac7e6c0e-6ddb-4c8f-970f-e89f6829219d", "01a20970-6fc5-7a31-ad56-80b5c2fd72eb", "grok-current", "grok-before"])
        XCTAssertEqual(HarnessSessionCleanup.keptSessions(runtime: root.appendingPathComponent("missing")), [])
    }

    /// Claude Code keeps a transcript per session beside a folder of its subagents and tool results. Old ones
    /// go; the current session, recent ones, and anything that is not a session, such as Claude's memory, stay.
    func testClaudeTranscriptsOlderThanTheCutoffGoUnlessKept() throws {
        let projects = ".noodle/home/.claude/projects/-workspace/"
        let stale = "11111111-1111-4111-8111-111111111111", current = "22222222-2222-4222-8222-222222222222"
        let fresh = "33333333-3333-4333-8333-333333333333", orphan = "44444444-4444-4444-8444-444444444444"
        let busy = "55555555-5555-4555-8555-555555555555"
        try file(projects + stale + ".jsonl", modified: old)
        try file(projects + stale + "/subagents/agent-1.jsonl", modified: old)
        try file(projects + stale + "/tool-results/result.txt", modified: old)
        try file(projects + current + ".jsonl", modified: old)
        try file(projects + fresh + ".jsonl", modified: recent)
        try file(projects + orphan + "/tool-results/result.txt", modified: old)
        try file(projects + busy + ".jsonl", modified: old)
        try file(projects + busy + "/subagents/agent-2.jsonl", modified: recent)
        try file(projects + "memory/MEMORY.md", modified: old)
        try file(projects + "notes.jsonl", modified: old)
        for folder in [stale, orphan, busy] { try age(projects + folder, old) }
        try age(projects + stale + "/subagents", old); try age(projects + stale + "/tool-results", old)
        try age(projects + orphan + "/tool-results", old)

        let removed = HarnessSessionCleanup.sweepClaude(workspace: workspace, keeping: [current], before: cutoff)

        XCTAssertEqual(removed, 2)
        XCTAssertFalse(exists(projects + stale + ".jsonl"))
        XCTAssertFalse(exists(projects + stale))
        XCTAssertFalse(exists(projects + orphan))
        for kept in [current + ".jsonl", fresh + ".jsonl", busy + ".jsonl", busy, "memory/MEMORY.md", "notes.jsonl"] {
            XCTAssertTrue(exists(projects + kept), kept)
        }
    }

    /// Grok Build keeps a folder per session, under a folder per working directory, beside its search index.
    func testGrokSessionFoldersOlderThanTheCutoffGoUnlessKept() throws {
        let sessions = ".noodle/home/.grok/sessions/"
        let folder = sessions + "%2Fworkspace/"
        let stale = "01a1cd09-f0e3-7103-b2e1-396f2b242e1e", current = "01a217dd-f0ff-7661-919e-49e5296ad7a1"
        let previous = "01a14119-b166-79a2-b350-57b2b58f7d0d", fresh = "01a15a9a-1d85-78b3-972c-fc4e25ac31bd"
        for id in [stale, current, previous] {
            try file(folder + id + "/chat_history.jsonl", modified: old)
            try file(folder + id + "/events.jsonl", modified: old)
            try age(folder + id, old)
        }
        try file(folder + fresh + "/chat_history.jsonl", modified: old)
        try file(folder + fresh + "/events.jsonl", modified: recent)
        try age(folder + fresh, old)
        try file(sessions + "session_search.sqlite", modified: old)
        try file(folder + "not-a-session/events.jsonl", modified: old)

        let removed = HarnessSessionCleanup.sweepGrok(workspace: workspace, keeping: [current, previous], before: cutoff)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(exists(folder + stale))
        for kept in [folder + current, folder + previous, folder + fresh, sessions + "session_search.sqlite", folder + "not-a-session"] {
            XCTAssertTrue(exists(kept), kept)
        }
    }

    /// A bot writes its own home, so it could swap a folder for a link to Noodle's data. A sweep removes the link
    /// itself and never anything it points at.
    func testSweepsNeverFollowLinksOutOfTheBotsHome() throws {
        let outside = root.appendingPathComponent("outside")
        let id = "66666666-6666-4666-8666-666666666666"
        try file(id + ".jsonl", modified: old, in: outside)
        try file(id + "/data.json", modified: old, in: outside)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: outside.appendingPathComponent(id).path)
        let projects = workspace.appendingPathComponent(".noodle/home/.claude/projects")
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("-workspace"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("-linked"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("-workspace/\(id)"),
                                                   withDestinationURL: outside.appendingPathComponent(id))
        let grok = workspace.appendingPathComponent(".noodle/home/.grok")
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: grok.appendingPathComponent("sessions"), withDestinationURL: outside)

        HarnessSessionCleanup.sweepClaude(workspace: workspace, keeping: [], before: cutoff)
        HarnessSessionCleanup.sweepGrok(workspace: workspace, keeping: [], before: cutoff)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent(id + ".jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent(id + "/data.json").path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: projects.appendingPathComponent("-linked").path))
    }

    func testRemovingATreeRemovesNestedFilesAndLinksButNotTheirTargets() throws {
        let target = try file("target.txt", modified: old, in: root)
        try file("tree/a/b/c.txt", modified: old)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("tree/a/link"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("tree/up"), withDestinationURL: root)
        let mailbox = try WorkspaceMailbox(workspace: workspace, path: "")
        mailbox.removeTree("tree")
        XCTAssertFalse(exists("tree"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
    }

    /// Codex lists only threads whose rollout file remains, but deletes any thread its state database names,
    /// so the old ones are read from the newest state database, also once Codex has closed it and SQLite has
    /// folded its write-ahead log back in, as it does when Codex stops.
    func testCodexThreadsLastUpdatedBeforeTheCutoffComeFromTheNewestStateDatabase() throws {
        let codex = workspace.appendingPathComponent(".noodle/home/.codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        XCTAssertEqual(HarnessSessionCleanup.codexThreads(workspace: workspace, before: cutoff), [])
        func database(_ name: String, _ rows: [(String, Date)]) throws {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(codex.appendingPathComponent(name).path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, updated_at INTEGER NOT NULL)", nil, nil, nil), SQLITE_OK)
            for (id, date) in rows {
                XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('\(id)', '', \(Int(date.timeIntervalSince1970)))", nil, nil, nil), SQLITE_OK)
            }
        }
        try database("state_4.sqlite", [("superseded", old)])
        try database("state_5.sqlite", [("old-one", old), ("old-two", old), ("recent", recent)])
        // As Codex's SQLite leaves it once closed; Apple's keeps the empty sidecars.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: codex.appendingPathComponent("state_5.sqlite" + suffix)) }
        try Data().write(to: codex.appendingPathComponent("thread_history_1.sqlite"))
        try Data().write(to: codex.appendingPathComponent("thread_history_1.sqlite-wal"))
        XCTAssertEqual(Set(HarnessSessionCleanup.codexThreads(workspace: workspace, before: cutoff)), ["old-one", "old-two"])
        XCTAssertEqual(HarnessSessionCleanup.codexHistoryDatabases(workspace: workspace).map(\.lastPathComponent), ["thread_history_1.sqlite"])
    }

    /// When Codex cannot be started to delete its own threads, its history goes as whole files, never opened, once
    /// nothing in it has changed for the retention period. Its login, settings and memories stay.
    func testCodexHistoryFilesGoTogetherOnceAllAreUntouchedButLoginAndMemoriesStay() throws {
        let codex = ".noodle/home/.codex/"
        let history = ["sessions/2026/11/20/rollout.jsonl", "archived_sessions/rollout.jsonl", "thread_history_1.sqlite",
                       "thread_history_1.sqlite-wal", "state_5.sqlite", "logs_2.sqlite", "logs_2.sqlite-shm", "session_index.jsonl",
                       "cache/remote_plugin_catalog/catalog.json", "shell_snapshots/snapshot.sh"]
        let kept = ["auth.json", "config.toml", "memories_1.sqlite", "goals_1.sqlite", "generated_images/image.png", "skills/skill/SKILL.md"]
        for path in history + kept { try file(codex + path, modified: old) }
        for folder in ["sessions/2026/11/20", "sessions/2026/11", "sessions/2026", "sessions", "archived_sessions",
                       "cache/remote_plugin_catalog", "cache", "shell_snapshots"] { try age(codex + folder, old) }
        try age(codex + "logs_2.sqlite", recent)

        XCTAssertFalse(HarnessSessionCleanup.removeCodexHistory(workspace: workspace, before: cutoff), "Codex wrote its log this week")
        for path in history + kept { XCTAssertTrue(exists(codex + path), path) }

        try age(codex + "logs_2.sqlite", old)
        XCTAssertTrue(HarnessSessionCleanup.removeCodexHistory(workspace: workspace, before: cutoff))
        for path in ["sessions", "archived_sessions", "thread_history_1.sqlite", "thread_history_1.sqlite-wal", "state_5.sqlite",
                     "logs_2.sqlite", "logs_2.sqlite-shm", "session_index.jsonl", "cache", "shell_snapshots"] {
            XCTAssertFalse(exists(codex + path), path)
        }
        for path in kept { XCTAssertTrue(exists(codex + path), path) }
    }
}
