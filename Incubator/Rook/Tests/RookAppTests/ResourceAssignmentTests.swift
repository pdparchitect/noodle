import NoodleCore
import RookCore
import XCTest

@MainActor final class ResourceAssignmentTests: XCTestCase {
    private var base: URL!
    private var model: RookModel!
    private var connection: ToolConnection!
    private var folder: AgentFolder!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("RookResources-\(UUID())")
        let shared = base.appendingPathComponent("Evidence")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        folder = AgentFolder(path: shared.path, writable: false, description: "Recorded evidence")
        model = RookModel(root: base.appendingPathComponent("Repository"), messenger: nil, isScripted: true)
        try model.repository.prepare()
        connection = try ToolConnection(name: "Evidence Search", endpoint: URL(string: "https://mcp.example.com")!)
        var registry = ToolConnectionRegistry()
        registry.connections = [connection]
        try registry.save(root: model.repository.rootURL)
        try model.connectionsController.reloadAssignments()
    }

    override func tearDownWithError() throws { model = nil; try? FileManager.default.removeItem(at: base) }

    private func agent(_ name: String = "Lunar Fox", resources: RookModel.AgentResources = .init()) throws -> AgentRecord {
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

    func testMissionResourcesCanBeCreatedEditedAndRevokedWithoutLosingTheCase() throws {
        let lead = try agent()
        _ = try model.updateAgent(lead, name: lead.displayName, description: nil, instructions: "Investigate.", provider: nil, model: nil,
                                  resources: .init(connections: [connection.id]))
        var draft = RookModel.Draft(title: "Beacon", objective: "Find its source", lead: lead.id, folders: [folder])
        let mission = try model.open(draft)
        let evidence = try model.store.updateCase(mission.id, by: .champion("Avery")) { record, _ in
            (record.record(evidenceFrom: "EDR", method: "Query", result: "Beacon", by: .champion("Avery"), at: Date()), "evidence", "Recorded")
        }
        XCTAssertEqual(model.conversation(mission.id)?.folders, [folder])
        XCTAssertEqual(try granted(lead), [folder])
        XCTAssertEqual(model.connectionsController.selectedIDs(for: lead), [connection.id])
        draft.title = "Resolved beacon"
        draft.folders = []
        let updated = try model.updateMission(mission, draft: draft)
        XCTAssertEqual(updated.id, mission.id)
        XCTAssertEqual(updated.title, draft.title)
        XCTAssertTrue(try granted(lead).isEmpty)
        XCTAssertEqual(model.connectionsController.selectedIDs(for: lead), [connection.id], "The agent's own tools stay")
        XCTAssertEqual(model.caseRecord(mission.id).evidence.first?.id, evidence.id)
    }

    func testInvalidResourcesDoNotPartiallyChangeNamesMembersOrAssignments() throws {
        let original = try agent()
        let invalid = RookModel.AgentResources(folders: [folder], connections: [UUID()])
        XCTAssertThrowsError(try model.updateAgent(original, name: "Changed", description: nil, instructions: "Changed", provider: nil, model: nil, resources: invalid))
        XCTAssertEqual(model.agent(original.id)?.displayName, original.displayName)
        XCTAssertTrue(try granted(original).isEmpty)
        let group = try model.createGroup(name: "Triage", description: nil, members: [original.id])
        let protected = AgentFolder(path: model.repository.rootURL.path)
        XCTAssertThrowsError(try model.updateGroup(group, name: "Changed", description: nil, members: [original.id], folders: [protected]))
        XCTAssertEqual(model.conversation(group.id)?.displayName, "Triage")
        XCTAssertTrue(model.connectionsController.selectedIDs(for: original).isEmpty)
    }

    /// Computers are chosen in the Mission's sheet with its team, and each one added or taken away is audited.
    func testMissionComputersAreChosenWithTheTeam() throws {
        let lead = try agent()
        let linux = UUID(), jumpBox = UUID()
        var draft = RookModel.Draft(title: "Beacon", lead: lead.id, computers: [linux],
                                    computerNames: [linux: "Linux", jumpBox: "Jump box"])
        let mission = try model.open(draft)
        XCTAssertEqual(model.store.mission(mission.id)?.computers, [linux])
        draft.computers = [jumpBox]
        try model.updateMission(mission, draft: draft)
        XCTAssertEqual(model.store.mission(mission.id)?.computers, [jumpBox])
        XCTAssertEqual(model.store.audit(mission.id).filter { $0.event == "computer" }.map(\.detail),
                       ["Added Linux.", "Added Jump box.", "Removed Linux."])
    }

    /// The scope is set in the Mission's sheet and reaches the agents in the group's description, with the objective.
    func testMissionScopeIsToldToTheTeamWithTheObjective() throws {
        let lead = try agent()
        var draft = RookModel.Draft(title: "Portal", objective: "Get into the portal", lead: lead.id)
        draft.scope = ["*.Target.com", "deny payments.target.com"]
        let mission = try model.open(draft)
        XCTAssertEqual(model.store.mission(mission.id)?.scope, ["*.target.com", "deny payments.target.com"])
        XCTAssertEqual(model.conversation(mission.id)?.publicDescription,
                       MissionScope.groupDescription(objective: "Get into the portal", scope: ["*.target.com", "deny payments.target.com"]))
        draft.scope = ["not a target"]
        XCTAssertThrowsError(try model.updateMission(mission, draft: draft))
        XCTAssertEqual(model.store.mission(mission.id)?.scope, ["*.target.com", "deny payments.target.com"])
        draft.scope = []
        try model.updateMission(mission, draft: draft)
        XCTAssertEqual(model.store.mission(mission.id)?.scope, [])
        XCTAssertEqual(model.conversation(mission.id)?.publicDescription, "Get into the portal")
        let opened = try model.open(byAgent: lead.id, .init(title: "Side door", objective: "Check the VPN"))
        XCTAssertEqual(opened.scope, [], "only the champion sets a scope")
    }

    /// Services opened beyond the scope are kept with the Mission; its agents hear only that there are some.
    func testMissionExceptionsAreKeptButNotListedToTheTeam() throws {
        let lead = try agent()
        var draft = RookModel.Draft(title: "Portal", objective: "Get into the portal", lead: lead.id)
        draft.scope = ["*.target.com"]
        draft.exceptions = ["crt.sh"]
        let mission = try model.open(draft)
        XCTAssertEqual(model.store.mission(mission.id)?.exceptions, ["crt.sh"])
        let description = try XCTUnwrap(model.conversation(mission.id)?.publicDescription)
        XCTAssertFalse(description.contains("crt.sh"))
        XCTAssertEqual(description, MissionScope.groupDescription(objective: "Get into the portal", scope: ["*.target.com"], exceptions: ["crt.sh"]))
        draft.exceptions = ["deny crt.sh"]
        XCTAssertThrowsError(try model.updateMission(mission, draft: draft))
        draft.exceptions = []
        try model.updateMission(mission, draft: draft)
        XCTAssertEqual(model.store.mission(mission.id)?.exceptions, [])
    }

    func testClosedMissionsCannotChangeResourceGrants() throws {
        let lead = try agent()
        let other = try agent("Brisk Otter")
        let mission = try model.open(.init(title: "Beacon", lead: lead.id))
        model.setStatus(.closed, of: mission, outcome: .demonstrated)
        let closed = try XCTUnwrap(model.mission(mission.id))
        XCTAssertThrowsError(try model.updateMission(closed, draft: .init(title: "Changed", lead: lead.id, folders: [folder])))
        XCTAssertTrue(try granted(lead).isEmpty)
        let conversation = try XCTUnwrap(model.conversation(closed.id))
        XCTAssertThrowsError(try model.updateMission(closed, draft: .init(title: "Beacon", lead: lead.id, staff: [other.id])))
        XCTAssertEqual(model.conversation(closed.id)?.participantIDs, conversation.participantIDs)
    }

    func testTeamEditsRefreshFolderGrantsAndKeepTheMissionsLead() throws {
        let lead = try agent(), previous = try agent("Brisk Otter"), next = try agent("Quiet Lynx")
        let mission = try model.open(.init(title: "Beacon", lead: lead.id, staff: [previous.id], folders: [folder]))
        XCTAssertEqual(model.conversation(mission.id)?.lead, lead.id)
        XCTAssertEqual(try granted(previous), [folder])
        try model.updateMission(mission, draft: .init(title: "Beacon", lead: lead.id, staff: [next.id], folders: [folder]))
        XCTAssertEqual(Set(model.conversation(mission.id)?.participantIDs ?? []), [lead.id, next.id])
        XCTAssertEqual(model.conversation(mission.id)?.lead, lead.id)
        XCTAssertTrue(try granted(previous).isEmpty)
        XCTAssertEqual(try granted(next), [folder])
        XCTAssertEqual(try granted(lead), [folder])
    }

    func testTheChampionChoosesTheLeadAndAnMissionNeedsNone() throws {
        let first = try agent(), second = try agent("Brisk Otter")
        let mission = try model.open(.init(title: "Beacon", staff: [first.id, second.id]))
        let conversation = try XCTUnwrap(model.conversation(mission.id))
        XCTAssertNil(conversation.lead, "no lead unless the champion chooses one")
        model.setLead(second.id, of: conversation)
        XCTAssertEqual(model.conversation(mission.id)?.lead, second.id)
        XCTAssertEqual(model.audit(mission.id).last?.event, "lead")
        model.setLead(nil, of: conversation)
        XCTAssertNil(model.conversation(mission.id)?.lead)
    }
}
