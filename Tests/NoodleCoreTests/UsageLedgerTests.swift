import Foundation
import SQLite3
import XCTest
@testable import NoodleCore

final class UsageLedgerTests: XCTestCase {
    func testDaysGroupByAgentHarnessAndModelAndSurviveReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.sqlite")
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let alice = UUID(), bob = UUID()
        func sample(_ agent: UUID, _ name: String, _ harness: String, _ model: String, at date: Date,
                    input: Int, output: Int, cost: Double?) -> UsageSample {
            UsageSample(date: date, agentID: agent, agentName: name, harness: harness, model: model,
                        tokens: UsageTokens(input: input, output: output, cacheRead: 10, cacheWrite: 1, reasoning: 2),
                        costUSD: cost)
        }
        do {
            let ledger = try UsageLedger(url: url)
            try ledger.record(sample(alice, "Old Alice", "claude-code", "claude-haiku-4-5", at: yesterday.addingTimeInterval(3600), input: 5, output: 7, cost: 0.5))
            try ledger.record(sample(alice, "Alice", "claude-code", "claude-haiku-4-5", at: today.addingTimeInterval(3600), input: 1, output: 2, cost: 0.25))
            try ledger.record(sample(alice, "Alice", "claude-code", "claude-haiku-4-5", at: today.addingTimeInterval(7200), input: 3, output: 4, cost: 0.25))
            try ledger.record(sample(bob, "Bob", "codex", "gpt-5", at: today.addingTimeInterval(60), input: 100, output: 50, cost: nil))
        }
        let ledger = try UsageLedger(url: url)
        let days = try ledger.days(from: yesterday, to: today.addingTimeInterval(86_400))
        XCTAssertEqual(days.count, 3)
        let aliceToday = try XCTUnwrap(days.first { $0.agentID == alice && $0.day == today })
        XCTAssertEqual(aliceToday.tokens, UsageTokens(input: 4, output: 6, cacheRead: 20, cacheWrite: 2, reasoning: 4))
        XCTAssertEqual(aliceToday.costUSD, 0.5)
        XCTAssertEqual(aliceToday.harness, "claude-code")
        XCTAssertEqual(aliceToday.model, "claude-haiku-4-5")
        // Renames show the newest name for the whole history.
        XCTAssertEqual(days.first { $0.agentID == alice && $0.day == yesterday }?.agentName, "Alice")
        XCTAssertEqual(try ledger.days(from: yesterday, to: today).map(\.agentName), ["Alice"], "a name newer than the period is still its name")
        let bobToday = try XCTUnwrap(days.first { $0.agentID == bob })
        XCTAssertNil(bobToday.costUSD)
        XCTAssertEqual(bobToday.tokens.total, 161)
        XCTAssertEqual(try ledger.days(from: today, to: today.addingTimeInterval(86_400)).count, 2)
        XCTAssertEqual(try ledger.days(from: today, to: today.addingTimeInterval(86_400), agentID: bob).count, 1)
    }

    /// A Hub plan's token limit counts input and output, cache writes included, of one person's bots;
    /// cache reads and samples from before owners were kept do not count.
    func testSpendingCountsNewTokensOfOnePersonsBotsAfterAStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.sqlite")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let ada = UUID(), grace = UUID(), bot = UUID()
        func sample(_ owner: UUID?, at seconds: TimeInterval, input: Int) -> UsageSample {
            UsageSample(date: start.addingTimeInterval(seconds), agentID: bot, agentName: "Kai", harness: "codex", model: "gpt-5",
                        tokens: UsageTokens(input: input, output: 20, cacheRead: 5_000, cacheWrite: 3, reasoning: 7),
                        costUSD: nil, owner: owner)
        }
        do {
            let ledger = try UsageLedger(url: url)
            try ledger.record(sample(ada, at: 0, input: 1))
            try ledger.record(sample(ada, at: 20, input: 200))
            try ledger.record(sample(ada, at: 10, input: 100))
            try ledger.record(sample(grace, at: 15, input: 1_000))
            try ledger.record(sample(nil, at: 30, input: 10_000))
        }
        let ledger = try UsageLedger(url: url)
        XCTAssertEqual(try ledger.spending(owner: ada, after: start), [
            UsageSpend(date: start.addingTimeInterval(10), tokens: 123),
            UsageSpend(date: start.addingTimeInterval(20), tokens: 223)
        ])
        XCTAssertEqual(try ledger.spending(owner: grace, after: start).map(\.tokens), [1_023])
        XCTAssertEqual(try ledger.spending(owner: UUID(), after: start), [])
    }

    /// The Hub's Usage window groups by person, so a bot's day keeps whose it was apart.
    func testDaysKeepEachOwnerApart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try UsageLedger(url: root.appendingPathComponent("usage.sqlite"))
        let today = Calendar.current.startOfDay(for: Date())
        let ada = UUID(), bot = UUID()
        for (owner, input) in [(ada, 1), (ada, 2), (nil, 40)] as [(UUID?, Int)] {
            try ledger.record(UsageSample(date: today.addingTimeInterval(3600), agentID: bot, agentName: "Kai", harness: "codex",
                                          model: "gpt-5", tokens: UsageTokens(input: input), costUSD: nil, owner: owner))
        }
        let days = try ledger.days(from: today, to: today.addingTimeInterval(86_400))
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.first { $0.owner == ada }?.tokens.input, 3)
        XCTAssertEqual(days.first { $0.owner == nil }?.tokens.input, 40)
    }

    func testRecordedTotalsSumOneSessionPerModelInHistoriesFromBeforeSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("usage.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE usage (
                time REAL NOT NULL, agent_id TEXT NOT NULL, agent_name TEXT NOT NULL,
                harness TEXT NOT NULL, model TEXT NOT NULL,
                input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL,
                cache_write INTEGER NOT NULL, reasoning INTEGER NOT NULL, cost_usd REAL);
            INSERT INTO usage VALUES (0, '\(UUID().uuidString)', 'A', 'claude-code', 'opus', 100, 100, 0, 0, 0, 9);
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let ledger = try UsageLedger(url: url), agent = UUID()
        func record(_ session: String?, _ model: String, _ output: Int, _ cost: Double?) throws {
            try ledger.record(UsageSample(date: Date(), agentID: agent, agentName: "A", harness: "claude-code", model: model,
                tokens: UsageTokens(input: 1, output: output, reasoning: 1), costUSD: cost, session: session))
        }
        try record("s", "opus", 10, 0.5)
        try record("s", "opus", 20, 0.25)
        try record("s", "haiku", 5, nil)
        try record("other", "opus", 99, 1)
        try record(nil, "opus", 99, 1)
        XCTAssertEqual(try ledger.recorded(session: "s"), [
            "opus": UsageTotal(tokens: UsageTokens(input: 2, output: 30, reasoning: 2), costUSD: 0.75),
            "haiku": UsageTotal(tokens: UsageTokens(input: 1, output: 5, reasoning: 1), costUSD: 0)])
        XCTAssertEqual(try ledger.days(from: Date(timeIntervalSince1970: 0), to: Date().addingTimeInterval(60)).count, 3)
    }
}
