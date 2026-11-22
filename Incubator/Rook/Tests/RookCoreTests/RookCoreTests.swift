import Foundation
import NoodleCore
@testable import RookCore
import XCTest

final class RookCoreTests: XCTestCase {
    private var root: URL!
    private var store: RookStore!
    private let agent = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RookCoreTests-\(UUID().uuidString)", isDirectory: true)
        store = RookStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func open() throws -> Mission {
        try store.open(id: UUID(), title: "Beaconing laptop", objective: "Find out why LT-0423 beacons",
                       champion: "Avery")
    }

    // MARK: Status

    func testOnlyTheChampionClosesAndClosingNeedsAnOutcome() throws {
        let mission = try open()
        XCTAssertThrowsError(try store.setStatus(.closed, of: mission.id, by: .agent(agent), outcome: .demonstrated))
        XCTAssertThrowsError(try store.setStatus(.closed, of: mission.id, by: .champion("Avery")))
        let closed = try store.setStatus(.closed, of: mission.id, by: .champion("Avery"), outcome: .notExploitable, note: "Backup job")
        XCTAssertEqual(closed.outcome, .notExploitable)
        XCTAssertNotNil(closed.closedAt)
    }

    func testMissionsAreNumberedInOrder() throws {
        let first = try open(), second = try open()
        XCTAssertEqual(first.reference, "M-0001")
        XCTAssertEqual(second.reference, "M-0002")
        XCTAssertEqual(store.missions().map(\.number), [2, 1])
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
        let mission = try open()
        let before = store.audit(mission.id).count
        _ = try store.updateCase(mission.id, by: .agent(agent)) { record, _ in
            let item = record.record(evidenceFrom: "EDR", method: "query", result: "hit", by: .agent(self.agent), at: Date())
            return ((), "evidence", item.id)
        }
        let after = store.audit(mission.id)
        XCTAssertEqual(after.count, before + 1)
        XCTAssertEqual(after.first?.event, "opened")
        XCTAssertEqual(after.last?.event, "evidence")
    }

    // MARK: Case tool

    /// The lead of every Mission in these tests; nil leaves them without one.
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
        let mission = try open()
        let id = mission.id.uuidString
        let entity = try await structured("entity", ["conversation": id, "kind": "host", "name": "LT-0423"])
        XCTAssertEqual(entity["name"] as? String, "LT-0423")
        let evidence = try await structured("evidence", ["conversation": id, "source": "Defender", "method": "q", "result": "Beacon"])
        let evidenceID = try XCTUnwrap(evidence["id"] as? String)
        let finding = try await structured("finding", ["conversation": id, "claim": "Beaconing", "evidence": [evidenceID], "confidence": "high"])
        XCTAssertEqual(finding["evidence"] as? [String], [evidenceID])
        let severity = try await structured("severity", ["conversation": id, "severity": "high", "note": "n"])
        XCTAssertEqual(severity["severity"] as? String, "high")
        let read = try await structured("read", ["conversation": id])
        XCTAssertEqual(read["reference"] as? String, mission.reference)
        XCTAssertEqual(read["severity"] as? String, "high")
        XCTAssertEqual(read["leadName"] as? String, "Rafe")
        XCTAssertEqual((read["evidence"] as? [[String: Any]])?.first?["id"] as? String, evidenceID)
    }

    func testAnAgentOpensAnMissionThroughTheCaseToolWhereTheRookAllowsIt() async throws {
        let opener = UUID()
        final class Asked: @unchecked Sendable { var agent: UUID?; var opening: CaseToolProvider.Opening? }
        let asked = Asked(), store = self.store!
        let provider = CaseToolProvider(store: store, leadOf: { _ in nil }, open: { agent, opening in
            asked.agent = agent; asked.opening = opening
            return try store.open(id: UUID(), title: opening.title, objective: opening.objective, champion: "Avery", openedBy: .agent(agent))
        }) { _ in "Rafe" }
        let listed = try JSONSerialization.jsonObject(with: try await provider.tools(context: ToolCallContext(agentID: opener, workspace: root))) as? [String: Any]
        let open = try XCTUnwrap((listed?["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "open" })
        XCTAssertEqual((open["inputSchema"] as? [String: Any])?["required"] as? [String], ["title", "objective"], "opening one needs no Mission")

        let data = try await provider.call("open", arguments: JSONSerialization.data(withJSONObject: [
            "title": "Domain-wide project creation", "objective": "Restrict it."]), files: [],
            context: ToolCallContext(agentID: opener, workspace: root))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = ((object["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("You lead it"), text)
        let conversation = try XCTUnwrap((object["structuredContent"] as? [String: Any])?["conversation"] as? String)
        XCTAssertEqual(store.audit(try XCTUnwrap(UUID(uuidString: conversation))).first?.actor, .agent(opener))
        XCTAssertEqual(asked.agent, opener)
        XCTAssertEqual(asked.opening?.title, "Domain-wide project creation")
        XCTAssertNil((open["inputSchema"] as? [String: Any]).flatMap { ($0["properties"] as? [String: Any])?["team"] },
                     "an opener could name any agent to join")

        // Without the Rook's say, agents may not.
        let closed = CaseToolProvider(store: store, leadOf: { _ in nil }) { _ in "Rafe" }
        let none = try JSONSerialization.jsonObject(with: try await closed.tools(context: ToolCallContext(agentID: opener, workspace: root))) as? [String: Any]
        XCTAssertFalse((none?["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "open" } ?? true)
    }

    /// A closed Mission is read-only to agents: they read it, but record nothing more until the champion reopens it.
    func testAClosedMissionTakesNoMoreFromAgents() async throws {
        lead = agent
        let mission = try open()
        let id = mission.id.uuidString
        try store.setStatus(.closed, of: mission.id, by: .champion("Avery"), outcome: .demonstrated, note: "Fixed.")
        for (tool, arguments) in [("entity", ["kind": "host", "name": "LT-0423"]),
                                  ("evidence", ["source": "Defender", "method": "q", "result": "r"]),
                                  ("finding", ["claim": "c", "evidence": ["V-1"], "confidence": "high"])] {
            do {
                _ = try await call(tool, arguments.merging(["conversation": id]) { $1 })
                XCTFail("\(tool) was recorded in a closed Mission")
            } catch { XCTAssertTrue("\(error)".contains("closed"), "\(error)") }
        }
        XCTAssertTrue(store.caseRecord(mission.id).entities.isEmpty)
        let read = try await call("read", ["conversation": id])
        XCTAssertTrue(read.contains(mission.reference), read)
        try store.setStatus(.active, of: mission.id, by: .champion("Avery"))
        _ = try await call("entity", ["conversation": id, "kind": "host", "name": "LT-0423"])
        XCTAssertEqual(store.caseRecord(mission.id).entities.count, 1, "a reopened Mission took nothing")
    }

    func testTheCaseToolRefusesAConversationThatIsNotAnMission() async throws {
        do {
            _ = try await call("read", ["conversation": UUID().uuidString])
            XCTFail("expected a refusal")
        } catch {}
    }

    func testTheCaseToolRecordsWhatAgentsFind() async throws {
        let mission = try open()
        let id = mission.id.uuidString
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
        let mission = try open()
        let id = mission.id.uuidString
        do { _ = try await call("status", ["conversation": id, "status": "proven", "note": "n"], as: UUID()); XCTFail("expected a refusal") } catch {}
        do { _ = try await call("status", ["conversation": id, "status": "closed", "note": "n"]); XCTFail("expected a refusal") } catch {}
        _ = try await call("status", ["conversation": id, "status": "proven", "note": "Host isolated"])
        XCTAssertEqual(store.mission(mission.id)?.status, .proven)
    }

    func testAnMissionStartsUnassessedAndOnlyItsLeadSetsSeverity() async throws {
        lead = agent
        let mission = try open()
        XCTAssertNil(mission.severity)
        let id = mission.id.uuidString
        do { _ = try await call("severity", ["conversation": id, "severity": "high", "note": "n"], as: UUID()); XCTFail("expected a refusal") } catch {}
        do { _ = try await call("severity", ["conversation": id, "severity": "severe", "note": "n"]); XCTFail("expected a refusal") } catch {}
        _ = try await call("severity", ["conversation": id, "severity": "high", "note": "Credentials were used"])
        XCTAssertEqual(store.mission(mission.id)?.severity, .high)
        XCTAssertEqual(store.audit(mission.id).last?.event, "severity")
    }

    func testWithoutALeadNobodyChangesSeverityOrStatus() async throws {
        let mission = try open()
        let id = mission.id.uuidString
        do { _ = try await call("severity", ["conversation": id, "severity": "high", "note": "n"]); XCTFail("expected a refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no lead"), error.localizedDescription) }
        do { _ = try await call("status", ["conversation": id, "status": "proven", "note": "n"]); XCTFail("expected a refusal") } catch {}
        XCTAssertNil(store.mission(mission.id)?.severity)
        let read = try await call("read", ["conversation": id])
        XCTAssertTrue(read.contains("Lead: none"), read)
    }

    func testLinkJoinsEntitiesIntoTheGraphReadShowsItAndAGhostIsRefused() async throws {
        lead = agent
        let mission = try open()
        let id = mission.id.uuidString
        _ = try await call("entity", ["conversation": id, "kind": "credential", "name": "AKIA-KEY"])
        _ = try await call("entity", ["conversation": id, "kind": "account", "name": "deploy-ci"])
        let link = try await structured("link", ["conversation": id, "from": "AKIA-KEY", "relation": "unlocks", "to": "deploy-ci"])
        XCTAssertEqual(link["relation"] as? String, "unlocks")
        let read = try await call("read", ["conversation": id])
        XCTAssertTrue(read.contains("AKIA-KEY unlocks deploy-ci"), read)
        // A link to an entity that was never recorded is refused, so the graph never points at nothing.
        do { _ = try await call("link", ["conversation": id, "from": "ghost", "relation": "unlocks", "to": "deploy-ci"]); XCTFail("linked a ghost") } catch {}
    }

    func testTheToolListDeclaresTheConversationForTheBroker() async throws {
        let provider = CaseToolProvider(store: store, leadOf: { _ in nil }) { _ in nil }
        let tools = try ToolDescriptor.list(mcp: try await provider.tools(context: ToolCallContext(agentID: agent, workspace: root)))
        XCTAssertEqual(Set(tools.map(\.name)), ["read", "entity", "link", "evidence", "finding", "status", "severity"])
        XCTAssertTrue(tools.allSatisfy { $0.conversationParameter == "conversation" })
    }
}
