import Foundation

public struct AgentHeartbeatConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let intervalMinutes: Int
    public let disabledAgentIDs: Set<UUID>

    public init(isEnabled: Bool = true, intervalMinutes: Int = 30, disabledAgentIDs: Set<UUID> = []) {
        self.isEnabled = isEnabled
        self.intervalMinutes = min(1_440, max(1, intervalMinutes))
        self.disabledAgentIDs = disabledAgentIDs
    }

    public var interval: TimeInterval { TimeInterval(intervalMinutes) * 60 }

    public func isEnabled(for agentID: UUID) -> Bool {
        isEnabled && !disabledAgentIDs.contains(agentID)
    }

    public static func load(from defaults: UserDefaults) -> Self {
        Self(
            isEnabled: defaults.object(forKey: "Noodle.heartbeat.enabled") as? Bool ?? true,
            intervalMinutes: defaults.object(forKey: "Noodle.heartbeat.minutes") as? Int ?? 30,
            disabledAgentIDs: Set((defaults.stringArray(forKey: "Noodle.heartbeat.disabledAgents") ?? [])
                .compactMap(UUID.init(uuidString:)))
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: "Noodle.heartbeat.enabled")
        defaults.set(intervalMinutes, forKey: "Noodle.heartbeat.minutes")
        defaults.set(disabledAgentIDs.map(\.uuidString).sorted(), forKey: "Noodle.heartbeat.disabledAgents")
    }
}

/// A clock-injected inactivity policy. Checking the deadline never counts as activity.
/// One overdue heartbeat is consumed, even after a long sleep; there is no catch-up burst.
public struct AgentHeartbeatScheduler: Sendable {
    /// Undelivered inbox work does not wait out the inactivity floor: a bot
    /// whose Messenger inbox still holds unread messages this old is due every
    /// grace period instead of every configured interval, so a wake that failed
    /// to deliver the message is retried without a person's nudge.
    public static let unreadWakeGrace: TimeInterval = 300

    public private(set) var configuration: AgentHeartbeatConfiguration
    public private(set) var lastActivity: [UUID: Date] = [:]

    public init(
        configuration: AgentHeartbeatConfiguration = .init(),
        lastActivity: [UUID: Date] = [:]
    ) {
        self.configuration = configuration
        self.lastActivity = lastActivity
    }

    /// Begin tracking a bot without treating process startup as new activity.
    /// Existing persisted activity always wins.
    @discardableResult
    public mutating func register(_ agentID: UUID, at date: Date) -> Bool {
        guard lastActivity[agentID] == nil else { return false }
        lastActivity[agentID] = date
        return true
    }

    public mutating func recordActivity(for agentID: UUID, at date: Date) {
        lastActivity[agentID] = date
    }

    public mutating func remove(_ agentID: UUID) { lastActivity.removeValue(forKey: agentID) }

    public mutating func configure(_ updated: AgentHeartbeatConfiguration, at date: Date) {
        guard configuration != updated else { return }
        if configuration.isEnabled != updated.isEnabled || configuration.intervalMinutes != updated.intervalMinutes {
            lastActivity = lastActivity.mapValues { _ in date }
        } else {
            for id in configuration.disabledAgentIDs.symmetricDifference(updated.disabledAgentIDs)
                where lastActivity[id] != nil {
                lastActivity[id] = date
            }
        }
        configuration = updated
    }

    /// Due bots, oldest-name first. A bot with unread inbox messages is due on
    /// the grace period rather than the configured interval — undelivered work
    /// does not wait out the inactivity floor. The wake itself still counts as
    /// activity (a turn is another chance to read the inbox), so an inbox a bot
    /// refuses to consume is re-offered at the grace pace, never in a burst.
    public mutating func takeDueHeartbeats(readyAgentIDs: Set<UUID>, at date: Date, unreadAgentIDs: Set<UUID> = []) -> [UUID] {
        let due = readyAgentIDs.filter { id in
            guard configuration.isEnabled(for: id), let last = lastActivity[id] else { return false }
            let floor = unreadAgentIDs.contains(id) ? min(configuration.interval, Self.unreadWakeGrace) : configuration.interval
            return date.timeIntervalSince(last) >= floor
        }.sorted { $0.uuidString < $1.uuidString }
        for id in due { lastActivity[id] = date }
        return due
    }
}

public enum AgentWakeReason: String, CaseIterable, Sendable {
    case inboxChanged = "inbox-changed"
    case heartbeat
    case runtimeRecovered = "runtime-recovered"

    /// Names the Messenger skill so a bot whose harness never surfaced it still knows where to look.
    public var eventText: String { "<noodle-event type=\"\(rawValue)\" skill=\".agents/skills/messenger/SKILL.md\" />" }

    public static var heartbeatInstructions: String { AgentWakeReason.heartbeat.reference.guidance }

    public static var recoveryInstructions: String { AgentWakeReason.runtimeRecovered.reference.guidance }
}
