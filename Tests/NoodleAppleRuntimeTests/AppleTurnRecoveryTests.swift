#if canImport(FoundationModels, _version: 2)
import XCTest
import FoundationModels
import NoodleCore
@testable import NoodleAppleRuntime

final class AppleTurnRecoveryTests: XCTestCase {
    func testSlowReasoningAndAnswerChunksReportActivityBeforeCompletion() async throws {
        guard #available(macOS 27, *) else { return }
        let activity = RecoveryActivity()
        let state = RecoveryFixture([.slowChunks(activity)])
        let control = AppleTurnControl()
        let reply = try await AppleResponseRecovery.respond(session: session(state, control: control),
            prompt: Prompt("Think briefly, then answer."), responseTokens: 256, control: control,
            onActivity: { activity.note() })
        XCTAssertEqual(reply, "Complete answer.", "Streaming must retain the final chunk")
        let counts = await state.observedActivity
        XCTAssertEqual(counts.count, 3)
        XCTAssertGreaterThan(counts[1], counts[0], "Reasoning tokens must refresh the inactivity deadline")
        XCTAssertGreaterThan(counts[2], counts[1], "Response tokens must refresh the inactivity deadline")
    }

    func testSilentGenerationDoesNotManufactureActivity() async throws {
        guard #available(macOS 27, *) else { return }
        let activity = RecoveryActivity()
        let state = RecoveryFixture([.silentPause(activity)])
        let control = AppleTurnControl()
        _ = try await AppleResponseRecovery.respond(session: session(state, control: control),
            prompt: Prompt("Answer."), responseTokens: 256, control: control,
            onActivity: { activity.note() })
        let counts = await state.observedActivity
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(counts.first, counts.last, "A timer tick with no transcript change is not progress")
    }

    func testCancellationDuringGenerationStopsWithoutRetrying() async throws {
        guard #available(macOS 27, *) else { return }
        let state = RecoveryFixture([.waitForCancellation])
        let control = AppleTurnControl()
        let current = session(state, control: control)
        let task = Task {
            try await AppleResponseRecovery.respond(session: current, prompt: Prompt("Answer."),
                responseTokens: 256, control: control)
        }
        for _ in 0..<100 {
            if await !state.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must propagate cancellation") }
        catch is CancellationError {}
        let requests = await state.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testResumedInterruptedTurnStartsWithThinkingFallback() async throws {
        guard #available(macOS 27, *) else { return }
        let saved = AppleConversationSession(transcript: Transcript(entries: [
            .prompt(.init(segments: [.text(.init(content: "Continue the task"))])),
            .response(.init(metadata: ["incompleteOutput": true], segments: []))
        ]), messageIDs: [], reply: "", modelIdentifier: "local")
        let control = AppleTurnControl(resuming: saved)
        let prepared = try await control.prepare(request(Array(saved.transcript)), canDisableReasoning: true)
        XCTAssertEqual(prepared.contextOptions.reasoningLevel, .custom("no_think"))
        XCTAssertNil(prepared.generationOptions.maximumResponseTokens, "Recovery retains the full requested answer allowance")

        let completed = AppleConversationSession(transcript: saved.transcript, messageIDs: [UUID()], reply: "Done")
        let fresh = AppleTurnControl(resuming: completed)
        let ordinary = try await fresh.prepare(request(Array(saved.transcript)), canDisableReasoning: true)
        XCTAssertNil(ordinary.contextOptions.reasoningLevel)
    }

    func testInitialOptionalThinkingAttemptLeavesRoomForRecovery() async throws {
        guard #available(macOS 27, *) else { return }
        let control = AppleTurnControl()
        var original = request([.prompt(.init(segments: [.text(.init(content: "Do the task"))]))])
        original.generationOptions.maximumResponseTokens = 2_048
        let first = try await control.prepare(original, canDisableReasoning: true)
        XCTAssertEqual(first.generationOptions.maximumResponseTokens, 512)
        await control.recover()
        let recovery = try await control.prepare(original, canDisableReasoning: true)
        XCTAssertEqual(recovery.generationOptions.maximumResponseTokens, 2_048)
        XCTAssertEqual(recovery.contextOptions.reasoningLevel, .custom("no_think"))
        let unsupported = try await AppleTurnControl().prepare(original, canDisableReasoning: false)
        XCTAssertEqual(unsupported.generationOptions.maximumResponseTokens, 2_048)
        original.generationOptions.maximumResponseTokens = 128
        let small = try await AppleTurnControl().prepare(original, canDisableReasoning: true)
        XCTAssertEqual(small.generationOptions.maximumResponseTokens, 128)
    }

    func testEmptyReplyRecoversInSameSessionWithoutRepeatingCompletedTool() async throws {
        guard #available(macOS 27, *) else { return }
        let state = RecoveryFixture([.call("saffron"), .text("", false), .text("Created saffron.", false)])
        let control = AppleTurnControl()
        let session = session(state, control: control, toggleableReasoning: true)
        let activity = ActivityEvents()
        let reply = try await AppleResponseRecovery.respond(session: session, prompt: Prompt("Create the file once."),
            responseTokens: 256, control: control, onEvent: { await activity.append($0) })
        XCTAssertEqual(reply, "Created saffron.")
        let statuses = await activity.values.compactMap { event -> String? in
            if case .status(let title) = event { return title }; return nil
        }
        XCTAssertEqual(statuses, ["Generating response", "Retrying an empty model reply (1/2)", "Generating response"])
        let requests = await state.requests
        let calls = await state.calls
        XCTAssertEqual(calls, ["saffron"])
        XCTAssertEqual(requests.count, 3)
        XCTAssertNil(requests[0].contextOptions.reasoningLevel)
        XCTAssertEqual(requests[2].contextOptions.reasoningLevel, .custom("no_think"))
        XCTAssertTrue(requests[2].transcript.contains { if case .toolOutput = $0 { return true }; return false })
        let prompts = requests[2].transcript.filter { if case .prompt = $0 { return true }; return false }
        XCTAssertEqual(prompts.count, 1, "Recovery must retain the original task as the current prompt")
        XCTAssertTrue(prompts[0].description.contains("Create the file once."))
    }

    func testEmptyAndWhitespaceRepliesHaveFiniteRecoveryBudget() async throws {
        guard #available(macOS 27, *) else { return }
        let state = RecoveryFixture([.text("", false), .text(" \n", false), .text("", false)])
        let control = AppleTurnControl()
        do {
            _ = try await AppleResponseRecovery.respond(session: session(state, control: control), prompt: Prompt("Answer."),
                responseTokens: 256, control: control)
            XCTFail("Must fail after two recovery attempts")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("two recovery attempts"))
        }
        let requests = await state.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.contextOptions.reasoningLevel == nil },
            "Never send MLX's thinking toggle to an unsupported model")
    }

    func testTruncatedTextAndReasoningOnlyOutputRecoverToCompleteAnswer() async throws {
        guard #available(macOS 27, *) else { return }
        for fragment in ["", "An unfinished ans"] {
            let state = RecoveryFixture([.text(fragment, true), .text("Complete answer.", false)])
            let control = AppleTurnControl()
            let reply = try await AppleResponseRecovery.respond(session: session(state, control: control), prompt: Prompt("Answer."),
                responseTokens: 256, control: control)
            XCTAssertEqual(reply, "Complete answer.", "Do not deliver a truncated fragment as the final reply")
            let requests = await state.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(requests[1].transcript.map(\.description).joined(separator: "\n").contains("output limit"))
        }
    }

    func testRepeatedTruncationFailsAndDoesNotReturnPartialSuccess() async throws {
        guard #available(macOS 27, *) else { return }
        let state = RecoveryFixture(Array(repeating: .text("partial", true), count: 3))
        let control = AppleTurnControl()
        do {
            _ = try await AppleResponseRecovery.respond(session: session(state, control: control), prompt: Prompt("Answer."),
                responseTokens: 256, control: control)
            XCTFail("Truncation is not completion")
        } catch { XCTAssertTrue(error.localizedDescription.contains("output limit")) }
        let requests = await state.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testQuietBackgroundEventDoesNotCreateUnnecessaryRecovery() async throws {
        guard #available(macOS 27, *) else { return }
        let state = RecoveryFixture([.text("", false)])
        let control = AppleTurnControl()
        let reply = try await AppleResponseRecovery.respond(session: session(state, control: control), prompt: Prompt("Quiet event."),
            responseTokens: 256, control: control, allowsEmptyReply: true)
        XCTAssertEqual(reply, "")
        let requests = await state.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testThrownErrorAndCancellationAreNeverRetried() async throws {
        guard #available(macOS 27, *) else { return }
        for step in [RecoveryFixture.Step.failure, .cancel] {
            let state = RecoveryFixture([.call("once"), step])
            let control = AppleTurnControl()
            let current = session(state, control: control)
            do {
                _ = try await AppleResponseRecovery.respond(session: current, prompt: Prompt("Operate once."),
                    responseTokens: 256, control: control)
                XCTFail("Must propagate the failure")
            } catch {}
            let requests = await state.requests
            let calls = await state.calls
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(calls, ["once"])
            XCTAssertTrue(current.transcript.contains { if case .toolOutput = $0 { return true }; return false })
        }
    }

    func testCancellationBeforeGenerationDoesNoWork() async throws {
        guard #available(macOS 27, *) else { return }
        let state = RecoveryFixture([])
        let control = AppleTurnControl()
        let current = session(state, control: control)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppleResponseRecovery.respond(session: current, prompt: Prompt("Operate."), responseTokens: 256, control: control)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        let requests = await state.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRepeatingActionWarnsThenStopsToolsAndReportsBlocker() async throws {
        guard #available(macOS 27, *) else { return }
        let state = RecoveryFixture(Array(repeating: .call("same"), count: 4) + [.text("Blocked after repeated results.", false)])
        let control = AppleTurnControl()
        let reply = try await AppleResponseRecovery.respond(session: session(state, control: control), prompt: Prompt("Operate."),
            responseTokens: 256, control: control)
        let requests = await state.requests
        let calls = await state.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(requests[3].transcript.map(\.description).joined(separator: "\n").contains("materially different"))
        XCTAssertFalse(requests[3].enabledToolDefinitions.isEmpty)
        XCTAssertTrue(requests[4].enabledToolDefinitions.isEmpty)
        XCTAssertEqual(requests[4].generationOptions.toolCallingMode, .disallowed)
        XCTAssertTrue(reply.contains("Blocked"))
    }

    func testDifferentActionsWithIdenticalResultsDoNotTriggerCycleGuard() async throws {
        guard #available(macOS 27, *) else { return }
        let state = RecoveryFixture([.call("a"), .call("b"), .call("c"), .call("d"), .text("Done.", false)])
        let control = AppleTurnControl()
        _ = try await AppleResponseRecovery.respond(session: session(state, control: control), prompt: Prompt("Operate."),
            responseTokens: 256, control: control)
        let requests = await state.requests
        XCTAssertFalse(requests.last!.enabledToolDefinitions.isEmpty)
        XCTAssertFalse(requests.last!.transcript.map(\.description).joined(separator: "\n").contains("same tool requests"))
    }

    func testGenerationBudgetLeavesOneFinalAnswerAndNeverResetsOnRecovery() async throws {
        guard #available(macOS 27, *) else { return }
        let state = RecoveryFixture([.call("a"), .call("b"), .text("", false)])
        let control = AppleTurnControl(maximumGenerations: 3)
        do {
            _ = try await AppleResponseRecovery.respond(session: session(state, control: control), prompt: Prompt("Operate."),
                responseTokens: 256, control: control)
            XCTFail("An empty final answer cannot restart a depleted tool budget")
        } catch { XCTAssertTrue(error.localizedDescription.contains("generation budget")) }
        let requests = await state.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests[1].enabledToolDefinitions.isEmpty)
        XCTAssertTrue(requests[2].enabledToolDefinitions.isEmpty)
        XCTAssertTrue(requests[2].transcript.map(\.description).joined(separator: "\n").contains("last generation"))
    }

    func testToolRoundsAreCheckpointedBeforeLaterGenerationFails() async throws {
        guard #available(macOS 27, *) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-checkpoint-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let state = RecoveryFixture([.call("once"), .failure])
        let control = AppleTurnControl()
        let current = session(state, control: control) { transcript in
            try AppleConversationSession(transcript: transcript, messageIDs: [], reply: "").save(to: file)
        }
        do {
            _ = try await AppleResponseRecovery.respond(session: current, prompt: Prompt("Operate once."), responseTokens: 256, control: control)
            XCTFail("Expected model failure")
        } catch {}
        let saved = try XCTUnwrap(AppleConversationSession.load(from: file))
        XCTAssertFalse(saved.hasCompletedReply)
        XCTAssertTrue(saved.transcript.contains { if case .toolOutput = $0 { return true }; return false })
    }

    func testRecoveryWithLongToolHistoryKeepsOriginalTaskAndEveryReceipt() async throws {
        guard #available(macOS 27, *) else { return }
        let state = RecoveryFixture([.call("a"), .call("b"), .call("c"), .text("", false), .text("Done.", false)])
        let control = AppleTurnControl()
        let reply = try await AppleResponseRecovery.respond(session: session(state, control: control), prompt: Prompt("Perform three distinct steps."),
            responseTokens: 256, control: control)
        XCTAssertEqual(reply, "Done.")
        let requests = await state.requests
        XCTAssertEqual(requests.count, 5, "Recovery must not trigger a separate summary generation")
        XCTAssertEqual(requests.last!.transcript.filter { if case .toolOutput = $0 { return true }; return false }.count, 3)
        XCTAssertTrue(requests.last!.transcript.map(\.description).joined(separator: "\n").contains("Perform three distinct steps."))
    }

    func testCycleCorpusCoversAlternatingPatternsAndProgress() {
        guard #available(macOS 27, *) else { return }
        let corpus: [([String], Int)] = [([], 0), (["a"], 0), (["a", "a", "a"], 3),
            (["a", "b", "a", "b", "a", "b"], 3), (["a", "a", "a", "b"], 1),
            (["a", "b", "c", "a", "b", "c", "a", "b", "c"], 3)]
        for (values, expected) in corpus { XCTAssertEqual(AppleTurnControl.repeatedSuffix(values), expected, "\(values)") }
    }

    func testOldEmptyCompletionReceiptIsNotReusable() throws {
        guard #available(macOS 26, *) else { return }
        for reply in ["", " \n"] {
            let saved = AppleConversationSession(transcript: Transcript(entries: []), messageIDs: [UUID()], reply: reply)
            XCTAssertFalse(saved.hasCompletedReply)
        }
        XCTAssertTrue(AppleConversationSession(transcript: Transcript(entries: []), messageIDs: [UUID()], reply: "Done").hasCompletedReply)
    }

    func testEarlierTruncationDoesNotInvalidateFinalAnswer() {
        guard #available(macOS 27, *) else { return }
        let entries: [Transcript.Entry] = [
            .response(.init(metadata: ["incompleteOutput": true], segments: [.text(.init(content: "partial"))])),
            .response(.init(segments: [.text(.init(content: "Finished."))]))
        ]
        XCTAssertFalse(AppleResponseRecovery.isIncomplete(entries[...]))
        XCTAssertTrue(AppleResponseRecovery.isIncomplete(entries.prefix(1)))
    }

    func testPastTurnsDoNotCountAsCurrentRepetition() async throws {
        guard #available(macOS 27, *) else { return }
        let control = AppleTurnControl()
        var history: [Transcript.Entry] = [.instructions(.init(segments: [.text(.init(content: "Instructions"))], toolDefinitions: []))]
        for index in 0..<4 { history += try exchange("old-\(index)", arguments: #"{"value":"same"}"#, result: "Done") }
        history.append(.prompt(.init(segments: [.text(.init(content: "New task"))])))
        let original = request(history)
        _ = try await control.prepare(original, canDisableReasoning: false)
        history += try exchange("current", arguments: #"{"value":"same"}"#, result: "Done")
        let prepared = try await control.prepare(request(history), canDisableReasoning: false)
        XCTAssertFalse(prepared.transcript.map(\.description).joined().contains("repeating"))
        let recorded = await control.recentExchanges
        XCTAssertEqual(recorded.count, 1)
    }

    func testArgumentOrderIsCanonicalButChangingResultsAreProgress() async throws {
        guard #available(macOS 27, *) else { return }
        for changingResults in [false, true] {
            let control = AppleTurnControl()
            var history: [Transcript.Entry] = [.instructions(.init(segments: [.text(.init(content: "Instructions"))], toolDefinitions: [])),
                .prompt(.init(segments: [.text(.init(content: "Operate"))]))]
            _ = try await control.prepare(request(history), canDisableReasoning: false)
            for index in 0..<3 {
                history += try exchange("current-\(index)",
                    arguments: index.isMultiple(of: 2) ? #"{"a":1,"b":2}"# : #"{"b":2,"a":1}"#,
                    result: changingResults ? "Progress \(index)" : "Done")
                let prepared = try await control.prepare(request(history), canDisableReasoning: false)
                if index == 2 {
                    XCTAssertEqual(prepared.transcript.map(\.description).joined().contains("materially different"), !changingResults)
                }
            }
        }
    }

    func testCheckpointFailureStopsBeforeModelOrToolExecution() async throws {
        guard #available(macOS 27, *) else { return }
        let state = RecoveryFixture([.call("must not run")])
        let control = AppleTurnControl()
        let current = session(state, control: control) { _ in throw HarnessSetupError("Cannot save checkpoint") }
        do {
            _ = try await AppleResponseRecovery.respond(session: current, prompt: Prompt("Operate."), responseTokens: 256, control: control)
            XCTFail("Do not perform work when its checkpoint cannot be saved")
        } catch {}
        let requests = await state.requests
        let calls = await state.calls
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(calls.isEmpty)
    }

    @available(macOS 27, *)
    private func exchange(_ id: String, arguments: String, result: String) throws -> [Transcript.Entry] {
        [.toolCalls(.init([.init(id: id, toolName: "operation", arguments: try GeneratedContent(json: arguments))])),
         .toolOutput(.init(id: id, toolName: "operation", segments: [.text(.init(content: result))]))]
    }

    @available(macOS 27, *)
    private func request(_ entries: [Transcript.Entry]) -> LanguageModelExecutorGenerationRequest {
        .init(id: UUID(), transcript: Transcript(entries: entries), enabledTools: [], generationOptions: .init(), contextOptions: .init(), metadata: [:])
    }

    @available(macOS 27, *)
    private func session(_ state: RecoveryFixture, control: AppleTurnControl, toggleableReasoning: Bool = false,
                         checkpoint: (@Sendable (Transcript) throws -> Void)? = nil) -> LanguageModelSession {
        let model = AppleContextModel(base: RecoveryModel(state: state),
            budget: AppleContextBudget(contextSize: 32_768, responseTokens: 256), count: { _ in 500 },
            control: control, canDisableReasoning: toggleableReasoning, checkpoint: checkpoint)
        return AppleTurnProfile.session(model: model, tools: [RecoveryTool(state: state)], instructions: "Perform the task and report actual results.")
    }
}

@available(macOS 27, *)
private actor RecoveryFixture {
    enum Step: Sendable {
        case text(String, Bool), call(String), failure, cancel, waitForCancellation
        case slowChunks(RecoveryActivity), silentPause(RecoveryActivity)
    }
    var steps: [Step]
    var requests: [LanguageModelExecutorGenerationRequest] = []
    var calls: [String] = []
    var observedActivity: [Int] = []
    init(_ steps: [Step]) { self.steps = steps }
    func next(_ request: LanguageModelExecutorGenerationRequest) throws -> (Step, Int) {
        requests.append(request)
        guard !steps.isEmpty else { throw HarnessSetupError("Unexpected extra model generation") }
        return (steps.removeFirst(), requests.count)
    }
    func operate(_ value: String) { calls.append(value) }
    func observe(_ value: Int) { observedActivity.append(value) }
}

private final class RecoveryActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func note() { lock.withLock { count += 1 } }
    func value() -> Int { lock.withLock { count } }
    func waitForChange(from previous: Int) async throws {
        for _ in 0..<500 {
            if value() > previous { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@available(macOS 27, *)
private struct RecoveryModel: LanguageModel {
    let state: RecoveryFixture
    let executorConfiguration = UUID()
    var capabilities: LanguageModelCapabilities { .init([.toolCalling, .reasoning]) }
    struct Executor: LanguageModelExecutor {
        init(configuration: UUID) {}
        func respond(to request: LanguageModelExecutorGenerationRequest, model: RecoveryModel,
                     streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            let (step, index) = try await model.state.next(request)
            switch step {
            case .text(let text, let incomplete):
                await channel.send(.response(entryID: "answer-\(index)", action: .updateMetadata(["incompleteOutput": incomplete])))
                await channel.send(.response(entryID: "answer-\(index)", action: .appendText(text, tokenCount: 1)))
            case .call(let value):
                await channel.send(.toolCalls(action: .toolCall(id: "call-\(index)", name: "operation",
                    action: .appendArguments("{\"value\":\"\(value)\"}", tokenCount: 5))))
            case .failure: throw HarnessSetupError("Synthetic provider failure")
            case .cancel: throw CancellationError()
            case .waitForCancellation:
                try await Task.sleep(for: .seconds(60))
                throw HarnessSetupError("Cancellation did not reach the model")
            case .silentPause(let activity):
                try await Task.sleep(for: .milliseconds(1_100))
                await model.state.observe(activity.value())
                try await Task.sleep(for: .milliseconds(1_100))
                await model.state.observe(activity.value())
                await channel.send(.response(action: .appendText("Finished.", tokenCount: 1)))
            case .slowChunks(let activity):
                try await Task.sleep(for: .milliseconds(1_100))
                let initial = activity.value()
                await model.state.observe(initial)
                await channel.send(.reasoning(entryID: "thinking", action: .appendText("A short thought.", tokenCount: 4)))
                try await activity.waitForChange(from: initial)
                let reasoning = activity.value()
                await model.state.observe(reasoning)
                await channel.send(.response(entryID: "answer", action: .appendText("Complete ", tokenCount: 1)))
                try await activity.waitForChange(from: reasoning)
                await model.state.observe(activity.value())
                await channel.send(.response(entryID: "answer", action: .appendText("answer.", tokenCount: 2)))
            }
        }
    }
}

@available(macOS 27, *)
private struct RecoveryTool: Tool {
    let state: RecoveryFixture
    let name = "operation"
    let description = "Perform an operation."
    @Generable struct Arguments { let value: String }
    func call(arguments: Arguments) async throws -> String {
        await state.operate(arguments.value)
        return "Operation completed."
    }
}
#endif
