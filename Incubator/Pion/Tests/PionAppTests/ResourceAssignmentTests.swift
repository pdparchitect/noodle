import NoodleCore
import PionCore
import XCTest

@MainActor final class ResourceAssignmentTests: XCTestCase {
    private var base: URL!
    private var model: PionModel!
    private var connection: MCPConnectionRecord!
    private var folder: AgentFolder!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("PionResources-\(UUID())")
        let shared = base.appendingPathComponent("Evidence")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        folder = AgentFolder(path: shared.path, writable: false, description: "Recorded evidence")
        model = PionModel(root: base.appendingPathComponent("Repository"), messenger: nil, isScripted: true)
        try model.repository.prepare()
        connection = try MCPConnectionRecord(name: "Evidence Search", endpoint: URL(string: "https://mcp.example.com")!)
        var registry = MCPRegistry()
        registry.connections = [connection]
        try registry.save(root: model.repository.rootURL)
        try model.mcp.reloadAssignments()
    }

    override func tearDownWithError() throws { model = nil; try? FileManager.default.removeItem(at: base) }

    private func agent(_ name: String = "Lunar Fox", resources: PionModel.AgentResources = .init()) throws -> AgentRecord {
        try model.createAgent(name: name, description: nil, instructions: "Investigate.", provider: nil, model: nil, resources: resources)
    }

    private func granted(_ agent: AgentRecord) throws -> [AgentFolder] {
        try AgentFolder.granted(workspace: model.repository.directory(for: agent), protecting: [model.repository.rootURL])
    }

    func testAgentAssignmentsAreSavedAndActuallyGrantedToTheBrokerAndSandbox() throws {
        let assigned = try agent(resources: .init(folders: [folder], connections: [connection.id]))
        let other = try agent("Brisk Otter")
        let saved = try model.resources(for: assigned)
        XCTAssertEqual(saved.folders, [folder])
        XCTAssertEqual(saved.connections, [connection.id])
        XCTAssertEqual(try granted(assigned), [folder])
        XCTAssertTrue(model.toolManifests(for: assigned.id).contains { $0.id == connection.skillName })
        XCTAssertFalse(model.toolManifests(for: other.id).contains { $0.id == connection.skillName })
        XCTAssertTrue(model.toolManifests(for: other.id).contains { $0.id == "case" })
    }

    func testEditingCanPreserveOrRevokeAnAgentsAssignments() throws {
        let original = try agent(resources: .init(folders: [folder], connections: [connection.id]))
        let renamed = try model.updateAgent(original, name: "Quiet Lynx", description: nil, instructions: "Investigate.", provider: nil, model: nil)
        XCTAssertEqual(try model.resources(for: renamed).connections, [connection.id])
        XCTAssertEqual(try granted(renamed), [folder])
        _ = try model.updateAgent(renamed, name: "Quiet Lynx", description: nil, instructions: "Investigate.", provider: nil, model: nil, resources: .init())
        XCTAssertTrue(try model.resources(for: renamed).connections.isEmpty)
        XCTAssertTrue(try granted(renamed).isEmpty)
        XCTAssertFalse(model.toolManifests(for: renamed.id).contains { $0.id == connection.skillName })
    }

    func testGroupFoldersFollowMembershipWhileToolsStayAssignedToTheChosenAgent() throws {
        let first = try agent(), second = try agent("Brisk Otter")
        let group = try model.createGroup(name: "Triage", description: nil, members: [first.id], folders: [folder], memberTools: [first.id: [connection.id]])
        XCTAssertEqual(try granted(first), [folder])
        XCTAssertTrue(try granted(second).isEmpty)
        XCTAssertEqual(model.mcp.selectedIDs(for: first), [connection.id])
        let updated = try model.updateGroup(group, name: "Response", description: nil, members: [second.id], folders: [folder], memberTools: [second.id: []])
        XCTAssertEqual(updated.folders, [folder])
        XCTAssertTrue(try granted(first).isEmpty)
        XCTAssertEqual(try granted(second), [folder])
        XCTAssertEqual(model.mcp.selectedIDs(for: first), [connection.id])
        XCTAssertTrue(model.mcp.selectedIDs(for: second).isEmpty)
    }

    func testInvestigationResourcesCanBeCreatedEditedAndRevokedWithoutLosingTheCase() throws {
        let lead = try agent()
        var draft = PionModel.Draft(title: "Beacon", objective: "Find its source", lead: lead.id, folders: [folder], memberTools: [lead.id: [connection.id]])
        let investigation = try model.open(draft)
        let evidence = try model.store.updateCase(investigation.id, by: .champion("Avery")) { record, _ in
            (record.record(evidenceFrom: "EDR", method: "Query", result: "Beacon", by: .champion("Avery"), at: Date()), "evidence", "Recorded")
        }
        XCTAssertEqual(model.conversation(investigation.id)?.folders, [folder])
        XCTAssertEqual(try granted(lead), [folder])
        XCTAssertEqual(model.mcp.selectedIDs(for: lead), [connection.id])
        draft.title = "Resolved beacon"
        draft.folders = []
        draft.memberTools = [lead.id: []]
        let updated = try model.updateInvestigation(investigation, draft: draft)
        XCTAssertEqual(updated.id, investigation.id)
        XCTAssertEqual(updated.title, draft.title)
        XCTAssertTrue(try granted(lead).isEmpty)
        XCTAssertTrue(model.mcp.selectedIDs(for: lead).isEmpty)
        XCTAssertEqual(model.caseRecord(investigation.id).evidence.first?.id, evidence.id)
    }

    func testInvalidResourcesDoNotPartiallyChangeNamesMembersOrAssignments() throws {
        let original = try agent()
        let invalid = PionModel.AgentResources(folders: [folder], connections: [UUID()])
        XCTAssertThrowsError(try model.updateAgent(original, name: "Changed", description: nil, instructions: "Changed", provider: nil, model: nil, resources: invalid))
        XCTAssertEqual(model.agent(original.id)?.displayName, original.displayName)
        XCTAssertTrue(try granted(original).isEmpty)
        let group = try model.createGroup(name: "Triage", description: nil, members: [original.id])
        let protected = AgentFolder(path: model.repository.rootURL.path)
        XCTAssertThrowsError(try model.updateGroup(group, name: "Changed", description: nil, members: [original.id], folders: [protected], memberTools: [original.id: [connection.id]]))
        XCTAssertEqual(model.conversation(group.id)?.displayName, "Triage")
        XCTAssertTrue(model.mcp.selectedIDs(for: original).isEmpty)
    }

    func testClosedInvestigationsCannotChangeResourceGrants() throws {
        let lead = try agent()
        let other = try agent("Brisk Otter")
        let investigation = try model.open(.init(title: "Beacon", lead: lead.id))
        model.setStatus(.closed, of: investigation, outcome: .resolved)
        let closed = try XCTUnwrap(model.investigation(investigation.id))
        XCTAssertThrowsError(try model.updateInvestigation(closed, draft: .init(title: "Changed", lead: lead.id, folders: [folder])))
        XCTAssertTrue(try granted(lead).isEmpty)
        let conversation = try XCTUnwrap(model.conversation(closed.id))
        model.setMembers([lead.id, other.id], of: conversation)
        XCTAssertEqual(model.conversation(closed.id)?.participantIDs, conversation.participantIDs)
    }

    func testQuickTeamEditsRefreshFolderGrantsAndKeepTheInvestigationsLead() throws {
        let lead = try agent(), previous = try agent("Brisk Otter"), next = try agent("Quiet Lynx")
        let investigation = try model.open(.init(title: "Beacon", lead: lead.id, staff: [previous.id], folders: [folder]))
        XCTAssertEqual(try granted(previous), [folder])
        let conversation = try XCTUnwrap(model.conversation(investigation.id))
        model.setMembers([next.id], of: conversation)
        XCTAssertEqual(Set(model.conversation(investigation.id)?.participantIDs ?? []), [lead.id, next.id])
        XCTAssertTrue(try granted(previous).isEmpty)
        XCTAssertEqual(try granted(next), [folder])
        XCTAssertEqual(try granted(lead), [folder])
    }
}
