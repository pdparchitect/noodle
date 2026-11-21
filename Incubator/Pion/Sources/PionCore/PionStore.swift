import Foundation
import NoodleCore

/// One line of an Investigation's audit log. The log is only ever appended to.
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

/// Pion's own data beside Noodle's workspace: Investigations, their case records and audit logs.
/// Every change goes through here, under one lock, so the case tool on the broker's queue and the app on the main thread never race.
public final class PionStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    /// Called after any change, on whichever thread made it.
    public var onChange: (@Sendable () -> Void)?

    public init(root: URL) {
        self.root = root
    }

    // MARK: Paths

    private var investigationsFolder: URL { root.appendingPathComponent("Investigations", isDirectory: true) }
    /// Where an Investigation keeps its own files: investigation.json, case.json and audit.jsonl.
    public func folder(_ id: UUID) -> URL { investigationsFolder.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    private func investigationURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("investigation.json") }
    private func caseURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("case.json") }
    public func auditURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("audit.jsonl") }

    // MARK: Investigations

    public func investigations() -> [Investigation] {
        lock.withLock { unlockedInvestigations() }
    }

    public func investigation(_ id: UUID) -> Investigation? {
        lock.withLock { try? read(Investigation.self, from: investigationURL(id)) }
    }

    private func unlockedInvestigations() -> [Investigation] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: investigationsFolder.path)) ?? []
        return names.compactMap { UUID(uuidString: $0) }
            .compactMap { try? read(Investigation.self, from: investigationURL($0)) }
            .sorted { $0.number > $1.number }
    }

    /// Opens an Investigation for a group conversation that already exists, numbering it after the last one.
    public func open(id: UUID, title: String, objective: String, severity: Investigation.Severity? = nil,
                     champion: String, source: String? = nil,
                     number: Int? = nil, openedBy: CaseActor? = nil, now: Date = Date()) throws -> Investigation {
        let investigation = try lock.withLock {
            let next = number ?? (unlockedInvestigations().map(\.number).max() ?? 0) + 1
            let investigation = Investigation(id: id, number: next, title: title, objective: objective,
                                              severity: severity, champion: champion,
                                              source: source, openedAt: now)
            try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
            try write(investigation, to: investigationURL(id))
            try write(CaseRecord(), to: caseURL(id))
            // The champion owns it whoever opens it; the audit log says who did.
            try unlockedAppend(AuditEntry(at: now, actor: openedBy ?? .champion(champion), event: "opened",
                                          detail: "\(investigation.reference) \(title)."), to: id)
            return investigation
        }
        onChange?()
        return investigation
    }

    /// Changes an Investigation and logs what changed. The closure may throw to refuse the change.
    @discardableResult
    public func update(_ id: UUID, by actor: CaseActor, now: Date = Date(),
                       _ change: (inout Investigation) throws -> [(event: String, detail: String)]) throws -> Investigation {
        let updated = try lock.withLock {
            var investigation = try read(Investigation.self, from: investigationURL(id))
            let events = try change(&investigation)
            guard !events.isEmpty else { return investigation }
            investigation.updatedAt = now
            try write(investigation, to: investigationURL(id))
            for event in events { try unlockedAppend(AuditEntry(at: now, actor: actor, event: event.event, detail: event.detail), to: id) }
            return investigation
        }
        onChange?()
        return updated
    }

    /// Moves an Investigation to `status`. Only the champion closes, and closing records an outcome.
    @discardableResult
    public func setStatus(_ status: Investigation.Status, of id: UUID, by actor: CaseActor, outcome: Investigation.Outcome? = nil,
                          note: String? = nil, now: Date = Date()) throws -> Investigation {
        try update(id, by: actor, now: now) { investigation in
            guard investigation.status != status else { return [] }
            if status == .closed {
                guard case .champion = actor else { throw CaseError("Only the champion closes an Investigation.") }
                guard let outcome else { throw CaseError("Closing needs an outcome.") }
                investigation.outcome = outcome
                investigation.closingNote = note
                investigation.closedAt = now
            } else if investigation.status == .closed {
                guard case .champion = actor else { throw CaseError("Only the champion reopens an Investigation.") }
                investigation.outcome = nil
                investigation.closingNote = nil
                investigation.closedAt = nil
            }
            let from = investigation.status
            investigation.status = status
            var detail = "\(from.title) → \(status.title)"
            if let outcome, status == .closed { detail += " as \(outcome.title.lowercased())" }
            if let note, !note.isEmpty { detail += ": \(note)" }
            return [("status", detail)]
        }
    }

    // MARK: Case record

    public func caseRecord(_ id: UUID) -> CaseRecord {
        lock.withLock { (try? read(CaseRecord.self, from: caseURL(id))) ?? CaseRecord() }
    }

    /// Changes a case record and appends what the closure reports to the audit log.
    public func updateCase<Result>(_ id: UUID, by actor: CaseActor, now: Date = Date(),
                                   _ change: (inout CaseRecord, Investigation) throws -> (Result, event: String, detail: String)) throws -> Result {
        let result = try lock.withLock {
            let investigation = try read(Investigation.self, from: investigationURL(id))
            // A closed Investigation's record stays as it was closed, until the champion reopens it.
            guard !investigation.isClosed else { throw CaseError("\(investigation.reference) is closed.") }
            var record = (try? read(CaseRecord.self, from: caseURL(id))) ?? CaseRecord()
            let (result, event, detail) = try change(&record, investigation)
            try write(record, to: caseURL(id))
            try unlockedAppend(AuditEntry(at: now, actor: actor, event: event, detail: detail), to: id)
            var touched = investigation
            touched.updatedAt = now
            try write(touched, to: investigationURL(id))
            return result
        }
        onChange?()
        return result
    }

    // MARK: Audit log

    /// A call an agent held for the champion's approval, or how it was decided, logged in the Investigation it was held
    /// in, closed or not. Returns false where it was held in no Investigation.
    @discardableResult
    public func logApproval(_ approval: AgentApproval, agent: UUID, agentName: String, now: Date = Date()) -> Bool {
        guard let id = approval.conversationID, investigation(id) != nil else { return false }
        let call = ([approval.tool] + approval.inputLines.map { "\($0.name): \($0.value)" }).joined(separator: " ")
        let actor: CaseActor, detail: String
        switch approval.state {
        case .pending, .running:
            actor = .agent(agent)
            detail = "\(agentName) asked to run \(call) on \(approval.providerTitle): \(approval.reason)"
        case .done, .failed, .declined, .expired:
            actor = approval.decidedBy.map(CaseActor.champion) ?? .agent(agent)
            let decided = switch approval.state {
            case .done: "Approved by \(approval.decidedBy ?? "the champion"); it ran"
            case .failed: "Approved by \(approval.decidedBy ?? "the champion"), but it did not succeed"
            case .declined: "Declined by \(approval.decidedBy ?? "the champion")"
            default: "Expired without an answer"
            }
            detail = "\(decided): \(call) on \(approval.providerTitle)" + (approval.result.map { ". \($0)" } ?? "")
        }
        do {
            try lock.withLock { try unlockedAppend(AuditEntry(at: now, actor: actor, event: "approval", detail: detail), to: id) }
        } catch { return false }
        onChange?()
        return true
    }

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
