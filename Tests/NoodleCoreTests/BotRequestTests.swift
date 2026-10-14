import XCTest
@testable import NoodleCore

final class BotRequestTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func messenger(_ agent: AgentRecord, _ arguments: String...) -> MessengerCommandResult {
        let command = repository.directory(for: agent).appendingPathComponent(".agents/skills/messenger/messenger")
        return MessengerCLI.runDirect(arguments: [command.path] + arguments)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from result: MessengerCommandResult) throws -> Value {
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(result.standardOutput.utf8))
    }

    private func listBots(_ agent: AgentRecord, in conversation: UUID) throws -> [UUID?] {
        try decode([MessengerBot].self, from: messenger(agent, "--list-bots", "--conversation", conversation.uuidString))
            .map(\.bot.agentID)
    }

    func testBotListsTheOtherBotsOfItsOwner() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent, conversation = created.conversation
        let accounts = try repository.createAgent(named: "Accounts", publicDescription: "Keeps the accounts").agent
        let research = try repository.createAgent(named: "Research").agent
        let listed = try decode([MessengerBot].self,
                                from: messenger(asker, "--list-bots", "--conversation", conversation.id.uuidString))
        XCTAssertEqual(listed.map(\.bot.agentID), [accounts.id, research.id])
        XCTAssertEqual(listed.map(\.bot.handle), [.bot, .bot])
        XCTAssertEqual(listed.first?.publicDescription, "Keeps the accounts")
    }

    func testBotListsNoBotsOfAnotherOwner() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent, conversation = created.conversation
        let accounts = try repository.createAgent(named: "Accounts").agent
        let other = try repository.createAgent(named: "Other Assistant")
        let stranger = other.agent, strangerConversation = other.conversation
        let first = AgentOwner(id: UUID(), name: "First owner"), second = AgentOwner(id: UUID(), name: "Second owner")
        try repository.updateAgentOwner(asker, owner: first)
        try repository.updateAgentOwner(accounts, owner: first)
        try repository.updateAgentOwner(stranger, owner: second)
        XCTAssertEqual(try listBots(asker, in: conversation.id), [accounts.id])
        XCTAssertEqual(try listBots(stranger, in: strangerConversation.id), [])
    }

    func testGuestConversationListsOnlyBotsSharedWithThatGuest() throws {
        let asker = try repository.createAgent(named: "Assistant").agent
        let shared = try repository.createAgent(named: "Shared Helper").agent
        let unshared = try repository.createAgent(named: "Private Helper").agent
        let guest = ConversationGuest(id: UUID(), name: "Guest")
        let guestConversation = try repository.createGuestConversation(with: asker, guest: guest)
        _ = try repository.createGuestConversation(with: shared, guest: guest)
        _ = try repository.createGuestConversation(with: unshared, guest: ConversationGuest(id: UUID(), name: "Another guest"))
        XCTAssertEqual(try listBots(asker, in: guestConversation.id), [shared.id])
    }

    func testBotCannotListBotsForAConversationItIsNotIn() throws {
        let asker = try repository.createAgent(named: "Assistant").agent
        let elsewhere = try repository.createAgent(named: "Accounts").conversation
        XCTAssertNotEqual(messenger(asker, "--list-bots", "--conversation", elsewhere.id.uuidString).exitCode, 0)
        XCTAssertNotEqual(messenger(asker, "--list-bots").exitCode, 0)
    }

    private func ask(_ agent: AgentRecord, _ helper: UUID, in conversation: UUID, _ text: String) -> MessengerCommandResult {
        messenger(agent, "--ask-bot", helper.uuidString, "--conversation", conversation.uuidString, "--body", text)
    }

    func testBotAsksABotItMayList() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent, conversation = created.conversation
        let helper = try repository.createAgent(named: "Accounts").agent
        let asked = try decode(BotRequest.self, from: ask(asker, helper.id, in: conversation.id, "Total the invoices"))
        XCTAssertEqual(asked.askerID, asker.id)
        XCTAssertEqual(asked.helperID, helper.id)
        XCTAssertEqual(asked.conversationID, conversation.id)
        XCTAssertEqual(asked.text, "Total the invoices")
        XCTAssertEqual(asked.status, .waiting)
        XCTAssertEqual(try repository.botRequests(), [asked])
    }

    func testBotCannotAskABotItMayNotList() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent, conversation = created.conversation
        let stranger = try repository.createAgent(named: "Other Assistant").agent
        try repository.updateAgentOwner(stranger, owner: AgentOwner(id: UUID(), name: "Second owner"))
        let unshared = try repository.createAgent(named: "Private Helper").agent
        let guestConversation = try repository.createGuestConversation(with: asker, guest: ConversationGuest(id: UUID(), name: "Guest"))
        let elsewhere = try repository.createAgent(named: "Accounts")
        XCTAssertNotEqual(ask(asker, stranger.id, in: conversation.id, "Hello").exitCode, 0)
        XCTAssertNotEqual(ask(asker, unshared.id, in: guestConversation.id, "Hello").exitCode, 0)
        XCTAssertNotEqual(ask(asker, asker.id, in: conversation.id, "Hello").exitCode, 0)
        XCTAssertNotEqual(ask(asker, elsewhere.agent.id, in: elsewhere.conversation.id, "Hello").exitCode, 0)
        XCTAssertNotEqual(ask(asker, UUID(), in: conversation.id, "Hello").exitCode, 0)
        XCTAssertEqual(try repository.botRequests(), [])
    }

    func testRequestNeedsText() throws {
        let created = try repository.createAgent(named: "Assistant")
        let helper = try repository.createAgent(named: "Accounts").agent
        XCTAssertNotEqual(ask(created.agent, helper.id, in: created.conversation.id, "  \n").exitCode, 0)
        XCTAssertNotEqual(messenger(created.agent, "--ask-bot", helper.id.uuidString,
                                    "--conversation", created.conversation.id.uuidString).exitCode, 0)
        XCTAssertEqual(try repository.botRequests(), [])
    }

    private func answer(_ agent: AgentRecord, _ request: UUID, _ text: String) -> MessengerCommandResult {
        messenger(agent, "--answer-request", request.uuidString, "--body", text)
    }

    func testHelperListsOnlyRequestsWaitingForIt() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent, conversation = created.conversation
        let helper = try repository.createAgent(named: "Accounts").agent
        let other = try repository.createAgent(named: "Research").agent
        let first = try decode(BotRequest.self, from: ask(asker, helper.id, in: conversation.id, "First"))
        let second = try decode(BotRequest.self, from: ask(asker, helper.id, in: conversation.id, "Second"))
        _ = try decode(BotRequest.self, from: ask(asker, other.id, in: conversation.id, "Elsewhere"))
        XCTAssertEqual(try decode([BotRequest].self, from: messenger(helper, "--list-requests")), [first, second])
        XCTAssertEqual(try decode([BotRequest].self, from: messenger(asker, "--list-requests")), [])
        _ = try decode(BotRequest.self, from: answer(helper, first.id, "Done"))
        XCTAssertEqual(try decode([BotRequest].self, from: messenger(helper, "--list-requests")), [second])
    }

    func testHelperAnswersARequest() throws {
        let created = try repository.createAgent(named: "Assistant")
        let helper = try repository.createAgent(named: "Accounts").agent
        let asked = try decode(BotRequest.self, from: ask(created.agent, helper.id, in: created.conversation.id, "Total the invoices"))
        let answered = try decode(BotRequest.self, from: answer(helper, asked.id, "The total is 120"))
        XCTAssertEqual(answered.id, asked.id)
        XCTAssertEqual(answered.status, .answered)
        XCTAssertEqual(answered.answer, "The total is 120")
        XCTAssertNotNil(answered.answeredAt)
        XCTAssertEqual(try repository.botRequests(), [answered])
    }

    func testOnlyTheAskedBotAnswersAndOnlyOnce() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent
        let helper = try repository.createAgent(named: "Accounts").agent
        let other = try repository.createAgent(named: "Research").agent
        let asked = try decode(BotRequest.self, from: ask(asker, helper.id, in: created.conversation.id, "Total the invoices"))
        XCTAssertNotEqual(answer(asker, asked.id, "Answering myself").exitCode, 0)
        XCTAssertNotEqual(answer(other, asked.id, "Not asked").exitCode, 0)
        XCTAssertNotEqual(answer(helper, UUID(), "No such request").exitCode, 0)
        XCTAssertNotEqual(answer(helper, asked.id, "  ").exitCode, 0)
        XCTAssertEqual(try repository.botRequests(), [asked])
        _ = try decode(BotRequest.self, from: answer(helper, asked.id, "First answer"))
        XCTAssertNotEqual(answer(helper, asked.id, "Second answer").exitCode, 0)
        XCTAssertEqual(try repository.botRequests().map(\.answer), ["First answer"])
    }

    func testAskingWakesTheHelperOnce() throws {
        let created = try repository.createAgent(named: "Assistant")
        let helper = try repository.createAgent(named: "Accounts").agent
        let before = Date()
        XCTAssertEqual(ask(created.agent, helper.id, in: created.conversation.id, "First").exitCode, 0)
        XCTAssertEqual(ask(created.agent, helper.id, in: created.conversation.id, "Second").exitCode, 0)
        XCTAssertNil(repository.nextWakeDate(agentID: created.agent.id))
        XCTAssertLessThanOrEqual(try XCTUnwrap(repository.nextWakeDate(agentID: helper.id)), before.addingTimeInterval(1))
        XCTAssertTrue(try repository.takeDueWakes(agentID: helper.id, at: Date().addingTimeInterval(1)))
        let due = try repository.listWakes(agentID: helper.id).due
        XCTAssertEqual(due.count, 1)
        XCTAssertTrue(due.first?.note.contains("--list-requests") == true, due.first?.note ?? "")
    }

    func testRequestWakesLeaveTheHelpersOwnWakeLimitsAlone() throws {
        let created = try repository.createAgent(named: "Assistant")
        let helper = try repository.createAgent(named: "Accounts").agent
        var now = Date()
        for _ in 1...AgentWakeLimits.withoutOutsideMessages {
            XCTAssertEqual(ask(created.agent, helper.id, in: created.conversation.id, "Again").exitCode, 0)
            now = Date().addingTimeInterval(1)
            XCTAssertTrue(try repository.takeDueWakes(agentID: helper.id, at: now))
        }
        XCTAssertEqual(ask(created.agent, helper.id, in: created.conversation.id, "Waiting").exitCode, 0)
        for hours in 1...AgentWakeLimits.pending {
            XCTAssertNoThrow(try repository.scheduleWake(agentID: helper.id, at: now.addingTimeInterval(Double(hours) * 3_600),
                                                         note: "Own wake \(hours)", now: now))
        }
    }

    func testBotCannotDisguiseItsOwnWakeAsARequest() throws {
        let bot = try repository.createAgent(named: "Assistant").agent
        XCTAssertNotEqual(messenger(bot, "--wake-in", "10m", "--note", AgentWake.requestNote).exitCode, 0)
        XCTAssertNil(repository.nextWakeDate(agentID: bot.id))
    }

    func testAddedRequestIsKeptForBothBots() throws {
        let asker = try repository.createAgent(named: "Assistant").agent
        let helper = try repository.createAgent(named: "Accounts").agent
        let conversation = UUID()
        let added = try repository.addBotRequest(askerID: asker.id, helperID: helper.id, conversationID: conversation,
                                                 text: "Total the invoices in the shared folder")
        XCTAssertEqual(added.askerID, asker.id)
        XCTAssertEqual(added.helperID, helper.id)
        XCTAssertEqual(added.conversationID, conversation)
        XCTAssertEqual(added.text, "Total the invoices in the shared folder")
        XCTAssertEqual(added.status, .waiting)
        XCTAssertEqual(try WorkspaceRepository(rootURL: root).botRequests(), [added])
    }

    func testRequestsAreKeptOutsideEveryWorkspace() throws {
        let asker = try repository.createAgent(named: "Assistant").agent
        let helper = try repository.createAgent(named: "Accounts").agent
        _ = try repository.addBotRequest(askerID: asker.id, helperID: helper.id, conversationID: UUID(), text: "Hello")
        let files = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String }
            .filter { $0.contains("request") } ?? []
        XCTAssertFalse(files.isEmpty)
        let workspaces = [asker, helper].map { repository.directory(for: $0).standardizedFileURL.path + "/" }
        XCTAssertTrue(files.allSatisfy { file in
            let path = root.appendingPathComponent(file).standardizedFileURL.path
            return !workspaces.contains { path.hasPrefix($0) }
        })
    }

    func testRequestsAddedAtOnceAreAllKept() throws {
        let asker = try repository.createAgent(named: "Assistant").agent
        let helper = try repository.createAgent(named: "Accounts").agent
        let repository = repository!
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            _ = try? repository.addBotRequest(askerID: asker.id, helperID: helper.id, conversationID: UUID(), text: "Request \(index)")
        }
        XCTAssertEqual(Set(try repository.botRequests().map(\.text)), Set((0..<20).map { "Request \($0)" }))
    }
}
