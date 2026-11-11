import Foundation
import NoodleCore
import NoodleRuntime
import Observation

/// Who used up the tokens their plan allows, and until when. Their bots take no new turn until enough
/// of those tokens are older than the plan's period; a turn under way finishes.
@MainActor @Observable public final class HubTokenLimits {
    /// When each user out of tokens can use their bots again.
    public private(set) var holds: [UUID: Date] = [:]
    /// Runs when someone runs out of tokens or can use their bots again.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// The time now; tests set their own.
    @ObservationIgnored public var now: () -> Date = Date.init
    @ObservationIgnored private let access: HubAccess
    @ObservationIgnored private let usage: UsageHistory
    @ObservationIgnored private var checked = false

    package init(access: HubAccess, usage: UsageHistory) {
        self.access = access
        self.usage = usage
    }

    /// The tokens the user's bots used in their plan's period up to now, and that limit; nil when their plan has none.
    public func used(by user: HubUser) -> (tokens: Int, limit: HubTokenLimit)? {
        guard let limit = access.tokenLimit(for: user) else { return nil }
        return (spending(of: user.id, limit).reduce(0) { $0 + $1.tokens }, limit)
    }

    /// Works out again who is out of tokens: after a bot used some, or a plan or someone's plan changed.
    public func check() {
        var held: [UUID: Date] = [:]
        for user in access.users {
            guard let limit = access.tokenLimit(for: user),
                  let until = Self.resumption(of: spending(of: user.id, limit), limit: limit) else { continue }
            held[user.id] = until
        }
        defer { checked = true }
        guard held != holds else { return }
        // Those held when the Hub opens were noted when they ran out.
        for (id, until) in held where holds[id] == nil && checked {
            guard let user = access.users.first(where: { $0.id == id }) else { continue }
            access.note("Paused \(user.name)’s bots until \(until.formatted(date: .abbreviated, time: .shortened)), "
                        + "as they used the tokens their plan allows", about: [id])
        }
        holds = held
        onChange?()
    }

    /// Lets go whoever has waited long enough. It only compares dates, so it can run every second.
    public func checkExpired() {
        if holds.values.contains(where: { $0 <= now() }) { check() }
    }

    /// Why the user cannot call one of their own bots or have it organize now, or nil when they can.
    public func refusal(for user: HubUser) -> String? {
        guard let until = holds[user.id], let limit = access.tokenLimit(for: user) else { return nil }
        return "You have used the \(limit.tokens.formatted()) tokens your plan allows per \(limit.periodName). "
            + "Your bots can continue \(relative(until))."
    }

    /// Why someone a bot is shared with cannot call it now, or nil when they can.
    public func refusal(forGuestOf bot: String, ownedBy owner: UUID) -> String? {
        guard let until = holds[owner] else { return nil }
        return "\(bot) has used the tokens its owner’s plan allows. It can continue \(relative(until))."
    }

    /// What a held bot shows as its status.
    static func status(until: Date) -> String {
        "Token limit reached. Continues \(until.formatted(date: .abbreviated, time: .shortened))."
    }

    private func relative(_ date: Date) -> String { Self.relative(date, to: now()) }

    /// Relative, as the person's device may be in another time zone: "in 5 hours". Linux's
    /// Foundation has only the format style, which rounds the odd minute differently.
    static func relative(_ date: Date, to now: Date) -> String {
        #if canImport(Darwin)
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
        #else
        date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
        #endif
    }

    private func spending(of user: UUID, _ limit: HubTokenLimit) -> [UsageSpend] {
        usage.spending(owner: user, after: now().addingTimeInterval(-limit.period))
    }

    /// When the oldest tokens leaving the period take the rest below the limit; nil while already below it.
    static func resumption(of spending: [UsageSpend], limit: HubTokenLimit) -> Date? {
        limit.resumption(of: spending)
    }
}
