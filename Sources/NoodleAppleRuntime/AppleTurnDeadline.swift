import Foundation

/// A slow multi-step turn may keep working as long as it produces activity.
/// The overall ceiling still bounds a model that keeps making unhelpful calls.
public struct AppleTurnDeadline: Sendable {
    public enum Limit: Sendable, Equatable {
        case idle, total
        public var message: String {
            switch self {
            case .idle: "Apple made no progress for five minutes. Unfinished work is preserved."
            case .total: "Apple exceeded the 30-minute turn limit. Unfinished work is preserved."
            }
        }
    }

    private let started: TimeInterval
    private var activity: TimeInterval
    private let idleLimit: TimeInterval
    private let totalLimit: TimeInterval

    public init(now: TimeInterval, idleLimit: TimeInterval = 300, totalLimit: TimeInterval = 1_800) {
        started = now
        activity = now
        self.idleLimit = max(0, idleLimit)
        self.totalLimit = max(0, totalLimit)
    }

    public mutating func noteActivity(at now: TimeInterval) { activity = max(activity, now) }

    public func exceeded(at now: TimeInterval) -> Limit? {
        if now - started >= totalLimit { return .total }
        if now - activity >= idleLimit { return .idle }
        return nil
    }

    public func remaining(at now: TimeInterval) -> TimeInterval {
        max(0, min(started + totalLimit, activity + idleLimit) - now)
    }
}
