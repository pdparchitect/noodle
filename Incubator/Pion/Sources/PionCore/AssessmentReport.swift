import Foundation

/// An Assessment written up in Markdown for people outside Pion: what its latest run found, most severe first, what
/// changed since the run before, what couldn't be checked and why, and the policy it held the service to.
///
/// Only the latest run's results stand. A finding an earlier run made stays in the case record, but once a later
/// run replaced it or marked it fixed, the report never shows it as current.
public enum AssessmentReport {
    /// The most offenders a finding lists; the rest are counted.
    public static let listedOffenders = 50

    /// The report of `investigation`, an Assessment, from its `runs`, oldest first, and its case `record`.
    /// `policy` is its policy file as it reads now, whose prose stands in for a run that didn't keep its own; `checks`
    /// give each result's rationale and fix by its ID, and a check no longer among them goes without; `name` names
    /// whoever wrote a finding.
    public static func markdown(investigation: Investigation, record: CaseRecord, runs: [AssessmentRun], policy: String? = nil,
                                checks: [AssessmentCheck] = GoogleWorkspaceChecks.all, timeZone: TimeZone = .current,
                                name: (CaseActor) -> String) -> String {
        let when = Dates(timeZone: timeZone)
        var out = ["# \(escaped(investigation.title)) (\(investigation.reference))", ""]
        guard let latest = runs.last else {
            out += ["- Champion: \(escaped(investigation.champion))", "", "No checks have run yet."]
            return out.joined(separator: "\n") + "\n"
        }
        let previous = runs.dropLast().last
        out += ["- Champion: \(escaped(investigation.champion))",
                "- Latest run: \(when.full(latest.date))",
                "- Connection: \(latest.connection.map(escaped) ?? "none")"]
        if let previous { out.append("- Previous run: \(when.full(previous.date))") }

        let changes = previous.map { latest.changes(since: $0) }
        let failed = latest.results.enumerated()
            .filter { $0.element.status == .fail }
            .sorted { $0.element.severity != $1.element.severity ? $0.element.severity > $1.element.severity : $0.offset < $1.offset }
            .map(\.element)
        let byID = Dictionary(checks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let evidence = Dictionary(record.evidence.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Notes are what anyone but the checks recorded; each goes with the failures whose evidence it cites.
        let notes = record.findings.filter { if case .checks = $0.recordedBy { false } else { true } }
        let failedEvidence = Set(failed.compactMap(\.evidenceID))

        // MARK: Summary
        out += ["", "## Summary", ""]
        if let gaps = latest.policyGaps { out += ["**Policy incomplete**: \(gaps).", ""] }
        out.append("- \(latest.tally)")
        if !failed.isEmpty {
            let counts = Investigation.Severity.allCases.reversed().compactMap { severity -> String? in
                let count = failed.count { $0.severity == severity }
                return count == 0 ? nil : "\(count) \(severity.rawValue)"
            }
            out.append("- Failed by severity: \(counts.joined(separator: ", ")).")
        }
        if let previous, let changes { out.append("- " + diffLine(changes, since: when.full(previous.date))) }
        if let shared = latest.sharedProblemLine { out.append("- " + shared) }

        // MARK: Findings
        out += ["", "## Findings", ""]
        if failed.isEmpty { out.append("Nothing failed.") }
        for (index, result) in failed.enumerated() {
            if index > 0 { out.append("") }
            out.append("### \(index + 1). \(result.title)")
            out += ["", ([result.severity.title, result.findingID].compactMap { $0 } + ["`\(result.checkID)`"]).joined(separator: " · "), ""]
            out.append("**What was found.** \(result.summary.map(escaped) ?? result.title)")
            if result.offenderCount > 0 {
                out += ["", "Offenders (\(result.offenderCount)):", ""]
                let shown = result.offenders.prefix(listedOffenders)
                // Names the service gave, which outsiders may choose, so never read as Markdown.
                out += shown.map { "- " + code($0) }
                if result.offenderCount > shown.count { out.append("- …and \(result.offenderCount - shown.count) more.") }
            }
            if let check = byID[result.checkID] {
                out += ["", "**Why it matters.** \(check.rationale)", "", "**Fix.** \(check.fix)"]
            }
            if let id = result.evidenceID {
                let item = evidence[id]
                out += ["", "**Evidence.** \(id)" + (item.map { ", collected \(when.full($0.collectedAt)): " + code($0.method) } ?? ".")]
            }
            let cited = notes.filter { note in result.evidenceID.map(note.evidence.contains) ?? false }
            if !cited.isEmpty {
                out += ["", "**Agents' notes.**", ""]
                out += cited.map { "- \($0.id), by \(escaped(name($0.recordedBy))): \(escaped($0.claim))" }
            }
        }

        // MARK: Changes
        if let previous, let changes {
            out += ["", "## Changes since \(when.full(previous.date))", ""]
            if changes.isEmpty {
                out.append("Nothing changed.")
            } else {
                out += ["| Check | Before | Now |", "| --- | --- | --- |"]
                out += changes.map { row($0, before: previous, now: latest) }
            }
        }

        // MARK: Not checked
        out += ["", "## Not checked", ""]
        let skipped = latest.results.filter { $0.status == .couldNotRun }
        if skipped.isEmpty { out.append("Every check ran.") }
        let limited = skipped.filter { $0.obstacle == .limitation }
        let waiting = skipped.filter { $0.obstacle == .policy }
        let problems = skipped.filter(\.hasProblem)
        func item(_ result: CheckResult, reason: Bool = true) -> String {
            "- **\(result.title)**" + (result.evidenceID.map { " (\($0))" } ?? "") + (reason ? ": \(escaped(result.reason ?? ""))" : "")
                + (result.findingID.map { " Its earlier failure, \($0), stays open until a run can tell." } ?? "")
        }
        if !limited.isEmpty {
            out += ["### Limits of what could be read", "",
                    "These are limits of what the service lets Pion read here, not errors; each says where to check it instead.", ""]
            out += limited.map { item($0) }
            out.append("")
        }
        if !waiting.isEmpty {
            out += ["### Waiting on the policy", ""]
            out += waiting.map { item($0) }
            out.append("")
        }
        if !problems.isEmpty {
            out += ["### Couldn't run", ""]
            // A reason many share is said once, above the checks it stopped.
            var reasons: [String] = []
            for problem in problems where !reasons.contains(problem.reason ?? "") { reasons.append(problem.reason ?? "") }
            for reason in reasons {
                let stopped = problems.filter { ($0.reason ?? "") == reason }
                if stopped.count > 1 {
                    out += ["\(stopped.count) checks couldn't run: \(escaped(reason))", ""]
                    out += stopped.map { item($0, reason: false) }
                } else {
                    out += stopped.map { item($0) }
                }
                out.append("")
            }
        }
        if out.last == "" { out.removeLast() }

        // MARK: Passed
        out += ["", "## Passed", ""]
        let passed = latest.results.filter { $0.status == .pass }
        if passed.isEmpty { out.append("Nothing passed.") }
        out += passed.map { result in
            var line = "- **\(result.title)**: \(result.summary.map(escaped) ?? "Passed.")"
            if let resolved = result.resolves {
                line += " Fixed since the previous run: \(resolved) no longer holds" + (result.findingID.map { " (\($0))" } ?? "") + "."
            }
            return line
        }

        // MARK: Other findings
        out += ["", "## Other findings", ""]
        let latestEvidence = Set(latest.results.compactMap(\.evidenceID))
        let checkEvidence = Set(runs.flatMap { $0.results.compactMap(\.evidenceID) })
        let others = notes.filter { !$0.evidence.contains(where: failedEvidence.contains) }
        if others.isEmpty { out.append("None.") }
        out += others.map { note in
            let cites = note.evidence.isEmpty ? "" : " (cites \(note.evidence.joined(separator: ", ")))"
            // Citing only an earlier run's checks, it speaks of results that no longer stand.
            let earlier = !note.evidence.isEmpty && note.evidence.allSatisfy { checkEvidence.contains($0) && !latestEvidence.contains($0) }
            return "- \(note.id), by \(escaped(name(note.recordedBy))), \(when.full(note.recordedAt)): \(escaped(note.claim))\(cites)"
                + (earlier ? " This was about an earlier run's results." : "")
        }

        // MARK: Appendix
        out += ["", "## Appendix: the policy", "", "As it stood for the run on \(when.full(latest.date)).", "",
                "| Question | Answer |", "| --- | --- |"]
        out += AssessmentPolicy.keys.map { "| \($0) | \(cell(latest.policy.value(forKey: $0).map(escaped) ?? "unanswered")) |" }
        let kept = latest.policyBody
        let prose = (kept ?? policy.map(AssessmentPolicy.body(of:)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !prose.isEmpty {
            out += ["", "### Notes" + (kept == nil ? " (as they read now)" : ""), "", prose]
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// "<title> <date>.md", by the latest run's date, without characters a file name cannot hold.
    public static func fileName(of investigation: Investigation, runs: [AssessmentRun], timeZone: TimeZone = .current) -> String {
        let day = runs.last.map { " " + Dates(timeZone: timeZone).day($0.date) } ?? ""
        return (investigation.title + day).components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-") + ".md"
    }

    /// Such as "Since 2026-11-18 09:00 UTC: 1 newly failing, 1 fixed."
    static func diffLine(_ changes: [CheckChange], since date: String) -> String {
        guard !changes.isEmpty else { return "Nothing changed since \(date)." }
        var counts: [String] = []
        func add(_ label: String, _ labels: String? = nil, _ test: (CheckChange) -> Bool) {
            let count = changes.count(where: test)
            if count > 0 { counts.append("\(count) \(count == 1 ? label : labels ?? label)") }
        }
        add("newly failing") { if case .newlyFailing = $0 { true } else { false } }
        add("fixed") { if case .fixed = $0 { true } else { false } }
        add("still failing with different offenders") { if case .offendersChanged = $0 { true } else { false } }
        add("now couldn't run") { if case .nowCouldNotRun = $0 { true } else { false } }
        add("running again") { if case .runsAgain = $0 { true } else { false } }
        add("new") { if case .added = $0 { true } else { false } }
        add("no longer checked") { if case .removed = $0 { true } else { false } }
        add("policy answer changed", "policy answers changed") { if case .policy = $0 { true } else { false } }
        return "Since \(date): " + counts.joined(separator: ", ") + "."
    }

    /// One change as a row of check, before and now.
    static func row(_ change: CheckChange, before: AssessmentRun, now: AssessmentRun) -> String {
        func names(_ list: [String]) -> String {
            list.prefix(10).map(code).joined(separator: ", ") + (list.count > 10 ? " and \(list.count - 10) more" : "")
        }
        func result(_ id: String, in run: AssessmentRun) -> CheckResult? { run.results.first { $0.checkID == id } }
        // Without finding IDs: the run before's may since be replaced, and the Findings name those that stand.
        func state(_ result: CheckResult?) -> String {
            guard let result else { return "Not checked" }
            switch result.status {
            case .pass: return "Pass"
            case .couldNotRun: return "Couldn't run"
            case .fail: return "Fail, \(result.offenderCount) offender\(result.offenderCount == 1 ? "" : "s")"
            }
        }
        let cells: (String, String, String) = switch change {
        case .newlyFailing(let id, let title, let offenders):
            (title, state(result(id, in: before)), state(result(id, in: now)) + (offenders.isEmpty ? "" : ": " + names(offenders)))
        case .fixed(let id, let title, let finding):
            (title, state(result(id, in: before)), "Pass" + (finding.map { "; \($0) fixed" } ?? ""))
        case .offendersChanged(let id, let title, let added, let removed):
            (title, state(result(id, in: before)),
             ([state(result(id, in: now))] + [added.isEmpty ? nil : "added " + names(added), removed.isEmpty ? nil : "removed " + names(removed)]
                .compactMap { $0 }).joined(separator: "; "))
        case .nowCouldNotRun(let id, let title, let reason):
            (title, state(result(id, in: before)), "Couldn't run: " + escaped(reason))
        case .runsAgain(let id, let title, _):
            (title, state(result(id, in: before)), state(result(id, in: now)))
        case .added(let id, let title, _): (title, "Not checked", state(result(id, in: now)))
        case .removed(let id, let title): (title, state(result(id, in: before)), "No longer checked")
        case .policy(let key, let from, let to): ("Policy: \(key)", from.map(escaped) ?? "unanswered", to.map(escaped) ?? "unanswered")
        }
        return "| \(cell(cells.0)) | \(cell(cells.1)) | \(cell(cells.2)) |"
    }

    /// Text from outside Pion, such as a summary naming an app an outsider called anything, or an agent's note, as plain
    /// text on one line: no link, image, HTML, code, emphasis or block of its own, whatever it holds.
    static func escaped(_ text: String) -> String {
        var line = ""
        for character in oneLine(text) {
            switch character {
            case "&": line += "&amp;"
            case "<": line += "&lt;"
            case ">": line += "&gt;"
            case "\\", "`", "*", "_", "[", "]", "!", "|", "~": line += "\\" + String(character)
            default: line.append(character)
            }
        }
        // Nor may a bare address become a link, as GitHub's Markdown makes one of "https://…" or "www.…".
        line = line.replacingOccurrences(of: "://", with: "\\://")
            .replacingOccurrences(of: "www.", with: "www\\.", options: .caseInsensitive)
        // Where it begins a line, it must not begin a heading, list, quote or numbered item.
        if let first = line.first, "#-+".contains(first) { line = "\\" + line }
        if let digits = line.firstIndex(where: { !$0.isNumber }), digits > line.startIndex, ".)".contains(line[digits]) {
            line.insert("\\", at: digits)
        }
        return line
    }

    /// Text that stays in one table cell.
    static func cell(_ text: String) -> String {
        // A pipe `escaped` already escaped stays as it is.
        oneLine(text).replacingOccurrences(of: "\\|", with: "\u{0}").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\u{0}", with: "\\|")
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `text` as inline code, fenced with more backticks than it holds in a row.
    static func code(_ text: String) -> String {
        var longest = 0, run = 0
        for character in text { run = character == "`" ? run + 1 : 0; longest = max(longest, run) }
        let fence = String(repeating: "`", count: longest + 1)
        let padded = longest > 0 ? " \(oneLine(text)) " : oneLine(text)
        return fence + padded + fence
    }

    /// Dates as the report writes them, in one time zone, whatever the reader's language.
    struct Dates {
        private let full: DateFormatter, day: DateFormatter

        init(timeZone: TimeZone) {
            func formatter(_ format: String) -> DateFormatter {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = timeZone
                formatter.dateFormat = format
                return formatter
            }
            full = formatter("yyyy-MM-dd HH:mm zzz")
            day = formatter("yyyy-MM-dd")
        }

        /// Such as "2026-11-25 14:03 UTC".
        func full(_ date: Date) -> String { full.string(from: date) }
        /// Such as "2026-11-25".
        func day(_ date: Date) -> String { day.string(from: date) }
    }
}
