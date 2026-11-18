import HubLink
import NoodleBrand
import NoodleCore
import PionCore
import XCTest

@MainActor final class AgentEditingTests: XCTestCase {
    private var root: URL!
    private var model: PionModel!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PionEditing-\(UUID())")
        model = PionModel(root: root, messenger: nil, isScripted: true)
    }

    override func tearDownWithError() throws {
        model = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func agent(_ name: String = "Avery") throws -> AgentRecord {
        try model.createAgent(name: name, description: "Analyst", instructions: "Check evidence.",
                              provider: .codex, model: "original", effort: "high", symbol: "shield", color: 3)
    }

    func testGeneratedNamesAreTheDefaultAndHumanNamesRemainAvailable() throws {
        XCTAssertEqual(PionModel.defaultAgentNameStyle, .playful)
        let generated = model.suggestedAgentName()
        XCTAssertEqual(generated.split(separator: " ").count, 2)
        _ = try agent(generated)
        let next = model.suggestedAgentName(excluding: generated)
        XCTAssertFalse(next.isEmpty)
        XCTAssertNotEqual(next.lowercased(), generated.lowercased())
        let human = model.suggestedAgentName(style: .real)
        XCTAssertFalse(human.isEmpty)
        XCTAssertFalse(human.contains(" "))
        let created = try agent("   ")
        XCTAssertEqual(created.displayName.split(separator: " ").count, 2)
    }

    /// As in Noodle: a login profile of another harness, or a voice the harness doesn't have, is dropped, not refused,
    /// and an agent moved to another harness leaves its old profile behind.
    func testAProfileOrVoiceNotOfTheAgentsHarnessIsDropped() throws {
        let claude = try model.harnessProfiles.create(provider: .claudeCode, named: "Work")
        let codex = try model.harnessProfiles.create(provider: .codex, named: "Work")
        let created = try model.createAgent(name: "Avery", description: nil, instructions: "", provider: .codex, model: nil,
                                            resources: .init(profile: claude.id))
        XCTAssertNil(try model.repository.loadAgentHarnessProfile(created))
        model.setVoice("not-a-voice", for: created)
        XCTAssertEqual(model.voice(of: created), "")
        model.setVoice("juniper", for: created)
        XCTAssertEqual(model.voice(of: created), "juniper")

        let kept = try model.updateAgent(created, name: "Avery", description: nil, instructions: "", provider: .codex, model: nil,
                                         resources: .init(profile: codex.id))
        XCTAssertEqual(try model.repository.loadAgentHarnessProfile(kept), codex.id)
        let moved = try model.updateAgent(kept, name: "Avery", description: nil, instructions: "", provider: .claudeCode, model: nil)
        XCTAssertNil(try model.repository.loadAgentHarnessProfile(moved))
    }

    /// A change that fails is undone, and its own error is what the person reads, with what could not be undone after it.
    func testAFailedChangeKeepsItsOwnErrorWhenUndoingItFailsToo() throws {
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        let checkpoint = try AgentSettingsCheckpoint(repository: repository)
        XCTAssertThrowsError(try checkpoint.undoing({ throw CaseError("The folder is gone.") },
                                                     undo: { throw CaseError("The agent is still there.") })) { error in
            XCTAssertEqual(error.localizedDescription,
                           "The folder is gone. Previous settings could not be fully restored: The agent is still there.")
        }
        XCTAssertThrowsError(try checkpoint.undoing { throw CaseError("The folder is gone.") }) { error in
            XCTAssertEqual(error.localizedDescription, "The folder is gone.")
        }
        XCTAssertEqual(try checkpoint.undoing { 7 }, 7)
    }

    func testEditingAnAgentPersistsItsIdentityInstructionsAndConversationName() throws {
        let original = try agent()
        let conversation = try XCTUnwrap(model.directConversation(of: original))
        let directory = model.repository.directory(for: original)
        try model.send("Keep this conversation.", in: conversation.id)
        XCTAssertEqual(try model.agentInstructions(original), "Check evidence.")
        let updated = try model.updateAgent(original, name: "Morgan", description: "Responder", instructions: "Follow leads.",
                                             provider: .claudeCode, model: "replacement")
        model.refresh()
        let saved = try XCTUnwrap(model.agent(original.id))
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(saved.displayName, "Morgan")
        XCTAssertEqual(saved.publicDescription, "Responder")
        XCTAssertEqual(saved.harnessIdentifier, HarnessProvider.claudeCode.rawValue)
        XCTAssertEqual(saved.modelIdentifier, "replacement")
        XCTAssertEqual(saved.reasoningEffort, "high")
        XCTAssertEqual(saved.avatarSymbolName, "shield")
        XCTAssertEqual(saved.avatarColorIndex, 3)
        XCTAssertEqual(model.repository.directory(for: saved), directory)
        XCTAssertEqual(model.directConversation(of: saved)?.id, conversation.id)
        XCTAssertEqual(model.directConversation(of: saved)?.displayName, "Morgan")
        XCTAssertTrue(model.messages(in: conversation.id).contains { $0.body == "Keep this conversation." })
        XCTAssertEqual(try model.agentInstructions(saved), "Follow leads.")
        let backstory = try model.repository.loadAgentBackstory(saved)
        XCTAssertEqual(backstory.components(separatedBy: AgentPrinciples.text).count, 2)
    }

    func testEditingAGroupKeepsItsHistoryAndSavesItsMembers() throws {
        let first = try agent(), second = try agent("Morgan")
        let group = try model.createGroup(name: "Triage", description: "Before", members: [first.id])
        try model.send("Keep the evidence.", in: group.id)
        _ = try model.updateGroup(group, name: "Response", description: "After", members: [first.id, second.id])
        model.refresh()
        let saved = try XCTUnwrap(model.conversation(group.id))
        XCTAssertEqual(saved.displayName, "Response")
        XCTAssertEqual(saved.publicDescription, "After")
        XCTAssertEqual(Set(saved.participantIDs), [first.id, second.id])
        XCTAssertTrue(model.messages(in: group.id).contains { $0.body == "Keep the evidence." })
    }

    func testAnAgentWithNoCustomInstructionsDoesNotDuplicatePionsRulesOnSave() throws {
        let original = try model.createAgent(name: "Morgan", description: nil, instructions: "", provider: nil, model: nil)
        XCTAssertEqual(try model.agentInstructions(original), "")
        let updated = try model.updateAgent(original, name: "Morgan", description: nil,
                                             instructions: try model.agentInstructions(original), provider: nil, model: nil)
        XCTAssertEqual(try model.repository.loadAgentBackstory(updated), AgentPrinciples.text)
    }

    func testEditRoutesToTheClickedRowWithoutChangingTheSelection() throws {
        let agent = try agent()
        let direct = try XCTUnwrap(model.directConversation(of: agent))
        let group = try model.createGroup(name: "Triage", description: nil, members: [agent.id])
        let window = WindowState()
        model.selection = group.id
        window.edit(direct, in: model)
        if case .editAgent(let target) = window.sheet { XCTAssertEqual(target.id, agent.id) }
        else { XCTFail("The agent row must open its editor") }
        XCTAssertEqual(model.selection, group.id)
        window.edit(group, in: model)
        if case .editGroup(let target) = window.sheet { XCTAssertEqual(target.id, group.id) }
        else { XCTFail("The group row must open its editor") }
    }

    func testInvalidEditsLeaveSavedValuesIntact() throws {
        let original = try agent()
        XCTAssertThrowsError(try model.updateAgent(original, name: " ", description: "Changed", instructions: "Changed",
                                                   provider: nil, model: nil))
        XCTAssertEqual(try model.repository.loadAgents().first?.displayName, original.displayName)
        XCTAssertEqual(try model.agentInstructions(original), "Check evidence.")
        let group = try model.createGroup(name: "Triage", description: nil, members: [original.id])
        XCTAssertThrowsError(try model.updateGroup(group, name: "Changed", description: nil, members: []))
        XCTAssertEqual(model.conversation(group.id)?.displayName, "Triage")
    }

    /// Settings > Agents lists archived agents too, as Noodle's Bots tab does, so one can be brought back.
    func testArchivedAgentsLeaveTheSidebarButStayInSettings() throws {
        let kept = try agent("Avery")
        let archived = try agent("Morgan")
        _ = try model.repository.setAgentArchived(true, agentID: archived.id)
        model.refresh()
        XCTAssertEqual(model.agents.map(\.id), [kept.id])
        XCTAssertEqual(Set(model.everyAgent.map(\.id)), [kept.id, archived.id])
        XCTAssertNotNil(model.everyAgent.first { $0.id == archived.id }?.archivedAt)
        _ = try model.repository.setAgentArchived(false, agentID: archived.id)
        model.refresh()
        XCTAssertEqual(Set(model.agents.map(\.id)), [kept.id, archived.id])
    }

    /// As in Noodle: an archived agent's conversation leaves the sidebar, the window and the Dock with it,
    /// read, since out of the sidebar it could never be read; an archived group is read too.
    func testArchivingTakesAConversationOutOfTheSidebarRead() throws {
        model.start()
        let avery = try agent("Avery")
        let morgan = try agent("Morgan")
        let direct = try XCTUnwrap(model.directConversation(of: morgan))
        let group = try model.createGroup(name: "Triage", description: nil, members: [avery.id])
        model.selection = nil
        for (agentID, id) in [(morgan.id, direct.id), (avery.id, group.id)] {
            _ = try model.repository.sendAgentMessage(agentID: agentID, conversationID: id, body: "Contained.")
        }
        model.refresh()
        XCTAssertEqual(model.badgedConversationIDs, [direct.id, group.id])
        model.selection = direct.id
        model.setArchived(true, agentID: morgan.id)
        model.setGroupArchived(true, id: group.id)
        XCTAssertNil(model.conversation(direct.id))
        XCTAssertNil(model.selection)
        XCTAssertTrue(model.badgedConversationIDs.isEmpty)
        XCTAssertFalse(model.sidebarSections(.newestFirst).agents.contains { $0.id == direct.id })
        model.setArchived(false, agentID: morgan.id)
        XCTAssertNotNil(model.conversation(direct.id))
        XCTAssertFalse(model.isUnread(direct.id))
    }

    /// An agent opens an Investigation for a problem it found, leads it and posts what started it itself; the
    /// champion owns it, the audit log says who opened it, and an agent cannot open them without end.
    func testAnAgentOpensAnInvestigationItLeads() throws {
        let avery = try agent("Avery"), morgan = try agent("Morgan")
        let opened = try model.open(byAgent: avery.id, .init(title: "Domain-wide project creation",
                                                             objective: "Restrict who can create projects.", team: ["morgan"]))
        XCTAssertEqual(model.conversation(opened.id)?.lead, avery.id)
        XCTAssertEqual(Set(model.conversation(opened.id)?.participantIDs ?? []), [avery.id, morgan.id])
        XCTAssertEqual(opened.champion, model.champion)
        XCTAssertEqual(model.store.audit(opened.id).first?.actor, .agent(avery.id))
        XCTAssertTrue(model.messages(in: opened.id).isEmpty, "a message was posted in the champion's name")

        XCTAssertThrowsError(try model.open(byAgent: avery.id, .init(title: "Other", objective: "x", team: ["Nobody"])))
        for index in 1...2 { _ = try model.open(byAgent: avery.id, .init(title: "Lead \(index)", objective: "x", team: [])) }
        XCTAssertThrowsError(try model.open(byAgent: avery.id, .init(title: "One too many", objective: "x", team: [])),
                             "an agent opened a fourth Investigation within the hour")
        XCTAssertNoThrow(try model.open(byAgent: morgan.id, .init(title: "Morgan's", objective: "x", team: [])))
        XCTAssertThrowsError(try model.open(byAgent: UUID(), .init(title: "Stranger", objective: "x", team: [])))
    }

    /// As in Noodle: an archived agent stays a member of its groups until removed, so a group with one can still
    /// be edited, and an Investigation too.
    func testAGroupWithAnArchivedMemberCanStillBeEdited() throws {
        let avery = try agent("Avery"), morgan = try agent("Morgan")
        let group = try model.createGroup(name: "Triage", description: nil, members: [avery.id, morgan.id])
        let investigation = try model.open(.init(title: "Beacon", lead: avery.id, staff: [morgan.id]))
        model.setArchived(true, agentID: morgan.id)
        let renamed = try model.updateGroup(group, name: "Response", description: nil, members: [avery.id, morgan.id])
        XCTAssertEqual(renamed.displayName, "Response")
        XCTAssertEqual(Set(renamed.participantIDs), [avery.id, morgan.id])
        let edited = try model.updateInvestigation(investigation, draft: .init(title: "Beacon on LT-0423", lead: avery.id, staff: [morgan.id]))
        XCTAssertEqual(edited.title, "Beacon on LT-0423")
        let removed = try model.updateGroup(renamed, name: "Response", description: nil, members: [avery.id])
        XCTAssertEqual(removed.participantIDs, [avery.id], "An archived member can be removed")
    }

    /// Settings > Groups lists archived groups, but not Investigations, which close instead, and brings one back.
    func testArchivedGroupsLeaveTheSidebarButStayInSettings() throws {
        let avery = try agent("Avery")
        let group = try model.createGroup(name: "Triage", description: nil, members: [avery.id])
        model.selection = group.id
        model.setGroupArchived(true, id: group.id)
        XCTAssertNil(model.conversation(group.id))
        XCTAssertNil(model.selection, "An archived group leaves the window it was open in")
        XCTAssertEqual(model.groupsInSettings.map(\.id), [group.id])
        XCTAssertNotNil(model.groupsInSettings.first?.archivedAt)
        model.setGroupArchived(false, id: group.id)
        XCTAssertNotNil(model.conversation(group.id))
        XCTAssertNil(model.groupsInSettings.first?.archivedAt)
    }
}
