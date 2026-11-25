import Foundation

/// One line of a Mission's audit log. The log is only ever appended to.
public struct AuditEntry: Codable, Hashable, Sendable {
    public let at: Date
    public let actor: CaseActor
    /// A short verb, such as opened, evidence or scope.
    public let event: String
    public let detail: String

    public init(at: Date, actor: CaseActor, event: String, detail: String) {
        self.at = at; self.actor = actor; self.event = event; self.detail = detail
    }
}

/// Rook's own data beside Noodle's workspace: Missions, their case records and audit logs.
/// Every change goes through here, under one lock, so the case tool on the broker's queue and the app on the main thread never race.
public final class RookStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    /// Called after any change, on whichever thread made it.
    public var onChange: (@Sendable () -> Void)?

    public init(root: URL) {
        self.root = root
    }

    // MARK: Paths

    private var missionsFolder: URL { root.appendingPathComponent("Missions", isDirectory: true) }
    /// Where a Mission keeps its own files: mission.json, case.json and audit.jsonl.
    public func folder(_ id: UUID) -> URL { missionsFolder.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    private func missionURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("mission.json") }
    private func caseURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("case.json") }
    public func auditURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("audit.jsonl") }

    // MARK: Missions

    public func missions() -> [Mission] {
        lock.withLock { unlockedMissions() }
    }

    public func mission(_ id: UUID) -> Mission? {
        lock.withLock { try? read(Mission.self, from: missionURL(id)) }
    }

    private func unlockedMissions() -> [Mission] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: missionsFolder.path)) ?? []
        return names.compactMap { UUID(uuidString: $0) }
            .compactMap { try? read(Mission.self, from: missionURL($0)) }
            .sorted { $0.number > $1.number }
    }

    /// Opens a Mission for a group conversation that already exists, numbering it after the last one.
    public func open(id: UUID, title: String, objective: String, severity: Mission.Severity? = nil,
                     champion: String, source: String? = nil,
                     number: Int? = nil, openedBy: CaseActor? = nil, now: Date = Date()) throws -> Mission {
        let mission = try lock.withLock {
            let next = number ?? (unlockedMissions().map(\.number).max() ?? 0) + 1
            let mission = Mission(id: id, number: next, title: title, objective: objective,
                                              severity: severity, champion: champion,
                                              source: source, openedAt: now)
            try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
            try write(mission, to: missionURL(id))
            try write(CaseRecord(), to: caseURL(id))
            // The champion owns it whoever opens it; the audit log says who did.
            try unlockedAppend(AuditEntry(at: now, actor: openedBy ?? .champion(champion), event: "opened",
                                          detail: "\(mission.reference) \(title)."), to: id)
            return mission
        }
        onChange?()
        return mission
    }

    /// Changes a Mission and logs what changed. The closure may throw to refuse the change.
    @discardableResult
    public func update(_ id: UUID, by actor: CaseActor, now: Date = Date(),
                       _ change: (inout Mission) throws -> [(event: String, detail: String)]) throws -> Mission {
        let updated = try lock.withLock {
            var mission = try read(Mission.self, from: missionURL(id))
            let events = try change(&mission)
            guard !events.isEmpty else { return mission }
            mission.updatedAt = now
            try write(mission, to: missionURL(id))
            for event in events { try unlockedAppend(AuditEntry(at: now, actor: actor, event: event.event, detail: event.detail), to: id) }
            return mission
        }
        onChange?()
        return updated
    }

    /// Moves a Mission to `status`. Only the champion closes, and closing records an outcome.
    @discardableResult
    public func setStatus(_ status: Mission.Status, of id: UUID, by actor: CaseActor, outcome: Mission.Outcome? = nil,
                          note: String? = nil, now: Date = Date()) throws -> Mission {
        try update(id, by: actor, now: now) { mission in
            guard mission.status != status else { return [] }
            if status == .closed {
                guard case .champion = actor else { throw CaseError("Only the champion closes a Mission.") }
                guard let outcome else { throw CaseError("Closing needs an outcome.") }
                mission.outcome = outcome
                mission.closingNote = note
                mission.closedAt = now
            } else if mission.status == .closed {
                guard case .champion = actor else { throw CaseError("Only the champion reopens a Mission.") }
                mission.outcome = nil
                mission.closingNote = nil
                mission.closedAt = nil
            }
            let from = mission.status
            mission.status = status
            var detail = "\(from.title) → \(status.title)"
            if let outcome, status == .closed { detail += " as \(outcome.title.lowercased())" }
            if let note, !note.isEmpty { detail += ": \(note)" }
            return [("status", detail)]
        }
    }

    // MARK: Computers

    /// Assigns a computer to a Mission or takes it away. Only the champion does; agents never choose their computers.
    public func setComputer(_ computer: UUID, named name: String, assigned: Bool, in id: UUID, by actor: CaseActor,
                            now: Date = Date()) throws {
        guard case .champion = actor else { throw CaseError("Only the champion assigns computers to a Mission.") }
        try update(id, by: actor, now: now) { mission in
            guard mission.computers.contains(computer) != assigned else { return [] }
            if assigned { mission.computers.append(computer) } else { mission.computers.removeAll { $0 == computer } }
            return [("computer", "\(assigned ? "Added" : "Removed") \(name).")]
        }
    }

    /// Replaces what the Mission has in scope; only its champion sets it, and the audit log keeps every version.
    public func setScope(_ scope: [String], of id: UUID, by actor: CaseActor, now: Date = Date()) throws {
        guard case .champion = actor else { throw CaseError("Only the champion sets a Mission's scope.") }
        let rules = try MissionScope.parse(scope.joined(separator: "\n"))
        try update(id, by: actor, now: now) { mission in
            guard mission.scope != rules else { return [] }
            mission.scope = rules
            return [("scope", rules.isEmpty ? "Cleared the scope." : "Set the scope: \(rules.joined(separator: ", ")).")]
        }
    }

    /// Takes a deleted computer out of every Mission that had it.
    public func forgetComputer(_ computer: UUID, named name: String, by actor: CaseActor, now: Date = Date()) throws {
        for mission in missions() where mission.computers.contains(computer) {
            try update(mission.id, by: actor, now: now) { mission in
                mission.computers.removeAll { $0 == computer }
                return [("computer", "Removed \(name), which was deleted.")]
            }
        }
    }

    // MARK: Case record

    public func caseRecord(_ id: UUID) -> CaseRecord {
        lock.withLock { (try? read(CaseRecord.self, from: caseURL(id))) ?? CaseRecord() }
    }

    /// Changes a case record and appends what the closure reports to the audit log.
    public func updateCase<Result>(_ id: UUID, by actor: CaseActor, now: Date = Date(),
                                   _ change: (inout CaseRecord, Mission) throws -> (Result, event: String, detail: String)) throws -> Result {
        let result = try lock.withLock {
            let mission = try read(Mission.self, from: missionURL(id))
            // A closed Mission's record stays as it was closed, until the champion reopens it.
            guard !mission.isClosed else { throw CaseError("\(mission.reference) is closed.") }
            var record = (try? read(CaseRecord.self, from: caseURL(id))) ?? CaseRecord()
            let (result, event, detail) = try change(&record, mission)
            try write(record, to: caseURL(id))
            try unlockedAppend(AuditEntry(at: now, actor: actor, event: event, detail: detail), to: id)
            var touched = mission
            touched.updatedAt = now
            try write(touched, to: missionURL(id))
            return result
        }
        onChange?()
        return result
    }

    // MARK: Audit log

    public func audit(_ id: UUID) -> [AuditEntry] {
        lock.withLock {
            guard let data = try? Data(contentsOf: auditURL(id)) else { return [] }
            let decoder = Self.decoder
            return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(AuditEntry.self, from: Data($0)) }
        }
    }

    public func append(_ entry: AuditEntry, to id: UUID) throws {
        try lock.withLock { try unlockedAppend(entry, to: id) }
        onChange?()
    }

    /// Opened for appending only, so earlier lines are never rewritten.
    private func unlockedAppend(_ entry: AuditEntry, to id: UUID) throws {
        var line = try Self.lineEncoder.encode(entry)
        line.append(UInt8(ascii: "\n"))
        let url = auditURL(id)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    // MARK: Files

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try Self.decoder.decode(type, from: Data(contentsOf: url))
    }
}
