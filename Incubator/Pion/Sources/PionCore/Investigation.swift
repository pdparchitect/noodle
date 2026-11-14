import Foundation

/// The primary object in Pion: a group conversation with an objective, a status and a case record.
/// Its identifier is the group conversation's, so the transcript and the case always match.
public struct Investigation: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, CaseIterable, Sendable {
        case open, triaging, contained, closed

        public var title: String {
            switch self {
            case .open: "Open"
            case .triaging: "Triaging"
            case .contained: "Contained"
            case .closed: "Closed"
            }
        }
    }

    /// What closing an Investigation concluded.
    public enum Outcome: String, Codable, CaseIterable, Sendable {
        case falsePositive = "false-positive", resolved, handedOff = "handed-off"

        public var title: String {
            switch self {
            case .falsePositive: "False Positive"
            case .resolved: "Resolved"
            case .handedOff: "Handed Off"
            }
        }
    }

    public enum Severity: String, Codable, CaseIterable, Comparable, Sendable {
        case low, medium, high, critical

        public var title: String { rawValue.capitalized }
        private var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    public let id: UUID
    /// Shown as INV-0007; numbers are never reused.
    public let number: Int
    public var title: String
    public var objective: String
    public var status: Status
    /// Nil until the lead agent has assessed it; only the lead sets it.
    public var severity: Severity?
    public var outcome: Outcome?
    /// What the champion wrote when closing.
    public var closingNote: String?
    /// The person who owns it and closes it.
    public var champion: String
    public var leadAgentID: UUID?
    /// Where it came from, such as an alert's name; nil when opened by hand.
    public var source: String?
    public let openedAt: Date
    public var updatedAt: Date
    public var closedAt: Date?

    public init(id: UUID, number: Int, title: String, objective: String, severity: Severity? = nil,
                champion: String, leadAgentID: UUID?, source: String? = nil,
                status: Status = .open, openedAt: Date = Date()) {
        self.id = id
        self.number = number
        self.title = title
        self.objective = objective
        self.status = status
        self.severity = severity
        self.champion = champion
        self.leadAgentID = leadAgentID
        self.source = source
        self.openedAt = openedAt
        updatedAt = openedAt
    }

    public var reference: String { String(format: "INV-%04d", number) }
    public var isClosed: Bool { status == .closed }
    /// What its severity reads as, "Unassessed" until the lead sets it.
    public var severityTitle: String { severity?.title ?? "Unassessed" }

}
