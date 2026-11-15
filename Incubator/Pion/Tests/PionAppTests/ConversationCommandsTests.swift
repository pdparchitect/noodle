import NoodleCore
import PionCore
import XCTest

@MainActor final class ConversationCommandsTests: XCTestCase {
    private var root: URL!
    private var model: PionModel!
    private var agent: AgentRecord!
    private var direct: BotConversation!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PionCommands-\(UUID())")
        model = PionModel(root: root, messenger: nil, isScripted: true)
        agent = try model.repository.createAgent(named: "Avery", publicDescription: "Network analyst").agent
        model.refresh()
        direct = try XCTUnwrap(model.directConversation(of: agent))
    }

    override func tearDownWithError() throws {
        model = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testSearchFindsAgentsGroupsAndMessageTextWithoutChangingSelection() throws {
        let group = try model.createGroup(name: "Response Team", description: "Triage", members: [agent.id])
        try model.send("Unusual beacon from the laptop", in: direct.id)
        model.selection = group.id

        func found(_ text: String) -> [UUID]? {
            model.sidebarSearch(text, showingAll: true).map { ($0.investigations + $0.groups + $0.agents).map(\.id) }
        }
        XCTAssertEqual(found("avery"), [group.id, direct.id], "As in Noodle, a group is found by an agent in it")
        XCTAssertEqual(found("network analyst"), [direct.id])
        XCTAssertEqual(found("RESPONSE"), [group.id])
        XCTAssertEqual(found("beacon"), [])
        XCTAssertEqual(model.sidebarSearch("beacon", showingAll: true)?.mentions.map(\.conversationID), [direct.id])
        XCTAssertNil(found("  "))
        XCTAssertEqual(found("missing"), [])
        XCTAssertEqual(model.selection, group.id)
    }

    func testExportingAnInvestigationZipsItsCaseAuditMessagesAndAttachments() throws {
        let investigation = try model.open(PionModel.Draft(title: "Beaconing laptop", lead: agent.id))
        let file = root.appendingPathComponent("capture.txt")
        try Data("netstat".utf8).write(to: file)
        model.attach([file], to: investigation.id)
        model.drafts[investigation.id].text = "Capture attached"
        model.sendDraft(to: investigation.id)
        let zip = root.appendingPathComponent("Export.zip")

        try model.exportArchive(of: investigation, to: zip)

        let data = try Data(contentsOf: zip)
        XCTAssertEqual(data.prefix(2), Data("PK".utf8))
        let folder = "INV-0001 Beaconing laptop/"
        for name in ["investigation.json", "case.json", "audit.jsonl", "Conversation/messages.json", "Conversation/Attachments/"] {
            XCTAssertNotNil(data.range(of: Data((folder + name).utf8)), name)
        }
    }

    func testSearchIncludesClosedInvestigationsAndTheirReference() throws {
        let investigation = try model.open(PionModel.Draft(title: "Beaconing laptop", lead: agent.id))
        model.setStatus(.closed, of: investigation, outcome: .resolved)

        XCTAssertEqual(model.sidebarSearch(investigation.reference, showingAll: true)?.investigations.map(\.id), [investigation.id])
        XCTAssertEqual(model.sidebarSearch("beaconing", showingAll: true)?.investigations.map(\.id), [investigation.id])
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
