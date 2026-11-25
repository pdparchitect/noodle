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
    /// What the champion put in scope, one rule per line as `MissionScope.parse` writes them; none until set.
    public var scope: [String] {
        get { scopeRules ?? [] }
        set { scopeRules = newValue.isEmpty ? nil : newValue }
    }
    private var scopeRules: [String]?
    /// Services the champion opened for the Mission's computers beyond its scope, such as lookup sites; never targets,
    /// so its agents are not told which.
    public var exceptions: [String] {
        get { exceptionRules ?? [] }
        set { exceptionRules = newValue.isEmpty ? nil : newValue }
    }
    private var exceptionRules: [String]?

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

/// One line of a Mission's scope: a domain, every subdomain of one, an address or a network, which `deny`
/// in front takes out of scope.
public struct ScopeRule: Hashable, Sendable {
    public enum Target: Hashable, Sendable {
        case host(String)
        /// `*.target.com`: every name under it, but not target.com itself.
        case subdomains(of: String)
        case address(String)
        case network(String, prefix: Int)

        public var text: String {
            switch self {
            case .host(let name): name
            case .subdomains(let name): "*." + name
            case .address(let address): address
            case .network(let address, let prefix): "\(address)/\(prefix)"
            }
        }
    }

    public let target: Target
    public let isExcluded: Bool

    public init(_ line: String) throws {
        var words = line.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        isExcluded = words.first == "deny"
        if isExcluded { words.removeFirst() }
        guard words.count == 1, let target = Self.target(words[0]) else {
            throw CaseError("“\(line.trimmingCharacters(in: .whitespaces))” is not a domain, address or network.")
        }
        self.target = target
    }

    /// The rule as it is kept and shown.
    public var line: String { (isExcluded ? "deny " : "") + target.text }

    private static func target(_ word: String) -> Target? {
        if let address = address(word) { return .address(address) }
        if let slash = word.firstIndex(of: "/") {
            guard let address = address(String(word[..<slash])), let prefix = Int(word[word.index(after: slash)...]),
                  prefix >= 0, prefix <= (address.contains(":") ? 128 : 32) else { return nil }
            return .network(address, prefix: prefix)
        }
        if word.hasPrefix("*.") { return host(String(word.dropFirst(2))).map { .subdomains(of: $0) } }
        return host(word).map { .host($0) }
    }

    /// An IPv4 or IPv6 address in its usual short form, or nil.
    private static func address(_ text: String) -> String? {
        for family in [AF_INET, AF_INET6] {
            var bytes = [UInt8](repeating: 0, count: 16)
            guard inet_pton(family, text, &bytes) == 1 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(family, bytes, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return nil
    }

    /// A host name of letters, digits and hyphens, not all digits (so a mistyped address is not taken for one).
    private static func host(_ text: String) -> String? {
        let name = text.hasSuffix(".") ? String(text.dropLast()) : text
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !name.isEmpty, name.count <= 253, !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        for label in labels {
            guard (1...63).contains(label.count), label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        }
        return name
    }
}

/// A Mission's scope as the champion writes it and as its agents are told it.
public enum MissionScope {
    /// One rule per line, blank lines skipped and repeats dropped; throws naming the first line that is not a rule.
    public static func parse(_ text: String) throws -> [String] {
        var rules: [String] = []
        for (index, line) in text.components(separatedBy: .newlines).enumerated()
        where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            do {
                let rule = try ScopeRule(line).line
                if !rules.contains(rule) { rules.append(rule) }
            } catch { throw CaseError("Line \(index + 1): \(error.localizedDescription)") }
        }
        return rules
    }

    /// As `parse`, for services opened beyond the scope: they only open, so a deny line belongs in the scope.
    public static func parseExceptions(_ text: String) throws -> [String] {
        let rules = try parse(text)
        if let denied = rules.first(where: { $0.hasPrefix("deny ") }),
           let line = text.components(separatedBy: .newlines).firstIndex(where: { (try? ScopeRule($0).line) == denied }) {
            throw CaseError("Line \(line + 1): Opened services cannot deny; put “\(denied)” in the scope.")
        }
        return rules
    }

    /// What the agents are told about services opened beyond the scope: that there are some, never which.
    static let servicesNote = "Some services outside the scope can also be reached from this Mission's computers, for lookups. They are never targets."

    /// What the agents read: what is in scope, then what is taken out of it; nil while none is set.
    public static func agentText(_ scope: [String]) -> String? {
        let rules = scope.compactMap { try? ScopeRule($0) }
        let included = rules.filter { !$0.isExcluded }.map { "- " + $0.target.text }
        let excluded = rules.filter(\.isExcluded).map { "- " + $0.target.text }
        let sections = [included.isEmpty ? nil : (["In scope, set by the champion:"] + included).joined(separator: "\n"),
                        excluded.isEmpty ? nil : (["Out of scope, even where an in-scope rule covers it:"] + excluded).joined(separator: "\n")]
        let text = sections.compactMap { $0 }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    /// The Mission group's description, which every member is told: the objective, then the scope.
    public static func groupDescription(objective: String, scope: [String], exceptions: [String] = []) -> String {
        [objective, agentText(scope) ?? "", exceptions.isEmpty ? "" : servicesNote].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
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
