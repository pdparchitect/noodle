import Foundation

/// How many tokens may be used in any period of the same length up to now: a rolling window, so
/// tokens stop counting once they are older than the period.
public struct TokenLimit: Codable, Hashable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case hours, days, weeks, months

        /// A month is 30 days, so every period is as long as the last.
        var seconds: TimeInterval {
            switch self {
            case .hours: 3600
            case .days: 86_400
            case .weeks: 7 * 86_400
            case .months: 30 * 86_400
            }
        }

        /// "hour" or "hours".
        public func name(count: Int) -> String { count == 1 ? String(rawValue.dropLast()) : rawValue }
    }

    public var tokens: Int
    /// How many units the period lasts.
    public var length: Int
    public var unit: Unit

    public init(tokens: Int, length: Int = 1, unit: Unit = .weeks) {
        self.tokens = max(1, tokens)
        self.length = max(1, length)
        self.unit = unit
    }

    public var period: TimeInterval { Double(length) * unit.seconds }

    /// What follows "per": "7 days", "month".
    public var periodName: String { length == 1 ? unit.name(count: 1) : "\(length) \(unit.name(count: length))" }

    /// When the oldest tokens leaving the period take the rest below the limit; nil while already below it.
    /// `spending` is oldest first and holds only what the period counts.
    public func resumption(of spending: [UsageSpend]) -> Date? {
        var total = spending.reduce(0) { $0 + $1.tokens }
        guard total >= tokens else { return nil }
        for spend in spending {
            total -= spend.tokens
            if total < tokens { return spend.date.addingTimeInterval(period) }
        }
        return nil
    }
}

/// The tokens one bot may use, counted as a Hub plan counts each person's. Kept in its agent.json,
/// outside the workspace, so the bot cannot change it.
public struct BotBudget: Codable, Hashable, Sendable {
    public var limit: TokenLimit
    /// Tokens used before this no longer count, once someone reset the budget.
    public var resetAt: Date?

    public init(limit: TokenLimit, resetAt: Date? = nil) {
        self.limit = limit
        self.resetAt = resetAt
    }

    /// The earliest moment whose tokens count now.
    public func start(now: Date) -> Date {
        max(now.addingTimeInterval(-limit.period), resetAt ?? .distantPast)
    }
}
