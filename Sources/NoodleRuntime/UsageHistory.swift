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

    public init(url: URL) {
        ledger = try? UsageLedger(url: url)
    }

    public func record(_ sample: UsageSample) {
        guard (try? ledger?.record(sample)) != nil else { return }
        revision += 1
    }

    public func days(from start: Date, to end: Date, agentID: UUID?) -> [UsageDay] {
        (try? ledger?.days(from: start, to: end, agentID: agentID)) ?? []
    }
}
