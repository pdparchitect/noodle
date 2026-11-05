import Foundation
import NoodleCore
import Observation

/// Which bots used up their spending budget, and until when. A bot out of budget takes no new turn
/// until enough of its tokens are older than the budget's period, or someone resets it; a turn under way finishes.
@MainActor @Observable public final class BotBudgets {
    public private(set) var budgets: [UUID: BotBudget] = [:]
    /// When each bot out of budget can continue on its own.
    public private(set) var holds: [UUID: Date] = [:]
    /// Runs when a bot runs out of budget or can continue.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// The time now; tests set their own.
    @ObservationIgnored public var now: () -> Date = Date.init
    @ObservationIgnored private let usage: UsageHistory

    public init(usage: UsageHistory) {
        self.usage = usage
    }

    /// Every bot's budget, as their agent.json files keep them; bots missing have none.
    public func replace(_ budgets: [UUID: BotBudget]) {
        guard budgets != self.budgets else { return }
        self.budgets = budgets
        check()
    }

    public func set(_ budget: BotBudget?, for agent: UUID) {
        guard budgets[agent] != budget else { return }
        budgets[agent] = budget
        check()
    }

    /// The tokens the bot used that its budget counts now; nil when it has none.
    public func used(by agent: UUID) -> Int? {
        guard let budget = budgets[agent] else { return nil }
        return spending(of: agent, budget).reduce(0) { $0 + $1.tokens }
    }

    /// Works out again who is out of budget: after a bot used tokens, or a budget changed or was reset.
    public func check() {
        var held: [UUID: Date] = [:]
        for (agent, budget) in budgets {
            if let until = budget.limit.resumption(of: spending(of: agent, budget)) { held[agent] = until }
        }
        guard held != holds else { return }
        holds = held
        onChange?()
    }

    /// Lets go whichever bot has waited long enough. It only compares dates, so it can run every second.
    public func checkExpired() {
        if holds.values.contains(where: { $0 <= now() }) { check() }
    }

    /// What a bot out of budget shows as its status.
    public static func status(until: Date) -> String {
        "Spending budget reached. Continues \(until.formatted(date: .abbreviated, time: .shortened)) unless reset."
    }

    private func spending(of agent: UUID, _ budget: BotBudget) -> [UsageSpend] {
        usage.spending(agent: agent, after: budget.start(now: now()))
    }
}
