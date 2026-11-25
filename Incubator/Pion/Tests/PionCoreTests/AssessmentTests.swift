import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class AssessmentTests: XCTestCase {
    private var root: URL!
    private var store: PionStore!
    private let checks = CaseActor.checks(champion: "Avery")
    private let workspace = try! GoogleWorkspace.preset.makeConnection(name: "Workspace", values: ["clientID": "1234-abc.apps.googleusercontent.com"])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AssessmentTests-\(UUID().uuidString)", isDirectory: true)
        store = PionStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Stand-ins

    /// The tools a stand-in call was asked for, in order.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String] = []
        var tools: [String] { lock.withLock { made } }
        func add(_ tool: String) { lock.withLock { made.append(tool) } }
    }

    /// A tools/call result as Pion's adapters give it.
    private static func answer(_ structured: [String: Any]? = nil, text: String = "", isError: Bool = false) -> Data {
        var object: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
        if let structured { object["structuredContent"] = structured }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private static let things = CheckRead("things", ["limit": .number(4)], items: "things")

    /// A check that fails on every thing named bad in `read`'s answer.
    private static func check(_ id: String = "test.bad-things", read: CheckRead = things, policyKeys: [String] = [],
                              reads: (@Sendable (AssessmentPolicy) throws -> [CheckRead])? = nil) -> AssessmentCheck {
        AssessmentCheck(id: id, title: "No bad things", severity: .high, rationale: "Bad things are bad.", fix: "Remove them.",
                        source: "Test", policyKeys: policyKeys, reads: reads ?? { _ in [read] }) { inputs, _ in
            struct Listed: Decodable { let things: [String] }
            let bad = try inputs.decode(Listed.self, from: read).things.filter { $0.hasPrefix("bad") }
            return bad.isEmpty ? .pass("No bad things.") : .fail("\(bad.count) bad things.", offenders: bad)
        }
    }

    private func call(_ calls: Calls = Calls(), _ answer: @escaping @Sendable (String) throws -> Data) -> AssessmentCall {
        { tool, _ in calls.add(tool); return try answer(tool) }
    }

    private func runChecks(_ checks: [AssessmentCheck], policy: AssessmentPolicy = AssessmentPolicy(),
                     detection: AssessmentCall?, containment: AssessmentCall? = nil) async -> AssessmentRun {
        await AssessmentRunner.run(checks, policy: policy, connection: "Workspace", detection: detection, containment: containment,
                                   now: Date(timeIntervalSince1970: 1_000))
    }

    private func result(_ things: [String], incomplete: Bool? = nil) async -> AssessmentRun {
        var structured: [String: Any] = ["things": things]
        if let incomplete { structured["incomplete"] = incomplete }
        let answer = Self.answer(structured)
        return await runChecks([Self.check()], detection: call { _ in answer })
    }

    // MARK: Policy

    func testPolicyRoundTripsAndKeepsTheProseUnderIt() {
        let prose = "# Our policy\n\nContractors use their own laptops until March.\n"
        var policy = AssessmentPolicy.defaults
        policy.approvedApps = ["111.apps.googleusercontent.com", "222"]
        let markdown = policy.markdown(body: prose)
        XCTAssertEqual(AssessmentPolicy(markdown: markdown), policy)
        XCTAssertEqual(AssessmentPolicy.body(of: markdown), prose)
        var changed = policy
        changed.maxSuperAdmins = 2
        let rewritten = changed.markdown(keepingBody: markdown)
        XCTAssertEqual(AssessmentPolicy(markdown: rewritten), changed)
        XCTAssertTrue(rewritten.hasSuffix(prose), rewritten)
        XCTAssertEqual(changed.changes(from: policy).map(\.key), ["max-super-admins"])
        XCTAssertEqual(AssessmentPolicy(markdown: AssessmentPolicy().markdown(body: "")), AssessmentPolicy())
    }

    func testPolicyLeavesWhatItCannotReadUnansweredAndIgnoresCommentsAndUnknownKeys() {
        let policy = AssessmentPolicy(markdown: """
            ---
            # what we allow
            devices: sometimes
            external-sharing: "not-allowed"
            two-step-verification: Required # everyone
            max-super-admins: 0
            inactive-account-days: ninety
            stale-device-days: 30
            colour: blue
            approved-apps:
              - 111.apps.googleusercontent.com
              - '222'
            ---
            Prose.
            """)
        XCTAssertNil(policy.devices)
        XCTAssertEqual(policy.externalSharing, .notAllowed)
        XCTAssertEqual(policy.twoStepVerification, .required)
        XCTAssertNil(policy.maxSuperAdmins)
        XCTAssertNil(policy.inactiveAccountDays)
        XCTAssertEqual(policy.staleDeviceDays, 30)
        XCTAssertEqual(policy.approvedApps, ["111.apps.googleusercontent.com", "222"])
        XCTAssertEqual(AssessmentPolicy(markdown: "No front matter at all."), AssessmentPolicy())
        XCTAssertEqual(AssessmentPolicy.body(of: "No front matter at all."), "No front matter at all.")
        XCTAssertEqual(AssessmentPolicy(markdown: "---\napproved-apps: []\n---\n").approvedApps, [])
        XCTAssertNil(AssessmentPolicy(markdown: "---\napproved-apps: [111\n---\n").approvedApps)
    }

    /// Each Assessment keeps its own policy; the template is only where a new one's questionnaire starts.
    func testAnAssessmentKeepsItsOwnPolicyAndLogsWhatChanged() throws {
        let assessment = try store.open(id: UUID(), title: "Workspace review", objective: "", champion: "Avery", kind: .assessment)
        XCTAssertNil(store.readPolicy(assessment.id))
        XCTAssertNil(store.readPolicyTemplate())
        try store.writePolicyTemplate(.defaults)
        XCTAssertEqual(store.readPolicyTemplate(), .defaults)
        XCTAssertEqual(store.policyTemplateURL.lastPathComponent, "Policy.md")

        try store.writePolicy(.defaults, in: assessment.id, body: "Contractors may share with their agencies.\n", by: .champion("Avery"))
        var relaxed = AssessmentPolicy.defaults
        relaxed.twoStepVerification = .optional
        try store.writePolicy(relaxed, in: assessment.id, by: .champion("Avery"))
        XCTAssertEqual(store.readPolicy(assessment.id), relaxed)
        let markdown = try String(contentsOf: store.policyURL(assessment.id), encoding: .utf8)
        XCTAssertTrue(markdown.hasSuffix("Contractors may share with their agencies.\n"), markdown)
        XCTAssertEqual(store.audit(assessment.id).last?.detail, "Policy: two-step-verification required → optional.")
        XCTAssertEqual(store.readPolicyTemplate(), .defaults, "the template is not the Assessment's")
    }

    // MARK: Runner

    func testAnAnswerPassesOrFailsWithSortedOffenders() async {
        let failed = await result(["ok", "bad-2", "bad-10"])
        XCTAssertEqual(failed.results.first?.status, .fail)
        XCTAssertEqual(failed.results.first?.offenders, ["bad-2", "bad-10"])
        XCTAssertEqual(failed.results.first?.offenderCount, 2)
        XCTAssertEqual(failed.results.first?.summary, "2 bad things.")
        let passed = await result(["ok"])
        XCTAssertEqual(passed.results.first?.status, .pass)
        XCTAssertEqual(passed.tally, "Ran 1 check: 0 failed, 1 passed, 0 couldn't run.")
    }

    func testChecksAskingTheSameAreAnsweredByOneRead() async {
        let calls = Calls()
        let run = await runChecks([Self.check("a"), Self.check("b")], detection: call(calls) { _ in Self.answer(["things": ["bad"]]) })
        XCTAssertEqual(calls.tools, ["things"])
        XCTAssertEqual(run.results.map(\.checkID), ["a", "b"])
        XCTAssertEqual(run.results.map(\.status), [.fail, .fail])
    }

    func testAMissingConnectionMeansItCouldNotRun() async {
        let run = await runChecks([Self.check(), Self.check("test.held", read: CheckRead("apps", needsContainment: true))], detection: nil,
                            containment: nil)
        XCTAssertEqual(run.results.map(\.status), [.couldNotRun, .couldNotRun])
        XCTAssertEqual(run.results[0].reason, "Google Workspace Detection isn't connected or given to an agent on this Assessment.")
        XCTAssertEqual(run.results[1].reason, "This check needs Google Workspace Containment, which isn't connected or given to an agent on this Assessment.")
    }

    func testAReadThatThrowsFailsOrAnswersOddlyMeansItCouldNotRun() async {
        struct Down: LocalizedError { var errorDescription: String? { "The connection timed out." } }
        let thrown = await runChecks([Self.check()], detection: call { _ in throw Down() })
        XCTAssertEqual(thrown.results.first?.reason, "The connection timed out.")
        let refused = await runChecks([Self.check()], detection: call { _ in Self.answer(text: "Google refused users: add Users › Read.", isError: true) })
        XCTAssertEqual(refused.results.first?.status, .couldNotRun)
        XCTAssertEqual(refused.results.first?.reason, "Google refused users: add Users › Read.")
        let bare = await runChecks([Self.check()], detection: call { _ in Self.answer(text: "Some text") })
        XCTAssertEqual(bare.results.first?.reason, "things gave an unexpected answer.")
        let odd = await runChecks([Self.check()], detection: call { _ in Self.answer(["other": 1]) })
        XCTAssertEqual(odd.results.first?.reason, "things gave an unexpected answer.")
    }

    func testAMissingPolicyAnswerIsAskedForInsteadOfAssumed() async {
        let calls = Calls()
        let needy = Self.check(policyKeys: ["two-step-verification"]) { policy in
            _ = try policy.required(policy.twoStepVerification, "whether 2-step verification is required")
            return [Self.things]
        }
        let run = await runChecks([needy], detection: call(calls) { _ in Self.answer(["things": []]) })
        XCTAssertEqual(run.results.first?.status, .couldNotRun)
        XCTAssertEqual(run.results.first?.reason, "The policy doesn't say whether 2-step verification is required; answer it in the questionnaire.")
        XCTAssertEqual(calls.tools, [], "nothing is read for a check that cannot run")
    }

    /// A failure found in part of the answer stands, saying so; a pass on part of it is no pass.
    func testAReadInPartFailsWithACaveatButNeverPasses() async {
        let failed = await result(["bad", "ok"], incomplete: true)
        XCTAssertEqual(failed.results.first?.status, .fail)
        XCTAssertEqual(failed.results.first?.summary, "1 bad things. This is based on only the 2 things read; there are more.")
        let passed = await result(["ok"], incomplete: true)
        XCTAssertEqual(passed.results.first?.status, .couldNotRun)
        XCTAssertEqual(passed.results.first?.reason, "things was read only in part, and a pass needs all of it.")
        // As many as the limit asked for may have had more.
        let full = await result(["ok", "ok", "ok", "ok"])
        XCTAssertEqual(full.results.first?.status, .couldNotRun)
        let counted = await runChecks([Self.check()], detection: call { _ in Self.answer(["things": ["bad"], "incomplete": ["things"], "total": 9]) })
        XCTAssertEqual(counted.results.first?.summary, "1 bad things. This is based on 1 of 9 things read.")
    }

    // MARK: Recording

    private func assessment() throws -> Investigation {
        try store.open(id: UUID(), title: "Workspace review", objective: "Hold Workspace to the policy", champion: "Avery", kind: .assessment)
    }

    func testARunIsRecordedAsEvidenceAndFindingsByTheChecks() async throws {
        let assessment = try assessment()
        let run = await AssessmentRunner.run([Self.check(), Self.check("test.fine", read: CheckRead("other", items: "things"))],
                                             policy: AssessmentPolicy(), detection: call { tool in
                                                 Self.answer(["things": tool == "things" ? ["bad-1"] : ["ok"]])
                                             }, containment: nil, now: Date(timeIntervalSince1970: 1_000))
        let recorded = try store.recordAssessment(run, in: assessment.id, by: checks)
        XCTAssertEqual(recorded.results.map(\.evidenceID), ["V-1", "V-2"])
        XCTAssertEqual(recorded.results.map(\.findingID), ["F-1", nil])
        let record = store.caseRecord(assessment.id)
        XCTAssertEqual(record.findings.first?.evidence, ["V-1"])
        XCTAssertEqual(record.findings.first?.entities, ["bad-1"])
        XCTAssertEqual(record.findings.first?.confidence, .high)
        XCTAssertEqual(record.findings.first?.recordedBy, checks)
        XCTAssertEqual(record.evidence.first?.method, "Check test.bad-things: things {\"limit\":4}")
        XCTAssertTrue(record.evidence.first?.result.contains("Offenders: bad-1.") == true, record.evidence.first?.result ?? "")
        XCTAssertEqual(store.assessmentRuns(assessment.id), [recorded])
        let audit = store.audit(assessment.id).filter { $0.event == "checks" }
        XCTAssertEqual(audit.map(\.detail), ["Ran 2 checks: 1 failed, 1 passed, 0 couldn't run."])
        XCTAssertEqual(audit.first?.actor, checks)
    }

    func testAnUnchangedFailureCarriesItsFindingAndAChangedOneReplacesIt() {
        var record = CaseRecord()
        let first = AssessmentRun(date: Date(), connection: nil, policy: AssessmentPolicy(),
                                  results: [CheckResult(check: Self.check(), status: .fail, summary: "1 bad", offenders: ["bad-1"])])
            .recording(into: &record, previous: nil, by: checks, at: Date())
        let same = first.recordingAgain(into: &record, offenders: ["bad-1"])
        XCTAssertEqual(same.results.first?.findingID, "F-1")
        XCTAssertEqual(same.results.first?.evidenceID, "V-2", "every run is evidence")
        let changed = same.recordingAgain(into: &record, offenders: ["bad-1", "bad-2"])
        XCTAssertEqual(changed.results.first?.findingID, "F-2")
        XCTAssertEqual(record.findings.last?.claim, "1 bad This replaces F-1.")
        XCTAssertEqual(record.findings.count, 2)
    }

    /// Fixed shows in the record as a finding of its own, as nothing recorded is ever changed or removed.
    func testAFixedFailureIsMarkedFixedInTheRecordAndTheChanges() {
        var record = CaseRecord()
        let failed = AssessmentRun(date: Date(), connection: nil, policy: AssessmentPolicy(),
                                   results: [CheckResult(check: Self.check(), status: .fail, summary: "1 bad", offenders: ["bad-1"])])
            .recording(into: &record, previous: nil, by: checks, at: Date())
        let fixed = AssessmentRun(date: Date(), connection: nil, policy: AssessmentPolicy(),
                                  results: [CheckResult(check: Self.check(), status: .pass, summary: "No bad things.")])
            .recording(into: &record, previous: failed, by: checks, at: Date())
        XCTAssertEqual(fixed.results.first?.resolves, "F-1")
        XCTAssertEqual(record.findings.map(\.claim), ["1 bad", "Fixed since the last run: F-1 no longer holds. No bad things."])
        XCTAssertEqual(record.findings.last?.evidence, [fixed.results.first?.evidenceID].compactMap { $0 })
        XCTAssertEqual(fixed.changes(since: failed), [.fixed(check: "test.bad-things", title: "No bad things", finding: "F-1")])
        XCTAssertTrue(fixed.announcement(changes: fixed.changes(since: failed)).contains("Fixed since the last run: No bad things, so F-1 no longer holds."))
    }

    /// Not knowing is not fixed: a failure stays open while its check can't run.
    func testAFailureStaysOpenWhileItsCheckCannotRun() {
        var record = CaseRecord()
        let failed = AssessmentRun(date: Date(), connection: nil, policy: AssessmentPolicy(),
                                   results: [CheckResult(check: Self.check(), status: .fail, summary: "1 bad", offenders: ["bad-1"])])
            .recording(into: &record, previous: nil, by: checks, at: Date())
        let unknown = AssessmentRun(date: Date(), connection: nil, policy: AssessmentPolicy(),
                                    results: [CheckResult(check: Self.check(), status: .couldNotRun, reason: "Down.")])
            .recording(into: &record, previous: failed, by: checks, at: Date())
        XCTAssertEqual(unknown.results.first?.findingID, "F-1")
        let fixed = AssessmentRun(date: Date(), connection: nil, policy: AssessmentPolicy(),
                                  results: [CheckResult(check: Self.check(), status: .pass, summary: "No bad things.")])
            .recording(into: &record, previous: unknown, by: checks, at: Date())
        XCTAssertEqual(fixed.results.first?.resolves, "F-1")
        XCTAssertEqual(fixed.changes(since: unknown), [.fixed(check: "test.bad-things", title: "No bad things", finding: "F-1")])
    }

    func testAClosedAssessmentRefusesARunAndAnInvestigationTakesNone() async throws {
        let assessment = try assessment()
        try store.setStatus(.closed, of: assessment.id, by: .champion("Avery"), outcome: .resolved)
        let run = await result(["bad"])
        XCTAssertThrowsError(try store.recordAssessment(run, in: assessment.id, by: checks)) {
            XCTAssertEqual(($0 as? CaseError)?.message, "INV-0001 is closed.")
        }
        XCTAssertEqual(store.assessmentRuns(assessment.id), [])
        let investigation = try store.open(id: UUID(), title: "Beacon", objective: "", champion: "Avery")
        XCTAssertThrowsError(try store.recordAssessment(run, in: investigation.id, by: checks))
    }

    // MARK: Changes

    func testEveryKindOfChangeBetweenRuns() {
        func result(_ id: String, _ status: CheckStatus, _ offenders: [String] = [], reason: String? = nil) -> CheckResult {
            CheckResult(check: Self.check(id), status: status, summary: status == .couldNotRun ? nil : "s", offenders: offenders, reason: reason)
        }
        var policy = AssessmentPolicy()
        policy.maxSuperAdmins = 3
        let before = AssessmentRun(date: Date(), connection: nil, policy: policy, results: [
            result("newly", .pass), result("fixed", .fail, ["a"]), result("same", .fail, ["a"]), result("moved", .fail, ["a", "b"]),
            result("lost", .pass), result("back", .couldNotRun, reason: "Down."), result("gone", .pass),
        ])
        policy.maxSuperAdmins = 2
        let after = AssessmentRun(date: Date(), connection: nil, policy: policy, results: [
            result("newly", .fail, ["x"]), result("fixed", .pass), result("same", .fail, ["a"]), result("moved", .fail, ["b", "c"]),
            result("lost", .couldNotRun, reason: "Refused."), result("back", .fail, ["a"]), result("new", .pass),
        ])
        XCTAssertEqual(after.changes(since: before), [
            .policy(key: "max-super-admins", from: "3", to: "2"),
            .newlyFailing(check: "newly", title: "No bad things", offenders: ["x"]),
            .fixed(check: "fixed", title: "No bad things", finding: nil),
            .offendersChanged(check: "moved", title: "No bad things", added: ["c"], removed: ["a"]),
            .nowCouldNotRun(check: "lost", title: "No bad things", reason: "Refused."),
            .runsAgain(check: "back", title: "No bad things", status: .fail),
            .added(check: "new", title: "No bad things", status: .pass),
            .removed(check: "gone", title: "No bad things"),
        ])
    }

    func testTheAnnouncementAsksTheLeadToExplainAndOrderTheFixesWithoutReadingAgain() {
        var record = CaseRecord()
        let run = AssessmentRun(date: Date(), connection: "Workspace", policy: AssessmentPolicy(), results: [
            CheckResult(check: Self.check(), status: .fail, summary: "1 bad", offenders: ["bad-1"]),
            CheckResult(check: Self.check("test.down"), status: .couldNotRun, reason: "Refused."),
        ]).recording(into: &record, previous: nil, by: checks, at: Date())
        let text = run.announcement(changes: nil)
        XCTAssertTrue(text.contains("Ran 2 checks: 1 failed, 0 passed, 1 couldn't run."), text)
        XCTAssertTrue(text.contains("- No bad things (high, V-1, F-1): 1 bad"), text)
        XCTAssertTrue(text.contains("Refused."), text)
        XCTAssertTrue(text.contains("citing their evidence IDs") && text.contains("Don't run the reads again"), text)
        XCTAssertFalse(text.contains("Since the last run"), text)
        XCTAssertTrue(run.announcement(changes: []).contains("Nothing changed since the last run."))
    }

    // MARK: Investigations

    func testAnInvestigationWrittenBeforeAssessmentsStillReads() throws {
        let id = UUID()
        let folder = store.folder(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
            {"champion":"Avery","id":"\(id.uuidString)","number":4,"objective":"","openedAt":"2026-11-01T09:00:00Z",
             "status":"open","title":"Old one","updatedAt":"2026-11-01T09:00:00Z"}
            """.utf8).write(to: folder.appendingPathComponent("investigation.json"))
        let investigation = try XCTUnwrap(store.investigation(id))
        XCTAssertNil(investigation.kind)
        XCTAssertFalse(investigation.isAssessment)
        let assessment = try store.open(id: UUID(), title: "Review", objective: "", champion: "Avery", kind: .assessment)
        XCTAssertEqual(store.investigation(assessment.id)?.kind, .assessment)
    }

    func testTheChecksAreNamedAsTheChecksRunByTheChampion() throws {
        let encoded = try JSONEncoder().encode(checks)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"checks":"Avery"}"#)
        XCTAssertEqual(try JSONDecoder().decode(CaseActor.self, from: encoded), checks)
        XCTAssertEqual(try JSONDecoder().decode(CaseActor.self, from: Data(#"{"champion":"Avery"}"#.utf8)), .champion("Avery"))
        let assessment = try assessment()
        var record = CaseRecord()
        record.record(evidenceFrom: "Google Workspace", method: "users", result: "Fail", by: checks, at: Date())
        let text = CaseToolProvider.describe(assessment, record, lead: nil) { _ in nil }
        XCTAssertTrue(text.contains("Kind: Assessment. Pion's checks recorded each result as evidence and each failure as a finding; explain and prioritise them, don't add checks."), text)
        XCTAssertTrue(text.contains("by Pion's checks, run by Avery"), text)
        let investigation = try store.open(id: UUID(), title: "Beacon", objective: "", champion: "Avery")
        XCTAssertFalse(CaseToolProvider.describe(investigation, CaseRecord(), lead: nil) { _ in nil }.contains("Kind:"))
    }

    // MARK: Google Workspace

    private func google(_ service: FakeService) -> AssessmentCall {
        let workspace = workspace
        return { tool, arguments in try await GoogleWorkspace.adapter.run(tool, arguments: arguments, connection: workspace, access: service) }
    }

    private static let users = "/admin/directory/v1/users"
    private static let domains = "/admin/directory/v1/customer/my_customer/domains"

    func testTwoStepEnrolmentFailsOnActiveAccountsNotEnrolled() async throws {
        let service = FakeService()
        service.answers[Self.users] = (200, #"{"users":[{"primaryEmail":"ivana@kestrel.example","isEnrolledIn2Sv":true},{"primaryEmail":"nick@kestrel.example","isEnrolledIn2Sv":false},{"primaryEmail":"gone@kestrel.example","isEnrolledIn2Sv":false,"suspended":true},{"primaryEmail":"old@kestrel.example","archived":true},{"primaryEmail":"amy@kestrel.example"},{"primaryEmail":"visitor@kestrel.example","isGuestUser":true}]}"#)
        let run = await AssessmentRunner.run([GoogleWorkspaceChecks.twoStepEnrolment], policy: .defaults, detection: google(service), containment: nil)
        let result = try XCTUnwrap(run.results.first)
        XCTAssertEqual(result.status, .fail, result.reason ?? "")
        XCTAssertEqual(result.offenders, ["amy@kestrel.example", "nick@kestrel.example"])
        XCTAssertEqual(result.summary, "2 of 3 active accounts aren't enrolled in 2-step verification, which the policy requires. Not counted: 1 suspended, 1 archived, 1 guest accounts.")
        XCTAssertEqual(queryItems(service.requests.first)["customer"], "my_customer")

        service.answers[Self.users] = (200, #"{"users":[{"primaryEmail":"ivana@kestrel.example","isEnrolledIn2Sv":true}]}"#)
        let passed = await AssessmentRunner.run([GoogleWorkspaceChecks.twoStepEnrolment], policy: .defaults, detection: google(service), containment: nil)
        XCTAssertEqual(passed.results.first?.status, .pass)
        XCTAssertEqual(passed.results.first?.summary, "All 1 active account is enrolled in 2-step verification.")

        var optional = AssessmentPolicy.defaults
        optional.twoStepVerification = .optional
        let requests = service.requests.count
        let relaxed = await AssessmentRunner.run([GoogleWorkspaceChecks.twoStepEnrolment], policy: optional, detection: google(service), containment: nil)
        XCTAssertEqual(relaxed.results.first?.status, .pass)
        XCTAssertEqual(service.requests.count, requests, "nothing to read when the policy doesn't require it")
    }

    func testUnverifiedDomainsFailByName() async throws {
        let service = FakeService()
        service.answers[Self.domains] = (200, #"{"domains":[{"domainName":"kestrel.example","isPrimary":true,"verified":true,"domainAliases":[{"domainAliasName":"kestrel-old.example","verified":false}]},{"domainName":"kestrl.example","verified":false}]}"#)
        let run = await AssessmentRunner.run([GoogleWorkspaceChecks.unverifiedDomains], policy: AssessmentPolicy(), detection: google(service), containment: nil)
        XCTAssertEqual(run.results.first?.status, .fail, run.results.first?.reason ?? "")
        XCTAssertEqual(run.results.first?.offenders, ["kestrel-old.example", "kestrl.example"])
        service.answers[Self.domains] = (200, #"{"domains":[{"domainName":"kestrel.example","isPrimary":true,"verified":true}]}"#)
        let passed = await AssessmentRunner.run([GoogleWorkspaceChecks.unverifiedDomains], policy: AssessmentPolicy(), detection: google(service), containment: nil)
        XCTAssertEqual(passed.results.first?.status, .pass)
    }

    /// A refusal says what to change in the admin's role, as the tool itself would.
    func testARefusedReadSaysWhatToChange() async throws {
        let service = FakeService()
        service.answers[Self.users] = (403, #"{"error":{"code":403,"message":"Not Authorized to access this resource/api"}}"#)
        service.answers[Self.domains] = (403, #"{"error":{"code":403,"message":"Request had insufficient authentication scopes."}}"#)
        let run = await AssessmentRunner.run([GoogleWorkspaceChecks.twoStepEnrolment, GoogleWorkspaceChecks.unverifiedDomains], policy: .defaults,
                                             detection: google(service), containment: nil)
        XCTAssertEqual(run.results.map(\.status), [.couldNotRun, .couldNotRun])
        XCTAssertTrue(run.results[0].reason?.contains("Users › Read") == true, run.results[0].reason ?? "")
        XCTAssertTrue(run.results[1].reason?.contains("https://www.googleapis.com/auth/admin.directory.domain.readonly") == true, run.results[1].reason ?? "")
    }

    /// Checks only read, and only what Audit is for.
    func testEveryCheckReadsOnlyThroughReadOnlyAuditOperations() throws {
        let operations = Dictionary(GoogleWorkspace.operations.map { (type(of: $0).name, $0) }, uniquingKeysWith: { first, _ in first })
        var policies = [AssessmentPolicy.defaults]
        var relaxed = AssessmentPolicy.defaults
        relaxed.twoStepVerification = .optional
        policies.append(relaxed)
        XCTAssertEqual(Set(GoogleWorkspaceChecks.all.map(\.id)).count, GoogleWorkspaceChecks.all.count, "ids are unique")
        for check in GoogleWorkspaceChecks.all {
            for policy in policies {
                for read in try check.reads(policy) {
                    let operation = try XCTUnwrap(operations[read.tool], "\(check.id) reads \(read.tool), which Google Workspace has no operation for")
                    let kind = type(of: operation)
                    XCTAssertTrue(kind.readOnly, "\(check.id): \(read.tool)")
                    XCTAssertFalse(kind.destructive, "\(check.id): \(read.tool)")
                    XCTAssertTrue(kind.jobs.contains(.audit), "\(check.id): \(read.tool)")
                }
            }
        }
    }
}

private extension AssessmentRun {
    /// The same check failing again with `offenders`, recorded after this run.
    func recordingAgain(into record: inout CaseRecord, offenders: [String]) -> AssessmentRun {
        let check = AssessmentCheck(id: results[0].checkID, title: results[0].title, severity: .high, rationale: "", fix: "", source: "Test",
                                    reads: { _ in [] }, evaluate: { _, _ in .pass("") })
        return AssessmentRun(date: Date(), connection: nil, policy: policy,
                             results: [CheckResult(check: check, status: .fail, summary: "1 bad", offenders: offenders)])
            .recording(into: &record, previous: self, by: .checks(champion: "Avery"), at: Date())
    }
}
