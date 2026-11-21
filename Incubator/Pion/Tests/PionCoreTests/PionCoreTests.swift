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

    /// A call held for the champion, and their decision, go into the Investigation's audit log, even once it is closed.
    func testAHeldCallAndItsDecisionAreLoggedInTheInvestigation() throws {
        let investigation = try open()
        var approval = AgentApproval(conversationID: investigation.id, provider: "workspace", providerTitle: "Google Workspace Containment",
                                     tool: "suspend", input: #"{"user":"m.okafor@kestrel.example"}"#, reason: "Signed in from a known-bad IP",
                                     createdAt: Date())
        XCTAssertTrue(store.logApproval(approval, agent: agent, agentName: "Rafe"))
        approval.state = .done; approval.decidedBy = "Avery"; approval.result = "Suspended."
        XCTAssertTrue(store.logApproval(approval, agent: agent, agentName: "Rafe"))
        let logged = store.audit(investigation.id).suffix(2)
        XCTAssertEqual(logged.map(\.event), ["approval", "approval"])
        XCTAssertEqual(logged.first?.actor, .agent(agent))
        XCTAssertEqual(logged.last?.actor, .champion("Avery"))
        XCTAssertTrue(logged.first?.detail.contains("suspend user: m.okafor@kestrel.example") == true, logged.first?.detail ?? "")
        XCTAssertTrue(logged.first?.detail.contains("Signed in from a known-bad IP") == true, logged.first?.detail ?? "")
        XCTAssertTrue(logged.last?.detail.contains("Approved by Avery") == true, logged.last?.detail ?? "")
        XCTAssertTrue(logged.last?.detail.contains("Suspended.") == true, logged.last?.detail ?? "")
        // A direct conversation is no Investigation, so there is nothing to log in.
        XCTAssertFalse(store.logApproval(AgentApproval(conversationID: UUID(), provider: "p", providerTitle: "P", tool: "t", input: "{}",
                                                       reason: "r", createdAt: Date()), agent: agent, agentName: "Rafe"))
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

    func testAnAgentOpensAnInvestigationThroughTheCaseToolWhereThePionAllowsIt() async throws {
        let opener = UUID()
        final class Asked: @unchecked Sendable { var agent: UUID?; var opening: CaseToolProvider.Opening? }
        let asked = Asked(), store = self.store!
        let provider = CaseToolProvider(store: store, leadOf: { _ in nil }, open: { agent, opening in
            asked.agent = agent; asked.opening = opening
            return try store.open(id: UUID(), title: opening.title, objective: opening.objective, champion: "Avery", openedBy: .agent(agent))
        }) { _ in "Rafe" }
        let listed = try JSONSerialization.jsonObject(with: try await provider.tools(context: ToolCallContext(agentID: opener, workspace: root))) as? [String: Any]
        let open = try XCTUnwrap((listed?["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "open" })
        XCTAssertEqual((open["inputSchema"] as? [String: Any])?["required"] as? [String], ["title", "objective"], "opening one needs no Investigation")

        let data = try await provider.call("open", arguments: JSONSerialization.data(withJSONObject: [
            "title": "Domain-wide project creation", "objective": "Restrict it.", "team": ["Morgan"]]), files: [],
            context: ToolCallContext(agentID: opener, workspace: root))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = ((object["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("You lead it"), text)
        let conversation = try XCTUnwrap((object["structuredContent"] as? [String: Any])?["conversation"] as? String)
        XCTAssertEqual(store.audit(try XCTUnwrap(UUID(uuidString: conversation))).first?.actor, .agent(opener))
        XCTAssertEqual(asked.agent, opener)
        XCTAssertEqual(asked.opening?.team, ["Morgan"])

        // Without the Pion's say, agents may not.
        let closed = CaseToolProvider(store: store, leadOf: { _ in nil }) { _ in "Rafe" }
        let none = try JSONSerialization.jsonObject(with: try await closed.tools(context: ToolCallContext(agentID: opener, workspace: root))) as? [String: Any]
        XCTAssertFalse((none?["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "open" } ?? true)
    }

    /// A closed Investigation is read-only to agents: they read it, but record nothing more until the champion reopens it.
    func testAClosedInvestigationTakesNoMoreFromAgents() async throws {
        lead = agent
        let investigation = try open()
        let id = investigation.id.uuidString
        try store.setStatus(.closed, of: investigation.id, by: .champion("Avery"), outcome: .resolved, note: "Fixed.")
        for (tool, arguments) in [("entity", ["kind": "host", "name": "LT-0423"]),
                                  ("evidence", ["source": "Defender", "method": "q", "result": "r"]),
                                  ("finding", ["claim": "c", "evidence": ["V-1"], "confidence": "high"])] {
            do {
                _ = try await call(tool, arguments.merging(["conversation": id]) { $1 })
                XCTFail("\(tool) was recorded in a closed Investigation")
            } catch { XCTAssertTrue("\(error)".contains("closed"), "\(error)") }
        }
        XCTAssertTrue(store.caseRecord(investigation.id).entities.isEmpty)
        let read = try await call("read", ["conversation": id])
        XCTAssertTrue(read.contains(investigation.reference), read)
        try store.setStatus(.triaging, of: investigation.id, by: .champion("Avery"))
        _ = try await call("entity", ["conversation": id, "kind": "host", "name": "LT-0423"])
        XCTAssertEqual(store.caseRecord(investigation.id).entities.count, 1, "a reopened Investigation took nothing")
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
