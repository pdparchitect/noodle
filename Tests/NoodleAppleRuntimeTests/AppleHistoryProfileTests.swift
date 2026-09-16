#if canImport(FoundationModels, _version: 2)
import XCTest
import FoundationModels
@testable import NoodleAppleRuntime

final class AppleHistoryProfileTests: XCTestCase {
    func testEmptyOrTruncatedSummaryCannotEraseSavedWork() async throws {
        guard #available(macOS 27, *) else { return }
        for (text, incomplete) in [("", false), (" \n", false), ("unfinished summary", true)] {
            let state = HistoryFixtureState(summaryText: text, incompleteSummary: incomplete)
            let saved = history(firstPrompt: "Keep the original task and its constraints.")
            let session = AppleTurnProfile.session(model: model(state), instructions: "Continue the work.", history: saved)
            _ = try await session.respond(to: "Continue the current task.")
            let lastRequest = await state.lastRequest()
            let request = try XCTUnwrap(lastRequest)
            XCTAssertTrue(request.transcript.map(\.description).joined().contains("Keep the original task and its constraints."))
            XCTAssertTrue(session.transcript.contains(saved[0]))
            XCTAssertFalse(session.transcript.map(\.description).joined().contains("Summary of the conversation so far:"))
        }
    }

    func testFailureAfterToolCallPreservesCompletedWorkForRecovery() async throws {
        guard #available(macOS 27, *) else { return }
        let state = HistoryFixtureState(failAfterOperation: true)
        let session = AppleTurnProfile.session(model: model(state), tools: [HistoryFixtureTool(state: state)],
            instructions: "Perform the requested operation once.", requireTool: true)
        do {
            _ = try await session.respond(to: "Do the operation.")
            XCTFail("Expected the continuation to fail")
        } catch is AppleContextLimit {}
        let calls = await state.calls
        XCTAssertEqual(calls, 1)
        let receipt = AppleConversationSession(transcript: session.transcript, messageIDs: [], reply: "")
        let restored = try JSONDecoder().decode(AppleConversationSession.self, from: JSONEncoder().encode(receipt))
        XCTAssertTrue(restored.transcript.contains { if case .toolCalls = $0 { return true }; return false })
        XCTAssertTrue(restored.transcript.contains { if case .toolOutput(let output) = $0 {
            return output.description.contains("Completed operation with saffron")
        }; return false }, "A later failure must not erase the completed command's result")
        let resumedState = HistoryFixtureState()
        let resumed = AppleTurnProfile.session(model: model(resumedState), tools: [HistoryFixtureTool(state: resumedState)],
            instructions: "Report the completed operation; do not repeat it.",
            history: restored.transcript.filter { if case .instructions = $0 { return false }; return true })
        _ = try await resumed.respond(to: "Continue from the saved result.")
        let resumedRequest = await resumedState.lastRequest()
        XCTAssertTrue(resumedRequest?.transcript.contains { if case .toolOutput = $0 { return true }; return false } == true)
        let repeatedCalls = await resumedState.calls
        XCTAssertEqual(repeatedCalls, 0)
    }

    func testSummarySurvivesSavingAndKeepsCurrentRequestAndFreshInstructions() async throws {
        guard #available(macOS 27, *) else { return }
        let state = HistoryFixtureState()
        let session = AppleTurnProfile.session(model: model(state), instructions: "Current bot instructions.",
                                               history: history())
        _ = try await session.respond(to: "Verify output.txt now.")
        let requests = await state.requests
        XCTAssertEqual(requests.count, 2, "One summary followed by the actual answer")
        let summary = try XCTUnwrap(requests.first)
        XCTAssertTrue(summary.transcript.map(\.description).joined(separator: "\n").contains("saffron"))
        XCTAssertFalse(summary.transcript.map(\.description).joined(separator: "\n").contains("Verify output.txt now."),
                       "The new request must not become material for a conversation summary")
        XCTAssertTrue(summary.enabledToolDefinitions.isEmpty, "Summarizing must not execute actions")
        XCTAssertEqual(summary.generationOptions.maximumResponseTokens, 256)
        let answer = try XCTUnwrap(requests.last)
        XCTAssertTrue(answer.transcript.map(\.description).joined(separator: "\n").contains("Current bot instructions."))
        XCTAssertTrue(answer.transcript.map(\.description).joined(separator: "\n").contains(HistoryFixtureState.summary))
        XCTAssertTrue(answer.transcript.map(\.description).joined(separator: "\n").contains("Verify output.txt now."))
        XCTAssertEqual(session.transcript.filter { if case .prompt = $0 { return true }; return false }.count, 1)

        let receipt = AppleConversationSession(transcript: session.transcript, messageIDs: [UUID()], reply: "done", modelIdentifier: "default")
        let restored = try JSONDecoder().decode(AppleConversationSession.self, from: JSONEncoder().encode(receipt))
        XCTAssertEqual(restored.messageIDs, receipt.messageIDs)
        XCTAssertEqual(restored.reply, receipt.reply)
        let next = AppleTurnProfile.session(model: model(state), instructions: "Updated bot instructions.",
            history: restored.transcript.filter { if case .instructions = $0 { return false }; return true })
        _ = try await next.respond(to: "Continue verifying.")
        let lastRequest = await state.lastRequest()
        let resumed = try XCTUnwrap(lastRequest)
        XCTAssertTrue(resumed.transcript.map(\.description).joined(separator: "\n").contains(HistoryFixtureState.summary))
        XCTAssertTrue(resumed.transcript.map(\.description).joined(separator: "\n").contains("Updated bot instructions."))
        XCTAssertFalse(resumed.transcript.map(\.description).joined(separator: "\n").contains("Current bot instructions."))
        let count = await state.requests.count
        XCTAssertEqual(count, 3, "A resumed short summary needs no second summarization")
    }

    func testCompletedToolsAreDroppedWhenResumingAndActionsAreNotReplayed() async throws {
        guard #available(macOS 27, *) else { return }
        let state = HistoryFixtureState()
        var history: [Transcript.Entry] = []
        for number in 1...3 {
            // The runtime creates a fresh profile from the saved receipt on
            // each wake, supplying current instructions and tool definitions.
            let session = AppleTurnProfile.session(model: model(state), tools: [HistoryFixtureTool(state: state)],
                instructions: "Perform each new request once.", requireTool: true, history: history)
            _ = try await session.respond(to: "Do operation \(number).")
            history = session.transcript.filter { if case .instructions = $0 { return false }; return true }
        }
        let requests = await state.requests
        let summaries = requests.filter { $0.transcript.map(\.description).joined().contains("Summarize this conversation:") }
        let turns = requests.filter { !$0.transcript.map(\.description).joined().contains("Summarize this conversation:") }
        XCTAssertEqual(summaries.count, 1, "Summarize at the new prompt, never mid-tool execution")
        guard turns.count == 6 else { return XCTFail("Expected six tool generations; got \(turns.count) and \(summaries.count) summaries") }
        let calls = await state.calls
        XCTAssertEqual(calls, 3, "Each requested action executes exactly once")
        for index in [0, 2, 4] {
            XCTAssertFalse(turns[index].transcript.contains { if case .toolCalls = $0 { return true }; return false })
            XCTAssertFalse(turns[index].transcript.contains { if case .toolOutput = $0 { return true }; return false })
            XCTAssertEqual(turns[index].generationOptions.toolCallingMode, .required)
            let continuation = turns[index + 1]
            XCTAssertEqual(continuation.generationOptions.toolCallingMode, .allowed)
            XCTAssertTrue(continuation.transcript.contains { if case .toolCalls = $0 { return true }; return false })
            XCTAssertTrue(continuation.transcript.contains { if case .toolOutput = $0 { return true }; return false })
        }
        XCTAssertTrue(summaries.first?.transcript.map(\.description).joined(separator: "\n").contains("Completed operation") == true,
                      "The summary sees the completed actions, even though generation input omits old calls")
    }

    func testOversizedSummaryFallsBackWithoutRepeatingActionsOrDroppingCurrentPrompt() async throws {
        guard #available(macOS 27, *) else { return }
        let state = HistoryFixtureState()
        let session = AppleTurnProfile.session(model: model(state), tools: [HistoryFixtureTool(state: state)],
            instructions: "Perform the new request once.", requireTool: true,
            history: history(firstPrompt: String(repeating: "Old context. ", count: 2_000)))
        let result = try await session.respond(to: "Do the current operation.")
        XCTAssertEqual(result.content, "done")
        let requests = await state.requests
        XCTAssertEqual(requests.count, 2, "The executor rejects the oversized summary before inference")
        let calls = await state.calls
        XCTAssertEqual(calls, 1)
        for request in requests {
            XCTAssertTrue(request.transcript.map(\.description).joined(separator: "\n").contains("Do the current operation."))
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(request.transcript).count
                                    + (request.generationOptions.maximumResponseTokens ?? 0) + 512, 4_096)
        }
        XCTAssertFalse(session.transcript.map(\.description).joined(separator: "\n").contains("Old context."), "An oversized old turn must not prevent future summaries forever")
        XCTAssertTrue(session.transcript.map(\.description).joined(separator: "\n").contains("Step 3."), "Keep recent complete turns on summary overflow")
    }

    func testMultipleToolResultsStayAvailableWithinTheCurrentTurn() async throws {
        guard #available(macOS 27, *) else { return }
        let state = HistoryFixtureState(requiredOperations: 2)
        let session = AppleTurnProfile.session(model: model(state), tools: [HistoryFixtureTool(state: state)],
            instructions: "Perform both operations and compare their results.", requireTool: true)
        _ = try await session.respond(to: "Compare two files.")
        let lastRequest = await state.lastRequest()
        let request = try XCTUnwrap(lastRequest)
        XCTAssertTrue(request.transcript.map(\.description).joined(separator: "\n").contains("Compare two files."))
        XCTAssertEqual(request.transcript.filter { if case .toolCalls = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(request.transcript.filter { if case .toolOutput = $0 { return true }; return false }.count, 2)
        let calls = await state.calls
        XCTAssertEqual(calls, 2)
    }

    func testSummarizationPropagatesCancellation() async throws {
        guard #available(macOS 27, *) else { return }
        let state = HistoryFixtureState(cancelSummary: true)
        let session = AppleTurnProfile.session(model: model(state), instructions: "Answer the request.", history: history())
        do {
            _ = try await session.respond(to: "Continue.")
            XCTFail("Cancellation must not turn into a new generation")
        } catch {
            let requests = await state.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertTrue(session.transcript.map(\.description).joined(separator: "\n").contains("saffron"))
        }
    }

    func testSummaryKeepsTheCurrentImageAttachment() async throws {
        guard #available(macOS 27, *) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("summary-image-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Apple27LiveTests.writeSquare(to: file)
        let state = HistoryFixtureState()
        let model = AppleContextModel(base: HistoryFixtureModel(state: state),
            budget: AppleContextBudget(contextSize: 4_096), count: { _ in 100 })
        let session = AppleTurnProfile.session(model: model, instructions: "Describe the image.", history: history())
        _ = try await session.respond(to: Prompt {
            "What color is the current image?"
            Attachment(imageURL: file).label("current.png")
        })
        let lastRequest = await state.lastRequest()
        let request = try XCTUnwrap(lastRequest)
        let prompt = try XCTUnwrap(request.transcript.last)
        guard case .prompt(let entry) = prompt else { return XCTFail("Missing current prompt") }
        XCTAssertTrue(entry.description.contains("What color is the current image?"))
        XCTAssertTrue(entry.segments.contains {
            if case .attachment(let attachment) = $0 { return attachment.label == "current.png" }
            return false
        })
        XCTAssertTrue(entry.description.contains(HistoryFixtureState.summary))
    }

    @available(macOS 27, *)
    private func model(_ state: HistoryFixtureState) -> AppleContextModel<HistoryFixtureModel> {
        AppleContextModel(base: HistoryFixtureModel(state: state),
            budget: AppleContextBudget(contextSize: 4_096, responseTokens: 512),
            count: { try JSONEncoder().encode($0.transcript).count })
    }

    @available(macOS 27, *)
    private func history(firstPrompt: String = "Remember saffron and output.txt.") -> [Transcript.Entry] {
        (0..<4).flatMap { index in
            [Transcript.Entry.prompt(.init(segments: [.text(.init(content: index == 0 ? firstPrompt : "Step \(index)."))])),
             .response(.init(segments: [.text(.init(content: "Completed step \(index)."))]))]
        }
    }
}

@available(macOS 27, *)
private actor HistoryFixtureState {
    static let summary = "The marker is saffron. Completed writing output.txt; verification is pending."
    let cancelSummary: Bool
    let requiredOperations: Int
    let failAfterOperation: Bool
    let summaryText: String
    let incompleteSummary: Bool
    var requests: [LanguageModelExecutorGenerationRequest] = []
    var calls = 0
    init(cancelSummary: Bool = false, requiredOperations: Int = 1, failAfterOperation: Bool = false,
         summaryText: String = HistoryFixtureState.summary, incompleteSummary: Bool = false) {
        self.cancelSummary = cancelSummary
        self.requiredOperations = requiredOperations
        self.failAfterOperation = failAfterOperation
        self.summaryText = summaryText
        self.incompleteSummary = incompleteSummary
    }
    func record(_ request: LanguageModelExecutorGenerationRequest) { requests.append(request) }
    func lastRequest() -> LanguageModelExecutorGenerationRequest? { requests.last }
    func operate() { calls += 1 }
    func needsSecondOperation() -> Bool { requiredOperations == 2 && calls < 2 }
}

@available(macOS 27, *)
private struct HistoryFixtureModel: LanguageModel {
    let state: HistoryFixtureState
    let executorConfiguration = UUID()
    var capabilities: LanguageModelCapabilities { .init([.toolCalling, .vision]) }
    struct Executor: LanguageModelExecutor {
        init(configuration: UUID) {}
        func respond(to request: LanguageModelExecutorGenerationRequest, model: HistoryFixtureModel,
                     streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            await model.state.record(request)
            let needsSecondOperation = await model.state.needsSecondOperation()
            if request.transcript.map(\.description).joined(separator: "\n").contains("Summarize this conversation:") {
                if model.state.cancelSummary { throw CancellationError() }
                await channel.send(.response(entryID: "summary", action: .updateMetadata(["incompleteOutput": model.state.incompleteSummary])))
                await channel.send(.response(entryID: "summary", action: .appendText(model.state.summaryText, tokenCount: 20)))
            } else if request.generationOptions.toolCallingMode == .required || needsSecondOperation {
                await channel.send(.toolCalls(action: .toolCall(id: UUID().uuidString, name: "operation",
                    action: .appendArguments(#"{"value":"saffron"}"#, tokenCount: 5))))
            } else {
                if model.state.failAfterOperation { throw AppleContextLimit() }
                await channel.send(.response(action: .appendText("done", tokenCount: 1)))
            }
        }
    }
}

@available(macOS 27, *)
private struct HistoryFixtureTool: Tool {
    let state: HistoryFixtureState
    let name = "operation"
    let description = "Perform the operation once."
    @Generable struct Arguments { let value: String }
    func call(arguments: Arguments) async throws -> String {
        await state.operate()
        return "Completed operation with \(arguments.value)."
    }
}
#endif
