#if canImport(FoundationModels, _version: 2)
import XCTest
import FoundationModels
import NoodleCore
@testable import NoodleAppleRuntime

/// The Apple harness gets what Codex and Claude get: AGENTS.md, the skill list
/// and the wake event. Messenger work is the model's, through its tools.
final class AppleHarnessParityTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private var bot: CreatedAgentWorkspace!
    private var workspace: URL!
    private var broker: MessengerBroker!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-parity-\(UUID())").resolvingSymlinksInPath()
        repository = WorkspaceRepository(rootURL: root)
        bot = try repository.createAgent(named: "Parity test", harnessIdentifier: "apple")
        workspace = repository.directory(for: bot.agent)
        broker = MessengerBroker(repository: repository)
        try broker.start(agents: [bot.agent])
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".noodle/tmp"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { broker.stop(); try? FileManager.default.removeItem(at: root) }

    func testTurnGetsOnlyAgentsFileSkillsAndWakeEvent() async throws {
        guard #available(macOS 27, *) else { return }
        let message = try repository.sendUserMessage(conversationID: bot.conversation.id, body: "Remember saffron")
        let state = ScriptState(answers: [Self.peek, "Done."])
        let wake = AgentWakeReason.inboxChanged.eventText
        try await AppleModel.run(workspace: workspace, backend: backend(state), wake: wake, onEvent: { _ in }, onActivity: {})

        let requests = await state.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(Self.instructions(request), try AppleWorkspaceInstructions.text(workspace: workspace))
        XCTAssertEqual(Self.prompts(request), [wake])
        XCTAssertEqual(Set(request.enabledToolDefinitions.map(\.name)), ["bash", "read", "write", "edit"])
        XCTAssertEqual(try repository.latestMessages(for: bot.agent.id, consuming: false).map(\.message.id), [message.id],
                       "The model reads its inbox itself")
        XCTAssertFalse(try repository.loadMessages(conversationID: bot.conversation.id).contains { $0.author == .agent(bot.agent.id) },
                       "Only the model replies, through Messenger")
    }

    func testEveryWakeResumesOneSession() async throws {
        guard #available(macOS 27, *) else { return }
        let state = ScriptState(answers: [Self.peek, "First wake handled.", Self.peek, "Second wake handled."])
        for reason in [AgentWakeReason.inboxChanged, .heartbeat] {
            try await AppleModel.run(workspace: workspace, backend: backend(state), wake: reason.eventText, onEvent: { _ in }, onActivity: {})
        }
        let requests = await state.requests
        XCTAssertEqual(requests.count, 4, "Each wake reaches the model")
        let second = try XCTUnwrap(requests.last).transcript.map(\.description).joined(separator: "\n")
        XCTAssertTrue(second.contains("First wake handled."))
        XCTAssertTrue(second.contains(AgentWakeReason.heartbeat.eventText))
    }

    func testWakeThatNeverChecksMessagesFailsVisibly() async throws {
        guard #available(macOS 27, *) else { return }
        let state = ScriptState(answers: ["Done.", "Still done."])
        do {
            try await AppleModel.run(workspace: workspace, backend: backend(state), wake: AgentWakeReason.inboxChanged.eventText,
                                     onEvent: { _ in }, onActivity: {})
            XCTFail("A wake that never checked its messages must not end as Ready")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not check its messages"), error.localizedDescription)
        }
        let requests = await state.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testLargeContextKeepsShortHistoryWithoutSummarizing() async throws {
        guard #available(macOS 27, *) else { return }
        let state = ScriptState(answers: ["ok"])
        let history: [Transcript.Entry] = (0..<6).flatMap { index -> [Transcript.Entry] in
            [.prompt(.init(segments: [.text(.init(content: "Request \(index)"))])),
             .response(.init(assetIDs: [], segments: [.text(.init(content: "Answer \(index)"))]))]
        }
        let session = backend(state).session(instructions: "Instructions.", entries: history)
        _ = try await session.respond(to: "Next request")
        let requests = await state.requests
        XCTAssertEqual(requests.count, 1, "Twelve entries fit easily in 32K tokens; summarizing them only costs time")
    }

    @available(macOS 27, *)
    private func backend(_ state: ScriptState) -> AppleModelBackend {
        .custom(ScriptModel(state: state), contextSize: 32_768) { _ in 100 }
    }

    /// Every Noodle event asks the model to check Messenger; peeking leaves the inbox unread.
    static let peek = "$ ./.agents/skills/messenger/messenger --get-latest --peek"

    @available(macOS 27, *)
    static func instructions(_ request: LanguageModelExecutorGenerationRequest) -> String? {
        for entry in request.transcript {
            if case .instructions(let instructions) = entry {
                return instructions.segments.compactMap { if case .text(let text) = $0 { return text.content }; return nil }.joined()
            }
        }
        return nil
    }

    @available(macOS 27, *)
    static func prompts(_ request: LanguageModelExecutorGenerationRequest) -> [String] {
        request.transcript.compactMap { entry in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.segments.compactMap { if case .text(let text) = $0 { return text.content }; return nil }.joined()
        }
    }
}

@available(macOS 27, *)
private actor ScriptState {
    var answers: [String]
    var requests: [LanguageModelExecutorGenerationRequest] = []
    init(answers: [String]) { self.answers = answers }
    func next(_ request: LanguageModelExecutorGenerationRequest) throws -> String {
        requests.append(request)
        guard !answers.isEmpty else { throw HarnessSetupError("Unexpected extra model generation") }
        return answers.removeFirst()
    }
}

@available(macOS 27, *)
private struct ScriptModel: LanguageModel {
    let state: ScriptState
    let executorConfiguration = UUID()
    var capabilities: LanguageModelCapabilities { .init([.toolCalling]) }
    struct Executor: LanguageModelExecutor {
        init(configuration: UUID) {}
        func respond(to request: LanguageModelExecutorGenerationRequest, model: ScriptModel,
                     streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            let answer = try await model.state.next(request)
            if answer.hasPrefix("$ ") {
                let arguments = try JSONSerialization.data(withJSONObject: ["command": String(answer.dropFirst(2))])
                await channel.send(.toolCalls(action: .toolCall(id: UUID().uuidString, name: "bash",
                    action: .appendArguments(String(decoding: arguments, as: UTF8.self), tokenCount: 5))))
            } else {
                await channel.send(.response(action: .appendText(answer, tokenCount: 4)))
            }
        }
    }
}
#endif
