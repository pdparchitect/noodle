import Foundation

/// The primary object in Pion: a group conversation with a scope, a status and a case record.
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
    /// The entities and systems the Investigation may touch. Only the champion changes it.
    public var scope: [String]
    public var status: Status
    public var severity: Severity
    public var outcome: Outcome?
    /// What the champion wrote when closing.
    public var closingNote: String?
    /// The person who owns it: sets the scope, decides approvals and closes it.
    public var champion: String
    public var leadAgentID: UUID?
    public var playbookID: String?
    /// Where it came from, such as an alert's name; nil when opened by hand.
    public var source: String?
    public let openedAt: Date
    public var updatedAt: Date
    public var closedAt: Date?

    public init(id: UUID, number: Int, title: String, objective: String, scope: [String], severity: Severity,
                champion: String, leadAgentID: UUID?, playbookID: String?, source: String? = nil,
                status: Status = .open, openedAt: Date = Date()) {
        self.id = id
        self.number = number
        self.title = title
        self.objective = objective
        self.scope = scope
        self.status = status
        self.severity = severity
        self.champion = champion
        self.leadAgentID = leadAgentID
        self.playbookID = playbookID
        self.source = source
        self.openedAt = openedAt
        updatedAt = openedAt
    }

    public var reference: String { String(format: "INV-%04d", number) }
    public var isClosed: Bool { status == .closed }

    /// Whether `target` is inside the scope. An entry starting with `*.` covers every name ending in what follows.
    public func covers(_ target: String) -> Bool {
        let name = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return false }
        return scope.contains { entry in
            let entry = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if entry.hasPrefix("*."), entry.count > 2 { return name.hasSuffix(String(entry.dropFirst(1))) }
            return entry == name
        }
    }

    /// Scope typed as one entry per line or separated by commas.
    public static func scope(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
