import Foundation
import SQLite3

/// Input excludes cached tokens; reasoning is part of output and not added to the total.
public struct UsageTokens: Hashable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var reasoning = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    public var total: Int { input + output + cacheRead + cacheWrite }
    public var promptTotal: Int { input + cacheRead + cacheWrite }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead,
             cacheWrite: lhs.cacheWrite + rhs.cacheWrite, reasoning: lhs.reasoning + rhs.reasoning)
    }
}

/// One model's spend for one agent. Cost is nil when the harness does not report it.
public struct UsageSample: Hashable, Sendable {
    public var date: Date
    public var agentID: UUID
    public var agentName: String
    public var harness: String
    public var model: String
    public var tokens: UsageTokens
    public var costUSD: Double?

    public init(date: Date, agentID: UUID, agentName: String, harness: String, model: String,
                tokens: UsageTokens, costUSD: Double?) {
        self.date = date
        self.agentID = agentID
        self.agentName = agentName
        self.harness = harness
        self.model = model
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

/// Samples summed per local day, agent, harness and model.
public struct UsageDay: Hashable, Sendable {
    public var day: Date
    public var agentID: UUID
    public var agentName: String
    public var harness: String
    public var model: String
    public var tokens: UsageTokens
    public var costUSD: Double?
}

/// Append-only history that outlives the agents it describes.
public final class UsageLedger: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock = NSLock()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw UsageLedgerError("Could not open the usage history.")
        }
        db = handle
        sqlite3_busy_timeout(db, 2000)
        do {
            try execute("""
                PRAGMA journal_mode = WAL;
                CREATE TABLE IF NOT EXISTS usage (
                    time REAL NOT NULL, agent_id TEXT NOT NULL, agent_name TEXT NOT NULL,
                    harness TEXT NOT NULL, model TEXT NOT NULL,
                    input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL,
                    cache_write INTEGER NOT NULL, reasoning INTEGER NOT NULL, cost_usd REAL);
                CREATE INDEX IF NOT EXISTS usage_time ON usage(time);
                """)
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    public func record(_ sample: UsageSample) throws {
        try withStatement("""
            INSERT INTO usage (time, agent_id, agent_name, harness, model, input, output, cache_read, cache_write, reasoning, cost_usd)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            sqlite3_bind_double(statement, 1, sample.date.timeIntervalSince1970)
            bind(sample.agentID.uuidString, to: statement, at: 2)
            bind(sample.agentName, to: statement, at: 3)
            bind(sample.harness, to: statement, at: 4)
            bind(sample.model, to: statement, at: 5)
            for (index, value) in [sample.tokens.input, sample.tokens.output, sample.tokens.cacheRead,
                                   sample.tokens.cacheWrite, sample.tokens.reasoning].enumerated() {
                sqlite3_bind_int64(statement, Int32(6 + index), sqlite3_int64(value))
            }
            if let cost = sample.costUSD { sqlite3_bind_double(statement, 11, cost) } else { sqlite3_bind_null(statement, 11) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageLedgerError("Could not save usage.") }
        }
    }

    /// Days are local calendar days. `to` is exclusive.
    public func days(from start: Date, to end: Date, agentID: UUID? = nil) throws -> [UsageDay] {
        // The newest name per agent labels its whole history, so a rename does not split it.
        try withStatement("""
            SELECT date(u.time, 'unixepoch', 'localtime') AS day, u.agent_id, n.agent_name, u.harness, u.model,
                   SUM(u.input), SUM(u.output), SUM(u.cache_read), SUM(u.cache_write), SUM(u.reasoning),
                   SUM(u.cost_usd)
            FROM usage u
            JOIN (SELECT agent_id, agent_name, MAX(time) FROM usage GROUP BY agent_id) n ON n.agent_id = u.agent_id
            WHERE u.time >= ? AND u.time < ? AND (? IS NULL OR u.agent_id = ?)
            GROUP BY day, u.agent_id, u.harness, u.model
            ORDER BY day
            """) { statement in
            sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
            if let agentID {
                bind(agentID.uuidString, to: statement, at: 3)
                bind(agentID.uuidString, to: statement, at: 4)
            } else {
                sqlite3_bind_null(statement, 3)
                sqlite3_bind_null(statement, 4)
            }
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            var days: [UsageDay] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let day = formatter.date(from: text(statement, 0)),
                      let agentID = UUID(uuidString: text(statement, 1)) else { continue }
                let tokens = UsageTokens(input: Int(sqlite3_column_int64(statement, 5)), output: Int(sqlite3_column_int64(statement, 6)),
                    cacheRead: Int(sqlite3_column_int64(statement, 7)), cacheWrite: Int(sqlite3_column_int64(statement, 8)),
                    reasoning: Int(sqlite3_column_int64(statement, 9)))
                let cost = sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 10)
                days.append(UsageDay(day: Calendar.current.startOfDay(for: day), agentID: agentID, agentName: text(statement, 2),
                    harness: text(statement, 3), model: text(statement, 4), tokens: tokens, costUSD: cost))
            }
            return days
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageLedgerError("Could not prepare the usage history.")
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw UsageLedgerError("Could not read the usage history.")
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}

public struct UsageLedgerError: LocalizedError {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
