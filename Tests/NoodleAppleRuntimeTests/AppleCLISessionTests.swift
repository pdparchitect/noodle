#if canImport(FoundationModels, _version: 2)
import XCTest
import FoundationModels
import NoodleCore
@testable import NoodleAppleRuntime

final class AppleCLISessionTests: XCTestCase {
    func testThreeToolsRemainAvailableAcrossResumedConversationAndImageTurns() async throws {
        guard #available(macOS 27, *) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-cli-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let bot = try repository.createAgent(named: "CLI test")
        let workspace = repository.directory(for: bot.agent)
        let image = workspace.appendingPathComponent("square.png")
        try Apple27LiveTests.writeSquare(to: image)
        let context = try AppleToolContext(workspace: workspace)
        let state = CLIState()
        let activity = ActivityEvents()
        let prompts = ["Create a sample.", "Show me that.", "Save a copy beside it."]
        var history: [Transcript.Entry] = []
        for (index, prompt) in prompts.enumerated() {
            let session = AppleTurnProfile.session(model: CLIModel(state: state),
                tools: AppleModel.workspaceTools(context: context, onEvent: { await activity.append($0) }, onActivity: {}),
                instructions: MessengerDocumentation.appleConversationInstructions, history: history)
            _ = try await session.respond(to: Prompt {
                prompt
                if index == 2 { Attachment(imageURL: image).label("square.png") }
            })
            let saved = AppleConversationSession(transcript: AppleConversationSession.persistable(session.transcript),
                messageIDs: [UUID()], reply: "done")
            try saved.save(in: workspace, conversationID: bot.conversation.id)
            let restored = try JSONDecoder().decode(AppleConversationSession.self,
                from: Data(contentsOf: AppleConversationSession.file(in: workspace, conversationID: bot.conversation.id)))
            history = restored.transcript.filter { if case .instructions = $0 { return false }; return true }
        }
        let requests = await state.requests
        XCTAssertEqual(requests.count, 6, "One tool call and one answer per turn; no classifier")
        for request in requests {
            XCTAssertEqual(Set(request.enabledToolDefinitions.map(\.name)), ["bash", "read", "write"])
            XCTAssertEqual(request.generationOptions.toolCallingMode, .allowed)
        }
        XCTAssertTrue(requests[2].transcript.map(\.description).joined().contains(prompts[0]))
        XCTAssertTrue(requests[4].transcript.map(\.description).joined().contains(prompts[1]))
        XCTAssertTrue(requests[3].transcript.map(\.description).joined().contains("saffron"))
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("copy.txt"), encoding: .utf8), "saffron")
        let events = await activity.values
        XCTAssertEqual(events.count, 6, "Emit exactly one start and finish for each executed tool, without replaying history")
        for (index, name) in ["Bash", "Read file", "Write file"].enumerated() {
            guard case .toolStarted(let id, let actual, _) = events[index * 2],
                  case .toolFinished(let endID, _, let input, let result, let failed, _) = events[index * 2 + 1] else {
                return XCTFail("Missing tool activity pair")
            }
            XCTAssertEqual(actual, name)
            XCTAssertEqual(id, endID)
            XCTAssertFalse(failed)
            XCTAssertFalse(result.isEmpty)
            if name == "Write file" { XCTAssertEqual(input["bytes"], "7"); XCTAssertNil(input["content"]) }
        }
    }
}

@available(macOS 27, *)
private actor CLIState {
    var requests: [LanguageModelExecutorGenerationRequest] = []
    func record(_ request: LanguageModelExecutorGenerationRequest) -> Int {
        requests.append(request)
        return requests.count - 1
    }
}

@available(macOS 27, *)
private struct CLIModel: LanguageModel {
    let state: CLIState
    let executorConfiguration = UUID()
    var capabilities: LanguageModelCapabilities { .init([.toolCalling, .vision]) }
    struct Executor: LanguageModelExecutor {
        init(configuration: UUID) {}
        func respond(to request: LanguageModelExecutorGenerationRequest, model: CLIModel,
                     streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            if request.transcript.map(\.description).joined().contains("Summarize this conversation:") {
                await channel.send(.response(action: .appendText("Create a sample. Show me that. sample.txt contains saffron.", tokenCount: 20)))
                return
            }
            let index = await model.state.record(request)
            if index % 2 == 1 {
                await channel.send(.response(action: .appendText("done", tokenCount: 1)))
                return
            }
            let calls = [
                ("bash", #"{"command":"printf saffron > sample.txt"}"#),
                ("read", #"{"path":"sample.txt","offset":0}"#),
                ("write", #"{"path":"copy.txt","content":"saffron"}"#)
            ]
            guard index / 2 < calls.count else { throw AppleContextLimit() }
            let call = calls[index / 2]
            await channel.send(.toolCalls(action: .toolCall(id: UUID().uuidString, name: call.0,
                action: .appendArguments(call.1, tokenCount: 10))))
        }
    }
}
#endif
