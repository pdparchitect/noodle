import Foundation

/// One line of an Investigation's audit log. The log is only ever appended to.
public struct AuditEntry: Codable, Hashable, Sendable {
    public let at: Date
    public let actor: CaseActor
    /// A short verb, such as opened, evidence or approved.
    public let event: String
    public let detail: String

    public init(at: Date, actor: CaseActor, event: String, detail: String) {
        self.at = at; self.actor = actor; self.event = event; self.detail = detail
    }
}

/// Pion's own data beside Noodle's workspace: Investigations, their case records and audit logs,
/// the roles of the standing roster and the action policy. Every change goes through here, under
/// one lock, so the case tool on the broker's queue and the app on the main thread never race.
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
    private func folder(_ id: UUID) -> URL { investigationsFolder.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    private func investigationURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("investigation.json") }
    private func caseURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("case.json") }
    public func auditURL(_ id: UUID) -> URL { folder(id).appendingPathComponent("audit.jsonl") }
    private var rosterURL: URL { root.appendingPathComponent("roster.json") }
    private var policyURL: URL { root.appendingPathComponent("policy.json") }

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
    public func open(id: UUID, title: String, objective: String, scope: [String], severity: Investigation.Severity,
                     champion: String, leadAgentID: UUID?, playbookID: String?, source: String? = nil,
                     number: Int? = nil, now: Date = Date()) throws -> Investigation {
        let investigation = try lock.withLock {
            let next = number ?? (unlockedInvestigations().map(\.number).max() ?? 0) + 1
            let investigation = Investigation(id: id, number: next, title: title, objective: objective, scope: scope,
                                              severity: severity, champion: champion, leadAgentID: leadAgentID,
                                              playbookID: playbookID, source: source, openedAt: now)
            try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
            try write(investigation, to: investigationURL(id))
            try write(CaseRecord(), to: caseURL(id))
            try unlockedAppend(AuditEntry(at: now, actor: .champion(champion), event: "opened",
                                          detail: "\(investigation.reference) \(title). Scope: \(scope.joined(separator: ", "))."), to: id)
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

    /// Proposes an action. The policy decides its mode; an identical action still open is
    /// returned as it is, so an agent that retries never gets the same thing twice.
    public func propose(operation: String, targets: [String], rationale: String, expectedEffect: String, undo: String,
                        evidence: [String], in id: UUID, by actor: CaseActor, now: Date = Date()) throws -> (CaseRecord.ProposedAction, ActionPolicy.Verdict, repeated: Bool) {
        let policy = self.policy()
        let operation = operation.trimmingCharacters(in: .whitespaces).lowercased()
        let targets = targets.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !operation.isEmpty, operation.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw CaseError("An operation is one word such as isolate_host.")
        }
        var repeatedAction: (CaseRecord.ProposedAction, ActionPolicy.Verdict)?
        let result: (CaseRecord.ProposedAction, ActionPolicy.Verdict) = try updateCase(id, by: actor, now: now) { record, investigation in
            let verdict = policy.verdict(operation: operation, targets: targets, in: investigation)
            let sameTargets = Set(targets.map { $0.lowercased() })
            if let existing = record.actions.first(where: {
                $0.operation == operation && Set($0.targets.map { $0.lowercased() }) == sameTargets && [.pending, .approved, .done].contains($0.state)
            }) {
                repeatedAction = (existing, verdict)
                return ((existing, verdict), "repeated", "\(existing.id) \(operation) was proposed again; it is already \(existing.state.title.lowercased()).")
            }
            let state: CaseRecord.ProposedAction.State
            switch verdict.mode {
            case .automatic, .notify: state = .approved
            case .approval: state = .pending
            case .never: state = .refused
            }
            let action = CaseRecord.ProposedAction(
                id: CaseRecord.nextID("A", after: record.actions.map(\.id)), operation: operation, targets: targets,
                rationale: rationale, expectedEffect: expectedEffect, undo: undo, evidence: evidence, mode: verdict.mode,
                state: state, note: verdict.mode == .never ? verdict.reason : nil, proposedAt: now, proposedBy: actor,
                decidedAt: state == .pending ? nil : now, decidedBy: state == .pending ? nil : .policy)
            record.actions.append(action)
            let summary = "\(action.id) \(operation) on \(targets.joined(separator: ", ")): \(state.title.lowercased()). \(verdict.reason)"
            return ((action, verdict), "proposed", summary)
        }
        if let repeatedAction { return (repeatedAction.0, repeatedAction.1, true) }
        return (result.0, result.1, false)
    }

    /// The champion's decision on a pending action, or marking an approved one done.
    @discardableResult
    public func decide(_ actionID: String, in id: UUID, approve: Bool, note: String?, by champion: String,
                       now: Date = Date()) throws -> CaseRecord.ProposedAction {
        try updateCase(id, by: .champion(champion), now: now) { record, investigation in
            guard let index = record.actions.firstIndex(where: { $0.id == actionID }) else { throw CaseError("There is no action \(actionID).") }
            guard record.actions[index].state == .pending else {
                throw CaseError("\(actionID) is already \(record.actions[index].state.title.lowercased()).")
            }
            guard !investigation.isClosed else { throw CaseError("\(investigation.reference) is closed.") }
            record.actions[index].state = approve ? .approved : .denied
            record.actions[index].note = note?.isEmpty == true ? nil : note
            record.actions[index].decidedAt = now
            record.actions[index].decidedBy = .champion(champion)
            let action = record.actions[index]
            return (action, approve ? "approved" : "denied", "\(action.id) \(action.operation) on \(action.targets.joined(separator: ", "))" + (note.map { ": \($0)" } ?? ""))
        }
    }

    @discardableResult
    public func markDone(_ actionID: String, in id: UUID, note: String?, by champion: String, now: Date = Date()) throws -> CaseRecord.ProposedAction {
        try updateCase(id, by: .champion(champion), now: now) { record, _ in
            guard let index = record.actions.firstIndex(where: { $0.id == actionID }) else { throw CaseError("There is no action \(actionID).") }
            guard record.actions[index].state == .approved else { throw CaseError("Only an approved action can be marked done.") }
            record.actions[index].state = .done
            if let note, !note.isEmpty { record.actions[index].note = note }
            let action = record.actions[index]
            return (action, "done", "\(action.id) \(action.operation) carried out" + (note.map { ": \($0)" } ?? ""))
        }
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

    // MARK: Roster and policy

    /// The role of each agent on the roster, by agent identifier.
    public func roles() -> [UUID: String] {
        lock.withLock { (try? read([UUID: String].self, from: rosterURL)) ?? [:] }
    }

    public func setRole(_ role: String?, of agent: UUID) throws {
        try lock.withLock {
            var roles = (try? read([UUID: String].self, from: rosterURL)) ?? [:]
            roles[agent] = role
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try write(roles, to: rosterURL)
        }
        onChange?()
    }

    public func policy() -> ActionPolicy {
        lock.withLock { (try? read(ActionPolicy.self, from: policyURL)) ?? .standard }
    }

    public func setPolicy(_ policy: ActionPolicy) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try write(policy, to: policyURL)
        }
        onChange?()
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
