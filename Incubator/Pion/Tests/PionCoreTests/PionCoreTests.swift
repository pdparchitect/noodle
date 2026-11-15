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

    private func open() throws -> Investigation {
        try store.open(id: UUID(), title: "Beaconing laptop", objective: "Find out why LT-0423 beacons",
                       champion: "Avery")
    }

    // MARK: Status

    func testOnlyTheChampionClosesAndClosingNeedsAnOutcome() throws {
        let investigation = try open()
        XCTAssertThrowsError(try store.setStatus(.closed, of: investigation.id, by: .agent(agent), outcome: .resolved))
        XCTAssertThrowsError(try store.setStatus(.closed, of: investigation.id, by: .champion("Avery")))
        let closed = try store.setStatus(.closed, of: investigation.id, by: .champion("Avery"), outcome: .falsePositive, note: "Backup job")
        XCTAssertEqual(closed.outcome, .falsePositive)
        XCTAssertNotNil(closed.closedAt)
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
        XCTAssertThrowsError(try record.record(finding: "Bad", evidence: ["V-1"], confidence: .high, entities: [], by: .champion("Avery"), at: Date()))
        let evidence = record.record(evidenceFrom: "EDR", method: "query", result: "hit", by: .champion("Avery"), at: Date())
        XCTAssertEqual(evidence.id, "V-1")
        XCTAssertEqual(try record.record(finding: "Bad", evidence: ["v-1"], confidence: .high, entities: [], by: .champion("Avery"), at: Date()).evidence, ["V-1"])
    }

    func testRecordingAnEntityAgainRefreshesItInsteadOfAddingAnother() {
        var record = CaseRecord()
        let first = record.record(entity: .host, name: "LT-0423", detail: nil, by: .champion("Avery"), at: Date(timeIntervalSince1970: 0))
        let again = record.record(entity: .host, name: "lt-0423", detail: "Finance laptop", by: .champion("Avery"), at: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(record.entities.count, 1)
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(again.lastSeen, Date(timeIntervalSince1970: 60))
        XCTAssertEqual(again.detail, "Finance laptop")
    }

    func testTheAuditLogOnlyGrows() throws {
        let investigation = try open()
        let before = store.audit(investigation.id).count
        _ = try store.updateCase(investigation.id, by: .agent(agent)) { record, _ in
            let item = record.record(evidenceFrom: "EDR", method: "query", result: "hit", by: .agent(self.agent), at: Date())
            return ((), "evidence", item.id)
        }
        let after = store.audit(investigation.id)
        XCTAssertEqual(after.count, before + 1)
        XCTAssertEqual(after.first?.event, "opened")
        XCTAssertEqual(after.last?.event, "evidence")
    }

    // MARK: Case tool

    /// The lead of every Investigation in these tests; nil leaves them without one.
    private var lead: UUID?

    private func call(_ tool: String, _ arguments: [String: Any], as caller: UUID? = nil) async throws -> String {
        let lead = self.lead
        let provider = CaseToolProvider(store: store, leadOf: { _ in lead }) { _ in "Rafe" }
        let data = try await provider.call(tool, arguments: JSONSerialization.data(withJSONObject: arguments), files: [],
                                           context: ToolCallContext(agentID: caller ?? agent, workspace: root))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((object?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private func structured(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let lead = self.lead
        let provider = CaseToolProvider(store: store, leadOf: { _ in lead }) { _ in "Rafe" }
        let data = try await provider.call(tool, arguments: JSONSerialization.data(withJSONObject: arguments), files: [],
                                           context: ToolCallContext(agentID: agent, workspace: root))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["structuredContent"] as? [String: Any], "every case tool result carries JSON")
    }

    func testEveryCaseToolResultCarriesJSONForScripts() async throws {
        lead = agent
        let investigation = try open()
        let id = investigation.id.uuidString
        let entity = try await structured("entity", ["conversation": id, "kind": "host", "name": "LT-0423"])
        XCTAssertEqual(entity["name"] as? String, "LT-0423")
        let evidence = try await structured("evidence", ["conversation": id, "source": "Defender", "method": "q", "result": "Beacon"])
        let evidenceID = try XCTUnwrap(evidence["id"] as? String)
        let finding = try await structured("finding", ["conversation": id, "claim": "Beaconing", "evidence": [evidenceID], "confidence": "high"])
        XCTAssertEqual(finding["evidence"] as? [String], [evidenceID])
        let severity = try await structured("severity", ["conversation": id, "severity": "high", "note": "n"])
        XCTAssertEqual(severity["severity"] as? String, "high")
        let read = try await structured("read", ["conversation": id])
        XCTAssertEqual(read["reference"] as? String, investigation.reference)
        XCTAssertEqual(read["severity"] as? String, "high")
        XCTAssertEqual(read["leadName"] as? String, "Rafe")
        XCTAssertEqual((read["evidence"] as? [[String: Any]])?.first?["id"] as? String, evidenceID)
    }

    func testTheCaseToolRefusesAConversationThatIsNotAnInvestigation() async throws {
        do {
            _ = try await call("read", ["conversation": UUID().uuidString])
            XCTFail("expected a refusal")
        } catch {}
    }

    func testTheCaseToolRecordsWhatAgentsFind() async throws {
        let investigation = try open()
        let id = investigation.id.uuidString
        _ = try await call("entity", ["conversation": id, "kind": "host", "name": "LT-0423"])
        let evidence = try await call("evidence", ["conversation": id, "source": "Defender", "method": "DeviceNetworkEvents", "result": "Beacon every 60 s"])
        XCTAssertTrue(evidence.contains("V-1"))
        _ = try await call("finding", ["conversation": id, "claim": "Beaconing", "evidence": ["V-1"], "confidence": "high"])
        let read = try await call("read", ["conversation": id])
        XCTAssertTrue(read.contains("V-1 from Defender"))
        XCTAssertTrue(read.contains("F-1 (high) Beaconing"))
    }

    func testOnlyTheLeadChangesStatusAndNobodyClosesThroughTheTool() async throws {
        lead = agent
        let investigation = try open()
        let id = investigation.id.uuidString
        do { _ = try await call("status", ["conversation": id, "status": "contained", "note": "n"], as: UUID()); XCTFail("expected a refusal") } catch {}
        do { _ = try await call("status", ["conversation": id, "status": "closed", "note": "n"]); XCTFail("expected a refusal") } catch {}
        _ = try await call("status", ["conversation": id, "status": "contained", "note": "Host isolated"])
        XCTAssertEqual(store.investigation(investigation.id)?.status, .contained)
    }

    func testAnInvestigationStartsUnassessedAndOnlyItsLeadSetsSeverity() async throws {
        lead = agent
        let investigation = try open()
        XCTAssertNil(investigation.severity)
        let id = investigation.id.uuidString
        do { _ = try await call("severity", ["conversation": id, "severity": "high", "note": "n"], as: UUID()); XCTFail("expected a refusal") } catch {}
        do { _ = try await call("severity", ["conversation": id, "severity": "severe", "note": "n"]); XCTFail("expected a refusal") } catch {}
        _ = try await call("severity", ["conversation": id, "severity": "high", "note": "Credentials were used"])
        XCTAssertEqual(store.investigation(investigation.id)?.severity, .high)
        XCTAssertEqual(store.audit(investigation.id).last?.event, "severity")
    }

    func testWithoutALeadNobodyChangesSeverityOrStatus() async throws {
        let investigation = try open()
        let id = investigation.id.uuidString
        do { _ = try await call("severity", ["conversation": id, "severity": "high", "note": "n"]); XCTFail("expected a refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no lead"), error.localizedDescription) }
        do { _ = try await call("status", ["conversation": id, "status": "contained", "note": "n"]); XCTFail("expected a refusal") } catch {}
        XCTAssertNil(store.investigation(investigation.id)?.severity)
        let read = try await call("read", ["conversation": id])
        XCTAssertTrue(read.contains("Lead: none"), read)
    }

    func testTheToolListDeclaresTheConversationForTheBroker() async throws {
        let provider = CaseToolProvider(store: store, leadOf: { _ in nil }) { _ in nil }
        let tools = try ToolDescriptor.list(mcp: try await provider.tools(context: ToolCallContext(agentID: agent, workspace: root)))
        XCTAssertEqual(Set(tools.map(\.name)), ["read", "entity", "evidence", "finding", "status", "severity"])
        XCTAssertTrue(tools.allSatisfy { $0.conversationParameter == "conversation" })
    }
}
