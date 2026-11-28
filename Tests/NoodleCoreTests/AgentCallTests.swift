import XCTest
@testable import NoodleCore

final class AgentCallTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

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

    private func refusal(_ body: () throws -> AgentCallRequest) -> String {
        do { _ = try body() } catch { return error.localizedDescription }
        XCTFail("The call was placed")
        return ""
    }

    func testAwayStatePersistsAndRefusesCallsUntilItsDeadline() throws {
        let bot = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue).agent
        let until = date.addingTimeInterval(3600)
        let away = WorkspaceRepository.OwnerAway(until: until, note: "  Back soon  ")
        try repository.saveOwnerAway(away)
        XCTAssertEqual(try repository.loadOwnerAway(), away)
        XCTAssertEqual(away.note, "Back soon")
        XCTAssertTrue(refusal {
            try repository.requestCall(agentID: bot.id, reason: "Test call", now: self.date)
        }.contains("Your person is away"))
        XCTAssertNoThrow(try repository.requestCall(agentID: bot.id, reason: "Test call", now: until))
        try repository.saveOwnerAway(nil)
        XCTAssertNil(try repository.loadOwnerAway())
    }

    func testABotWhoseHarnessTakesCallsCallsItsPersonFromItsOwnConversation() throws {
        let made = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue)
        let result = messenger(made.agent, "--call", "--reason", "The release build is failing")
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let request = try decoder.decode(AgentCallRequest.self, from: Data(result.standardOutput.utf8))
        XCTAssertEqual(request.agentID, made.agent.id)
        XCTAssertEqual(request.conversationID, made.conversation.id)
        XCTAssertEqual(request.reason, "The release build is failing")
        XCTAssertEqual(request.expiresAt.timeIntervalSince(request.requestedAt), AgentCallLimits.ringing)
        XCTAssertEqual(repository.pendingCall(agentID: made.agent.id), request)
        // Kept beside agent.json, where the bot cannot change it.
        let workspace = repository.directory(for: made.agent).standardizedFileURL.path
        let stored = repository.storage(for: made.agent.id).package.appendingPathComponent("calls.json").standardizedFileURL.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored))
        XCTAssertFalse(stored.hasPrefix(workspace + "/"))
    }

    func testOnlyBotsWhoseHarnessTakesCallsCanCallAndOnlyWithAShortReason() throws {
        let claude = try repository.createAgent(named: "Clara", harnessIdentifier: HarnessProvider.claudeCode.rawValue).agent
        let refused = messenger(claude, "--call", "--reason", "Hello")
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertTrue(refused.standardError.contains("cannot take voice calls"), refused.standardError)
        XCTAssertNil(repository.pendingCall(agentID: claude.id))

        let codex = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue).agent
        XCTAssertNotEqual(messenger(codex, "--call").exitCode, 0)
        XCTAssertNotEqual(messenger(codex, "--call", "--reason", "  ").exitCode, 0)
        XCTAssertNotEqual(messenger(codex, "--call", "--reason", String(repeating: "a", count: AgentCallLimits.reasonLength + 1)).exitCode, 0)
        XCTAssertNil(repository.pendingCall(agentID: codex.id))
        let request = try repository.requestCall(agentID: codex.id, reason: "Two\nlines", now: date)
        XCTAssertEqual(request.reason, "Two lines")
    }

    func testOneCallRingsAtATimeThenACooldownAndADailyLimitApply() throws {
        let bot = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue).agent
        let minute: TimeInterval = 60
        let first = try repository.requestCall(agentID: bot.id, reason: "One", now: date)
        XCTAssertTrue(refusal { try repository.requestCall(agentID: bot.id, reason: "Again", now: date.addingTimeInterval(10)) }
            .contains("still ringing"))
        XCTAssertEqual(try repository.endCall(agentID: bot.id, id: first.id), first)
        XCTAssertNil(try repository.endCall(agentID: bot.id, id: first.id))
        XCTAssertTrue(refusal { try repository.requestCall(agentID: bot.id, reason: "Again", now: date.addingTimeInterval(10 * minute)) }
            .contains("less than 30 minutes ago"))

        let second = try repository.requestCall(agentID: bot.id, reason: "Two", now: date.addingTimeInterval(31 * minute))
        _ = try repository.endCall(agentID: bot.id, id: second.id)
        let third = try repository.requestCall(agentID: bot.id, reason: "Three", now: date.addingTimeInterval(62 * minute))
        _ = try repository.endCall(agentID: bot.id, id: third.id)
        XCTAssertTrue(refusal { try repository.requestCall(agentID: bot.id, reason: "Four", now: date.addingTimeInterval(93 * minute)) }
            .contains("3 times in the last 24 hours"))
        // The first call leaves the last 24 hours.
        XCTAssertNoThrow(try repository.requestCall(agentID: bot.id, reason: "Next day", now: date.addingTimeInterval(24 * 60 * minute + minute)))
    }

    private func write(_ author: MessageAuthor, in conversationID: UUID, at createdAt: Date) throws {
        try repository.append(ChatMessage(conversationID: conversationID, author: author, body: "Can you call me",
                                          createdAt: createdAt, delivery: .delivered))
    }

    /// Petko asked for a call, declined it by accident and asked again: a call within minutes of the
    /// person writing counts as asked for, so neither the cooldown nor the daily limit holds it back.
    func testACallThePersonAskedForSkipsTheCooldownAndTheDailyLimit() throws {
        let made = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue)
        let bot = made.agent
        let minute: TimeInterval = 60
        for (index, offset) in [0, 31, 62].enumerated() {
            let call = try repository.requestCall(agentID: bot.id, reason: "Call \(index)", now: date.addingTimeInterval(Double(offset) * minute))
            _ = try repository.endCall(agentID: bot.id, id: call.id)
        }
        try write(.user, in: made.conversation.id, at: date.addingTimeInterval(63 * minute))
        let asked = try repository.requestCall(agentID: bot.id, reason: "You asked me to call", now: date.addingTimeInterval(65 * minute))
        // Still one call ringing at a time.
        XCTAssertTrue(refusal { try repository.requestCall(agentID: bot.id, reason: "Again", now: date.addingTimeInterval(65 * minute + 10)) }
            .contains("still ringing"))
        _ = try repository.endCall(agentID: bot.id, id: asked.id)
        // One message asks for one call: calling again needs them to write again.
        XCTAssertTrue(refusal { try repository.requestCall(agentID: bot.id, reason: "Again", now: date.addingTimeInterval(66 * minute)) }
            .contains("less than 30 minutes ago"))
        try write(.user, in: made.conversation.id, at: date.addingTimeInterval(66 * minute))
        XCTAssertNoThrow(try repository.requestCall(agentID: bot.id, reason: "Call me again", now: date.addingTimeInterval(67 * minute)))
        XCTAssertTrue(MessengerCommandKind.call.guidance.contains("in the last 5 minutes and after your last call"))
    }

    func testAMessageOlderThanFiveMinutesDoesNotAskForACall() throws {
        let made = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue)
        let first = try repository.requestCall(agentID: made.agent.id, reason: "One", now: date)
        _ = try repository.endCall(agentID: made.agent.id, id: first.id)
        try write(.user, in: made.conversation.id, at: date.addingTimeInterval(60))
        let refused = refusal { try repository.requestCall(agentID: made.agent.id, reason: "Two", now: date.addingTimeInterval(60 + 5 * 60)) }
        XCTAssertTrue(refused.contains("less than 30 minutes ago"))
        XCTAssertTrue(refused.contains("you can call within 5 minutes of their message"), refused)
    }

    /// Only the person writing in the bot's own conversation asks for a call: not the bot itself, other
    /// bots, Noodle, or the person writing somewhere else.
    func testOnlyThePersonWritingInTheBotsConversationAsksForACall() throws {
        let made = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue)
        let other = try repository.createAgent(named: "Kai", harnessIdentifier: HarnessProvider.codex.rawValue).agent
        let group = try repository.createGroup(named: "Team", participantIDs: [made.agent.id, other.id],
                                               existingAgents: [made.agent, other])
        let first = try repository.requestCall(agentID: made.agent.id, reason: "One", now: date)
        _ = try repository.endCall(agentID: made.agent.id, id: first.id)
        let later = date.addingTimeInterval(2 * 60)
        try write(.agent(made.agent.id), in: made.conversation.id, at: later)
        try write(.agent(other.id), in: made.conversation.id, at: later)
        try write(.system, in: made.conversation.id, at: later)
        try write(.user, in: group.id, at: later)
        XCTAssertTrue(refusal { try repository.requestCall(agentID: made.agent.id, reason: "Two", now: later.addingTimeInterval(60)) }
            .contains("less than 30 minutes ago"))
    }

    func testACallThatRangWhileNobodyEndedItStopsBlockingTheNextOne() throws {
        let bot = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue).agent
        let stale = try repository.requestCall(agentID: bot.id, reason: "One", now: date)
        let next = try repository.requestCall(agentID: bot.id, reason: "Two", now: date.addingTimeInterval(31 * 60))
        XCTAssertNotEqual(next.id, stale.id)
        XCTAssertEqual(repository.pendingCall(agentID: bot.id), next)
    }

    func testAnUnansweredCallLeavesACardFromTheBotThatNeverReachesItsInbox() throws {
        let made = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue)
        let request = try repository.requestCall(agentID: made.agent.id, reason: "The build is broken", now: date)
        let card = try repository.recordUnansweredCall(request, .missed, at: request.expiresAt)
        XCTAssertEqual(card.author, .agent(made.agent.id))
        XCTAssertEqual(card.body, "Missed call")
        XCTAssertEqual(card.call, VoiceCallRecord(agentID: made.agent.id, endedAt: request.expiresAt, unanswered: .missed,
                                                  reason: "The build is broken"))
        XCTAssertEqual(try repository.loadMessages(conversationID: made.conversation.id).last, card)
        XCTAssertEqual(try repository.recordUnansweredCall(request, .declined).body, "Declined call")
        XCTAssertTrue(try repository.latestMessages(for: made.agent.id).isEmpty)

        // Cards saved before calls could be missed still read.
        let older = try JSONDecoder().decode(VoiceCallRecord.self, from: Data(#"{"agentID":"\#(made.agent.id)","lines":[]}"#.utf8))
        XCTAssertNil(older.unanswered)
        XCTAssertNil(older.reason)
    }

    func testTheBotLearnsWhyItsCallWentUnansweredAndWhatToDoInstead() {
        let conversation = UUID()
        let missed = AgentCallDocumentation.unansweredNote(.missed, personName: "Petko", reason: "The build is broken", conversationID: conversation)
        XCTAssertTrue(missed.contains("Petko did not answer your call about: The build is broken"))
        XCTAssertTrue(missed.contains(conversation.uuidString.lowercased()))
        XCTAssertTrue(missed.contains("do not call again"))
        XCTAssertTrue(AgentCallDocumentation.unansweredNote(.declined, personName: "Petko", reason: "x", conversationID: conversation)
            .contains("Petko declined your call"))

        let answered = VoiceCallDocumentation.startInstructions(conversationID: conversation, personName: "Petko",
                                                                answeredCallReason: "The build is broken")
        XCTAssertTrue(answered.contains("Petko answered the voice call you placed"))
        XCTAssertTrue(answered.contains("You called about: The build is broken"))
        XCTAssertTrue(VoiceCallDocumentation.startInstructions(conversationID: conversation, personName: "Petko")
            .contains("Petko started a voice call with you"))
        XCTAssertTrue(MessengerDocumentation.skillInstructions.contains("messenger --call --reason <text>"))
    }

    /// What rings is one line as the bot wrote it: no line breaks, bidirectional overrides or zero-width
    /// characters to make it read differently, and no longer than the limit in Unicode scalars.
    func testTheReasonRingsAsOneLineWithoutHiddenCharacters() throws {
        let bot = try repository.createAgent(named: "Theo", harnessIdentifier: HarnessProvider.codex.rawValue).agent
        let request = try repository.requestCall(agentID: bot.id, reason: "The \u{202E}build\u{202C} is\u{200B} broken\r\nnow\u{2028}please",
                                                 now: date)
        XCTAssertEqual(request.reason, "The build is broken now please")
        XCTAssertTrue(refusal { try repository.requestCall(agentID: bot.id, reason: "\u{200B}\u{2066}\n", now: date.addingTimeInterval(3_600)) }
            .contains("--reason"))
        // 150 characters, each a letter and a combining accent: 300 scalars.
        let accented = String(repeating: "e\u{301}", count: 150)
        XCTAssertEqual(accented.count, 150)
        XCTAssertTrue(refusal { try repository.requestCall(agentID: bot.id, reason: accented, now: date.addingTimeInterval(3_600)) }
            .contains("--reason"))
    }
}
