import Foundation
import NoodleCore
import NoodleRuntime
import XCTest
@testable import Noodle

/// A bot's spending budget stops it once used up, until its tokens leave the period or someone resets it.
@MainActor final class BotBudgetTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { await MainActor.run { f.cleanUp() } }
        f.store.budgets.now = { [unowned self] in self.now }
        return f
    }

    /// What the runtime reports for one model call of Ada's.
    private func use(_ f: StoreFixture, input: Int, cacheRead: Int = 0, at seconds: TimeInterval) {
        f.runtime.runtime.onUsage?(UsageSample(date: start.addingTimeInterval(seconds), agentID: f.a.id, agentName: "Ada",
                                               harness: "codex", model: "gpt-5", tokens: UsageTokens(input: input, cacheRead: cacheRead),
                                               costUSD: nil))
    }

    private func processes(_ f: StoreFixture) -> [RuntimeProcessFixture] {
        f.runtime.factory.processes.filter { $0.configuration.id == f.a.id }
    }

    func testABotFinishesItsTurnThenWaitsUntilReset() throws {
        let f = try fixture()
        f.store.startAgents()
        f.store.setBudget(TokenLimit(tokens: 1_000, length: 1, unit: .days), for: f.a)
        XCTAssertEqual(try f.repository.loadAgentBudget(f.a)?.limit.tokens, 1_000, "Kept in agent.json")
        let turn = try XCTUnwrap(processes(f).last)
        turn.transition(.working)

        // Cache reads repeat input already counted; other bots' tokens are theirs.
        use(f, input: 900, cacheRead: 50_000, at: 0)
        f.runtime.runtime.onUsage?(UsageSample(date: start, agentID: f.b.id, agentName: "Grace", harness: "codex",
                                               model: "gpt-5", tokens: UsageTokens(input: 5_000), costUSD: nil))
        XCTAssertEqual(f.store.budgets.used(by: f.a.id), 900)
        XCTAssertNil(f.store.budgets.holds[f.a.id])
        now = start.addingTimeInterval(60)
        use(f, input: 100, at: 60)
        XCTAssertEqual(f.store.budgets.holds[f.a.id], start.addingTimeInterval(86_400))
        XCTAssertNil(f.store.budgets.holds[f.b.id], "Grace has no budget")

        // The turn under way goes on; once it ends, the bot stops before taking another.
        XCTAssertEqual(turn.stops, 0)
        turn.transition(.ready)
        XCTAssertEqual(turn.stops, 1)
        let held = f.runtime.runtime.snapshot(for: f.a.id)
        XCTAssertEqual(held.phase, .offline)
        XCTAssertTrue(held.detail.hasPrefix("Spending budget reached."), held.detail)
        f.runtime.runtime.reconcile(agents: f.store.agents, repository: f.repository, immediately: true)
        XCTAssertEqual(processes(f).count, 1, "No new turn starts while it waits")

        // Reset lets it go at once and counts from then on.
        now = start.addingTimeInterval(120)
        f.store.resetBudget(for: f.a)
        XCTAssertNil(f.store.budgets.holds[f.a.id])
        XCTAssertEqual(f.store.budgets.used(by: f.a.id), 0)
        XCTAssertEqual(processes(f).count, 2)
        XCTAssertNotNil(try f.repository.loadAgentBudget(f.a)?.resetAt, "The reset outlives Noodle quitting")
    }

    func testTheBotContinuesOnItsOwnOnceItsTokensLeaveThePeriod() throws {
        let f = try fixture()
        f.store.startAgents()
        use(f, input: 500, at: 0)
        XCTAssertNil(f.store.budgets.used(by: f.a.id), "No budget by default")

        // A budget applies straight away, to tokens already used in the period too.
        f.store.setBudget(TokenLimit(tokens: 400, length: 2, unit: .hours), for: f.a)
        XCTAssertEqual(f.store.budgets.holds[f.a.id], start.addingTimeInterval(2 * 3600))
        XCTAssertEqual(f.runtime.runtime.snapshot(for: f.a.id).phase, .offline, "An idle bot stops at once")

        now = start.addingTimeInterval(2 * 3600 - 1)
        f.store.budgets.checkExpired()
        XCTAssertNotNil(f.store.budgets.holds[f.a.id])
        now = start.addingTimeInterval(2 * 3600)
        f.store.budgets.checkExpired()
        XCTAssertNil(f.store.budgets.holds[f.a.id])
        XCTAssertEqual(processes(f).count, 2)

        // Raising or removing the budget lets it go too.
        use(f, input: 500, at: 2 * 3600)
        XCTAssertNotNil(f.store.budgets.holds[f.a.id])
        f.store.setBudget(nil, for: f.a)
        XCTAssertNil(f.store.budgets.holds[f.a.id])
        XCTAssertNil(try f.repository.loadAgentBudget(f.a))
    }

    func testABudgetSavedEarlierHoldsTheBotWhenNoodleOpens() throws {
        let f = try fixture()
        try f.repository.updateAgentBudget(f.a, budget: BotBudget(limit: TokenLimit(tokens: 10, length: 1, unit: .weeks)))
        f.store.usage.record(UsageSample(date: Date(), agentID: f.a.id, agentName: "Ada", harness: "codex", model: "gpt-5",
                                         tokens: UsageTokens(input: 50), costUSD: nil))
        f.store.budgets.now = Date.init
        f.store.reload()
        f.store.startAgents()
        XCTAssertNotNil(f.store.budgets.holds[f.a.id])
        XCTAssertTrue(processes(f).isEmpty, "A bot out of budget does not start")
        XCTAssertFalse(f.runtime.factory.processes.filter { $0.configuration.id == f.b.id }.isEmpty)
    }
}
