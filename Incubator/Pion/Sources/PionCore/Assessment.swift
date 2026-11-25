import Foundation

/// One question an Assessment asks of a service, such as whether everyone is enrolled in 2-step verification: the reads
/// that answer it, given the policy, and how their answers pass or fail. Checks only read, and never assume a policy
/// answer the person did not give.
public struct AssessmentCheck: Sendable {
    /// Stable across releases, as earlier runs are compared by it, such as gws.2sv-enrolment.
    public let id: String
    public let title: String
    public let severity: Investigation.Severity
    /// Why it matters, in plain words.
    public let rationale: String
    /// What to change, naming where in the service's console.
    public let fix: String
    /// The service the evidence says it came from.
    public let source: String
    /// The policy answers it reads, by their front matter keys.
    public let policyKeys: [String]
    /// What it reads, given the policy; throws `AssessmentCheckError.policyMissing` when an answer it needs is missing.
    public let reads: @Sendable (AssessmentPolicy) throws -> [CheckRead]
    /// Passes or fails it on what its reads answered; throws `AssessmentCheckError` when it cannot tell.
    public let evaluate: @Sendable (CheckInputs, AssessmentPolicy) throws -> CheckOutcome
    /// Why it couldn't run when a read failed, given why the read did, such as a refusal said as what this check needs.
    public let unread: @Sendable (_ reason: String) -> String

    public init(id: String, title: String, severity: Investigation.Severity, rationale: String, fix: String,
                source: String, policyKeys: [String] = [],
                unread: @escaping @Sendable (_ reason: String) -> String = { $0 },
                reads: @escaping @Sendable (AssessmentPolicy) throws -> [CheckRead],
                evaluate: @escaping @Sendable (CheckInputs, AssessmentPolicy) throws -> CheckOutcome) {
        self.id = id; self.title = title; self.severity = severity; self.rationale = rationale; self.fix = fix
        self.source = source; self.policyKeys = policyKeys; self.unread = unread; self.reads = reads; self.evaluate = evaluate
    }
}

/// Why a check did not pass or fail.
public enum AssessmentCheckError: LocalizedError, Equatable, Sendable {
    /// The policy has no answer to the question, such as "whether 2-step verification is required".
    case policyMissing(String)
    case couldNotRun(String)
    /// The service doesn't let a read tell, such as a setting it lists without its value: a limit of what can be read,
    /// not something gone wrong.
    case limitation(String)

    public var errorDescription: String? {
        switch self {
        case .policyMissing(let question): "The policy doesn't say \(question); answer it in the questionnaire."
        case .couldNotRun(let reason), .limitation(let reason): reason
        }
    }

    /// What kept a check from running, for an error a check threw.
    static func obstacle(of error: Error) -> CheckResult.Obstacle {
        switch error as? AssessmentCheckError {
        case .policyMissing?: .policy
        case .limitation?: .limitation
        default: .problem
        }
    }
}

/// One call of a read-only tool, which checks asking the same are answered by once.
public struct CheckRead: Codable, Hashable, Sendable {
    public enum Value: Codable, Hashable, Sendable {
        case text(String), number(Int), flag(Bool)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) { self = .flag(flag) }
            else if let number = try? container.decode(Int.self) { self = .number(number) }
            else { self = .text(try container.decode(String.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .number(let number): try container.encode(number)
            case .flag(let flag): try container.encode(flag)
            }
        }
    }

    public let tool: String
    public let arguments: [String: Value]
    /// Whether the Containment tool answers it, as it alone reads some things, such as apps' current grants.
    public let needsContainment: Bool
    /// The list in its answer that holds what it read, such as users, to say how much a read in part covered.
    public let items: String?

    public init(_ tool: String, _ arguments: [String: Value] = [:], needsContainment: Bool = false, items: String? = nil) {
        self.tool = tool; self.arguments = arguments; self.needsContainment = needsContainment; self.items = items
    }

    public var argumentsJSON: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(arguments)) ?? Data("{}".utf8)
    }

    /// The call as someone would make it again, such as users {"limit":10000}.
    public var described: String {
        tool + (arguments.isEmpty ? "" : " " + String(decoding: argumentsJSON, as: UTF8.self))
    }
}

/// The answers a check's reads gave, as their structured results, and when the run read them.
public struct CheckInputs: Sendable {
    let answers: [CheckRead: Data]
    /// The run's time, which a check that counts days goes by rather than the clock.
    public let now: Date

    public init(_ answers: [CheckRead: Data], now: Date = Date()) { self.answers = answers; self.now = now }

    /// `read`'s structured result as `type`; an answer of another shape means the check cannot run.
    public func decode<Value: Decodable>(_ type: Value.Type, from read: CheckRead) throws -> Value {
        guard let data = answers[read] else { throw AssessmentCheckError.couldNotRun("\(read.tool) wasn't read.") }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AssessmentCheckError.couldNotRun("\(read.tool) gave an unexpected answer.") }
    }
}

public enum CheckOutcome: Equatable, Sendable {
    case pass(String)
    /// What failed, and who or what fails it, by name.
    case fail(String, offenders: [String])
}

public enum CheckStatus: String, Codable, CaseIterable, Sendable {
    case pass, fail, couldNotRun = "could-not-run"

    public var title: String {
        switch self {
        case .pass: "Pass"
        case .fail: "Fail"
        case .couldNotRun: "Couldn't run"
        }
    }
}

/// What one check found in one run.
public struct CheckResult: Codable, Equatable, Sendable {
    /// The most offenders kept; `offenderCount` counts them all.
    public static let keptOffenders = 500

    /// What kept a check from running: a policy answer still to give; a limit of what the service lets it read, such
    /// as settings only a super admin may read or a list cut short, which is no error; or a problem to fix, such as
    /// no connection or a refused read.
    public enum Obstacle: String, Codable, Sendable {
        case policy, limitation, problem
    }

    public let checkID: String
    public let title: String
    public let severity: Investigation.Severity
    public let source: String
    public let status: CheckStatus
    /// What it found, for a pass or a fail.
    public let summary: String?
    /// Sorted, at most `keptOffenders` of them.
    public let offenders: [String]
    public let offenderCount: Int
    /// Why it couldn't run.
    public let reason: String?
    /// What kind of thing kept it from running; nil when it ran, and for a result kept before results said.
    public let obstacle: Obstacle?
    public let reads: [CheckRead]
    public let policyKeys: [String]
    /// The evidence its result was recorded as.
    public var evidenceID: String?
    /// For a fail, the finding it stands as, carried from the run before while its offenders are the same; for a pass
    /// that fixed an earlier failure, the finding that says so; for a check that couldn't run, the earlier failure's,
    /// still open.
    public var findingID: String?
    /// The earlier failure's finding a pass marked fixed.
    public var resolves: String?

    public init(check: AssessmentCheck, status: CheckStatus, summary: String? = nil, offenders: [String] = [], reason: String? = nil,
                obstacle: Obstacle? = nil, reads: [CheckRead] = []) {
        let unique = Array(Set(offenders)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        checkID = check.id; title = check.title; severity = check.severity; source = check.source
        self.status = status; self.summary = summary; self.reason = reason; self.reads = reads; policyKeys = check.policyKeys
        self.obstacle = status == .couldNotRun ? obstacle ?? .problem : nil
        self.offenders = Array(unique.prefix(Self.keptOffenders))
        offenderCount = unique.count
    }

    /// The failure finding a later run carries or resolves, if this result left one open.
    var openFinding: String? { status == .pass ? nil : findingID }

    /// Whether it couldn't run for a problem to fix rather than the policy or a limit of what can be read.
    var hasProblem: Bool { status == .couldNotRun && (obstacle ?? .problem) == .problem }
}

/// One run of an Assessment's checks, with the policy as it stood.
public struct AssessmentRun: Codable, Equatable, Sendable {
    public let date: Date
    /// The connection its reads went through, by name.
    public let connection: String?
    public let policy: AssessmentPolicy
    /// The person's prose under the policy's answers as it read for this run; nil for a run kept before runs kept it.
    public var policyBody: String?
    public var results: [CheckResult]

    public init(date: Date, connection: String?, policy: AssessmentPolicy, policyBody: String? = nil, results: [CheckResult]) {
        self.date = date; self.connection = connection; self.policy = policy; self.policyBody = policyBody; self.results = results
    }

    public func count(_ status: CheckStatus) -> Int { results.count { $0.status == status } }

    /// Such as "Ran 11 checks: 3 failed, 7 passed, 1 couldn't run."
    public var tally: String {
        "Ran \(results.count) check\(results.count == 1 ? "" : "s"): \(count(.fail)) failed, \(count(.pass)) passed, \(count(.couldNotRun)) couldn't run."
    }

    /// The policy's keys that checks needed an answer to but didn't get, in the policy's order.
    public var unansweredKeys: [String] {
        let needed = Set(results.filter { $0.status == .couldNotRun && $0.obstacle == .policy }.flatMap(\.policyKeys))
        return AssessmentPolicy.keys.filter { needed.contains($0) && policy.value(forKey: $0) == nil }
    }

    /// Whether checks couldn't run for want of a policy answer.
    public var isPolicyIncomplete: Bool { results.contains { $0.status == .couldNotRun && $0.obstacle == .policy } }

    /// What the policy leaves unanswered, such as "it doesn't answer max-super-admins, which 1 check needs", for a run
    /// labelled policy incomplete; nil when the policy answers all the checks ask.
    public var policyGaps: String? {
        guard isPolicyIncomplete else { return nil }
        let waiting = results.count { $0.status == .couldNotRun && $0.obstacle == .policy }
        let keys = unansweredKeys
        let unanswered = keys.isEmpty ? "it is missing answers" : "it doesn't answer " + keys.joined(separator: ", ")
        return "\(unanswered), which \(waiting) check\(waiting == 1 ? "" : "s") need\(waiting == 1 ? "s" : "")"
    }

    /// The one problem every check that hit one couldn't run for, such as no connection or a sign-in needed, when
    /// more than one did: said once instead of for each.
    public var sharedProblem: (reason: String, count: Int)? {
        let problems = results.filter(\.hasProblem)
        guard problems.count > 1, let reason = problems.first?.reason, problems.allSatisfy({ $0.reason == reason }) else { return nil }
        return (reason, problems.count)
    }

    /// The shared problem as one line, such as "Google Workspace Detection needs signing in. None of the checks
    /// could run." Nil when there is none.
    public var sharedProblemLine: String? {
        guard let (reason, count) = sharedProblem else { return nil }
        let said = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let ended = said.hasSuffix(".") || said.hasSuffix("!") || said.hasSuffix("?") ? said : said + "."
        return ended + (count == results.count ? " None of the checks could run." : " \(count) of the \(results.count) checks couldn't run because of it.")
    }
}

/// Calls a read-only tool with JSON arguments and returns its MCP tools/call result.
public typealias AssessmentCall = @Sendable (_ tool: String, _ arguments: Data) async throws -> Data

/// Runs checks: reads what they need once each, one at a time, then passes or fails each in the checklist's order.
public enum AssessmentRunner {
    /// What one read answered: its structured result, and whether it was read only in part, with how many items it
    /// holds and how many there are when the answer says; or why it could not be read.
    enum Answer {
        case read(Data, partial: Bool, count: Int?, total: Int?)
        case failed(String)
    }

    public static func run(_ checks: [AssessmentCheck], policy: AssessmentPolicy, policyBody: String? = nil, connection: String? = nil,
                           detection: AssessmentCall?, containment: AssessmentCall?,
                           detectionName: String = "Google Workspace Detection", containmentName: String = "Google Workspace Containment",
                           now: Date = Date()) async -> AssessmentRun {
        var planned: [Result<[CheckRead], Error>] = []
        var order: [CheckRead] = [], seen: Set<CheckRead> = []
        for check in checks {
            do {
                let reads = try check.reads(policy)
                planned.append(.success(reads))
                order += reads.filter { seen.insert($0).inserted }
            } catch { planned.append(.failure(error)) }
        }
        var answers: [CheckRead: Answer] = [:]
        for read in order {
            guard let call = read.needsContainment ? containment : detection else {
                answers[read] = .failed(read.needsContainment
                    ? "This check needs \(containmentName), which isn't connected or given to an agent on this Assessment."
                    : "\(detectionName) isn't connected or given to an agent on this Assessment.")
                continue
            }
            do { answers[read] = answer(to: read, try await call(read.tool, read.argumentsJSON)) }
            catch { answers[read] = .failed(error.localizedDescription) }
        }
        let results = zip(checks, planned).map { check, plan in
            switch plan {
            case .failure(let error):
                CheckResult(check: check, status: .couldNotRun, reason: error.localizedDescription, obstacle: AssessmentCheckError.obstacle(of: error))
            case .success(let reads): evaluate(check, reads: reads, answers: answers, policy: policy, now: now)
            }
        }
        return AssessmentRun(date: now, connection: connection, policy: policy, policyBody: policyBody, results: results)
    }

    private static func evaluate(_ check: AssessmentCheck, reads: [CheckRead], answers: [CheckRead: Answer],
                                 policy: AssessmentPolicy, now: Date) -> CheckResult {
        var inputs: [CheckRead: Data] = [:], caveats: [String] = [], partly: [String] = []
        for read in reads {
            switch answers[read] {
            case .failed(let reason):
                // A check that says a failed read as what it needs knows it as a limit, such as a super admin to read.
                let said = check.unread(reason)
                return CheckResult(check: check, status: .couldNotRun, reason: said, obstacle: said == reason ? .problem : .limitation, reads: reads)
            case .read(let data, let partial, let count, let total):
                inputs[read] = data
                guard partial else { continue }
                partly.append(read.tool)
                let items = read.items ?? "items"
                let caveat = switch (count, total) {
                case (let count?, let total?): "This is based on \(count) of \(total) \(items) read."
                case (let count?, nil): "This is based on only the \(count) \(items) read; there are more."
                default: "This is based on only part of \(read.tool)'s answer."
                }
                caveats.append(caveat)
            case nil: return CheckResult(check: check, status: .couldNotRun, reason: "\(read.tool) wasn't read.", reads: reads)
            }
        }
        do {
            switch try check.evaluate(CheckInputs(inputs, now: now), policy) {
            case .pass(let summary):
                // What was not read may fail it, so a pass on part of the answer is no pass.
                guard partly.isEmpty else {
                    return CheckResult(check: check, status: .couldNotRun,
                                       reason: "\(partly.joined(separator: " and ")) was read only in part, and a pass needs all of it.",
                                       obstacle: .limitation, reads: reads)
                }
                return CheckResult(check: check, status: .pass, summary: summary, reads: reads)
            case .fail(let summary, let offenders):
                return CheckResult(check: check, status: .fail, summary: ([summary] + caveats).joined(separator: " "), offenders: offenders, reads: reads)
            }
        } catch {
            return CheckResult(check: check, status: .couldNotRun, reason: error.localizedDescription,
                               obstacle: AssessmentCheckError.obstacle(of: error), reads: reads)
        }
    }

    /// An MCP tools/call result as its structured content, as Pion's adapters give it, or why it is no answer.
    static func answer(to read: CheckRead, _ data: Data) -> Answer {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failed("\(read.tool) gave an unexpected answer.")
        }
        // As a JSON-RPC response carries it, should the call give the whole response.
        if object["content"] == nil, object["structuredContent"] == nil, let result = object["result"] as? [String: Any] { object = result }
        if object["isError"] as? Bool == true {
            let text = ((object["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            return .failed(text.isEmpty ? "\(read.tool) failed without saying why." : text)
        }
        guard let structured = object["structuredContent"] as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: structured) else {
            return .failed("\(read.tool) gave an unexpected answer.")
        }
        let count = read.items.flatMap { (structured[$0] as? [Any])?.count }
        // An answer says it is incomplete with a flag, or a list of what it read in part; one with neither that holds
        // as many as its limit asked for may have had more.
        var partial = false
        switch structured["incomplete"] {
        case let flag as Bool: partial = flag
        case let list as [Any]: partial = !list.isEmpty
        case let text as String: partial = !text.isEmpty
        default: if case .number(let limit)? = read.arguments["limit"], let count { partial = count >= limit }
        }
        return .read(encoded, partial: partial, count: count, total: structured["total"] as? Int)
    }
}

// MARK: Recording

extension AssessmentRun {
    /// This run recorded in `record`: each result as evidence, and each failure as a finding, unless it failed the
    /// same way in `previous`, whose finding it carries instead. A pass where `previous` failed adds a finding that
    /// the earlier one is fixed; nothing is ever removed.
    public func recording(into record: inout CaseRecord, previous: AssessmentRun?, by actor: CaseActor, at now: Date) -> AssessmentRun {
        var run = self
        let earlier = Dictionary((previous?.results ?? []).map { ($0.checkID, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(record.findings.map(\.id))
        for index in run.results.indices {
            var result = run.results[index]
            let evidence = record.record(evidenceFrom: result.source, method: method(of: result), result: Self.evidence(of: result),
                                         by: actor, at: now)
            result.evidenceID = evidence.id
            let before = earlier[result.checkID]
            let open = before?.openFinding.flatMap { known.contains($0) ? $0 : nil }
            switch result.status {
            case .fail:
                if let open, before?.status == .fail, before?.offenders == result.offenders, before?.offenderCount == result.offenderCount {
                    result.findingID = open
                } else {
                    let claim = (result.summary ?? result.title) + (open.map { " This replaces \($0)." } ?? "")
                    result.findingID = try? record.record(finding: claim, evidence: [evidence.id], confidence: .high,
                                                          entities: Array(result.offenders.prefix(25)), by: actor, at: now).id
                }
            case .pass:
                if let open {
                    result.resolves = open
                    result.findingID = try? record.record(finding: "Fixed since the last run: \(open) no longer holds. \(result.summary ?? result.title)",
                                                          evidence: [evidence.id], confidence: .high, entities: [], by: actor, at: now).id
                }
            case .couldNotRun:
                // Unknown is not fixed: the earlier failure stays open until a run tells.
                result.findingID = open
            }
            run.results[index] = result
        }
        return run
    }

    /// The reads exactly as made and the policy answers used, so someone can collect it again.
    func method(of result: CheckResult) -> String {
        var parts = result.reads.map { ($0.needsContainment ? "Containment " : "") + $0.described }
        parts += result.policyKeys.map { "policy \($0): \(policy.value(forKey: $0) ?? "unanswered")" }
        return parts.isEmpty ? "Check \(result.checkID)" : "Check \(result.checkID): " + parts.joined(separator: "; ")
    }

    /// The most offenders evidence names; the rest are counted.
    static let offendersInEvidence = 50

    static func evidence(of result: CheckResult) -> String {
        var text = "\(result.title): \(result.status.title). " + (result.summary ?? result.reason ?? "")
        if !result.offenders.isEmpty {
            let shown = result.offenders.prefix(offendersInEvidence)
            let more = result.offenderCount - shown.count
            text += " Offenders: " + shown.joined(separator: ", ") + (more > 0 ? ", and \(more) more." : ".")
        }
        return text
    }
}

// MARK: Changes

/// What differs in one check, or the policy, from one run to the next.
public enum CheckChange: Equatable, Sendable {
    case newlyFailing(check: String, title: String, offenders: [String])
    /// It passes where it failed, with the earlier finding it marked fixed.
    case fixed(check: String, title: String, finding: String?)
    case offendersChanged(check: String, title: String, added: [String], removed: [String])
    case nowCouldNotRun(check: String, title: String, reason: String)
    case runsAgain(check: String, title: String, status: CheckStatus)
    case added(check: String, title: String, status: CheckStatus)
    case removed(check: String, title: String)
    case policy(key: String, from: String?, to: String?)

    /// One line for the lead to read.
    public var line: String {
        func names(_ list: [String]) -> String {
            list.prefix(10).joined(separator: ", ") + (list.count > 10 ? " and \(list.count - 10) more" : "")
        }
        return switch self {
        case .newlyFailing(_, let title, let offenders):
            "Newly failing: \(title)" + (offenders.isEmpty ? "." : " (\(names(offenders))).")
        case .fixed(_, let title, let finding): "Fixed since the last run: \(title)" + (finding.map { ", so \($0) no longer holds." } ?? ".")
        case .offendersChanged(_, let title, let added, let removed):
            "Still failing: \(title)" + [added.isEmpty ? nil : "; now also \(names(added))", removed.isEmpty ? nil : "; no longer \(names(removed))"]
                .compactMap { $0 }.joined() + (added.isEmpty && removed.isEmpty ? ", with a different number of offenders." : ".")
        case .nowCouldNotRun(_, let title, let reason): "Now couldn't run: \(title). \(reason)"
        case .runsAgain(_, let title, let status): "Runs again: \(title), and \(status == .pass ? "passes" : "fails")."
        case .added(_, let title, let status): "New check: \(title): \(status.title.lowercased())."
        case .removed(_, let title): "No longer checked: \(title)."
        case .policy(let key, let from, let to): "Policy \(key): \(from ?? "unanswered") → \(to ?? "unanswered")."
        }
    }
}

extension AssessmentRun {
    /// What changed since `previous`: the policy's answers first, then each check in this run's order, then the checks
    /// it no longer has.
    public func changes(since previous: AssessmentRun) -> [CheckChange] {
        var changes = policy.changes(from: previous.policy).map { CheckChange.policy(key: $0.key, from: $0.from, to: $0.to) }
        let earlier = Dictionary(previous.results.map { ($0.checkID, $0) }, uniquingKeysWith: { first, _ in first })
        for result in results {
            let id = result.checkID, title = result.title
            guard let before = earlier[id] else { changes.append(.added(check: id, title: title, status: result.status)); continue }
            switch (before.status, result.status) {
            case (.fail, .fail):
                let added = result.offenders.filter { !before.offenders.contains($0) }
                let removed = before.offenders.filter { !result.offenders.contains($0) }
                if !added.isEmpty || !removed.isEmpty || before.offenderCount != result.offenderCount {
                    changes.append(.offendersChanged(check: id, title: title, added: added, removed: removed))
                }
            case (.pass, .fail): changes.append(.newlyFailing(check: id, title: title, offenders: result.offenders))
            case (.fail, .pass): changes.append(.fixed(check: id, title: title, finding: result.resolves ?? before.findingID))
            case (.couldNotRun, .pass) where result.resolves != nil: changes.append(.fixed(check: id, title: title, finding: result.resolves))
            case (.couldNotRun, .pass), (.couldNotRun, .fail): changes.append(.runsAgain(check: id, title: title, status: result.status))
            case (.pass, .couldNotRun), (.fail, .couldNotRun):
                changes.append(.nowCouldNotRun(check: id, title: title, reason: result.reason ?? ""))
            case (.pass, .pass), (.couldNotRun, .couldNotRun): break
            }
        }
        let current = Set(results.map(\.checkID))
        changes += previous.results.filter { !current.contains($0.checkID) }.map { CheckChange.removed(check: $0.checkID, title: $0.title) }
        return changes
    }

    /// The message that hands a recorded run to the Assessment's lead: what was found, what changed since the run
    /// before (nil `changes` for the first run), and what to do with it.
    public func announcement(changes: [CheckChange]?) -> String {
        var lines = ["Pion's checks ran\(connection.map { " on \($0)" } ?? ""). \(tally)"]
        if let shared = sharedProblemLine { lines.append(shared) }
        if let gaps = policyGaps { lines.append("Policy incomplete: \(gaps).") }
        if let changes {
            lines.append(changes.isEmpty ? "Nothing changed since the last run." : "Since the last run:")
            lines += changes.map { "- " + $0.line }
        }
        let failed = results.filter { $0.status == .fail }.sorted { $0.severity > $1.severity }
        if !failed.isEmpty {
            lines.append("\nFailed, most severe first:")
            lines += failed.map { result in
                let cited = [result.evidenceID, result.findingID].compactMap { $0 }.joined(separator: ", ")
                return "- \(result.title) (\(result.severity.rawValue)\(cited.isEmpty ? "" : ", " + cited)): \(result.summary ?? "")"
            }
        }
        let skipped = results.filter { $0.status == .couldNotRun }
        if !skipped.isEmpty {
            lines.append("\nCouldn't run:")
            let shared = sharedProblem?.reason
            lines += skipped.map { result in
                let line = "- \(result.title)\(result.evidenceID.map { " (\($0))" } ?? "")"
                // The shared problem was said once, above.
                return result.hasProblem && result.reason == shared ? line : line + ": \(result.reason ?? "")"
            }
        }
        lines.append(failed.isEmpty
            ? "\nNothing failed. Tell the champion what couldn't run and what it would take to run it, if anything."
            : "\nExplain each failure from its evidence: what it exposes here and how urgent it is. Then record one finding that "
                + "orders the fixes, most urgent first, citing their evidence IDs. Don't run the reads again: the evidence "
                + "already holds what they answered. Say what couldn't run and what it would take.")
        return lines.joined(separator: "\n")
    }
}
