import Foundation

/// The primary object in Rook: a group conversation with an objective, a status and a case record.
/// Its identifier is the group conversation's, so the transcript and the case always match.
public struct Mission: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, CaseIterable, Sendable {
        case open, active, proven, closed

        public var title: String {
            switch self {
            case .open: "Open"
            case .active: "Active"
            case .proven: "Proven"
            case .closed: "Closed"
            }
        }
    }

    /// What closing a Mission concluded.
    public enum Outcome: String, Codable, CaseIterable, Sendable {
        case demonstrated, notExploitable = "not-exploitable", reported

        public var title: String {
            switch self {
            case .demonstrated: "Demonstrated"
            case .notExploitable: "Not Exploitable"
            case .reported: "Reported"
            }
        }
    }

    public enum Severity: String, Codable, CaseIterable, Comparable, Sendable {
        case low, medium, high, critical

        public var title: String { rawValue.capitalized }
        private var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    /// Unassessed first, then low to critical, for sorting.
    public var severityRank: Int { severity.map { Severity.allCases.firstIndex(of: $0)! + 1 } ?? 0 }

    public let id: UUID
    /// Shown as M-0007; numbers are never reused.
    public let number: Int
    public var title: String
    public var objective: String
    public var status: Status
    /// Nil until the group's lead has assessed it; only the lead sets it.
    public var severity: Severity?
    public var outcome: Outcome?
    /// What the champion wrote when closing.
    public var closingNote: String?
    /// The person who owns it and closes it.
    public var champion: String
    /// Where it came from, such as an alert's name; nil when opened by hand.
    public var source: String?
    public let openedAt: Date
    public var updatedAt: Date
    public var closedAt: Date?
    /// The computers the champion assigned, in the order assigned. A computer may serve several Missions.
    public var computers: [UUID] {
        get { computerIDs ?? [] }
        set { computerIDs = newValue.isEmpty ? nil : newValue }
    }
    private var computerIDs: [UUID]?

    public init(id: UUID, number: Int, title: String, objective: String, severity: Severity? = nil,
                champion: String, source: String? = nil,
                status: Status = .open, openedAt: Date = Date()) {
        self.id = id
        self.number = number
        self.title = title
        self.objective = objective
        self.status = status
        self.severity = severity
        self.champion = champion
        self.source = source
        self.openedAt = openedAt
        updatedAt = openedAt
    }

    public var reference: String { String(format: "M-%04d", number) }
    public var isClosed: Bool { status == .closed }
    /// What its severity reads as, "Unassessed" until the lead sets it.
    public var severityTitle: String { severity?.title ?? "Unassessed" }

}

/// Which computers each agent may use: those of every Mission it is in that is not closed.
public enum MissionComputers {
    /// The tool kind Noodle's computer tool is assigned under.
    public static let kind = "computer"

    /// `members` gives a Mission's agents, from its group conversation.
    public static func assignments(missions: [Mission], members: (UUID) -> [UUID]) -> [UUID: Set<String>] {
        var access: [UUID: Set<String>] = [:]
        for mission in missions where !mission.isClosed && !mission.computers.isEmpty {
            for agent in members(mission.id) { access[agent, default: []].formUnion(mission.computers.map(\.uuidString)) }
        }
        return access
    }
}
