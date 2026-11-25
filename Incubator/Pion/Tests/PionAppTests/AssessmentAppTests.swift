import NoodleCore
import PionCore
import XCTest

/// Assessments in the app: opening one writes its kind and policy and runs its checks, which read only through a
/// Google Workspace connection given to an agent on its team, record what they found and hand it to the lead.
@MainActor final class AssessmentAppTests: XCTestCase {
    private var root: URL!
    private var model: PionModel!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PionAssessment-\(UUID())")
        model = PionModel(root: root, messenger: nil, isScripted: true)
        model.start()
    }

    override func tearDownWithError() throws { model = nil; try? FileManager.default.removeItem(at: root) }

    private func detection() throws -> ToolConnection {
        try ToolConnection(name: "Google Workspace Detection", endpoint: URL(string: "https://admin.googleapis.com")!, adapter: "google-workspace")
    }

    private func containment() throws -> ToolConnection {
        try ToolConnection(name: "Google Workspace Containment", endpoint: URL(string: "https://admin.googleapis.com")!,
                           adapter: "google-workspace-containment")
    }

    /// An agent holding `connections`, saved to the registry first.
    private func agent(holding connections: [ToolConnection] = []) throws -> AgentRecord {
        if !connections.isEmpty {
            var registry = ToolConnectionRegistry()
            registry.connections = connections
            try registry.save(root: model.repository.rootURL)
            try model.connectionsController.reloadAssignments()
        }
        return try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil,
                                     resources: .init(connections: Set(connections.map(\.id))))
    }

    nonisolated private static func answer(_ structured: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "ok"]], "isError": false, "structuredContent": structured])
    }

    func testOpeningAnAssessmentWritesItsKindAndPolicyAndRunsItsChecks() async throws {
        let avery = try agent()
        var policy = AssessmentPolicy.defaults
        policy.maxSuperAdmins = 2
        let assessment = try model.openAssessment(PionModel.Draft(title: "Google Workspace assessment", lead: avery.id), policy: policy,
                                                  body: "Contractors may use personal phones.")

        XCTAssertEqual(model.store.investigation(assessment.id)?.kind, .assessment)
        XCTAssertEqual(model.store.readPolicy(assessment.id), policy)
        XCTAssertEqual(model.policyBody(of: assessment), "Contractors may use personal phones.")
        XCTAssertTrue(model.isRunningChecks(assessment.id))

        // Waits for the run opening started rather than starting another.
        let finished = await model.runChecks(on: assessment)
        let run = try XCTUnwrap(finished)
        XCTAssertEqual(model.store.assessmentRuns(assessment.id).count, 1)
        XCTAssertFalse(model.isRunningChecks(assessment.id))
        XCTAssertEqual(run.policy, policy)
        // No agent on it holds a Google Workspace connection, so nothing could be read.
        XCTAssertFalse(run.results.isEmpty)
        XCTAssertTrue(run.results.allSatisfy { $0.status == .couldNotRun }, run.tally)
        XCTAssertEqual(run.results.first { $0.checkID == "gws.2sv-enrolment" }?.reason,
                       "Google Workspace Detection isn't connected or given to an agent on this Assessment.")
        XCTAssertNil(run.connection)
        XCTAssertEqual(model.messages(in: assessment.id).last?.body.hasPrefix("Pion's checks ran."), true)
    }

    func testARunReadsThroughTheTeamsConnectionRecordsItsResultsAndHandsThemToTheLead() async throws {
        let connection = try detection()
        let avery = try agent(holding: [connection])
        XCTAssertEqual(model.assessmentConnection(PionModel.detectionAdapter, for: try model.open(PionModel.Draft(title: "Other", lead: avery.id))),
                       connection, "Any Investigation's team is where a connection is looked for")
        let called = Called()
        model.assessmentCall = { used in
            XCTAssertEqual(used.id, connection.id)
            return { tool, _ in
                await called.add(tool)
                switch tool {
                case "users":
                    return Self.answer(["users": [["primaryEmail": "ana@example.com", "isEnrolledIn2Sv": true],
                                                  ["primaryEmail": "bo@example.com", "isEnrolledIn2Sv": false]]])
                case "domains": return Self.answer(["domains": [["name": "example.com", "verified": true]]])
                default:
                    return try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "Not in this test."]], "isError": true])
                }
            }
        }
        let assessment = try model.openAssessment(PionModel.Draft(title: "Google Workspace assessment", lead: avery.id),
                                                  policy: .defaults, body: "")
        let finished = await model.runChecks(on: assessment)
        let run = try XCTUnwrap(finished)

        XCTAssertEqual(run.connection, "Google Workspace Detection")
        let enrolment = try XCTUnwrap(run.results.first { $0.checkID == "gws.2sv-enrolment" })
        XCTAssertEqual(enrolment.status, .fail)
        XCTAssertEqual(enrolment.offenders, ["bo@example.com"])
        XCTAssertEqual(run.results.first { $0.checkID == "gws.unverified-domains" }?.status, .pass)
        let calls = await called.tools
        XCTAssertEqual(calls.filter { $0 == "users" }.count, 1, "Checks asking the same read share one call")
        let (_, readOnly) = await PionModel.tools(of: connection)
        XCTAssertTrue(Set(calls).isSubset(of: readOnly), "\(calls)")

        let record = model.caseRecord(assessment.id)
        XCTAssertEqual(record.evidence.count, run.results.count)
        XCTAssertTrue(record.evidence.allSatisfy { $0.recordedBy == .checks(champion: model.champion) })
        XCTAssertTrue(record.findings.contains { $0.id == enrolment.findingID })
        let message = try XCTUnwrap(model.messages(in: assessment.id).last)
        XCTAssertTrue(message.body.hasPrefix("Pion's checks ran on Google Workspace Detection. \(run.tally)"), message.body)
        XCTAssertTrue(message.body.contains("Active accounts enrolled in 2-step verification"))

        // The next run says what changed since this one.
        let finishedAgain = await model.runChecks(on: assessment)
        let again = try XCTUnwrap(finishedAgain)
        XCTAssertEqual(again.results.first { $0.checkID == "gws.2sv-enrolment" }?.findingID, enrolment.findingID)
        XCTAssertEqual(model.messages(in: assessment.id).last?.body.contains("Nothing changed since the last run."), true)
    }

    func testAClosedAssessmentRunsNoChecks() async throws {
        let avery = try agent()
        let assessment = try model.openAssessment(PionModel.Draft(title: "Google Workspace assessment", lead: avery.id),
                                                  policy: .defaults, body: "")
        _ = await model.runChecks(on: assessment)
        model.setStatus(.closed, of: assessment, outcome: .resolved)
        let closed = try XCTUnwrap(model.investigation(assessment.id))

        XCTAssertNil(model.startChecks(on: closed))
        let run = await model.runChecks(on: closed)
        XCTAssertNil(run)
        XCTAssertEqual(model.problem, "Reopen \(assessment.reference) before running its checks.")
        XCTAssertEqual(model.store.assessmentRuns(assessment.id).count, 1)
        XCTAssertThrowsError(try model.savePolicy(.defaults, body: "Changed", of: closed))
    }

    func testAnInvestigationHasNoChecks() async throws {
        let avery = try agent()
        let investigation = try model.open(PionModel.Draft(title: "Beaconing laptop", lead: avery.id))
        XCTAssertNil(model.store.investigation(investigation.id)?.kind)
        let run = await model.runChecks(on: investigation)
        XCTAssertNil(run)
        XCTAssertTrue(model.store.assessmentRuns(investigation.id).isEmpty)
    }

    func testAMissingConnectionIsSaidOnceForEveryCheck() async throws {
        let avery = try agent()
        let assessment = try model.openAssessment(PionModel.Draft(title: "Google Workspace assessment", lead: avery.id),
                                                  policy: .defaults, body: "")
        let finished = await model.runChecks(on: assessment)
        let run = try XCTUnwrap(finished)
        let reason = "Google Workspace Detection isn't connected or given to an agent on this Assessment."
        XCTAssertEqual(run.sharedProblem?.count, run.results.count)
        let message = try XCTUnwrap(model.messages(in: assessment.id).last?.body)
        XCTAssertTrue(message.hasPrefix("Pion's checks ran. \(run.tally)\n\(reason) None of the checks could run."), message)
        XCTAssertEqual(message.components(separatedBy: "isn't connected").count, 2, "said once:\n\(message)")
        XCTAssertFalse(message.contains("Policy incomplete"), message)
    }

    func testAnUnansweredPolicyMarksTheRunIncomplete() async throws {
        let avery = try agent()
        var policy = AssessmentPolicy.defaults
        policy.maxSuperAdmins = nil
        let assessment = try model.openAssessment(PionModel.Draft(title: "Google Workspace assessment", lead: avery.id),
                                                  policy: policy, body: "")
        let finished = await model.runChecks(on: assessment)
        let run = try XCTUnwrap(finished)
        XCTAssertEqual(run.unansweredKeys, ["max-super-admins"])
        let message = try XCTUnwrap(model.messages(in: assessment.id).last?.body)
        XCTAssertTrue(message.contains("Policy incomplete: it doesn't answer max-super-admins, which 1 check needs."), message)
        XCTAssertTrue(model.report(of: assessment).contains("**Policy incomplete**: it doesn't answer max-super-admins"))
    }

    func testTheReportCanBeExportedOnceTheChecksHaveRun() async throws {
        let avery = try agent()
        let investigation = try model.open(PionModel.Draft(title: "Beaconing laptop", lead: avery.id))
        XCTAssertFalse(model.canExportReport(investigation), "An Investigation has no report")
        let assessment = try model.openAssessment(PionModel.Draft(title: "Google Workspace assessment", lead: avery.id),
                                                  policy: .defaults, body: "Contractors may use personal phones.")
        XCTAssertFalse(model.canExportReport(assessment), "Nothing to report until a run is recorded")
        let destination = root.appendingPathComponent("Report.md")
        XCTAssertThrowsError(try model.writeReport(of: assessment, to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        _ = await model.runChecks(on: assessment)
        XCTAssertTrue(model.canExportReport(assessment))
        try model.writeReport(of: assessment, to: destination)
        let written = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(written.hasPrefix("# Google Workspace assessment (\(assessment.reference))\n"), written)
        XCTAssertTrue(written.contains("- Champion: \(model.champion)"), written)
        XCTAssertTrue(written.contains("### Couldn't run"), written)
        XCTAssertTrue(written.contains("### Notes\n\nContractors may use personal phones."), written)
        XCTAssertTrue(AssessmentReport.fileName(of: assessment, runs: model.assessmentRuns(assessment.id))
            .hasPrefix("Google Workspace assessment 2"))
    }

    func testChecksNeverCallAToolThatChangesThings() async throws {
        let called = Called()
        let stub: AssessmentCall = { tool, _ in await called.add(tool); return Data("{}".utf8) }

        let contain = await PionModel.readOnly(stub, on: try containment())
        do {
            _ = try await contain("suspend", Data(#"{"user":"bo@example.com"}"#.utf8))
            XCTFail("suspend changes things, so it must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("a tool that changes things"), error.localizedDescription)
        }
        _ = try await contain("tokens", Data(#"{"user":"bo@example.com"}"#.utf8))

        let detect = await PionModel.readOnly(stub, on: try detection())
        _ = try await detect("users", Data("{}".utf8))
        do {
            _ = try await detect("suspend", Data("{}".utf8))
            XCTFail("Detection doesn't offer suspend")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("doesn't offer"), error.localizedDescription)
        }

        let calls = await called.tools
        XCTAssertEqual(calls, ["tokens", "users"], "Only the reads reached the service")
    }
}

private actor Called {
    private(set) var tools: [String] = []
    func add(_ tool: String) { tools.append(tool) }
}
