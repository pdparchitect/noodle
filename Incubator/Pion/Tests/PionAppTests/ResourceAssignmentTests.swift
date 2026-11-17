import NoodleCore
import PionCore
import XCTest

@MainActor final class ResourceAssignmentTests: XCTestCase {
    private var base: URL!
    private var model: PionModel!
    private var connection: ToolConnection!
    private var folder: AgentFolder!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("PionResources-\(UUID())")
        let shared = base.appendingPathComponent("Evidence")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        folder = AgentFolder(path: shared.path, writable: false, description: "Recorded evidence")
        model = PionModel(root: base.appendingPathComponent("Repository"), messenger: nil, isScripted: true)
        try model.repository.prepare()
        connection = try ToolConnection(name: "Evidence Search", endpoint: URL(string: "https://mcp.example.com")!)
        var registry = ToolConnectionRegistry()
        registry.connections = [connection]
        try registry.save(root: model.repository.rootURL)
        try model.connectionsController.reloadAssignments()
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

    /// As in Noodle: a group shares folders with whoever is in it, and its tools stay each agent's own.
    func testGroupFoldersFollowMembershipWhileToolsStayEachAgentsOwn() throws {
        let first = try agent(), second = try agent("Brisk Otter")
        _ = try model.updateAgent(first, name: first.displayName, description: nil, instructions: "Investigate.", provider: nil, model: nil,
                                  resources: .init(connections: [connection.id]))
        let group = try model.createGroup(name: "Triage", description: nil, members: [first.id], folders: [folder])
        XCTAssertEqual(try granted(first), [folder])
        XCTAssertTrue(try granted(second).isEmpty)
        XCTAssertEqual(model.connectionsController.selectedIDs(for: first), [connection.id])
        let updated = try model.updateGroup(group, name: "Response", description: nil, members: [second.id], folders: [folder])
        XCTAssertEqual(updated.folders, [folder])
        XCTAssertTrue(try granted(first).isEmpty)
        XCTAssertEqual(try granted(second), [folder])
        XCTAssertEqual(model.connectionsController.selectedIDs(for: first), [connection.id])
        XCTAssertTrue(model.connectionsController.selectedIDs(for: second).isEmpty)
    }

    func testInvestigationResourcesCanBeCreatedEditedAndRevokedWithoutLosingTheCase() throws {
        let lead = try agent()
        _ = try model.updateAgent(lead, name: lead.displayName, description: nil, instructions: "Investigate.", provider: nil, model: nil,
                                  resources: .init(connections: [connection.id]))
        var draft = PionModel.Draft(title: "Beacon", objective: "Find its source", lead: lead.id, folders: [folder])
        let investigation = try model.open(draft)
        let evidence = try model.store.updateCase(investigation.id, by: .champion("Avery")) { record, _ in
            (record.record(evidenceFrom: "EDR", method: "Query", result: "Beacon", by: .champion("Avery"), at: Date()), "evidence", "Recorded")
        }
        XCTAssertEqual(model.conversation(investigation.id)?.folders, [folder])
        XCTAssertEqual(try granted(lead), [folder])
        XCTAssertEqual(model.connectionsController.selectedIDs(for: lead), [connection.id])
        draft.title = "Resolved beacon"
        draft.folders = []
        let updated = try model.updateInvestigation(investigation, draft: draft)
        XCTAssertEqual(updated.id, investigation.id)
        XCTAssertEqual(updated.title, draft.title)
        XCTAssertTrue(try granted(lead).isEmpty)
        XCTAssertEqual(model.connectionsController.selectedIDs(for: lead), [connection.id], "The agent's own tools stay")
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
        XCTAssertThrowsError(try model.updateGroup(group, name: "Changed", description: nil, members: [original.id], folders: [protected]))
        XCTAssertEqual(model.conversation(group.id)?.displayName, "Triage")
        XCTAssertTrue(model.connectionsController.selectedIDs(for: original).isEmpty)
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
        XCTAssertThrowsError(try model.updateInvestigation(closed, draft: .init(title: "Beacon", lead: lead.id, staff: [other.id])))
        XCTAssertEqual(model.conversation(closed.id)?.participantIDs, conversation.participantIDs)
    }

    func testTeamEditsRefreshFolderGrantsAndKeepTheInvestigationsLead() throws {
        let lead = try agent(), previous = try agent("Brisk Otter"), next = try agent("Quiet Lynx")
        let investigation = try model.open(.init(title: "Beacon", lead: lead.id, staff: [previous.id], folders: [folder]))
        XCTAssertEqual(model.conversation(investigation.id)?.lead, lead.id)
        XCTAssertEqual(try granted(previous), [folder])
        try model.updateInvestigation(investigation, draft: .init(title: "Beacon", lead: lead.id, staff: [next.id], folders: [folder]))
        XCTAssertEqual(Set(model.conversation(investigation.id)?.participantIDs ?? []), [lead.id, next.id])
        XCTAssertEqual(model.conversation(investigation.id)?.lead, lead.id)
        XCTAssertTrue(try granted(previous).isEmpty)
        XCTAssertEqual(try granted(next), [folder])
        XCTAssertEqual(try granted(lead), [folder])
    }

    func testTheChampionChoosesTheLeadAndAnInvestigationNeedsNone() throws {
        let first = try agent(), second = try agent("Brisk Otter")
        let investigation = try model.open(.init(title: "Beacon", staff: [first.id, second.id]))
        let conversation = try XCTUnwrap(model.conversation(investigation.id))
        XCTAssertNil(conversation.lead, "no lead unless the champion chooses one")
        model.setLead(second.id, of: conversation)
        XCTAssertEqual(model.conversation(investigation.id)?.lead, second.id)
        XCTAssertEqual(model.audit(investigation.id).last?.event, "lead")
        model.setLead(nil, of: conversation)
        XCTAssertNil(model.conversation(investigation.id)?.lead)
    }
}
