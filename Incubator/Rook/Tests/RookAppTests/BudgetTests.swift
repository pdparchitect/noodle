import NoodleCore
import NoodleRuntime
import XCTest

/// An agent's spending budget, as in Noodle: kept with the agent, counted from its recorded usage, and holding it
/// once spent until reset.
@MainActor final class BudgetTests: XCTestCase {
    func testABudgetIsKeptCountsUsageHoldsWhenSpentAndResets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RookBudget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = RookModel(root: root, messenger: nil, isScripted: true)
        model.start()
        let agent = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil)
        model.setBudget(TokenLimit(tokens: 100, length: 1, unit: .days), for: agent)
        XCTAssertEqual(model.budgets.budgets[agent.id]?.limit.tokens, 100)
        try XCTUnwrap(model.runtime.onUsage)(UsageSample(date: Date(), agentID: agent.id, agentName: "Avery", harness: "codex",
                                                         model: "gpt-5", tokens: UsageTokens(input: 150), costUSD: nil))
        XCTAssertNotNil(model.budgets.holds[agent.id], "Spent, it waits")
        model.resetBudget(for: agent)
        XCTAssertNil(model.budgets.holds[agent.id])

        let reopened = RookModel(root: root, messenger: nil, isScripted: true)
        reopened.start()
        XCTAssertEqual(reopened.budgets.budgets[agent.id]?.limit.tokens, 100, "Kept with the agent")
    }
}
