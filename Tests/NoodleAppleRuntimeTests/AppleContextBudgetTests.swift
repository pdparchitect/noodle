#if canImport(FoundationModels, _version: 2)
import XCTest
import FoundationModels
import CoreGraphics
@testable import NoodleAppleRuntime

final class AppleContextBudgetTests: XCTestCase {
    func testDropsWholeOldTurnsAndPreservesCurrentWork() async throws {
        guard #available(macOS 27, *) else { return }
        let instruction = Transcript.Entry.instructions(.init(segments: [.text(.init(content: "Keep these instructions."))], toolDefinitions: []))
        let old = prompt(String(repeating: "old ", count: 2_000))
        let current = prompt("Finish the current request.")
        let call = Transcript.Entry.toolCalls(.init([.init(id: "call", toolName: "write_file", arguments: try GeneratedContent(json: #"{"path":"result.txt","content":"saffron"}"#))]))
        let result = Transcript.Entry.toolOutput(.init(id: "call", toolName: "write_file", segments: [.text(.init(content: "Wrote result.txt."))]))
        let original = request([instruction, old, .response(.init(segments: [.text(.init(content: "old answer"))])), current, call, result])
        let fitted = try await AppleContextBudget(contextSize: 2_048, responseTokens: 256).fit(original, count: byteCount)
        XCTAssertEqual(Array(fitted.transcript), [instruction, current, call, result])
        XCTAssertEqual(original.transcript.count, 6, "Compacting input must not mutate the stored transcript")
        XCTAssertLessThanOrEqual(try byteCount(fitted) + 256 + 512, 2_048)
    }

    func testOversizedCurrentRequestIsNotSilentlyTruncated() async throws {
        guard #available(macOS 27, *) else { return }
        let original = request([prompt(String(repeating: "essential ", count: 2_000))])
        do {
            _ = try await AppleContextBudget(contextSize: 4_096).fit(original, count: byteCount)
            XCTFail("An oversized current request needs an actionable error")
        } catch is AppleContextLimit {}
    }

    func testReplyLimitUsesRemainingSpace() async throws {
        guard #available(macOS 27, *) else { return }
        let fitted = try await AppleContextBudget(contextSize: 4_096).fit(request([prompt("Hello")])) { _ in 3_300 }
        XCTAssertEqual(fitted.generationOptions.maximumResponseTokens, 284)
    }

    func testCounterOverflowStillAllowsCompaction() async throws {
        guard #available(macOS 27, *) else { return }
        let original = request([prompt(String(repeating: "old ", count: 2_000)), prompt("Current request")])
        let fitted = try await AppleContextBudget(contextSize: 4_096).fit(original) { request in
            let count = try Self.byteCount(request)
            if count > 4_096 {
                throw LanguageModelError.contextSizeExceeded(.init(contextSize: 4_096, tokenCount: count, debugDescription: "Over budget"))
            }
            return count
        }
        XCTAssertEqual(fitted.transcript.count, 1)
        XCTAssertTrue(fitted.transcript.first?.description.contains("Current request") == true)
    }

    func testCancellationStopsBeforeCallingTheCounter() async throws {
        guard #available(macOS 27, *) else { return }
        let original = request([prompt("Current request")])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppleContextBudget(contextSize: 4_096).fit(original) { _ in
                XCTFail("Cancelled work must stop before consulting the model")
                return 0
            }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }

    func testUnicodeToolOutputCompactsAndKeepsCallReceipt() async throws {
        guard #available(macOS 27, *) else { return }
        let call = Transcript.Entry.toolCalls(.init([.init(id: "call", toolName: "read_file", arguments: try GeneratedContent(json: #"{"path":"seed.txt"}"#))]))
        let output = Transcript.Entry.toolOutput(.init(id: "call", toolName: "read_file", segments: [.text(.init(content: "START " + String(repeating: "你好🌳", count: 1_000) + "a" + String(repeating: "\u{301}", count: 2_000) + " END"))]))
        let fitted = try await AppleContextBudget(contextSize: 2_048, responseTokens: 256).fit(request([prompt("Read seed.txt"), call, output]), count: byteCount)
        XCTAssertEqual(Array(fitted.transcript)[1], call)
        guard case .toolOutput(let compact) = fitted.transcript.last else { return XCTFail("Lost completed tool output") }
        XCTAssertEqual(compact.id, "call")
        XCTAssertTrue(compact.description.contains("START"))
        XCTAssertTrue(compact.description.contains("END"))
        XCTAssertTrue(compact.description.contains("already completed"))
        XCTAssertLessThanOrEqual(try byteCount(fitted) + 256 + 512, 2_048)
    }

    func testCompactedOutputKeepsTheFullRetrievalPath() async throws {
        guard #available(macOS 27, *) else { return }
        let footer = "\n[Full result saved at /workspace/" + String(repeating: "long-folder/", count: 24)
            + "result.txt; 20000 bytes. Read remaining bytes with read_file offset 3072 before considering this result complete.]"
        let output = Transcript.Entry.toolOutput(.init(id: "call", toolName: "execute_command",
            segments: [.text(.init(content: "Exit status: 0\n" + String(repeating: "Details ", count: 2_000) + footer))]))
        let fitted = try await AppleContextBudget(contextSize: 2_048, responseTokens: 256).fit(request([prompt("Inspect the result"), output]), count: byteCount)
        XCTAssertTrue(fitted.transcript.last?.description.contains(footer) == true)
        XCTAssertTrue(fitted.transcript.last?.description.contains("Exit status: 0") == true)
    }

    func testImageBudgetResizesModelInputAndPreservesOriginal() async throws {
        guard #available(macOS 27, *) else { return }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2_048, height: 1_024, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let entry = Transcript.Entry.prompt(.init(segments: [.text(.init(content: "Describe this image")),
            .attachment(.init(id: "image", content: .image(.init(image)), label: "Photo"))]))
        let (countable, imageAllowance) = AppleContextBudget.textAndImageBudget([entry])
        guard case .prompt(let countedPrompt) = countable.first else { return XCTFail("Lost prompt") }
        XCTAssertTrue(countedPrompt.segments.allSatisfy { if case .text = $0 { return true }; return false })
        XCTAssertTrue(countedPrompt.description.contains("Photo"))
        XCTAssertGreaterThan(imageAllowance, 0)
        let fitted = try await AppleContextBudget(contextSize: 4_096).fit(request([entry])) { request in
            guard case .prompt(let prompt) = request.transcript.last,
                  case .attachment(let attachment) = prompt.segments.last,
                  case .image(let image) = attachment.content else { throw AppleContextLimit() }
            return image.cgImage.width * 2
        }
        guard case .prompt(let prompt) = fitted.transcript.last, case .attachment(let attachment) = prompt.segments.last,
              case .image(let resized) = attachment.content else { return XCTFail("Lost image") }
        XCTAssertEqual(resized.cgImage.width, 1_024)
        XCTAssertEqual(resized.cgImage.height, 512)
        XCTAssertEqual(attachment.label, "Photo")
        XCTAssertEqual(image.width, 2_048)
        XCTAssertLessThan(AppleContextBudget.textAndImageBudget(Array(fitted.transcript)).1, imageAllowance)
    }

    func testBudgetRunsAfterToolCallsWithoutReplayingActions() async throws {
        guard #available(macOS 27, *) else { return }
        let state = ContextFixtureState()
        let model = AppleContextModel(base: ContextFixtureModel(state: state),
            budget: AppleContextBudget(contextSize: 4_096, responseTokens: 256), count: { try Self.byteCount($0) })
        let session = LanguageModelSession(model: model, tools: [ContextFixtureTool(state: state)], instructions: "Run the tool once and report its result.")
        let response = try await session.respond(to: "Do the operation.")
        XCTAssertEqual(response.content, "done")
        let requests = await state.requests
        let calls = await state.calls
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(calls, 1, "Compaction must not replay a completed action")
        for request in requests {
            XCTAssertLessThanOrEqual(try Self.byteCount(request) + (request.generationOptions.maximumResponseTokens ?? 0) + 512, 4_096)
        }
        XCTAssertTrue(session.transcript.contains { if case .toolOutput(let output) = $0 { return output.description.utf8.count > 12_000 }; return false },
                      "Keep full tool results in the original transcript")
    }

    @available(macOS 27, *)
    private func prompt(_ text: String) -> Transcript.Entry { .prompt(.init(segments: [.text(.init(content: text))])) }

    @available(macOS 27, *)
    private func request(_ entries: [Transcript.Entry]) -> LanguageModelExecutorGenerationRequest {
        .init(id: UUID(), transcript: Transcript(entries: entries), enabledTools: [], generationOptions: .init(), contextOptions: .init(), metadata: [:])
    }

    @available(macOS 27, *)
    private func byteCount(_ request: LanguageModelExecutorGenerationRequest) throws -> Int { try Self.byteCount(request) }

    @available(macOS 27, *)
    static func byteCount(_ request: LanguageModelExecutorGenerationRequest) throws -> Int {
        try JSONEncoder().encode(request.transcript).count
    }
}

@available(macOS 27, *)
private actor ContextFixtureState {
    var calls = 0
    var requests: [LanguageModelExecutorGenerationRequest] = []
    func record(_ request: LanguageModelExecutorGenerationRequest) { requests.append(request) }
    func operate() { calls += 1 }
}

@available(macOS 27, *)
private struct ContextFixtureModel: LanguageModel {
    let state: ContextFixtureState
    let executorConfiguration = UUID()
    var capabilities: LanguageModelCapabilities { .init([.toolCalling]) }
    struct Executor: LanguageModelExecutor {
        init(configuration: UUID) {}
        func respond(to request: LanguageModelExecutorGenerationRequest, model: ContextFixtureModel,
                     streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            await model.state.record(request)
            if request.transcript.contains(where: { if case .toolOutput = $0 { return true }; return false }) {
                await channel.send(.response(action: .appendText("done", tokenCount: 1)))
            } else {
                await channel.send(.toolCalls(action: .toolCall(id: "once", name: "operation",
                    action: .appendArguments(#"{"value":"saffron"}"#, tokenCount: 5))))
            }
        }
    }
}

@available(macOS 27, *)
private struct ContextFixtureTool: Tool {
    let state: ContextFixtureState
    let name = "operation"
    let description = "Perform the operation once."
    @Generable struct Arguments { let value: String }
    func call(arguments: Arguments) async throws -> String {
        await state.operate()
        return "Completed \(arguments.value). " + String(repeating: "Detail. ", count: 2_000) + " Operation succeeded."
    }
}
#endif
