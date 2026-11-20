import NoodleCore
import NoodleRuntimeSettings
import RookCore
import XCTest

@MainActor final class ConversationCommandsTests: XCTestCase {
    private var root: URL!
    private var model: RookModel!
    private var agent: AgentRecord!
    private var direct: BotConversation!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RookCommands-\(UUID())")
        model = RookModel(root: root, messenger: nil, isScripted: true)
        agent = try model.repository.createAgent(named: "Avery", publicDescription: "Network analyst").agent
        model.refresh()
        direct = try XCTUnwrap(model.directConversation(of: agent))
    }

    override func tearDownWithError() throws {
        model = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testSearchFindsAgentsGroupsAndMessageTextWithoutChangingSelection() async throws {
        let group = try model.createGroup(name: "Response Team", description: "Triage", members: [agent.id])
        try model.send("Unusual beacon from the laptop", in: direct.id)
        model.selection = group.id

        func found(_ text: String) -> [UUID]? {
            model.sidebarSearch(text, showingAll: true, mentions: MentionFinder()).map { ($0.missions + $0.groups + $0.agents).map(\.id) }
        }
        XCTAssertEqual(found("avery"), [group.id, direct.id], "As in Noodle, a group is found by an agent in it")
        XCTAssertEqual(found("network analyst"), [direct.id])
        XCTAssertEqual(found("RESPONSE"), [group.id])
        XCTAssertEqual(found("beacon"), [])
        let mentions = await model.searched("beacon")?.mentions
        XCTAssertEqual(mentions?.map(\.conversationID), [direct.id])
        XCTAssertNil(found("  "))
        XCTAssertEqual(found("missing"), [])
        XCTAssertEqual(model.selection, group.id)
    }

    func testExportingAnMissionZipsItsCaseAuditMessagesAndAttachments() throws {
        let mission = try model.open(RookModel.Draft(title: "Beaconing laptop", lead: agent.id))
        let file = root.appendingPathComponent("capture.txt")
        try Data("netstat".utf8).write(to: file)
        model.attach([file], to: mission.id)
        model.drafts[mission.id].text = "Capture attached"
        model.sendDraft(to: mission.id)
        let zip = root.appendingPathComponent("Export.zip")

        try model.exportArchive(of: mission, to: zip)

        let data = try Data(contentsOf: zip)
        XCTAssertEqual(data.prefix(2), Data("PK".utf8))
        let folder = "M-0001 Beaconing laptop/"
        for name in ["mission.json", "case.json", "audit.jsonl", "Conversation/messages.json", "Conversation/Attachments/"] {
            XCTAssertNotNil(data.range(of: Data((folder + name).utf8)), name)
        }
    }

    func testSearchIncludesClosedMissionsAndTheirReference() throws {
        let mission = try model.open(RookModel.Draft(title: "Beaconing laptop", lead: agent.id))
        model.setStatus(.closed, of: mission, outcome: .demonstrated)

        XCTAssertEqual(model.sidebarSearch(mission.reference, showingAll: true, mentions: MentionFinder())?.missions.map(\.id), [mission.id])
        XCTAssertEqual(model.sidebarSearch("beaconing", showingAll: true, mentions: MentionFinder())?.missions.map(\.id), [mission.id])
    }

    func testStopTargetsTheRequestedDirectConversationAndRecordsItOnce() throws {
        let group = try model.createGroup(name: "Response Team", description: nil, members: [agent.id])
        model.selection = group.id
        model.scriptedPhases[agent.id] = .working

        XCTAssertNil(model.stoppableAgent(in: group.id))
        XCTAssertNil(model.stoppableAgent(in: nil))
        XCTAssertEqual(model.stoppableAgent(in: direct.id)?.id, agent.id)
        let before = model.messages(in: direct.id).count
        model.stop(in: direct.id)
        XCTAssertEqual(model.phase(of: agent), .ready)
        XCTAssertNil(model.stoppableAgent(in: direct.id))
        XCTAssertEqual(model.messages(in: direct.id).count, before + 1)
        model.stop(in: direct.id)
        XCTAssertEqual(model.messages(in: direct.id).count, before + 1)
        XCTAssertEqual(model.selection, group.id)
    }
}
