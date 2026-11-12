import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class PionCoreTests: XCTestCase {
    private var root: URL!
    private var store: PionStore!
    private let agent = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PionCoreTests-\(UUID().uuidString)", isDirectory: true)
        store = PionStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func open(scope: [String] = ["LT-0423", "*.corp.example", "d.price"]) throws -> Investigation {
        try store.open(id: UUID(), title: "Beaconing laptop", objective: "Find out why LT-0423 beacons", scope: scope,
                       severity: .high, champion: "Avery", leadAgentID: agent, playbookID: "malware")
    }

    // MARK: Scope and policy

    func testScopeCoversExactNamesAndWildcardSuffixesOnly() throws {
        let investigation = try open()
        XCTAssertTrue(investigation.covers("lt-0423"))
        XCTAssertTrue(investigation.covers("fs01.corp.example"))
        XCTAssertFalse(investigation.covers("corp.example.evil.test"))
        XCTAssertFalse(investigation.covers("LT-0424"))
        XCTAssertFalse(investigation.covers(""))
    }

    func testPolicyRefusesTargetsOutsideTheScopeWhateverTheRuleSays() throws {
        let investigation = try open()
        let verdict = ActionPolicy.standard.verdict(operation: "enrich_ip", targets: ["LT-0423", "DC01"], in: investigation)
        XCTAssertEqual(verdict.mode, .never)
        XCTAssertTrue(verdict.reason.contains("DC01"))
    }

    func testPolicyRefusesProtectedAssetsInsideTheScope() throws {
        var policy = ActionPolicy.standard
        policy.protectedAssets = ["dc01.corp.example"]
        let verdict = policy.verdict(operation: "isolate_host", targets: ["DC01.corp.example"], in: try open())
        XCTAssertEqual(verdict.mode, .never)
    }

    func testPolicyFollowsTheFirstMatchingRuleThenTheFallback() throws {
        let investigation = try open()
        XCTAssertEqual(ActionPolicy.standard.verdict(operation: "enrich_hash", targets: ["LT-0423"], in: investigation).mode, .automatic)
        XCTAssertEqual(ActionPolicy.standard.verdict(operation: "isolate_host", targets: ["LT-0423"], in: investigation).mode, .approval)
        XCTAssertEqual(ActionPolicy.standard.verdict(operation: "delete_mailbox", targets: ["d.price"], in: investigation).mode, .never)
        XCTAssertEqual(ActionPolicy.standard.verdict(operation: "something_new", targets: ["LT-0423"], in: investigation).mode, .approval)
    }

    // MARK: Proposals and approval

    func testAnActionNeedingApprovalWaitsForTheChampionAndIsNeverProposedTwice() throws {
        let investigation = try open()
        let (first, _, firstRepeated) = try store.propose(operation: "isolate_host", targets: ["LT-0423"], rationale: "Beacons",
                                                          expectedEffect: "Offline", undo: "Release", evidence: [], in: investigation.id, by: .agent(agent))
        XCTAssertEqual(first.state, .pending)
        XCTAssertFalse(firstRepeated)
        let (again, _, repeated) = try store.propose(operation: "ISOLATE_HOST", targets: ["lt-0423"], rationale: "Still beacons",
                                                     expectedEffect: "Offline", undo: "Release", evidence: [], in: investigation.id, by: .agent(agent))
        XCTAssertTrue(repeated)
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(store.caseRecord(investigation.id).actions.count, 1)

        let approved = try store.decide(first.id, in: investigation.id, approve: true, note: "Go", by: "Avery")
        XCTAssertEqual(approved.state, .approved)
        XCTAssertThrowsError(try store.decide(first.id, in: investigation.id, approve: false, note: nil, by: "Avery"))
        XCTAssertEqual(try store.markDone(first.id, in: investigation.id, note: nil, by: "Avery").state, .done)
    }

    func testARefusedActionIsRecordedWithItsReason() throws {
        let investigation = try open()
        let (action, verdict, _) = try store.propose(operation: "disable_user", targets: ["ceo"], rationale: "r", expectedEffect: "e",
                                                     undo: "u", evidence: [], in: investigation.id, by: .agent(agent))
        XCTAssertEqual(action.state, .refused)
        XCTAssertEqual(action.note, verdict.reason)
    }

    func testAnAutomaticActionIsApprovedByPolicy() throws {
        let investigation = try open()
        let (action, _, _) = try store.propose(operation: "enrich_ip", targets: ["LT-0423"], rationale: "r", expectedEffect: "e",
                                               undo: "u", evidence: [], in: investigation.id, by: .agent(agent))
        XCTAssertEqual(action.state, .approved)
        XCTAssertEqual(action.decidedBy, .policy)
    }

    // MARK: Status

    func testOnlyTheChampionClosesAndClosingNeedsAnOutcome() throws {
        let investigation = try open()
        XCTAssertThrowsError(try store.setStatus(.closed, of: investigation.id, by: .agent(agent), outcome: .resolved))
        XCTAssertThrowsError(try store.setStatus(.closed, of: investigation.id, by: .champion("Avery")))
        let closed = try store.setStatus(.closed, of: investigation.id, by: .champion("Avery"), outcome: .falsePositive, note: "Backup job")
        XCTAssertEqual(closed.outcome, .falsePositive)
        XCTAssertNotNil(closed.closedAt)
        let verdict = store.policy().verdict(operation: "enrich_ip", targets: ["LT-0423"], in: closed)
        XCTAssertEqual(verdict.mode, .never)
    }

    func testInvestigationsAreNumberedInOrder() throws {
        let first = try open(), second = try open()
        XCTAssertEqual(first.reference, "INV-0001")
        XCTAssertEqual(second.reference, "INV-0002")
        XCTAssertEqual(store.investigations().map(\.number), [2, 1])
    }

    // MARK: Case record

    func testAFindingMustCiteRecordedEvidence() throws {
        var record = CaseRecord()
        XCTAssertThrowsError(try record.record(finding: "Bad", evidence: ["V-1"], confidence: .high, entities: [], by: .policy, at: Date()))
        let evidence = record.record(evidenceFrom: "EDR", method: "query", result: "hit", by: .policy, at: Date())
        XCTAssertEqual(evidence.id, "V-1")
        XCTAssertEqual(try record.record(finding: "Bad", evidence: ["v-1"], confidence: .high, entities: [], by: .policy, at: Date()).evidence, ["V-1"])
    }

    func testRecordingAnEntityAgainRefreshesItInsteadOfAddingAnother() {
        var record = CaseRecord()
        let first = record.record(entity: .host, name: "LT-0423", detail: nil, by: .policy, at: Date(timeIntervalSince1970: 0))
        let again = record.record(entity: .host, name: "lt-0423", detail: "Finance laptop", by: .policy, at: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(record.entities.count, 1)
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(again.lastSeen, Date(timeIntervalSince1970: 60))
        XCTAssertEqual(again.detail, "Finance laptop")
    }

    func testTheAuditLogOnlyGrows() throws {
        let investigation = try open()
        let before = store.audit(investigation.id).count
        _ = try store.propose(operation: "isolate_host", targets: ["LT-0423"], rationale: "r", expectedEffect: "e", undo: "u",
                              evidence: [], in: investigation.id, by: .agent(agent))
        let after = store.audit(investigation.id)
        XCTAssertEqual(after.count, before + 1)
        XCTAssertEqual(after.first?.event, "opened")
        XCTAssertEqual(after.last?.event, "proposed")
    }

    // MARK: Case tool

    private func call(_ tool: String, _ arguments: [String: Any], as caller: UUID? = nil) async throws -> String {
        let provider = CaseToolProvider(store: store) { _ in "Rafe" }
        let data = try await provider.call(tool, arguments: JSONSerialization.data(withJSONObject: arguments), files: [],
                                           context: ToolCallContext(agentID: caller ?? agent, workspace: root))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((object?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    func testTheCaseToolRefusesAConversationThatIsNotAnInvestigation() async throws {
        do {
            _ = try await call("read", ["conversation": UUID().uuidString])
            XCTFail("expected a refusal")
        } catch {}
    }

    func testTheCaseToolRecordsAndProposesThroughThePolicy() async throws {
        let investigation = try open()
        let id = investigation.id.uuidString
        _ = try await call("entity", ["conversation": id, "kind": "host", "name": "LT-0423"])
        let evidence = try await call("evidence", ["conversation": id, "source": "Defender", "method": "DeviceNetworkEvents", "result": "Beacon every 60 s"])
        XCTAssertTrue(evidence.contains("V-1"))
        _ = try await call("finding", ["conversation": id, "claim": "Beaconing", "evidence": ["V-1"], "confidence": "high"])
        let pending = try await call("propose", ["conversation": id, "operation": "isolate_host", "targets": ["LT-0423"],
                                                 "rationale": "V-1", "effect": "Offline", "undo": "Release"])
        XCTAssertTrue(pending.contains("Pending approval, action A-1"))
        let refused = try await call("propose", ["conversation": id, "operation": "isolate_host", "targets": ["DC01"],
                                                 "rationale": "r", "effect": "e", "undo": "u"])
        XCTAssertTrue(refused.hasPrefix("Refused"))
        let read = try await call("read", ["conversation": id])
        XCTAssertTrue(read.contains("A-1 isolate_host on LT-0423: Needs Approval"))
        XCTAssertTrue(read.contains("F-1 (high) Beaconing"))
    }

    func testOnlyTheLeadChangesStatusAndNobodyClosesThroughTheTool() async throws {
        let investigation = try open()
        let id = investigation.id.uuidString
        do { _ = try await call("status", ["conversation": id, "status": "contained", "note": "n"], as: UUID()); XCTFail("expected a refusal") } catch {}
        do { _ = try await call("status", ["conversation": id, "status": "closed", "note": "n"]); XCTFail("expected a refusal") } catch {}
        _ = try await call("status", ["conversation": id, "status": "contained", "note": "Host isolated"])
        XCTAssertEqual(store.investigation(investigation.id)?.status, .contained)
    }

    func testTheToolListDeclaresTheConversationForTheBroker() async throws {
        let provider = CaseToolProvider(store: store) { _ in nil }
        let tools = try ToolDescriptor.list(mcp: try await provider.tools(context: ToolCallContext(agentID: agent, workspace: root)))
        XCTAssertEqual(Set(tools.map(\.name)), ["read", "entity", "evidence", "finding", "propose", "status"])
        XCTAssertTrue(tools.allSatisfy { $0.conversationParameter == "conversation" })
    }
}
