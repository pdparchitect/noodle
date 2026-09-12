import XCTest
import NoodleCore
@testable import NoodleAppleRuntime

final class AppleToolsTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private var workspace: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-tools-\(UUID())").resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root)
        let bot = try repository.createAgent(named: "Apple test")
        workspace = repository.directory(for: bot.agent)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".noodle/tmp"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testChatMemoryDoesNotEnableFilesFromAssistantClaims() {
        let history: [AppleConversationTurn.Message] = [
            .init(isAssistant: false, text: "Remember the secret word avocado"),
            .init(isAssistant: true, text: "Saved to secret_word.txt in the workspace.")
        ]
        for prompt in ["Hello", "What is the secret word?", "Change the word to marigold"] {
            let turn = AppleConversationTurn(conversationID: UUID(), messageIDs: [], history: history, prompt: prompt)
            XCTAssertFalse(turn.hasWorkspaceReference)
        }
        for prompt in ["Read notes.md", "List the files here", "Run pwd", "Use execute_command to run ls"] {
            let turn = AppleConversationTurn(conversationID: UUID(), messageIDs: [], history: [], prompt: prompt)
            XCTAssertTrue(turn.hasWorkspaceReference)
        }
        let followup = AppleConversationTurn(conversationID: UUID(), messageIDs: [],
            history: [.init(isAssistant: false, text: "Create notes.md")], prompt: "Change its title to Hello")
        XCTAssertTrue(followup.hasWorkspaceReference)
    }

    func testChatPromptProvidesBoundedUserSourcesWithoutRepeatingAssistantMistakes() {
        let turn = AppleConversationTurn(conversationID: UUID(), messageIDs: [], history: [
            .init(isAssistant: false, text: String(repeating: "old", count: 1_000)),
            .init(isAssistant: true, text: "The answer is password."),
            .init(isAssistant: false, text: "Remember marigold"),
            .init(isAssistant: true, text: "Hello!"),
            .init(isAssistant: false, text: "Hello")
        ], prompt: "What did I ask you to remember?")
        XCTAssertTrue(turn.chatPrompt.contains("Remember marigold"))
        XCTAssertFalse(turn.chatPrompt.contains("password"))
        XCTAssertFalse(turn.chatPrompt.contains("oldold"))
        XCTAssertTrue(turn.chatPrompt.hasSuffix(turn.prompt))
        XCTAssertLessThan(turn.chatPrompt.utf8.count, 2_250)
    }

    func testReadWriteAndPaginationPreserveFullOutput() async throws {
        let tools = try AppleToolContext(workspace: workspace)
        let content = String(repeating: "abcdef", count: 1_000)
        _ = try await tools.write(path: "sample.txt", content: content)
        let first = try await tools.read(path: "sample.txt")
        let next = try await tools.read(path: "sample.txt", offset: 3_072)
        XCTAssertTrue(first.contains("offset 3072"))
        XCTAssertTrue(next.contains("; end"))
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("sample.txt"), encoding: .utf8), content)
    }

    func testCommandReturnsExitCodeAndUsesWorkspace() async throws {
        let result = try await AppleCommand.run("pwd; printf expected; exit 7", workspace: workspace)
        XCTAssertEqual(result.status, 7)
        XCTAssertTrue(result.output.contains(workspace.path))
        XCTAssertTrue(result.output.hasSuffix("expected"))
    }

    func testReadPagesDoNotSplitUTF8Characters() async throws {
        let tools = try AppleToolContext(workspace: workspace)
        _ = try await tools.write(path: "unicode.txt", content: String(repeating: "a", count: 3_071) + "🍎done")
        let first = try await tools.read(path: "unicode.txt")
        XCTAssertTrue(first.contains("offset 3071"))
        let next = try await tools.read(path: "unicode.txt", offset: 3_071)
        XCTAssertTrue(next.hasPrefix("🍎done"))
    }

    func testCommandTimeoutKillsItsDescendants() async throws {
        do {
            _ = try await AppleCommand.run("(sleep 1; touch late.txt) & wait", workspace: workspace, timeout: 0.1)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("time limit")) }
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("late.txt").path))
    }

    func testCancellationStopsCommand() async throws {
        let task = Task { try await AppleCommand.run("sleep 30", workspace: workspace) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }

    func testMessengerCannotSendAsAnotherBotAndReusesInbox() async throws {
        let original = try repository.loadAgents()[0]
        let conversation = try repository.loadConversations()[0]
        let other = try repository.createAgent(named: "Other")
        let tools = try AppleToolContext(workspace: workspace)
        let first = try await tools.inbox()
        let second = try await tools.inbox()
        XCTAssertEqual(first, second)
        _ = try await tools.send(conversation: conversation.id.uuidString, body: "--get-latest is literal text")
        let sent = try XCTUnwrap(repository.loadMessages(conversationID: conversation.id).last)
        XCTAssertEqual(sent.author, .agent(original.id))
        XCTAssertEqual(sent.body, "--get-latest is literal text")
        do {
            _ = try await tools.send(conversation: other.conversation.id.uuidString, body: "unauthorized")
            XCTFail("Expected membership check")
        } catch {}
    }

    func testConversationRestoresRolesAndRecoversPendingReplyAfterRestart() async throws {
        let agent = try repository.loadAgents()[0]
        let chat = try repository.loadConversations()[0]
        _ = try repository.sendUserMessage(conversationID: chat.id, body: "Remember the secret word avocado")
        let initial = try AppleToolContext(workspace: workspace)
        let firstTurns = try await initial.conversationTurns()
        let first = try XCTUnwrap(firstTurns.first)
        try await initial.deliverReply("I’ll remember avocado.", to: first)

        _ = try repository.sendUserMessage(conversationID: chat.id, body: "What is the secret word?")
        let interrupted = try AppleToolContext(workspace: workspace)
        _ = try await interrupted.conversationTurns()
        let restarted = try AppleToolContext(workspace: workspace)
        let recovered = try await restarted.conversationTurns()
        let turn = try XCTUnwrap(recovered.first)
        XCTAssertEqual(turn.prompt, "What is the secret word?")
        XCTAssertEqual(turn.history.map(\.text), ["Remember the secret word avocado", "I’ll remember avocado."])
        XCTAssertEqual(turn.history.map(\.isAssistant), [false, true])
        let history = try await restarted.conversationHistory(conversation: chat.id.uuidString)
        XCTAssertTrue(history.contains("User: Remember the secret word avocado"))
        XCTAssertTrue(history.contains("Assistant: I’ll remember avocado."))
        XCTAssertLessThan(history.utf8.count, 300)
        let userHistory = try await restarted.conversationHistory(conversation: chat.id.uuidString, includeAssistantReplies: false)
        XCTAssertTrue(userHistory.contains("Remember the secret word avocado"))
        XCTAssertFalse(userHistory.contains("I’ll remember avocado."))
        try await restarted.deliverReply("Avocado.", to: turn)
        XCTAssertEqual(try repository.loadMessages(conversationID: chat.id).last?.author, .agent(agent.id))
        let finished = try AppleToolContext(workspace: workspace)
        let pending = try await finished.conversationTurns()
        XCTAssertTrue(pending.isEmpty)
    }

    func testDurableReplyPreventsDuplicateAfterInterruptedCleanup() async throws {
        let agent = try repository.loadAgents()[0]
        let chat = try repository.loadConversations()[0]
        _ = try repository.sendUserMessage(conversationID: chat.id, body: "Hello")
        let interrupted = try AppleToolContext(workspace: workspace)
        let turnsBeforeSend = try await interrupted.conversationTurns()
        try await interrupted.prepareReply("Hello!", to: XCTUnwrap(turnsBeforeSend.first))
        // Simulate a successful send followed by a crash before pending cleanup.
        _ = try repository.sendAgentMessage(agentID: agent.id, conversationID: chat.id, body: "Hello!")
        let restarted = try AppleToolContext(workspace: workspace)
        let turns = try await restarted.conversationTurns()
        XCTAssertTrue(turns.isEmpty)
    }

    func testConversationRoutingKeepsChatsSeparateAndPreservesNewArrivals() async throws {
        let agent = try repository.loadAgents()[0]
        let direct = try repository.loadConversations()[0]
        let group = try repository.createGroup(named: "Group", participantIDs: [agent.id], existingAgents: [agent])
        _ = try repository.sendUserMessage(conversationID: direct.id, body: "Private word avocado")
        _ = try repository.sendUserMessage(conversationID: group.id, body: "Group word pear")
        let tools = try AppleToolContext(workspace: workspace)
        let turns = try await tools.conversationTurns()
        let privateTurn = try XCTUnwrap(turns.first { $0.conversationID == direct.id })
        let groupTurn = try XCTUnwrap(turns.first { $0.conversationID == group.id })
        XCTAssertFalse(groupTurn.prompt.contains("avocado"))
        XCTAssertFalse(privateTurn.prompt.contains("pear"))
        _ = try repository.sendUserMessage(conversationID: direct.id, body: "A later request")
        try await tools.deliverReply("Private answer", to: privateTurn)
        try await tools.deliverReply("Group answer", to: groupTurn)
        XCTAssertEqual(try repository.loadMessages(conversationID: group.id).last?.body, "Group answer")
        let next = try AppleToolContext(workspace: workspace)
        let pending = try await next.conversationTurns()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.prompt, "A later request")
        // If this new request is interrupted, the earlier turn's late answer
        // must still not count as a reply to it during recovery.
        let restarted = try AppleToolContext(workspace: workspace)
        let recovered = try await restarted.conversationTurns()
        XCTAssertEqual(recovered.first?.prompt, "A later request")
    }

    func testLongHistoryKeepsRecentContextAndOlderMessagesRemainReadable() async throws {
        let agent = try repository.loadAgents()[0]
        let chat = try repository.loadConversations()[0]
        for index in 0..<20 {
            _ = try repository.sendUserMessage(conversationID: chat.id, body: "Fact \(index): " + String(repeating: "a", count: 200))
            _ = try repository.sendAgentMessage(agentID: agent.id, conversationID: chat.id, body: "Acknowledged \(index).")
        }
        _ = try repository.latestMessages(for: agent.id, consuming: true)
        _ = try repository.sendUserMessage(conversationID: chat.id, body: "What was fact 19?")
        let tools = try AppleToolContext(workspace: workspace)
        let turns = try await tools.conversationTurns()
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.prompt, "What was fact 19?")
        XCTAssertTrue(turn.history.contains { $0.text.hasPrefix("Fact 19:") })
        XCTAssertFalse(turn.history.contains { $0.text.hasPrefix("Fact 0:") })
        let fullHistory = try await tools.history(conversation: chat.id.uuidString)
        XCTAssertTrue(fullHistory.contains("Fact 0:"))
    }
}
