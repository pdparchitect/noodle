import Foundation

/// Who wrote something into a case: an agent, the champion, or the policy itself.
public enum CaseActor: Codable, Hashable, Sendable {
    case agent(UUID)
    case champion(String)
    case policy

    private enum CodingKeys: String, CodingKey { case agent, champion, policy }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UUID.self, forKey: .agent) { self = .agent(id) }
        else if let name = try container.decodeIfPresent(String.self, forKey: .champion) { self = .champion(name) }
        else { self = .policy }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .agent(let id): try container.encode(id, forKey: .agent)
        case .champion(let name): try container.encode(name, forKey: .champion)
        case .policy: try container.encode(true, forKey: .policy)
        }
    }
}

/// The structured part of an Investigation, written by its agents through the case tool and
/// shown beside the transcript. Every item cites who recorded it and when.
public struct CaseRecord: Codable, Equatable, Sendable {
    public struct Entity: Codable, Identifiable, Hashable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case host, identity, service, indicator, other
            public var title: String { rawValue.capitalized }
            public var symbol: String {
                switch self {
                case .host: "desktopcomputer"
                case .identity: "person.crop.square"
                case .service: "server.rack"
                case .indicator: "scope"
                case .other: "circle.dashed"
                }
            }
        }
        public let id: String
        public var kind: Kind
        public var name: String
        public var detail: String?
        public var firstSeen: Date
        public var lastSeen: Date
        public let recordedBy: CaseActor
    }

    public struct Evidence: Codable, Identifiable, Hashable, Sendable {
        public let id: String
        public var source: String
        /// The query or method used, so someone else can collect it again.
        public var method: String
        public var result: String
        public let collectedAt: Date
        public let recordedBy: CaseActor
    }

    public struct Finding: Codable, Identifiable, Hashable, Sendable {
        public enum Confidence: String, Codable, CaseIterable, Sendable {
            case low, medium, high
            public var title: String { rawValue.capitalized }
        }
        public let id: String
        public var claim: String
        public var evidence: [String]
        public var confidence: Confidence
        public var entities: [String]
        public let recordedAt: Date
        public let recordedBy: CaseActor
    }

    public struct ProposedAction: Codable, Identifiable, Hashable, Sendable {
        public enum State: String, Codable, Sendable {
            /// Waiting for the champion.
            case pending
            /// Approved by the champion or allowed by policy; carried out outside Pion for now.
            case approved
            case denied
            /// The policy never allows it, so nobody was asked.
            case refused
            /// Carried out and verified.
            case done

            public var title: String {
                switch self {
                case .pending: "Needs Approval"
                case .approved: "Approved"
                case .denied: "Denied"
                case .refused: "Refused"
                case .done: "Done"
                }
            }
        }
        public let id: String
        public let operation: String
        public let targets: [String]
        public let rationale: String
        public let expectedEffect: String
        public let undo: String
        public let evidence: [String]
        public let mode: ActionPolicy.Mode
        public var state: State
        /// Why the policy refused it, or what the champion said deciding it.
        public var note: String?
        public let proposedAt: Date
        public let proposedBy: CaseActor
        public var decidedAt: Date?
        public var decidedBy: CaseActor?
    }

    public var entities: [Entity] = []
    public var evidence: [Evidence] = []
    public var findings: [Finding] = []
    public var actions: [ProposedAction] = []

    public init() {}

    public var pendingActions: [ProposedAction] { actions.filter { $0.state == .pending } }

    /// The next identifier with `prefix`, such as A-4 after A-3. Identifiers are never reused.
    static func nextID(_ prefix: String, after existing: [String]) -> String {
        let numbers = existing.compactMap { $0.hasPrefix(prefix + "-") ? Int($0.dropFirst(prefix.count + 1)) : nil }
        return "\(prefix)-\((numbers.max() ?? 0) + 1)"
    }

    /// Records an entity, or refreshes when it was last seen if one of that kind and name is already there.
    @discardableResult
    public mutating func record(entity kind: Entity.Kind, name: String, detail: String?, by actor: CaseActor, at now: Date) -> Entity {
        if let index = entities.firstIndex(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            entities[index].lastSeen = now
            if let detail, !detail.isEmpty { entities[index].detail = detail }
            return entities[index]
        }
        let entity = Entity(id: Self.nextID("E", after: entities.map(\.id)), kind: kind, name: name,
                            detail: detail?.isEmpty == true ? nil : detail, firstSeen: now, lastSeen: now, recordedBy: actor)
        entities.append(entity)
        return entity
    }

    @discardableResult
    public mutating func record(evidenceFrom source: String, method: String, result: String, by actor: CaseActor, at now: Date) -> Evidence {
        let item = Evidence(id: Self.nextID("V", after: evidence.map(\.id)), source: source, method: method, result: result,
                            collectedAt: now, recordedBy: actor)
        evidence.append(item)
        return item
    }

    /// Unknown evidence is refused: a finding stands on what was collected, never on a reference to nothing.
    @discardableResult
    public mutating func record(finding claim: String, evidence cited: [String], confidence: Finding.Confidence,
                                entities named: [String], by actor: CaseActor, at now: Date) throws -> Finding {
        let known = Set(evidence.map { $0.id.uppercased() })
        let cited = cited.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
        if let missing = cited.first(where: { !known.contains($0) }) {
            throw CaseError("There is no evidence \(missing) in this case. Record it with the evidence tool first.")
        }
        let finding = Finding(id: Self.nextID("F", after: findings.map(\.id)), claim: claim, evidence: cited,
                              confidence: confidence, entities: named, recordedAt: now, recordedBy: actor)
        findings.append(finding)
        return finding
    }
}

public struct CaseError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
