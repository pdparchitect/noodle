import BrowserBridge
import Foundation
import SQLite3

/// Per-profile records live outside the small tab/settings archive. History is
/// retained until explicitly cleared, and large libraries are queried in pages.
final class BrowserRecords {
    private var database: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database = nil
            throw BrowserError("Could not open browser history and bookmarks.")
        }
        do {
            sqlite3_busy_timeout(database, 2000)
            try execute("CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL, visited_at TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS bookmarks (id TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS bookmarks_updated ON bookmarks(updated_at DESC)")
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { if let database { sqlite3_close(database) } }

    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else { throw failure() }
        for (index, value) in values.enumerated() {
            let status = value.withCString { sqlite3_bind_text(result, Int32(index + 1), $0, -1, Self.transient) }
            if status != SQLITE_OK { sqlite3_finalize(result); throw failure() }
        }
        return result
    }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        let prepared = try statement(sql, values); defer { sqlite3_finalize(prepared) }
        guard sqlite3_step(prepared) == SQLITE_DONE else { throw failure() }
    }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        let prepared = try statement(sql, values); defer { sqlite3_finalize(prepared) }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(prepared)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(prepared)).map { index in
                sqlite3_column_text(prepared, index).map { String(cString: $0) } ?? ""
            })
        }
    }
    private func failure() -> BrowserError { BrowserError("Could not read or save browser history and bookmarks: \(String(cString: sqlite3_errmsg(database)))") }
    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    private func filter(_ query: String) -> (String, [String]) {
        guard !query.isEmpty else { return ("", []) }
        let pattern = "%" + query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        return (" WHERE (title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\')", [pattern, pattern])
    }
    private func count(_ table: String, filter: (String, [String])) throws -> Int {
        // Table names are constants owned by this file; all user values are bound.
        guard let count = try rows("SELECT COUNT(*) FROM \(table)" + filter.0, filter.1).first?.first.flatMap(Int.init) else { throw failure() }
        return count
    }
    func history(query: String, limit: Int, offset: Int) throws -> ([BrowserHistoryEntry], Int) {
        let filter = filter(query)
        let entries = try rows("SELECT id,url,title,visited_at FROM history" + filter.0 + " ORDER BY rowid DESC LIMIT ? OFFSET ?", filter.1 + [String(limit), String(offset)]).map { row in
            guard let id = UUID(uuidString: row[0]) else { throw BrowserError("Invalid history record.") }
            return BrowserHistoryEntry(id: id, url: row[1], title: row[2], visitedAt: row[3])
        }
        return (entries, try count("history", filter: filter))
    }
    func record(url: String, title: String) throws -> UUID {
        let id = UUID()
        try execute("INSERT INTO history (id,url,title,visited_at) VALUES (?,?,?,?)", [id.uuidString, url, String(title.prefix(2048)), timestamp()])
        return id
    }
    func updateHistoryTitle(_ id: UUID, title: String) throws {
        try execute("UPDATE history SET title=? WHERE id=?", [String(title.prefix(2048)), id.uuidString])
    }
    func clearHistory() throws { try execute("DELETE FROM history") }
    func removeHistory(_ id: UUID) throws {
        try execute("DELETE FROM history WHERE id=?", [id.uuidString])
        guard sqlite3_changes(database) == 1 else { throw BrowserError("History entry does not belong to this browser or no longer exists.") }
    }
    func bookmarks(query: String, limit: Int, offset: Int) throws -> ([BrowserBookmark], Int) {
        let filter = filter(query)
        return (try rows("SELECT id,url,title,created_at,updated_at FROM bookmarks" + filter.0 + " ORDER BY updated_at DESC,rowid DESC LIMIT ? OFFSET ?", filter.1 + [String(limit), String(offset)]).map(bookmark), try count("bookmarks", filter: filter))
    }
    private func bookmark(_ row: [String]) throws -> BrowserBookmark {
        guard let id = UUID(uuidString: row[0]) else { throw BrowserError("Invalid bookmark record.") }
        return .init(id: id, url: row[1], title: row[2], createdAt: row[3], updatedAt: row[4])
    }
    func addBookmark(url: String, title: String?) throws -> BrowserBookmark {
        let id = UUID(), now = timestamp(), title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? url
        try execute("INSERT INTO bookmarks (id,url,title,created_at,updated_at) VALUES (?,?,?,?,?)", [id.uuidString, url, title, now, now])
        return .init(id: id, url: url, title: title, createdAt: now, updatedAt: now)
    }
    func updateBookmark(_ id: UUID, url: String?, title: String?) throws -> BrowserBookmark {
        guard let row = try rows("SELECT id,url,title,created_at,updated_at FROM bookmarks WHERE id=?", [id.uuidString]).first else { throw BrowserError("Bookmark does not belong to this browser or no longer exists.") }
        var record = try bookmark(row)
        record.url = url ?? record.url; record.title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? record.title; record.updatedAt = timestamp()
        try execute("UPDATE bookmarks SET url=?,title=?,updated_at=? WHERE id=?", [record.url, record.title, record.updatedAt, id.uuidString])
        return record
    }
    func removeBookmark(_ id: UUID) throws {
        try execute("DELETE FROM bookmarks WHERE id=?", [id.uuidString])
        guard sqlite3_changes(database) == 1 else { throw BrowserError("Bookmark does not belong to this browser or no longer exists.") }
    }
}
