import Foundation
#if os(Windows)
import WindowsPOSIX
#endif
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// The file side of deleting the sessions a bot's harnesses kept in its private home, `.noodle/home`, once they
/// have gone unused for a week. Each harness's cleaner decides how its own sessions go, and uses these where it
/// has to touch files: only session files, never the bot's own workspace files, which are the bot's to tidy, and
/// never a session a runtime pointer still names. Nothing outside that home is touched, so a bot with
/// unrestricted access, whose harness keeps its sessions in the person's own home, keeps them.
public enum HarnessSessionCleanup {
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    /// The sessions every runtime pointer in a bot's runtime folder names, lowercased: current ones, and those an
    /// ACP harness keeps for history recovery. The folder is Noodle's own, outside the workspace the bot writes.
    public static func keptSessions(runtime: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: runtime, includingPropertiesForKeys: nil)) ?? []
        var kept = Set<String>()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), data.count <= 1_048_576,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for key in ["sessionID", "threadID"] {
                if let id = object[key] as? String { kept.insert(id.lowercased()) }
            }
            for id in object["previousSessionIDs"] as? [String] ?? [] { kept.insert(id.lowercased()) }
        }
        return kept
    }

    /// Removes what nothing has touched since `cutoff` from the bot's temporary folder, which its harness is given
    /// as its own: scratch files the harness and the bot leave behind. Answers how many entries went.
    @discardableResult
    public static func sweepTemporary(workspace: URL, before cutoff: Date) -> Int {
        guard let folder = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/tmp") else { return 0 }
        return folder.removeEntries(untouchedSince: cutoff)
    }

    /// Removes the Claude Code sessions last changed before `cutoff`, answering how many went. Claude Code keeps
    /// each session as `<id>.jsonl` beside a folder `<id>` of its subagents and tool results, in a folder per
    /// working directory. Anything else there, such as its `memory` folder, is not a session.
    @discardableResult
    public static func sweepClaude(workspace: URL, keeping kept: Set<String>, before cutoff: Date) -> Int {
        let path = ".noodle/home/.claude/projects"
        guard let projects = try? WorkspaceMailbox(workspace: workspace, path: path) else { return 0 }
        var removed = 0
        for project in (try? projects.names(limit: .max)) ?? [] where projects.isDirectory(project) {
            guard let folder = try? WorkspaceMailbox(workspace: workspace, path: path + "/" + project) else { continue }
            let names = Set((try? folder.names(limit: .max)) ?? [])
            var sessions = Set<String>()
            for name in names {
                if name.hasSuffix(".jsonl"), isSessionID(String(name.dropLast(6))) { sessions.insert(String(name.dropLast(6))) }
                else if isSessionID(name), folder.isDirectory(name) { sessions.insert(name) }
            }
            for session in sessions where !kept.contains(session.lowercased()) {
                let parts = [session + ".jsonl", session].filter(names.contains)
                let dates = parts.map { folder.latestModification($0) ?? .distantFuture }
                guard !dates.isEmpty, dates.allSatisfy({ $0 < cutoff }) else { continue }
                parts.forEach(folder.removeTree)
                removed += 1
            }
        }
        return removed
    }

    /// Removes the Grok Build sessions last changed before `cutoff`, answering how many went. Grok Build keeps
    /// each session as a folder named by its ID, in a folder per working directory, beside a search index it
    /// rebuilds from the folders it finds.
    @discardableResult
    public static func sweepGrok(workspace: URL, keeping kept: Set<String>, before cutoff: Date) -> Int {
        let path = ".noodle/home/.grok/sessions"
        guard let sessions = try? WorkspaceMailbox(workspace: workspace, path: path) else { return 0 }
        var removed = 0
        for directory in (try? sessions.names(limit: .max)) ?? [] where sessions.isDirectory(directory) {
            guard let folder = try? WorkspaceMailbox(workspace: workspace, path: path + "/" + directory) else { continue }
            for name in (try? folder.names(limit: .max)) ?? []
            where isSessionID(name) && !kept.contains(name.lowercased()) && folder.isDirectory(name) {
                guard let date = folder.latestModification(name), date < cutoff else { continue }
                folder.removeTree(name)
                removed += 1
            }
        }
        return removed
    }

    /// Removes the FX sessions last changed before `cutoff`, answering how many went. FX keeps each session as a
    /// folder named by its ID beside an index it repairs itself: a session whose folder is gone is no longer
    /// listed, and FX records it deleted.
    @discardableResult
    public static func sweepFX(workspace: URL, keeping kept: Set<String>, before cutoff: Date) -> Int {
        guard let folder = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.fx/sessions/v2") else { return 0 }
        var removed = 0
        for name in (try? folder.names(limit: .max)) ?? []
        where isFXSessionID(name) && !kept.contains(name.lowercased()) && folder.isDirectory(name) {
            guard let date = folder.latestModification(name), date < cutoff else { continue }
            folder.removeTree(name)
            removed += 1
        }
        return removed
    }

    private static func isSessionID(_ name: String) -> Bool { UUID(uuidString: name) != nil }

    /// FX names a session with letters, digits, `-` and `_`; its own folders, such as `.tmp`, start with a dot.
    private static func isFXSessionID(_ name: String) -> Bool {
        (8...64).contains(name.utf8.count) && name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_")
        }
    }

    /// The threads Codex last updated before `cutoff`, from its newest state database. That database names every
    /// thread Codex can delete, including those whose rollout file is gone, which its thread list leaves out.
    /// Opened read-only: every write to a bot's database runs inside the bot's own sandbox.
    public static func codexThreads(workspace: URL, before cutoff: Date) -> [String] {
        guard let codex = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.codex"),
              let name = databases(named: "state_", in: codex).last,
              ["-wal", "-shm"].allSatisfy({ codex.linkDestination(name + $0) == nil }),
              let folder = realpath(codex.url.path, nil) else { return [] }
        // The folder's real path, since SQLite refuses a link anywhere in the path, as /var is on macOS.
        let path = String(cString: folder) + "/" + name
        free(folder)
        // A closed database has no write-ahead log, which a read-only connection cannot make; nothing writes
        // it then, so it is read as it stands.
        let closed = !codex.contains(name + "-wal")
        var components = URLComponents()
        components.scheme = "file"
        components.path = path
        if closed { components.queryItems = [URLQueryItem(name: "immutable", value: "1")] }
        guard let uri = components.string else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_048_576)
        sqlite3_exec(db, "PRAGMA trusted_schema=OFF", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM threads WHERE updated_at < ?1 LIMIT 100000", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(cutoff.timeIntervalSince1970))
        var threads: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let id = String(cString: text)
            if isThreadID(id) { threads.append(id) }
        }
        return threads
    }

    /// Removes Codex's history as whole files, never opened, when Codex cannot delete its own threads, but only
    /// once nothing in it has changed since `cutoff`: its rollouts, thread history, state and logs, with their
    /// caches. Its login, settings, memories and anything else stay. Answers whether it went.
    @discardableResult
    public static func removeCodexHistory(workspace: URL, before cutoff: Date) -> Bool {
        guard let codex = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.codex") else { return false }
        let history = ((try? codex.names(limit: 4096)) ?? []).filter { name in
            ["sessions", "archived_sessions", "shell_snapshots", "cache", "session_index.jsonl"].contains(name)
                || ["thread_history_", "state_", "logs_"].contains { prefix in
                    guard name.hasPrefix(prefix) else { return false }
                    let rest = name.dropFirst(prefix.count)
                    guard let dot = rest.firstIndex(of: "."), Int(rest[..<dot]) != nil else { return false }
                    return [".sqlite", ".sqlite-wal", ".sqlite-shm", ".sqlite-journal"].contains(String(rest[dot...]))
                }
        }
        guard !history.isEmpty, history.allSatisfy({ (codex.latestModification($0) ?? .distantFuture) < cutoff }) else { return false }
        history.forEach(codex.removeTree)
        return true
    }

    /// Removes the skills and plugins Claude Code synced from the claude.ai account, with the copies it set aside,
    /// which a bot's Claude Code runs without; see `ClaudeLaunch`. Answers whether anything went.
    @discardableResult
    public static func removeClaudeAccountSync(workspace: URL) -> Bool {
        var removed = false
        for path in ["skills", "plugins"] {
            guard let folder = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.claude/" + path) else { continue }
            for name in ["synced", ".trash"] where folder.contains(name) {
                folder.removeTree(name)
                removed = true
            }
        }
        return removed
    }

    /// Removes the plugins Codex synced from the ChatGPT account and the catalog of every plugin it fetched, which
    /// a bot's Codex runs without; see `CodexLaunch`. Answers whether anything went.
    @discardableResult
    public static func removeCodexPluginCaches(workspace: URL) -> Bool {
        var removed = false
        for (path, names) in [("cache", ["remote_plugin_catalog"]), ("plugins", ["cache", ".remote-plugin-install-staging"])] {
            guard let folder = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.codex/" + path) else { continue }
            for name in names where folder.contains(name) {
                folder.removeTree(name)
                removed = true
            }
        }
        return removed
    }

    /// Codex's thread history databases, whose freed pages only an incremental vacuum gives back to the disk.
    public static func codexHistoryDatabases(workspace: URL) -> [URL] {
        guard let codex = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.codex") else { return [] }
        return databases(named: "thread_history_", in: codex).map { codex.url.appendingPathComponent($0) }
    }

    /// Plain files called `<prefix><number>.sqlite`, oldest schema version first.
    private static func databases(named prefix: String, in folder: WorkspaceMailbox) -> [String] {
        let versioned = ((try? folder.names(limit: 4096)) ?? []).compactMap { name -> (Int, String)? in
            guard name.hasPrefix(prefix), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(prefix.count).dropLast(".sqlite".count)),
                  !folder.isDirectory(name), folder.linkDestination(name) == nil else { return nil }
            return (version, name)
        }
        return versioned.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func isThreadID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }
}
