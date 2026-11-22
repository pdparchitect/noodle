import XCTest
@testable import NoodleCore

/// A group's lead brings in and takes out bots through Messenger, but only in groups it leads, and only bots it
/// already shares a group with. The broker enforces it, whatever the bot's instructions say.
final class LeadMembershipTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private var broker: MessengerBroker!
    private var lead: AgentRecord!, member: AgentRecord!, colleague: AgentRecord!, stranger: AgentRecord!
    /// Led by `lead`, with `member`.
    private var incident: BotConversation!
    /// Shared by `lead` and `colleague`, without a lead.
    private var team: BotConversation!
    /// Shared by `stranger` and `member` only, so `lead` never meets `stranger`.
    private var elsewhere: BotConversation!
    private var changes: [(before: BotConversation, after: BotConversation, by: UUID)] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root)
        lead = try repository.createAgent(named: "Lead").agent
        member = try repository.createAgent(named: "Member").agent
        colleague = try repository.createAgent(named: "Colleague").agent
        stranger = try repository.createAgent(named: "Stranger").agent
        let agents = try repository.loadAgents()
        incident = try repository.createGroup(named: "Incident", participantIDs: [lead.id, member.id], existingAgents: agents, leadID: lead.id)
        team = try repository.createGroup(named: "Team", participantIDs: [lead.id, colleague.id], existingAgents: agents)
        elsewhere = try repository.createGroup(named: "Elsewhere", participantIDs: [stranger.id, member.id], existingAgents: agents)
        broker = MessengerBroker(repository: repository)
        let lock = NSLock()
        broker.onGroupMembersChanged = { [weak self] before, after, by in lock.withLock { self?.changes.append((before, after, by)) } }
        try broker.start(agents: agents)
    }

    override func tearDownWithError() throws { broker?.stop(); try? FileManager.default.removeItem(at: root) }

    private func call(_ action: MessengerAction, as agent: AgentRecord) throws -> MessengerCommandResult {
        try MessengerBridgeClient.request(action, workspace: repository.directory(for: agent))
    }

    private func members(of group: BotConversation) throws -> Set<UUID> {
        Set(try XCTUnwrap(repository.loadConversations().first { $0.id == group.id }).participantIDs)
    }

    func testOnlyALeadListsBotsAndSeesOnlyThoseItSharesAGroupWith() throws {
        XCTAssertNotEqual(try call(.listBots, as: member).exitCode, 0, "a bot that leads no group listed bots")

        let result = try call(.listBots, as: lead)
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let listed = try JSONDecoder().decode(MessengerKnownBots.self, from: Data(result.standardOutput.utf8))
        XCTAssertEqual(listed.me.agentID, lead.id)
        XCTAssertEqual(Set(listed.bots.compactMap(\.participant.agentID)), [member.id, colleague.id])
        XCTAssertFalse(result.standardOutput.contains("Stranger"), "a bot the lead never met was listed")
    }

    func testALeadInvitesABotItKnowsButNotOneItNeverMet() throws {
        let invited = try call(.addParticipant(conversationID: incident.id, agentID: colleague.id), as: lead)
        XCTAssertEqual(invited.exitCode, 0, invited.standardError)
        XCTAssertEqual(try members(of: incident), [lead.id, member.id, colleague.id])
        XCTAssertEqual(try repository.loadMessages(conversationID: incident.id).last?.body, GroupNotice.membersAdded(["Colleague"]).body)
        XCTAssertEqual(changes.map(\.by), [lead.id], "the app was not told, so the new member would not wake")

        // A bot the lead never met is refused exactly as one that does not exist, so refusals name no one.
        let refused = try call(.addParticipant(conversationID: incident.id, agentID: stranger.id), as: lead)
        let missing = try call(.addParticipant(conversationID: incident.id, agentID: UUID()), as: lead)
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertEqual(refused.standardError, missing.standardError)
        XCTAssertEqual(try members(of: incident), [lead.id, member.id, colleague.id])
    }

    func testALeadRemovesMembersButNotItself() throws {
        let removed = try call(.removeParticipant(conversationID: incident.id, agentID: member.id), as: lead)
        XCTAssertEqual(removed.exitCode, 0, removed.standardError)
        XCTAssertEqual(try members(of: incident), [lead.id])
        XCTAssertEqual(try repository.loadMessages(conversationID: incident.id).last?.body, GroupNotice.membersRemoved(["Member"]).body)

        XCTAssertNotEqual(try call(.removeParticipant(conversationID: incident.id, agentID: lead.id), as: lead).exitCode, 0)
        XCTAssertNotEqual(try call(.removeParticipant(conversationID: incident.id, agentID: colleague.id), as: lead).exitCode, 0,
                          "removing a bot that is not in the group succeeded")
        XCTAssertEqual(try members(of: incident), [lead.id])
    }

    func testOnlyTheGroupsOwnLeadChangesItsMembers() throws {
        // A member that is not the lead.
        XCTAssertNotEqual(try call(.addParticipant(conversationID: incident.id, agentID: stranger.id), as: member).exitCode, 0)
        XCTAssertNotEqual(try call(.removeParticipant(conversationID: incident.id, agentID: lead.id), as: member).exitCode, 0)
        // A lead elsewhere, in a group it does not lead.
        XCTAssertNotEqual(try call(.addParticipant(conversationID: team.id, agentID: member.id), as: lead).exitCode, 0)
        XCTAssertNotEqual(try call(.removeParticipant(conversationID: team.id, agentID: colleague.id), as: lead).exitCode, 0)
        // A lead, in a group it is not in.
        XCTAssertNotEqual(try call(.addParticipant(conversationID: elsewhere.id, agentID: colleague.id), as: lead).exitCode, 0)
        XCTAssertEqual(try members(of: incident), [lead.id, member.id])
        XCTAssertEqual(try members(of: team), [lead.id, colleague.id])
        XCTAssertEqual(try members(of: elsewhere), [stranger.id, member.id])
        XCTAssertTrue(changes.isEmpty)
    }

    func testAConversationTheAppClosesKeepsItsMembers() throws {
        broker.refusingPosts = { [incident] in $0 == incident!.id ? "This is closed." : nil }
        let refused = try call(.addParticipant(conversationID: incident.id, agentID: colleague.id), as: lead)
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertTrue(refused.standardError.contains("This is closed."), refused.standardError)
        XCTAssertNotEqual(try call(.removeParticipant(conversationID: incident.id, agentID: member.id), as: lead).exitCode, 0)
        XCTAssertEqual(try members(of: incident), [lead.id, member.id])
    }

    func testWhereTheAppCannotWakeNewMembersLeadsChangeNoOne() throws {
        broker.onGroupMembersChanged = nil
        XCTAssertNotEqual(try call(.listBots, as: lead).exitCode, 0)
        XCTAssertNotEqual(try call(.addParticipant(conversationID: incident.id, agentID: colleague.id), as: lead).exitCode, 0)
        XCTAssertEqual(try members(of: incident), [lead.id, member.id])
    }

    func testTheCLIParsesTheMembershipCommands() throws {
        let workspace = repository.directory(for: lead).path
        let added = MessengerCLI.run(arguments: ["messenger", "--agent-directory", workspace, "--add-participant",
                                                 colleague.id.uuidString, "--conversation", incident.id.uuidString])
        XCTAssertEqual(added.exitCode, 0, added.standardError)
        let removed = MessengerCLI.run(arguments: ["messenger", "--agent-directory", workspace, "--remove-participant",
                                                   colleague.id.uuidString, "--conversation", incident.id.uuidString])
        XCTAssertEqual(removed.exitCode, 0, removed.standardError)
        XCTAssertEqual(MessengerCLI.run(arguments: ["messenger", "--agent-directory", workspace, "--list-bots"]).exitCode, 0)
        XCTAssertEqual(try members(of: incident), [lead.id, member.id])
    }
}
