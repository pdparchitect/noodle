import Foundation

/// Who wrote something into a case: an agent or the champion.
public enum CaseActor: Codable, Hashable, Sendable {
    case agent(UUID)
    case champion(String)

    private enum CodingKeys: String, CodingKey { case agent, champion }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UUID.self, forKey: .agent) { self = .agent(id) }
        else { self = .champion(try container.decode(String.self, forKey: .champion)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .agent(let id): try container.encode(id, forKey: .agent)
        case .champion(let name): try container.encode(name, forKey: .champion)
        }
    }
}

/// The structured part of a Mission, written by its agents through the case tool and
/// shown beside the transcript. Every item cites who recorded it and when.
public struct CaseRecord: Codable, Equatable, Sendable {
    public struct Entity: Codable, Identifiable, Hashable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case host, service, account, credential, artifact, other
            public var title: String { rawValue.capitalized }
            public var symbol: String {
                switch self {
                case .host: "desktopcomputer"
                case .service: "server.rack"
                case .account: "person.badge.key.fill"
                case .credential: "key.fill"
                case .artifact: "shippingbox.fill"
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

    /// An edge in the attack graph: one entity related to another, such as a credential that unlocks an account,
    /// or a host reached from another. The two ends are entity IDs.
    public struct Link: Codable, Identifiable, Hashable, Sendable {
        public let id: String
        public var from: String
        /// How they relate, such as unlocks, on, found-on, pivoted-to or exfiltrated-from.
        public var relation: String
        public var to: String
        public let recordedAt: Date
        public let recordedBy: CaseActor
    }

    public var entities: [Entity] = []
    public var evidence: [Evidence] = []
    public var findings: [Finding] = []
    public var links: [Link] = []

    public init() {}

    /// Focus includes both ends of incident edges, but never follows a neighbour's other edges.
    /// A removed selection falls back to the full graph as the case changes underneath the view.
    public func graphFocus(around selected: String?) -> Set<String> {
        let known = Set(entities.map(\.id))
        guard let selected, known.contains(selected) else { return known }
        var focused: Set<String> = [selected]
        for link in links where link.from == selected || link.to == selected {
            focused.insert(link.from)
            focused.insert(link.to)
        }
        return focused.intersection(known)
    }

    /// The next identifier with `prefix`, such as V-4 after V-3. Identifiers are never reused.
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

    /// Links two entities into the attack graph. Each end is an entity by its ID or exact name; an unknown end is
    /// refused so the graph never points at nothing.
    @discardableResult
    public mutating func record(linkFrom from: String, relation: String, to: String, by actor: CaseActor, at now: Date) throws -> Link {
        func resolve(_ reference: String) throws -> Entity {
            let reference = reference.trimmingCharacters(in: .whitespaces)
            if let entity = entities.first(where: { $0.id.caseInsensitiveCompare(reference) == .orderedSame
                                                    || $0.name.caseInsensitiveCompare(reference) == .orderedSame }) { return entity }
            throw CaseError("There is no entity \"\(reference)\" in this case. Record it with the entity tool first.")
        }
        let start = try resolve(from), end = try resolve(to)
        let link = Link(id: Self.nextID("L", after: links.map(\.id)), from: start.id,
                        relation: relation.trimmingCharacters(in: .whitespaces), to: end.id, recordedAt: now, recordedBy: actor)
        links.append(link)
        return link
    }
}

public struct CaseError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
