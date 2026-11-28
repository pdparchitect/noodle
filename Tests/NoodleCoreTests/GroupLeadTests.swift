import XCTest
@testable import NoodleCore

final class GroupLeadTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-lead-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testOnlyTheLeadAndNamedBotsHearAPersonsMessageFirst() {
        let lunar = AgentRecord(displayName: "Lunar Fox", harnessIdentifier: "codex")
        let heron = AgentRecord(displayName: "Clever Heron", harnessIdentifier: "codex")
        let moth = AgentRecord(displayName: "Indigo Moth", harnessIdentifier: "codex")
        let all = [lunar, heron, moth]
        var group = BotConversation(displayName: "Case", kind: .group, participantIDs: all.map(\.id))

        let leaderless = GroupLead.wakeOrder(all, in: group, body: "Anyone?")
        XCTAssertEqual(leaderless.now.map(\.id), all.map(\.id))
        XCTAssertTrue(leaderless.later.isEmpty)

        group.leadID = lunar.id
        let led = GroupLead.wakeOrder(all, in: group, body: "What happened at 02:00?")
        XCTAssertEqual(led.now.map(\.id), [lunar.id])
        XCTAssertEqual(Set(led.later.map(\.id)), [heron.id, moth.id])

        let named = GroupLead.wakeOrder(all, in: group, body: "@clever heron, check the sign-ins.")
        XCTAssertEqual(Set(named.now.map(\.id)), [lunar.id, heron.id])
        XCTAssertEqual(named.later.map(\.id), [moth.id])

        // A lead no longer in the group leads nothing.
        group.participantIDs = [heron.id, moth.id]
        XCTAssertNil(group.lead)
        XCTAssertTrue(GroupLead.wakeOrder([heron, moth], in: group, body: "Hi").later.isEmpty)
    }

    func testAnImmediateGroupSendTargetsOnlyMentionedBots() {
        let ada = AgentRecord(displayName: "Ada", harnessIdentifier: "codex")
        let grace = AgentRecord(displayName: "Grace", harnessIdentifier: "codex")
        var group = BotConversation(displayName: "Case", kind: .group, participantIDs: [ada.id, grace.id])
        group.leadID = grace.id

        XCTAssertEqual(GroupLead.interruptionTargets([ada, grace], in: group, body: "@Ada, stop"), [ada.id])
        XCTAssertTrue(GroupLead.interruptionTargets([ada, grace], in: group, body: "Anybody?").isEmpty)
        let direct = BotConversation(displayName: "Ada", kind: .direct, participantIDs: [ada.id])
        XCTAssertEqual(GroupLead.interruptionTargets([ada], in: direct, body: "Stop"), [ada.id])
    }

    func testAMentionNeedsTheWholeName() {
        let ada = AgentRecord(displayName: "Ada", harnessIdentifier: "codex")
        XCTAssertEqual(GroupLead.mentioned(in: "@Ada?", among: [ada]), [ada.id])
        XCTAssertTrue(GroupLead.mentioned(in: "@Adams and Ada", among: [ada]).isEmpty)
    }

    func testThePersonSetsTheLeadWhichTheRosterMarksAndLeavingTheGroupClears() throws {
        let ada = try repository.createAgent(named: "Ada").agent, grace = try repository.createAgent(named: "Grace").agent
        let agents = try repository.loadAgents()
        let group = try repository.createGroup(named: "Design", participantIDs: [ada.id, grace.id], existingAgents: agents)
        XCTAssertNil(group.lead, "no lead until someone is made one")

        let led = try repository.setGroupLead(conversationID: group.id, agentID: grace.id, existingAgents: agents)
        XCTAssertEqual(led.lead, grace.id)
        XCTAssertEqual(try repository.loadMessages(conversationID: group.id).last?.body, "Grace now leads the group.")
        let roster = try repository.participantRoster(for: ada.id, conversationID: group.id)
        XCTAssertEqual(roster.participants.filter { $0.isLead == true }.map(\.participant.agentID), [grace.id])
        XCTAssertEqual(roster.conversation.lead, grace.id)

        XCTAssertThrowsError(try repository.setGroupLead(conversationID: group.id, agentID: UUID(), existingAgents: agents))

        let without = try repository.updateGroup(conversationID: group.id, named: "Design", publicDescription: nil,
                                                 participantIDs: [ada.id], existingAgents: agents)
        XCTAssertNil(without.leadID)
        let back = try repository.updateGroup(conversationID: group.id, named: "Design", publicDescription: nil,
                                              participantIDs: [ada.id, grace.id], existingAgents: agents)
        XCTAssertNil(back.lead, "rejoining does not make it the lead again")

        _ = try repository.setGroupLead(conversationID: group.id, agentID: ada.id, existingAgents: agents)
        let cleared = try repository.setGroupLead(conversationID: group.id, agentID: nil, existingAgents: agents)
        XCTAssertNil(cleared.lead)
        XCTAssertEqual(try repository.loadMessages(conversationID: group.id).last?.body, "The group no longer has a lead.")
    }
}
