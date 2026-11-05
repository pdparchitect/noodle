import Foundation
import NoodleCore
import Observation

/// The usage ledger the Usage window reads, fed by the runtime's `onUsage`.
@MainActor
@Observable
public final class UsageHistory {
    public private(set) var revision = 0
    /// Set before opening the window to show one bot.
    public var agentFilter: UUID?
    @ObservationIgnored private let ledger: UsageLedger?
    @ObservationIgnored private(set) var queries = 0

    public init(url: URL) {
        ledger = try? UsageLedger(url: url)
    }

    public func record(_ sample: UsageSample) {
        guard (try? ledger?.record(sample)) != nil else { return }
        revision += 1
    }

    public func recorded(session: String) -> [String: UsageTotal] {
        (try? ledger?.recorded(session: session)) ?? [:]
    }

    /// What one person's bots used after `start`, oldest first, as a Hub plan's token limit counts it.
    public func spending(owner: UUID, after start: Date) -> [UsageSpend] {
        (try? ledger?.spending(owner: owner, after: start)) ?? []
    }

    /// What one bot used after `start`, oldest first, as its spending budget counts it.
    public func spending(agent: UUID, after start: Date) -> [UsageSpend] {
        (try? ledger?.spending(agent: agent, after: start)) ?? []
    }

    public func days(from start: Date, to end: Date, agentID: UUID?) -> [UsageDay] {
        queries += 1
        return (try? ledger?.days(from: start, to: end, agentID: agentID)) ?? []
    }
}
