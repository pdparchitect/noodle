import Foundation
import NoodleCore
import NoodleRuntime
import XCTest
@testable import Noodle

/// A bot suspended on this Mac stays listed but takes no new turn until its time runs out or it is unsuspended.
@MainActor final class BotSuspensionTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture()
        addTeardownBlock { await MainActor.run { f.cleanUp() } }
        return f
    }

    private func processes(_ f: StoreFixture) -> [RuntimeProcessFixture] {
        f.runtime.factory.processes.filter { $0.configuration.id == f.a.id }
    }

    func testASuspendedBotFinishesItsTurnStaysListedAndContinuesWhenUnsuspended() throws {
        let f = try fixture()
        f.store.startAgents()
        let turn = try XCTUnwrap(processes(f).last)
        turn.transition(.working)

        f.store.setSuspended(until: Date().addingTimeInterval(3600), agentID: f.a.id)
        XCTAssertEqual(turn.stops, 0, "The turn under way goes on")
        turn.transition(.ready)
        XCTAssertEqual(turn.stops, 1)
        let held = f.runtime.runtime.snapshot(for: f.a.id)
        XCTAssertEqual(held.phase, .offline, "Shown stopped, so its picture is gray")
        XCTAssertTrue(held.detail.hasPrefix("Suspended until"), held.detail)

        // Still listed, saying until when, and kept in agent.json.
        XCTAssertTrue(f.store.conversations.contains { $0.id == f.directA.id })
        XCTAssertTrue(f.store.pauseSummary(for: f.directA)?.hasPrefix("Suspended until") == true)
        XCTAssertNotNil(try f.repository.loadAgents().first { $0.id == f.a.id }?.suspendedUntil)
        f.runtime.runtime.reconcile(agents: f.store.agents, repository: f.repository, immediately: true)
        XCTAssertEqual(processes(f).count, 1, "No new turn starts while it is suspended")

        f.store.setSuspended(until: nil, agentID: f.a.id)
        XCTAssertNil(f.runtime.runtime.heldAgents[f.a.id])
        XCTAssertEqual(processes(f).count, 2)
        XCTAssertNil(f.store.pauseSummary(for: f.directA))
    }

    func testASuspensionSavedEarlierHoldsTheBotWhenNoodleOpensUntilItRunsOut() throws {
        let f = try fixture()
        try f.repository.setAgentSuspended(until: AgentRecord.indefinitely, agentID: f.a.id)
        try f.repository.setAgentSuspended(until: Date().addingTimeInterval(-1), agentID: f.b.id)
        f.store.reload()
        f.store.startAgents()
        XCTAssertEqual(f.runtime.runtime.heldAgents[f.a.id], "Suspended")
        XCTAssertTrue(processes(f).isEmpty, "A suspended bot does not start")
        XCTAssertNil(f.runtime.runtime.heldAgents[f.b.id], "A suspension that ran out no longer holds")
        XCTAssertFalse(f.runtime.factory.processes.filter { $0.configuration.id == f.b.id }.isEmpty)
    }

    /// Unsuspending a bot that also used up its spending budget leaves it held by the budget.
    func testUnsuspendingLeavesTheBudgetHold() throws {
        let f = try fixture()
        f.store.startAgents()
        f.store.setSuspended(until: AgentRecord.indefinitely, agentID: f.a.id)
        f.store.setBudget(TokenLimit(tokens: 10, length: 1, unit: .days), for: f.a)
        f.runtime.runtime.onUsage?(UsageSample(date: Date(), agentID: f.a.id, agentName: "Ada", harness: "codex",
                                               model: "gpt-5", tokens: UsageTokens(input: 50), costUSD: nil))
        XCTAssertEqual(f.runtime.runtime.heldAgents[f.a.id], "Suspended", "The suspension says so first")
        f.store.setSuspended(until: nil, agentID: f.a.id)
        XCTAssertTrue(f.runtime.runtime.heldAgents[f.a.id]?.hasPrefix("Spending budget reached.") == true)
    }
}
