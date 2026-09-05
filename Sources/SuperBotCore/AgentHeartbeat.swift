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
            isEnabled: defaults.object(forKey: "SuperBot.heartbeat.enabled") as? Bool ?? true,
            intervalMinutes: defaults.object(forKey: "SuperBot.heartbeat.minutes") as? Int ?? 30,
            disabledAgentIDs: Set((defaults.stringArray(forKey: "SuperBot.heartbeat.disabledAgents") ?? [])
                .compactMap(UUID.init(uuidString:)))
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isEnabled, forKey: "SuperBot.heartbeat.enabled")
        defaults.set(intervalMinutes, forKey: "SuperBot.heartbeat.minutes")
        defaults.set(disabledAgentIDs.map(\.uuidString).sorted(), forKey: "SuperBot.heartbeat.disabledAgents")
    }
}

/// A clock-injected inactivity policy. Checking the deadline never counts as activity.
/// One overdue heartbeat is consumed, even after a long sleep; there is no catch-up burst.
public struct AgentHeartbeatScheduler: Sendable {
    public private(set) var configuration: AgentHeartbeatConfiguration
    public private(set) var lastActivity: [UUID: Date] = [:]

    public init(configuration: AgentHeartbeatConfiguration = .init()) {
        self.configuration = configuration
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

    public mutating func takeDueHeartbeats(readyAgentIDs: Set<UUID>, at date: Date) -> [UUID] {
        let due = readyAgentIDs.filter { id in
            guard configuration.isEnabled(for: id), let last = lastActivity[id] else { return false }
            return date.timeIntervalSince(last) >= configuration.interval
        }.sorted { $0.uuidString < $1.uuidString }
        for id in due { lastActivity[id] = date }
        return due
    }
}

public enum AgentWakeReason: String, Sendable {
    case inboxChanged = "inbox-changed"
    case heartbeat

    public var eventText: String { "<superbot-event type=\"\(rawValue)\" />" }

    public static let heartbeatInstructions = """
    A `heartbeat` event is an inactivity wake-up, not a user message. First check Messenger once for unread messages and prioritize them. If the inbox is empty, review your existing Backstory, memory.md, and previously assigned work for a useful authorized follow-up. A heartbeat does not authorize new projects, broader access, destructive operations, publishing, or other external actions. If nothing needs doing, finish silently; never send a heartbeat acknowledgement or invent work to fill the interval. Send meaningful progress, results, or a required question through Messenger to the relevant conversation only when useful.
    """
}
