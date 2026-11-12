import Foundation
import NoodleCore
@testable import PionCore
import XCTest

/// The case tool as agents reach it: through Noodle's tool broker, from an agent's own workspace.
final class CaseToolBrokerTests: XCTestCase {
    private var root: URL!
    private var broker: ToolBridgeBroker?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CaseToolBrokerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        broker?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ tool: String, _ arguments: [String: Any], as workspace: URL) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let result = try await Task.detached {
            try ToolBridgeClient.request(.call, provider: "case", tool: tool, arguments: data, workspace: workspace, currentDirectory: workspace)
        }.value
        let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        return ((object?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    func testAnAgentRecordsAndProposesInItsInvestigationAndIsRefusedAnyOther() async throws {
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("Pion", isDirectory: true))
        let store = PionStore(root: root.appendingPathComponent("Store", isDirectory: true))
        let member = try repository.createAgent(named: "Margot").agent
        let outsider = try repository.createAgent(named: "Theo").agent
        let agents = try repository.loadAgents()
        let group = try repository.createGroup(named: "INV-0001 Beacon", participantIDs: [member.id], existingAgents: agents)
        let investigation = try store.open(id: group.id, title: "Beacon", objective: "", scope: ["LT-0423"], severity: .high,
                                           champion: "Avery", leadAgentID: member.id, playbookID: nil)
        let registry = ToolProviderRegistry()
        try registry.register(CaseToolProvider(store: store) { id in agents.first { $0.id == id }?.displayName })
        let broker = ToolBridgeBroker(registry: registry, host: .repository(repository) { _ in .none }) { _ in .none }
        self.broker = broker
        try broker.start(agents: agents.map { ToolBridgeAgent(id: $0.id, workspace: repository.directory(for: $0)) })

        let id = investigation.id.uuidString
        let evidence = try await call("evidence", ["conversation": id, "source": "Defender", "method": "q", "result": "beacon"],
                                      as: repository.directory(for: member))
        XCTAssertTrue(evidence.contains("V-1"), evidence)
        let pending = try await call("propose", ["conversation": id, "operation": "isolate_host", "targets": ["LT-0423"],
                                                 "rationale": "V-1", "effect": "offline", "undo": "release"], as: repository.directory(for: member))
        XCTAssertTrue(pending.contains("Pending approval, action A-1"), pending)
        XCTAssertEqual(store.caseRecord(investigation.id).pendingActions.map(\.id), ["A-1"])
        XCTAssertEqual(store.audit(investigation.id).last?.actor, .agent(member.id))

        do {
            _ = try await call("read", ["conversation": id], as: repository.directory(for: outsider))
            XCTFail("An agent outside the Investigation read it.")
        } catch {}
        XCTAssertEqual(store.caseRecord(investigation.id).evidence.count, 1)
    }
}
