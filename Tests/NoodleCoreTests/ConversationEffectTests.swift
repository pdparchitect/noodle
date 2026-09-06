import XCTest
@testable import NoodleCore

final class ConversationEffectTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-effects-tests-\(UUID())")
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: root.appendingPathComponent("launcher"))
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testCLIListsEffectsAndReturnsAnEncodedReceipt() throws {
        let bot = try repository.createAgent(named: "Builder")
        let command = repository.directory(for: bot.agent).appendingPathComponent(".agents/skills/messenger/messenger").path
        let list = MessengerCLI.run(arguments: [command, "--list-effects"], environment: [:])
        XCTAssertEqual(list.exitCode, 0, list.standardError)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(list.standardOutput.utf8)), ["confetti"])
        let id = UUID()
        let arguments = [command, "--effect", "confetti", "--conversation", bot.conversation.id.uuidString,
                         "--request-id", id.uuidString]
        let result = MessengerCLI.run(arguments: arguments, environment: [:])
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any])
        XCTAssertEqual(receipt["status"] as? String, "queued")
        XCTAssertEqual((receipt["effect"] as? [String: Any])?["id"] as? String, id.uuidString)
        XCTAssertEqual(try repository.takePendingEffect(conversationID: bot.conversation.id)?.id, id)
        let retry = MessengerCLI.run(arguments: arguments, environment: [:])
        XCTAssertEqual(retry.exitCode, 0, retry.standardError)
        XCTAssertTrue(retry.standardOutput.contains("consumed"))
        XCTAssertNil(try repository.takePendingEffect(conversationID: bot.conversation.id))
    }

    func testCLIRejectsMalformedAndMixedCommands() throws {
        let bot = try repository.createAgent(named: "Builder")
        let prefix = ["messenger", "--agent-directory", repository.directory(for: bot.agent).path]
        let base = ["--effect", "confetti", "--conversation", bot.conversation.id.uuidString]
        for options in [
            ["--effect"], ["--effect", "confetti"], ["--effect", "confetti", "--conversation", "bad"],
            base + ["--request-id", "bad"], base + ["--send"], base + ["--attach", "file.png"],
            base + ["--effect", "confetti"], base + ["--conversation", UUID().uuidString],
            base + ["--react"], ["--list-effects", "--send"],
            ["--effect", "unknown", "--conversation", bot.conversation.id.uuidString]
        ] {
            XCTAssertNotEqual(MessengerCLI.run(arguments: prefix + options, environment: [:]).exitCode, 0, options.joined(separator: " "))
        }
        XCTAssertTrue(try repository.loadMessages(conversationID: bot.conversation.id).isEmpty)
        XCTAssertNil(try repository.takePendingEffect(conversationID: bot.conversation.id))
    }

    func testAuthorizationAndUnknownKind() throws {
        let bot = try repository.createAgent(named: "Builder")
        let other = try repository.createAgent(named: "Other")
        XCTAssertThrowsError(try repository.sendEffect(agentID: other.agent.id, conversationID: bot.conversation.id, kind: "confetti")) {
            XCTAssertEqual($0 as? ConversationEffectError, .notParticipant)
        }
        XCTAssertThrowsError(try repository.sendEffect(agentID: bot.agent.id, conversationID: UUID(), kind: "confetti"))
        XCTAssertThrowsError(try repository.sendEffect(agentID: UUID(), conversationID: bot.conversation.id, kind: "confetti"))
        XCTAssertThrowsError(try repository.sendEffect(agentID: bot.agent.id, conversationID: bot.conversation.id, kind: "shell")) {
            XCTAssertEqual($0 as? ConversationEffectError, .unsupportedKind)
        }
    }

    func testGroupEffectsDoNotTouchMessagesUnreadOrInbox() throws {
        let first = try repository.createAgent(named: "First")
        let second = try repository.createAgent(named: "Second")
        let group = try repository.createGroup(named: "Team", participantIDs: [first.agent.id, second.agent.id],
                                              existingAgents: [first.agent, second.agent])
        let before = try repository.loadConversations()
        let unread = try repository.loadUnreadConversationIDs()
        _ = try repository.sendEffect(agentID: first.agent.id, conversationID: group.id, kind: "confetti", now: instant)
        let last = try repository.sendEffect(agentID: second.agent.id, conversationID: group.id, kind: "confetti", now: instant.addingTimeInterval(2))
        XCTAssertEqual(try repository.takePendingEffect(conversationID: group.id, now: instant.addingTimeInterval(3))?.id, last.id)
        XCTAssertEqual(try repository.loadConversations(), before)
        XCTAssertEqual(try repository.loadUnreadConversationIDs(), unread)
        XCTAssertTrue(try repository.loadMessages(conversationID: group.id).isEmpty)
        XCTAssertTrue(try repository.latestMessages(for: first.agent.id).isEmpty)
        XCTAssertTrue(try repository.latestMessages(for: second.agent.id).isEmpty)
    }

    func testClaimPersistsAcrossRepositoryInstancesAndRetryDoesNotReplay() throws {
        let bot = try repository.createAgent(named: "Builder")
        let event = try repository.sendEffect(agentID: bot.agent.id, conversationID: bot.conversation.id, kind: "confetti", now: instant)
        XCTAssertEqual(try repository.takePendingEffect(conversationID: bot.conversation.id, now: instant)?.id, event.id)
        let reopened = WorkspaceRepository(rootURL: root)
        XCTAssertNil(try reopened.takePendingEffect(conversationID: bot.conversation.id, now: instant))
        let retried = try reopened.sendEffect(agentID: bot.agent.id, conversationID: bot.conversation.id, kind: "confetti", requestID: event.id, now: instant)
        XCTAssertNotNil(retried.consumedAt)
        XCTAssertNil(try reopened.takePendingEffect(conversationID: bot.conversation.id, now: instant))
    }

    func testExpiryAndPerConversationThrottling() throws {
        let bot = try repository.createAgent(named: "Builder")
        let other = try repository.createAgent(named: "Other")
        _ = try repository.sendEffect(agentID: bot.agent.id, conversationID: bot.conversation.id, kind: "confetti", now: instant)
        XCTAssertThrowsError(try repository.sendEffect(agentID: bot.agent.id, conversationID: bot.conversation.id, kind: "confetti", now: instant.addingTimeInterval(1))) {
            XCTAssertEqual($0 as? ConversationEffectError, .rateLimited)
        }
        XCTAssertNoThrow(try repository.sendEffect(agentID: other.agent.id, conversationID: other.conversation.id, kind: "confetti", now: instant))
        XCTAssertNil(try repository.takePendingEffect(conversationID: bot.conversation.id, now: instant.addingTimeInterval(30)))
        let fresh = try repository.sendEffect(agentID: bot.agent.id, conversationID: bot.conversation.id, kind: "confetti", now: instant.addingTimeInterval(31))
        XCTAssertEqual(try repository.takePendingEffect(conversationID: bot.conversation.id, now: instant.addingTimeInterval(60))?.id, fresh.id)
    }

    func testQueueIsBoundedAndOnlyNewestPendingEffectIsClaimed() throws {
        let bot = try repository.createAgent(named: "Builder")
        var latest: ConversationEffect?
        for index in 0..<40 {
            latest = try repository.sendEffect(agentID: bot.agent.id, conversationID: bot.conversation.id, kind: "confetti", now: instant.addingTimeInterval(Double(index * 2)))
        }
        let file = repository.conversationDirectory(id: bot.conversation.id).appendingPathComponent("effects.json")
        let queue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual((queue["events"] as? [Any])?.count, 32)
        XCTAssertEqual(try repository.takePendingEffect(conversationID: bot.conversation.id, now: instant.addingTimeInterval(80))?.id, latest?.id)
        XCTAssertNil(try repository.takePendingEffect(conversationID: bot.conversation.id, now: instant.addingTimeInterval(80)))
    }

    func testFutureEffectKindsAreSkippedAndCorruptQueuesPreserved() throws {
        let bot = try repository.createAgent(named: "Builder")
        _ = try repository.sendEffect(agentID: bot.agent.id, conversationID: bot.conversation.id, kind: "confetti", now: instant)
        let file = repository.conversationDirectory(id: bot.conversation.id).appendingPathComponent("effects.json")
        let json = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "confetti", with: "future-kind")
        try Data(json.utf8).write(to: file)
        XCTAssertNil(try repository.takePendingEffect(conversationID: bot.conversation.id, now: instant))
        let invalid = Data("{broken".utf8)
        try invalid.write(to: file)
        XCTAssertThrowsError(try repository.takePendingEffect(conversationID: bot.conversation.id, now: instant))
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    func testConflictingRetryCannotBeReusedByAnotherParticipant() throws {
        let a = try repository.createAgent(named: "A")
        let b = try repository.createAgent(named: "B")
        let group = try repository.createGroup(named: "Team", participantIDs: [a.agent.id, b.agent.id], existingAgents: [a.agent, b.agent])
        let event = try repository.sendEffect(agentID: a.agent.id, conversationID: group.id, kind: "confetti", now: instant)
        XCTAssertThrowsError(try repository.sendEffect(agentID: b.agent.id, conversationID: group.id, kind: "confetti", requestID: event.id, now: instant)) {
            XCTAssertEqual($0 as? ConversationEffectError, .requestConflict)
        }
    }

    func testGeneratedAgentInstructionsAdvertiseEffects() throws {
        let bot = try repository.createAgent(named: "Builder")
        for path in ["AGENTS.md", ".agents/skills/messenger/SKILL.md"] {
            let text = try String(contentsOf: repository.directory(for: bot.agent).appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(text.contains("--effect confetti"))
            XCTAssertTrue(text.contains("--list-effects"))
            XCTAssertTrue(text.contains("not that the user saw it"))
        }
    }

    func testConcurrentConsumersClaimExactlyOnce() throws {
        let bot = try repository.createAgent(named: "Builder")
        let event = try repository.sendEffect(agentID: bot.agent.id, conversationID: bot.conversation.id, kind: "confetti", now: instant)
        let results = LockedClaims()
        let root = root!
        let now = instant
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                let claim = try WorkspaceRepository(rootURL: root).takePendingEffect(conversationID: bot.conversation.id, now: now)
                results.record(claim: claim?.id, failed: false)
            } catch { results.record(claim: nil, failed: true) }
        }
        XCTAssertEqual(results.ids, [event.id])
        XCTAssertEqual(results.failures, 0)
    }
}

private final class LockedClaims: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var ids: [UUID] = []
    private(set) var failures = 0
    func record(claim: UUID?, failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let claim { ids.append(claim) }
        if failed { failures += 1 }
    }
}
