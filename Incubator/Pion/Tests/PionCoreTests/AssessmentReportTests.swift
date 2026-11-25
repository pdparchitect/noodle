import Foundation
@testable import PionCore
import XCTest

/// The Markdown report of an Assessment, and how a run says what kept checks from running: the policy, a limit of
/// what can be read, or a problem many checks share, said once.
final class AssessmentReportTests: XCTestCase {
    private let checks = CaseActor.checks(champion: "Avery")
    private let ada = UUID()
    private let utc = TimeZone(identifier: "UTC")!
    private let first = Date(timeIntervalSince1970: 1_795_000_000)
    private var second: Date { first.addingTimeInterval(7 * 86400) }

    private static func check(_ id: String, _ title: String, _ severity: Investigation.Severity, policyKeys: [String] = []) -> AssessmentCheck {
        AssessmentCheck(id: id, title: title, severity: severity, rationale: "Why \(id) matters.", fix: "How to fix \(id).",
                        source: "Test", policyKeys: policyKeys, reads: { _ in [] }, evaluate: { _, _ in .pass("") })
    }

    private static let low = check("test.low", "Low thing", .low)
    private static let critical = check("test.critical", "Critical thing", .critical)
    private static let high = check("test.high", "High thing", .high)
    private static let fixed = check("test.fixed", "Fixed thing", .medium)
    private static let settings = check("test.settings", "Settings thing", .medium)
    private static let policyNeeded = check("test.policy", "Policy thing", .medium, policyKeys: ["max-super-admins"])
    private static let connectionA = check("test.conn-a", "First connected thing", .high)
    private static let connectionB = check("test.conn-b", "Second connected thing", .high)
    private static let passing = check("test.pass", "Passing thing", .low)

    private static let many = (1...60).map { String(format: "user%02d@example.com", $0) }
    private static let limit = "This needs a super admin to read the organisation's settings; check it in the Admin console instead."
    private static let notConnected = "Workspace isn't connected."

    /// Two runs: the high check's offenders change, so its finding is replaced; the fixed check passes, so its failure
    /// is marked fixed. Ada notes the critical failure and, apart from any check, something else.
    private func fixture() throws -> (record: CaseRecord, runs: [AssessmentRun], superseded: [String], current: [String: String]) {
        var record = CaseRecord()
        var policy = AssessmentPolicy.defaults
        let one = AssessmentRun(date: first, connection: "Workspace", policy: policy, policyBody: "Old notes.", results: [
            CheckResult(check: Self.low, status: .fail, summary: "1 low.", offenders: ["lo@example.com"]),
            CheckResult(check: Self.critical, status: .fail, summary: "60 critical.", offenders: Self.many),
            CheckResult(check: Self.high, status: .fail, summary: "2 high.", offenders: ["a@example.com", "b@example.com"]),
            CheckResult(check: Self.fixed, status: .fail, summary: "1 to fix.", offenders: ["fix@example.com"]),
            CheckResult(check: Self.passing, status: .pass, summary: "All good."),
        ]).recording(into: &record, previous: nil, by: checks, at: first)
        try record.record(finding: "Earlier note on the high thing.", evidence: [one.results[2].evidenceID!], confidence: .medium,
                          entities: [], by: .agent(ada), at: first)

        policy.maxSuperAdmins = nil
        let two = AssessmentRun(date: second, connection: "Workspace", policy: policy, policyBody: "Contractors may use personal phones.", results: [
            CheckResult(check: Self.low, status: .fail, summary: "1 low.", offenders: ["lo@example.com"]),
            CheckResult(check: Self.critical, status: .fail, summary: "60 critical.", offenders: Self.many),
            CheckResult(check: Self.high, status: .fail, summary: "1 high.", offenders: ["a@example.com"]),
            CheckResult(check: Self.fixed, status: .pass, summary: "Nothing to fix."),
            CheckResult(check: Self.passing, status: .pass, summary: "All good."),
            CheckResult(check: Self.settings, status: .couldNotRun, reason: Self.limit, obstacle: .limitation),
            CheckResult(check: Self.policyNeeded, status: .couldNotRun,
                        reason: "The policy doesn't say how many super admins there may be; answer it in the questionnaire.", obstacle: .policy),
            CheckResult(check: Self.connectionA, status: .couldNotRun, reason: Self.notConnected, obstacle: .problem),
            CheckResult(check: Self.connectionB, status: .couldNotRun, reason: Self.notConnected, obstacle: .problem),
        ]).recording(into: &record, previous: one, by: checks, at: second)
        try record.record(finding: "The critical thing is worst for admins.", evidence: [two.results[1].evidenceID!], confidence: .high,
                          entities: [], by: .agent(ada), at: second)
        try record.record(finding: "Someone shared a drive publicly.", evidence: [], confidence: .low, entities: [], by: .agent(ada), at: second)

        let current = Dictionary(uniqueKeysWithValues: two.results.compactMap { result in result.findingID.map { (result.checkID, $0) } })
        // The high check's first finding was replaced, and the fixed check's marked fixed.
        let superseded = [one.results[2].findingID!]
        return (record, [one, two], superseded, current)
    }

    private func report(_ fixture: (record: CaseRecord, runs: [AssessmentRun], superseded: [String], current: [String: String]),
                        checks: [AssessmentCheck]? = nil) -> String {
        AssessmentReport.markdown(investigation: assessment, record: fixture.record, runs: fixture.runs, policy: nil,
                                  checks: checks ?? [Self.critical, Self.high, Self.fixed, Self.settings, Self.policyNeeded,
                                                     Self.connectionA, Self.connectionB, Self.passing],
                                  timeZone: utc) { actor in
            if case .agent = actor { "Ada" } else { "someone" }
        }
    }

    private let assessment = Investigation(id: UUID(), number: 7, title: "Workspace review", objective: "Hold Workspace to the policy",
                                           champion: "Avery", kind: .assessment)

    /// The text from `heading` to the next heading of its level or higher.
    private func section(_ heading: String, of text: String) -> String {
        guard let start = text.range(of: heading + "\n") else { return "" }
        let level = heading.prefix { $0 == "#" }.count
        let rest = text[start.upperBound...]
        let next = rest.ranges(of: "\n#").first { range in
            let hashes = rest[range.upperBound...].prefix { $0 == "#" }.count + 1
            return hashes <= level
        }
        return String(rest[..<(next?.lowerBound ?? rest.endIndex)])
    }

    func testTheReportsSectionsComeInOrder() throws {
        let text = report(try fixture())
        let headings = ["# Workspace review (INV-0007)", "## Summary", "## Findings", "## Changes since", "## Not checked", "## Passed",
                        "## Other findings", "## Appendix: the policy"]
        let positions = headings.map { text.range(of: $0)?.lowerBound }
        XCTAssertFalse(positions.contains(nil), text)
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted(), text)
        XCTAssertTrue(text.hasPrefix("""
            # Workspace review (INV-0007)

            - Champion: Avery
            - Latest run: 2026-11-25 11:06 GMT
            - Connection: Workspace
            - Previous run: 2026-11-18 11:06 GMT

            ## Summary

            **Policy incomplete**: it doesn't answer max-super-admins, which 1 check needs.

            - Ran 9 checks: 3 failed, 2 passed, 4 couldn't run.
            - Failed by severity: 1 critical, 1 high, 1 low.
            - Since 2026-11-18 11:06 GMT: 1 fixed, 1 still failing with different offenders, 4 new, 1 policy answer changed.

            """), text)
        XCTAssertEqual(AssessmentReport.fileName(of: assessment, runs: try fixture().runs, timeZone: utc), "Workspace review 2026-11-25.md")
    }

    func testFindingsGoMostSevereFirstWithTheirWhyFixEvidenceAndNotes() throws {
        let fixture = try fixture()
        let findings = section("## Findings", of: report(fixture))
        let order = ["### 1. Critical thing", "### 2. High thing", "### 3. Low thing"].map { findings.range(of: $0)?.lowerBound }
        XCTAssertFalse(order.contains(nil), findings)
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted(), findings)

        let critical = section("### 1. Critical thing", of: findings)
        XCTAssertTrue(critical.contains("Critical · \(fixture.current["test.critical"]!) · `test.critical`"), critical)
        XCTAssertTrue(critical.contains("**What was found.** 60 critical."), critical)
        XCTAssertTrue(critical.contains("Offenders (60):"), critical)
        XCTAssertEqual(critical.components(separatedBy: "\n").filter { $0.hasPrefix("- `user") }.count, AssessmentReport.listedOffenders)
        XCTAssertTrue(critical.contains("- `user50@example.com`\n- …and 10 more."), critical)
        XCTAssertFalse(critical.contains("user51@example.com"), critical)
        XCTAssertTrue(critical.contains("**Why it matters.** Why test.critical matters."), critical)
        XCTAssertTrue(critical.contains("**Fix.** How to fix test.critical."), critical)
        XCTAssertTrue(critical.contains("**Evidence.** V-7, collected 2026-11-25 11:06 GMT: `Check test.critical`"), critical)
        XCTAssertTrue(critical.contains("**Agents' notes.**\n\n- F-8, by Ada: The critical thing is worst for admins."), critical)

        // A check no longer in the checklist still reports what it found, without a why or a fix.
        let low = section("### 3. Low thing", of: findings)
        XCTAssertTrue(low.contains("**What was found.** 1 low."), low)
        XCTAssertFalse(low.contains("**Why it matters.**") || low.contains("**Fix.**"), low)
    }

    /// Only the latest run's findings stand: one replaced, or marked fixed, stays in the record but isn't current.
    func testSupersededFindingsArentShownAsCurrent() throws {
        let fixture = try fixture()
        let text = report(fixture)
        let findings = section("## Findings", of: text)
        for id in fixture.superseded {
            XCTAssertTrue(fixture.record.findings.contains { $0.id == id }, "it stays in the record")
            XCTAssertFalse(text.contains(id), "\(id) was replaced:\n\(text)")
        }
        XCTAssertTrue(section("### 2. High thing", of: findings).contains(fixture.current["test.high"]!), findings)
        // The fixed failure is named only as fixed.
        let fixedFinding = fixture.runs[0].results[3].findingID!
        XCTAssertFalse(findings.contains(fixedFinding), findings)
        XCTAssertTrue(section("## Passed", of: text).contains(
            "- **Fixed thing**: Nothing to fix. Fixed since the previous run: \(fixedFinding) no longer holds (\(fixture.current["test.fixed"]!))."), text)
    }

    func testChangesNotCheckedAndOtherFindings() throws {
        let text = report(try fixture())
        let changes = section("## Changes since 2026-11-18 11:06 GMT", of: text)
        XCTAssertTrue(changes.contains("| Check | Before | Now |"), changes)
        XCTAssertTrue(changes.contains("| Policy: max-super-admins | 3 | unanswered |"), changes)
        XCTAssertTrue(changes.contains("| High thing | Fail, 2 offenders | Fail, 1 offender; removed `b@example.com` |"), changes)
        XCTAssertTrue(changes.contains("| Fixed thing | Fail, 1 offender | Pass; F-4 fixed |"), changes)
        XCTAssertTrue(changes.contains("| Settings thing | Not checked | Couldn't run |"), changes)

        let skipped = section("## Not checked", of: text)
        let limits = section("### Limits of what could be read", of: skipped)
        XCTAssertTrue(limits.contains("not errors"), limits)
        XCTAssertTrue(limits.contains("- **Settings thing** (V-11): \(Self.limit)"), limits)
        XCTAssertTrue(section("### Waiting on the policy", of: skipped).contains("- **Policy thing** (V-12): The policy doesn't say"), skipped)
        let problems = section("### Couldn't run", of: skipped)
        XCTAssertFalse(problems.contains("Settings thing"), "A limitation isn't an error:\n\(skipped)")
        XCTAssertTrue(problems.contains("2 checks couldn't run: \(Self.notConnected)\n\n- **First connected thing** (V-13)\n- **Second connected thing** (V-14)"),
                      problems)

        let others = section("## Other findings", of: text)
        XCTAssertTrue(others.contains("- F-9, by Ada, 2026-11-25 11:06 GMT: Someone shared a drive publicly."), others)
        XCTAssertTrue(others.contains("Earlier note on the high thing. (cites V-3) This was about an earlier run's results."), others)
        XCTAssertFalse(others.contains("worst for admins"), "A note on a failure goes with it:\n\(others)")

        let appendix = section("## Appendix: the policy", of: text)
        XCTAssertTrue(appendix.contains("| max-super-admins | unanswered |"), appendix)
        XCTAssertTrue(appendix.contains("| two-step-verification | required |"), appendix)
        XCTAssertTrue(appendix.contains("### Notes\n\nContractors may use personal phones."), appendix)
        XCTAssertFalse(appendix.contains("Old notes."), appendix)
    }

    /// Names, summaries and notes come from outside: an app's name is whatever its maker chose. None of it may become a
    /// link, HTML or a heading in a report someone forwards.
    func testTextFromOutsideIsNeverReadAsMarkdownOrHTML() throws {
        let hostile = "# Security update [verify here](https://evil.example) <script>alert(1)</script><img src=x onerror=alert(1)>\n# Owned"
        var record = CaseRecord()
        let run = AssessmentRun(date: first, connection: "Workspace", policy: .defaults, results: [
            CheckResult(check: Self.critical, status: .fail, summary: hostile, offenders: [hostile, "1. `tick` www.evil.example"]),
        ]).recording(into: &record, previous: nil, by: checks, at: first)
        try record.record(finding: hostile, evidence: [run.results[0].evidenceID!], confidence: .low, entities: [], by: .agent(ada), at: first)
        try record.record(finding: "- " + hostile, evidence: [], confidence: .low, entities: [], by: .agent(ada), at: first)
        let text = AssessmentReport.markdown(investigation: assessment, record: record, runs: [run], timeZone: utc) { _ in "Ada" }

        let lines = text.components(separatedBy: "\n")
        // Outside an offender's code span, nothing opens a link or a tag, and no address can become one.
        let outside = lines.filter { !($0.hasPrefix("- `") && $0.hasSuffix("`")) }.joined(separator: "\n")
        for live in ["https://", "<script", "<img", "<", "www.evil"] { XCTAssertFalse(outside.contains(live), "\(live) is live:\n\(text)") }
        XCTAssertNil(outside.range(of: #"(?<!\\)[\[\]]"#, options: .regularExpression), "an unescaped bracket:\n\(text)")
        let headings = lines.filter { $0.hasPrefix("#") }
        XCTAssertEqual(headings, ["# Workspace review (INV-0007)", "## Summary", "## Findings", "### 1. Critical thing", "## Not checked", "## Passed",
                                  "## Other findings", "## Appendix: the policy"], text)
        XCTAssertFalse(lines.contains { $0.hasPrefix("# Owned") || $0.hasPrefix("1. ") }, text)
        XCTAssertTrue(text.contains("**What was found.** \\# Security update \\[verify here\\](https\\://evil.example) &lt;script&gt;alert(1)&lt;/script&gt;&lt;img src=x onerror=alert(1)&gt; # Owned"), text)
        XCTAssertTrue(text.contains("- `` 1. `tick` www.evil.example ``"), "an offender is code:\n\(text)")
        XCTAssertTrue(text.contains("- `# Security update [verify here](https://evil.example) <script>alert(1)</script><img src=x onerror=alert(1)> # Owned`"), text)
        XCTAssertTrue(text.contains("- F-2, by Ada: \\# Security update"), text)
        XCTAssertTrue(text.contains("- F-3, by Ada, 2026-11-18 11:06 GMT: \\- # Security update \\[verify here\\]"), text)
    }

    func testAReportWithNothingFailedOrNoRunYet() {
        var record = CaseRecord()
        let run = AssessmentRun(date: first, connection: nil, policy: .defaults, results: [
            CheckResult(check: Self.passing, status: .pass, summary: "All good."),
        ]).recording(into: &record, previous: nil, by: checks, at: first)
        let text = AssessmentReport.markdown(investigation: assessment, record: record, runs: [run],
                                             policy: "---\ndevices: company-only\n---\n\nAs it reads now.", timeZone: utc) { _ in "" }
        XCTAssertTrue(text.contains("- Connection: none"), text)
        XCTAssertFalse(text.contains("## Changes since") || text.contains("Policy incomplete") || text.contains("Previous run"), text)
        XCTAssertTrue(section("## Findings", of: text).contains("Nothing failed."), text)
        XCTAssertTrue(section("## Not checked", of: text).contains("Every check ran."), text)
        XCTAssertTrue(text.contains("### Notes (as they read now)\n\nAs it reads now."), text)

        let empty = AssessmentReport.markdown(investigation: assessment, record: CaseRecord(), runs: [], timeZone: utc) { _ in "" }
        XCTAssertTrue(empty.contains("No checks have run yet."), empty)
        XCTAssertEqual(AssessmentReport.fileName(of: assessment, runs: []), "Workspace review.md")
    }

    // MARK: What kept checks from running

    private static let things = CheckRead("things", ["limit": .number(4)], items: "things")

    private static func reading(_ id: String, unread: @escaping @Sendable (String) -> String = { $0 },
                                reads: @escaping @Sendable (AssessmentPolicy) throws -> [CheckRead] = { _ in [things] }) -> AssessmentCheck {
        AssessmentCheck(id: id, title: id, severity: .high, rationale: "", fix: "", source: "Test", policyKeys: ["max-super-admins"],
                        unread: unread, reads: reads) { inputs, _ in
            struct Listed: Decodable { let things: [String] }
            return try inputs.decode(Listed.self, from: things).things.isEmpty ? .pass("None.") : .fail("Some.", offenders: ["x"])
        }
    }

    private static func answer(_ structured: [String: Any]? = nil, text: String = "", isError: Bool = false) -> Data {
        var object: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
        if let structured { object["structuredContent"] = structured }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func testARunSaysWhatKeptEachCheckFromRunning() async {
        let needy = Self.reading("test.needy", reads: { policy in
            _ = try policy.required(policy.maxSuperAdmins, "how many super admins there may be")
            return [Self.things]
        })
        let known = Self.reading("test.known", unread: { $0.contains("super admin") ? "This needs a super admin." : $0 })
        let limited = Self.reading("test.limited", reads: { _ in throw AssessmentCheckError.limitation("Google doesn't say.") })
        let refused: AssessmentCall = { _, _ in Self.answer(text: "Only a super admin may read this.", isError: true) }
        let run = await AssessmentRunner.run([needy, known, limited, Self.reading("test.plain")], policy: AssessmentPolicy(),
                                             detection: refused, containment: nil)
        XCTAssertEqual(run.results.map(\.obstacle), [.policy, .limitation, .limitation, .problem])
        XCTAssertEqual(run.results[1].reason, "This needs a super admin.")
        XCTAssertTrue(run.isPolicyIncomplete)
        XCTAssertEqual(run.unansweredKeys, ["max-super-admins"])
        XCTAssertNil(run.sharedProblem, "one problem alone is said where it is")

        let partial: AssessmentCall = { _, _ in Self.answer(["things": [], "incomplete": true]) }
        let cut = await AssessmentRunner.run([Self.reading("test.cut")], policy: .defaults, detection: partial, containment: nil)
        XCTAssertEqual(cut.results.first?.obstacle, .limitation)
        XCTAssertFalse(cut.isPolicyIncomplete)

        let passed = await AssessmentRunner.run([Self.reading("test.ok")], policy: .defaults,
                                                detection: { _, _ in Self.answer(["things": []]) }, containment: nil)
        XCTAssertNil(passed.results.first?.obstacle)
    }

    func testTheAnnouncementSaysASharedProblemOnceAndLabelsAnIncompletePolicy() async {
        let needy = Self.reading("test.needy", reads: { policy in
            _ = try policy.required(policy.maxSuperAdmins, "how many super admins there may be")
            return [Self.things]
        })
        let run = await AssessmentRunner.run([Self.reading("test.a"), Self.reading("test.b"), Self.reading("test.c")], policy: .defaults,
                                             detection: nil, containment: nil)
        let reason = "Google Workspace Detection isn't connected or given to an agent on this Assessment."
        XCTAssertEqual(run.sharedProblem?.reason, reason)
        let text = run.announcement(changes: nil)
        XCTAssertTrue(text.hasPrefix("Pion's checks ran. \(run.tally)\n\(reason) None of the checks could run.\n"), text)
        XCTAssertEqual(text.components(separatedBy: "isn't connected").count, 2, "said once:\n\(text)")
        XCTAssertTrue(text.contains("Couldn't run:\n- test.a\n- test.b\n- test.c"), text)
        XCTAssertFalse(text.contains("Policy incomplete"), text)

        var policy = AssessmentPolicy.defaults
        policy.maxSuperAdmins = nil
        let mixed = await AssessmentRunner.run([Self.reading("test.a"), Self.reading("test.b"), needy], policy: policy,
                                               detection: nil, containment: nil)
        let said = mixed.announcement(changes: nil)
        XCTAssertTrue(said.contains("\(reason) 2 of the 3 checks couldn't run because of it."), said)
        XCTAssertTrue(said.contains("Policy incomplete: it doesn't answer max-super-admins, which 1 check needs."), said)
        XCTAssertTrue(said.contains("- test.needy: The policy doesn't say how many super admins"), said)
    }
}
