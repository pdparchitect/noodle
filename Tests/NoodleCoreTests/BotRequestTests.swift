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
        XCTAssertGreaterThan(try XCTUnwrap(repository.nextWakeDate(agentID: created.agent.id)), Date().addingTimeInterval(3_600))
        XCTAssertLessThanOrEqual(try XCTUnwrap(repository.nextWakeDate(agentID: helper.id)), before.addingTimeInterval(1))
        XCTAssertTrue(try repository.takeDueWakes(agentID: helper.id, at: Date().addingTimeInterval(1)))
        let due = try repository.listWakes(agentID: helper.id).due
        XCTAssertEqual(due.count, 1)
        XCTAssertTrue(due.first?.note.contains("--list-requests") == true, due.first?.note ?? "")
    }

    func testRequestWakesTakeNoneOfTheHelpersOwnWakes() throws {
        let created = try repository.createAgent(named: "Assistant")
        let helper = try repository.createAgent(named: "Accounts").agent
        XCTAssertEqual(ask(created.agent, helper.id, in: created.conversation.id, "Waiting").exitCode, 0)
        let now = Date()
        for hours in 1...AgentWakeLimits.pending {
            XCTAssertNoThrow(try repository.scheduleWake(agentID: helper.id, at: now.addingTimeInterval(Double(hours) * 3_600),
                                                         note: "Own wake \(hours)", now: now))
        }
    }

    func testBotHasAtMostThreeRequestsWaiting() throws {
        let created = try repository.createAgent(named: "Assistant")
        let helper = try repository.createAgent(named: "Accounts").agent
        let first = try decode(BotRequest.self, from: ask(created.agent, helper.id, in: created.conversation.id, "Request 1"))
        for index in 2...BotRequestLimits.waiting {
            XCTAssertEqual(ask(created.agent, helper.id, in: created.conversation.id, "Request \(index)").exitCode, 0)
        }
        let refused = ask(created.agent, helper.id, in: created.conversation.id, "One too many")
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertTrue(refused.standardError.contains("\(BotRequestLimits.waiting)"), refused.standardError)
        XCTAssertEqual(answer(helper, first.id, "Done").exitCode, 0)
        XCTAssertEqual(ask(created.agent, helper.id, in: created.conversation.id, "Room again").exitCode, 0)
    }

    func testBotCannotAskBackUpItsChainOfRequests() throws {
        let first = try repository.createAgent(named: "Assistant")
        let second = try repository.createAgent(named: "Accounts")
        let third = try repository.createAgent(named: "Research")
        XCTAssertEqual(ask(first.agent, second.agent.id, in: first.conversation.id, "Help").exitCode, 0)
        XCTAssertNotEqual(ask(second.agent, first.agent.id, in: second.conversation.id, "Back to you").exitCode, 0)
        XCTAssertEqual(ask(second.agent, third.agent.id, in: second.conversation.id, "Onwards").exitCode, 0)
        XCTAssertNotEqual(ask(third.agent, first.agent.id, in: third.conversation.id, "Round again").exitCode, 0)
        XCTAssertNotEqual(ask(third.agent, second.agent.id, in: third.conversation.id, "Back again").exitCode, 0)
        XCTAssertEqual(try repository.botRequests().count, 2)
    }

    func testRequestsGoAtMostTwoDeep() throws {
        let bots = try ["Assistant", "Accounts", "Research", "Calendar"].map { try repository.createAgent(named: $0) }
        XCTAssertEqual(ask(bots[0].agent, bots[1].agent.id, in: bots[0].conversation.id, "Depth 1").exitCode, 0)
        XCTAssertEqual(ask(bots[1].agent, bots[2].agent.id, in: bots[1].conversation.id, "Depth 2").exitCode, 0)
        let refused = ask(bots[2].agent, bots[3].agent.id, in: bots[2].conversation.id, "Depth 3")
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertTrue(refused.standardError.contains("\(BotRequestLimits.depth)"), refused.standardError)
        XCTAssertEqual(ask(bots[3].agent, bots[2].agent.id, in: bots[3].conversation.id, "A fresh chain").exitCode, 0)
    }

    func testRequestTurnsCountTowardWakingInARow() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent, conversation = created.conversation
        let helper = try repository.createAgent(named: "Accounts").agent
        var now = Date()
        for index in 1...AgentWakeLimits.withoutOutsideMessages {
            let asked = try decode(BotRequest.self, from: ask(asker, helper.id, in: conversation.id, "Request \(index)"))
            XCTAssertEqual(answer(helper, asked.id, "Answer \(index)").exitCode, 0)
            now = Date().addingTimeInterval(1)
            XCTAssertTrue(try repository.takeDueWakes(agentID: asker.id, at: now))
        }
        let refused = ask(asker, helper.id, in: conversation.id, "Once more")
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertTrue(refused.standardError.contains("\(AgentWakeLimits.withoutOutsideMessages)"), refused.standardError)
        XCTAssertThrowsError(try repository.scheduleWake(agentID: asker.id, at: now.addingTimeInterval(600), note: "Own", now: now))
        try repository.append(ChatMessage(conversationID: conversation.id, author: .user, body: "Carry on",
                                          createdAt: now.addingTimeInterval(1), delivery: .queued))
        XCTAssertEqual(ask(asker, helper.id, in: conversation.id, "After a message").exitCode, 0)
    }

    func testBotCannotDisguiseItsOwnWakeAsARequest() throws {
        let bot = try repository.createAgent(named: "Assistant").agent
        XCTAssertNotEqual(messenger(bot, "--wake-in", "10m", "--note", AgentWake.requestNote).exitCode, 0)
        XCTAssertNotEqual(messenger(bot, "--wake-in", "10m", "--note", AgentWake.answerNote).exitCode, 0)
        XCTAssertNil(repository.nextWakeDate(agentID: bot.id))
    }

    func testAnsweringWakesTheAskerOnce() throws {
        let created = try repository.createAgent(named: "Assistant")
        let helper = try repository.createAgent(named: "Accounts").agent
        let first = try decode(BotRequest.self, from: ask(created.agent, helper.id, in: created.conversation.id, "First"))
        let second = try decode(BotRequest.self, from: ask(created.agent, helper.id, in: created.conversation.id, "Second"))
        XCTAssertGreaterThan(try XCTUnwrap(repository.nextWakeDate(agentID: created.agent.id)), Date().addingTimeInterval(3_600))
        let before = Date()
        XCTAssertEqual(answer(helper, first.id, "One").exitCode, 0)
        XCTAssertEqual(answer(helper, second.id, "Two").exitCode, 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(repository.nextWakeDate(agentID: created.agent.id)), before.addingTimeInterval(1))
        XCTAssertTrue(try repository.takeDueWakes(agentID: created.agent.id, at: Date().addingTimeInterval(1)))
        let due = try repository.listWakes(agentID: created.agent.id).due
        XCTAssertEqual(due.count, 1)
        XCTAssertTrue(due.first?.note.contains("--list-answers") == true, due.first?.note ?? "")
    }

    func testAskerListsEachAnswerOnce() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent, conversation = created.conversation
        let helper = try repository.createAgent(named: "Accounts").agent
        let answered = try decode(BotRequest.self, from: ask(asker, helper.id, in: conversation.id, "Total the invoices"))
        _ = try decode(BotRequest.self, from: ask(asker, helper.id, in: conversation.id, "Still waiting"))
        XCTAssertEqual(try decode([BotRequest].self, from: messenger(asker, "--list-answers")), [])
        _ = try decode(BotRequest.self, from: answer(helper, answered.id, "The total is 120"))
        let listed = try decode([BotRequest].self, from: messenger(asker, "--list-answers"))
        XCTAssertEqual(listed.map(\.id), [answered.id])
        XCTAssertEqual(listed.first?.answer, "The total is 120")
        XCTAssertEqual(listed.first?.conversationID, conversation.id)
        XCTAssertEqual(try decode([BotRequest].self, from: messenger(asker, "--list-answers")), [])
        XCTAssertEqual(try decode([BotRequest].self, from: messenger(helper, "--list-answers")), [])
    }

    func testAskerCancelsAWaitingRequest() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent
        let helper = try repository.createAgent(named: "Accounts").agent
        let other = try repository.createAgent(named: "Research").agent
        let asked = try decode(BotRequest.self, from: ask(asker, helper.id, in: created.conversation.id, "Total the invoices"))
        XCTAssertNotEqual(messenger(helper, "--cancel-request", asked.id.uuidString).exitCode, 0)
        XCTAssertNotEqual(messenger(other, "--cancel-request", asked.id.uuidString).exitCode, 0)
        let cancelled = try decode(BotRequest.self, from: messenger(asker, "--cancel-request", asked.id.uuidString))
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(try decode([BotRequest].self, from: messenger(helper, "--list-requests")), [])
        let refused = answer(helper, asked.id, "Too late")
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertTrue(refused.standardError.contains("cancelled"), refused.standardError)
        XCTAssertNotEqual(messenger(asker, "--cancel-request", asked.id.uuidString).exitCode, 0)
        XCTAssertNil(repository.nextWakeDate(agentID: asker.id))
        XCTAssertEqual(try decode([BotRequest].self, from: messenger(asker, "--list-answers")), [])
    }

    func testAskingSetsAWakeForExpiryThatAnsweringRemoves() throws {
        let created = try repository.createAgent(named: "Assistant")
        let helper = try repository.createAgent(named: "Accounts").agent
        let asked = try decode(BotRequest.self, from: ask(created.agent, helper.id, in: created.conversation.id, "Total the invoices"))
        XCTAssertEqual(repository.nextWakeDate(agentID: created.agent.id), asked.createdAt.addingTimeInterval(BotRequestLimits.expiry))
        XCTAssertEqual(answer(helper, asked.id, "Done").exitCode, 0)
        XCTAssertFalse(try repository.listWakes(agentID: created.agent.id).pending.contains { $0.id == asked.id })
    }

    func testUnansweredRequestExpiresAfterADay() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent
        let helper = try repository.createAgent(named: "Accounts").agent
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let asked = try repository.askBot(helper.id, for: asker.id, in: created.conversation.id, text: "Total the invoices", now: start)
        let expiry = start.addingTimeInterval(BotRequestLimits.expiry)
        XCTAssertEqual(try repository.listBotRequests(waitingFor: helper.id, now: expiry.addingTimeInterval(-1)).map(\.id), [asked.id])
        XCTAssertTrue(try repository.takeDueWakes(agentID: asker.id, at: expiry))
        XCTAssertTrue(try repository.listWakes(agentID: asker.id).due.first?.note.contains("--list-answers") == true)
        XCTAssertEqual(try repository.listBotRequests(waitingFor: helper.id, now: expiry), [])
        XCTAssertThrowsError(try repository.answerBotRequest(asked.id, by: helper.id, answer: "Late", now: expiry))
        let expired = try repository.listBotAnswers(for: asker.id, now: expiry)
        XCTAssertEqual(expired.map(\.id), [asked.id])
        XCTAssertEqual(expired.first?.status, .expired)
        XCTAssertNil(expired.first?.answer)
        XCTAssertEqual(try repository.listBotAnswers(for: asker.id, now: expiry), [])
    }

    func testAnswerIsWithheldWhenTheHelperIsNoLongerSharedWithTheGuest() throws {
        let asker = try repository.createAgent(named: "Assistant").agent
        let helper = try repository.createAgent(named: "Accounts").agent
        let guest = ConversationGuest(id: UUID(), name: "Guest")
        let guestConversation = try repository.createGuestConversation(with: asker, guest: guest)
        let helperShare = try repository.createGuestConversation(with: helper, guest: guest)
        let asked = try decode(BotRequest.self, from: ask(asker, helper.id, in: guestConversation.id, "Total the invoices"))
        XCTAssertEqual(answer(helper, asked.id, "The total is 120").exitCode, 0)
        try repository.deleteConversation(id: helperShare.id)
        let listed = try decode([BotRequest].self, from: messenger(asker, "--list-answers"))
        XCTAssertEqual(listed.map(\.id), [asked.id])
        XCTAssertEqual(listed.first?.status, .withheld)
        XCTAssertNil(listed.first?.answer)
        XCTAssertNil(try repository.botRequests().first?.answer)
    }

    private func line(for request: UUID, in conversation: UUID) throws -> ChatMessage? {
        try repository.loadMessages(conversationID: conversation).first { $0.request?.requestID == request }
    }

    func testAskingAddsALineToTheAskingConversation() throws {
        let created = try repository.createAgent(named: "Assistant")
        let helper = try repository.createAgent(named: "Accounts").agent
        let asked = try decode(BotRequest.self, from: ask(created.agent, helper.id, in: created.conversation.id, "Total the invoices"))
        let line = try XCTUnwrap(try line(for: asked.id, in: created.conversation.id))
        XCTAssertEqual(line.author, .agent(created.agent.id))
        XCTAssertEqual(line.body, "Asked Accounts")
        XCTAssertEqual(line.request, BotRequestLine(requestID: asked.id, helperID: helper.id, helperName: "Accounts",
                                                    text: "Total the invoices", status: .waiting))
    }

    func testLineFollowsTheRequestAndShowsTheAnswerOnceCollected() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent, conversation = created.conversation.id
        let helper = try repository.createAgent(named: "Accounts").agent
        let answered = try decode(BotRequest.self, from: ask(asker, helper.id, in: conversation, "Total the invoices"))
        let cancelled = try decode(BotRequest.self, from: ask(asker, helper.id, in: conversation, "Never mind"))
        XCTAssertEqual(answer(helper, answered.id, "The total is 120").exitCode, 0)
        XCTAssertEqual(try line(for: answered.id, in: conversation)?.request?.status, .answered)
        XCTAssertNil(try line(for: answered.id, in: conversation)?.request?.answer)
        XCTAssertEqual(messenger(asker, "--cancel-request", cancelled.id.uuidString).exitCode, 0)
        XCTAssertEqual(try line(for: cancelled.id, in: conversation)?.request?.status, .cancelled)
        XCTAssertEqual(messenger(asker, "--list-answers").exitCode, 0)
        XCTAssertEqual(try line(for: answered.id, in: conversation)?.request?.answer, "The total is 120")
    }

    func testLineShowsExpiredAndWithheldRequestsWithoutAnAnswer() throws {
        let asker = try repository.createAgent(named: "Assistant").agent
        let helper = try repository.createAgent(named: "Accounts").agent
        let guest = ConversationGuest(id: UUID(), name: "Guest")
        let conversation = try repository.createGuestConversation(with: asker, guest: guest).id
        let helperShare = try repository.createGuestConversation(with: helper, guest: guest)
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let expired = try repository.askBot(helper.id, for: asker.id, in: conversation, text: "Slow", now: start)
        let withheld = try repository.askBot(helper.id, for: asker.id, in: conversation, text: "Private", now: start)
        _ = try repository.answerBotRequest(withheld.id, by: helper.id, answer: "Secret", now: start)
        try repository.deleteConversation(id: helperShare.id)
        _ = try repository.listBotAnswers(for: asker.id, now: start.addingTimeInterval(BotRequestLimits.expiry))
        XCTAssertEqual(try line(for: expired.id, in: conversation)?.request?.status, .expired)
        XCTAssertEqual(try line(for: withheld.id, in: conversation)?.request?.status, .withheld)
        XCTAssertNil(try line(for: withheld.id, in: conversation)?.request?.answer)
    }

    func testOtherBotsInTheConversationNeverReceiveTheLine() throws {
        let asker = try repository.createAgent(named: "Assistant").agent
        let member = try repository.createAgent(named: "Research").agent
        let helper = try repository.createAgent(named: "Accounts").agent
        let group = try repository.createGroup(named: "Team", participantIDs: [asker.id, member.id],
                                               existingAgents: try repository.loadAgents())
        _ = try repository.latestMessages(for: member.id)
        let asked = try repository.askBot(helper.id, for: asker.id, in: group.id, text: "Total the invoices")
        XCTAssertNotNil(try line(for: asked.id, in: group.id))
        XCTAssertFalse(try repository.latestMessages(for: member.id, consuming: false).contains { $0.message.request != nil })
    }

    /// The person can close a bot to other bots: then they can neither see it nor ask it.
    func testABotClosedToRequestsIsNeitherListedNorAsked() throws {
        let created = try repository.createAgent(named: "Assistant")
        let asker = created.agent, conversation = created.conversation.id
        let helper = try repository.createAgent(named: "Accounts").agent
        XCTAssertTrue(try repository.loadAgentTakesBotRequests(helper))
        try repository.updateAgentTakesBotRequests(helper, takes: false)
        XCTAssertFalse(try WorkspaceRepository(rootURL: root).loadAgentTakesBotRequests(helper))
        XCTAssertEqual(try listBots(asker, in: conversation), [])
        XCTAssertNotEqual(ask(asker, helper.id, in: conversation, "Total the invoices").exitCode, 0)
        XCTAssertEqual(try repository.botRequests(), [])
        try repository.updateAgentTakesBotRequests(helper, takes: true)
        XCTAssertEqual(try listBots(asker, in: conversation), [helper.id])
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
