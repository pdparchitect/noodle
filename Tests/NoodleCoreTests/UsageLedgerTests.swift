import Foundation
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
        let bobToday = try XCTUnwrap(days.first { $0.agentID == bob })
        XCTAssertNil(bobToday.costUSD)
        XCTAssertEqual(bobToday.tokens.total, 161)
        XCTAssertEqual(try ledger.days(from: today, to: today.addingTimeInterval(86_400)).count, 2)
        XCTAssertEqual(try ledger.days(from: today, to: today.addingTimeInterval(86_400), agentID: bob).count, 1)
    }
}
