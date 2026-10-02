#if canImport(FoundationModels, _version: 2)
import XCTest
import FoundationModels
import NoodleCore
@testable import NoodleAppleRuntime

/// A remote model runs a whole turn through the Foundation Models session:
/// tools, history and context fitting, with the provider scripted.
final class AppleRemoteModelTests: XCTestCase {
    private let luna = RemoteModelID(providerID: "openai", accountID: UUID(), modelID: "gpt-6-luna")

    @available(macOS 27, *)
    private func backend(_ transport: ScriptedProvider, effort: String? = "low") throws -> AppleModelBackend {
        try AppleModelBackend.remote(luna, access: AppleRemoteAccess(apiKey: "sk-test", effort: effort), transport: transport)
    }

    func testToolCallRunsTheToolAndSendsItsResultBack() async throws {
        guard #available(macOS 27, *) else { return }
        let provider = ScriptedProvider([.ok(Self.call("call_1", "echo", #"{"text":"hi"}"#)), .ok(Self.text("Done: hi"))])
        let session = try backend(provider).session(tools: [EchoTool()], instructions: "Use tools.")
        let response = try await session.respond(to: "Echo hi")
        XCTAssertEqual(response.content, "Done: hi")

        let first = try provider.body(0)
        XCTAssertEqual(first["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(first["instructions"] as? String, "Use tools.")
        XCTAssertEqual((first["tools"] as? [[String: Any]])?.map { $0["name"] as? String }, ["echo"])
        XCTAssertEqual((first["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        let input = try XCTUnwrap(provider.body(1)["input"] as? [[String: Any]])
        XCTAssertEqual(input.compactMap { $0["type"] as? String }, ["function_call", "function_call_output"])
        XCTAssertEqual(input.last?["call_id"] as? String, "call_1")
        XCTAssertEqual(input.last?["output"] as? String, "echo: hi")
        XCTAssertEqual(provider.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testReasoningIsReplayedBeforeTheCallItLedTo() async throws {
        guard #available(macOS 27, *) else { return }
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "encrypted_content": "gAAA", "summary": []]
        let provider = ScriptedProvider([
            .ok(Self.sse([["type": "response.reasoning_summary_text.delta", "delta": "Thinking."],
                          ["type": "response.output_item.done", "item": reasoning],
                          ["type": "response.output_item.done", "item": ["type": "function_call", "call_id": "call_1", "name": "echo", "arguments": #"{"text":"x"}"#]],
                          Self.completed])),
            .ok(Self.text("Finished."))
        ])
        let session = try backend(provider).session(tools: [EchoTool()], instructions: "Use tools.")
        _ = try await session.respond(to: "Go")
        let input = try XCTUnwrap(provider.body(1)["input"] as? [[String: Any]])
        XCTAssertEqual(input.map { $0["type"] as? String ?? $0["role"] as? String }, ["user", "reasoning", "function_call", "function_call_output"])
        XCTAssertEqual(input[1]["encrypted_content"] as? String, "gAAA")
    }

    func testRejectedAsTooLongRetriesOnceWithOlderTurnsRemoved() async throws {
        guard #available(macOS 27, *) else { return }
        let overflow = Self.sse([["type": "error", "error": ["code": "context_length_exceeded",
            "message": "Your input exceeds the context window of this model."]]])
        let provider = ScriptedProvider([.ok(overflow), .ok(Self.text("ok"))])
        let history: [Transcript.Entry] = (0..<6).flatMap { index -> [Transcript.Entry] in
            [.prompt(.init(segments: [.text(.init(content: "Request \(index)"))])),
             .response(.init(assetIDs: [], segments: [.text(.init(content: "Answer \(index)"))]))]
        }
        let session = try backend(provider).session(instructions: "Answer.", entries: history)
        let response = try await session.respond(to: "Latest request")
        XCTAssertEqual(response.content, "ok")
        let first = try XCTUnwrap(provider.body(0)["input"] as? [[String: Any]])
        let retry = try XCTUnwrap(provider.body(1)["input"] as? [[String: Any]])
        XCTAssertLessThan(retry.count, first.count)
        XCTAssertEqual(((retry.last?["content"] as? [[String: Any]])?.first?["text"] as? String), "Latest request")
    }

    func testStillTooLongAfterTheRetryFailsTheTurn() async throws {
        guard #available(macOS 27, *) else { return }
        let overflow = Self.sse([["type": "error", "error": ["code": "context_length_exceeded", "message": "Too long."]]])
        let provider = ScriptedProvider([.ok(overflow), .ok(overflow), .ok(Self.text("never"))])
        let history: [Transcript.Entry] = (0..<6).flatMap { index -> [Transcript.Entry] in
            [.prompt(.init(segments: [.text(.init(content: "Request \(index)"))])),
             .response(.init(assetIDs: [], segments: [.text(.init(content: "Answer \(index)"))]))]
        }
        let session = try backend(provider).session(instructions: "Answer.", entries: history)
        do {
            _ = try await session.respond(to: "Request")
            XCTFail("Two rejections end the generation")
        } catch { XCTAssertTrue(AppleContextOverflow.matches(error), "\(error)") }
        XCTAssertEqual(provider.requests.count, 2)
    }

    func testNothingLeftToRemoveFailsWithoutResending() async throws {
        guard #available(macOS 27, *) else { return }
        let overflow = Self.sse([["type": "error", "error": ["code": "context_length_exceeded", "message": "Too long."]]])
        let provider = ScriptedProvider([.ok(overflow), .ok(Self.text("never"))])
        let session = try backend(provider).session(instructions: "Answer.")
        do {
            _ = try await session.respond(to: "One long request")
            XCTFail("The request cannot be made smaller")
        } catch { XCTAssertTrue(error is AppleContextLimit, "\(error)") }
        XCTAssertEqual(provider.requests.count, 1, "The same request is not sent again")
    }

    func testStructuredOutputUsesTheProvidersJSONSchema() async throws {
        guard #available(macOS 27, *) else { return }
        let provider = ScriptedProvider([.ok(Self.text(#"{"city":"Paris","celsius":18}"#))])
        let session = try backend(provider).session(instructions: "Answer.")
        let response = try await session.respond(to: "Weather?", generating: Weather.self)
        XCTAssertEqual(response.content.city, "Paris")
        XCTAssertEqual(response.content.celsius, 18)
        let format = try XCTUnwrap((provider.body(0)["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNotNil((format["schema"] as? [String: Any])?["properties"])
    }

    /// A model that already replied through a tool may end its turn with no text.
    func testATurnThatEndsWithoutTextIsAnEmptyAnswer() async throws {
        guard #available(macOS 27, *) else { return }
        let reasoning: [String: Any] = ["type": "reasoning", "id": "rs_1", "encrypted_content": "gAAA", "summary": []]
        for ending in [Self.sse([Self.completed]),
                       Self.sse([["type": "response.output_item.done", "item": reasoning], Self.completed]),
                       Self.sse([["type": "response.output_item.done", "item": reasoning]])] {
            let provider = ScriptedProvider([.ok(Self.call("call_1", "echo", #"{"text":"hi"}"#)), .ok(ending)])
            let session = try backend(provider).session(tools: [EchoTool()], instructions: "Use tools.")
            let response = try await session.respond(to: "Echo hi")
            XCTAssertEqual(response.content, "")
            XCTAssertEqual(provider.requests.count, 2)
        }
    }

    func testRejectedKeyFailsWithTheProvidersMessage() async throws {
        guard #available(macOS 27, *) else { return }
        let provider = ScriptedProvider([.status(401, #"{"error":{"message":"Incorrect API key provided"}}"#)])
        let session = try backend(provider).session(instructions: "Answer.")
        do {
            _ = try await session.respond(to: "Hi")
            XCTFail("A rejected key ends the turn")
        } catch { XCTAssertEqual(error as? RemoteModelError, .authentication("Incorrect API key provided")) }
    }

    func testImagesAndEffortReachTheRequest() throws {
        guard #available(macOS 27, *) else { return }
        let image = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let prompt = Transcript.Prompt(segments: [.text(.init(content: "What is this?")),
            .attachment(.init(content: .image(.init(image)), label: "pixel.png"))])
        let model = try XCTUnwrap(RemoteProviders.provider(id: "openai")?.model(id: "gpt-6-luna"))
        let request = LanguageModelExecutorGenerationRequest(id: UUID(), transcript: Transcript(entries: [.prompt(prompt)]),
            enabledTools: [], generationOptions: GenerationOptions(), contextOptions: ContextOptions(reasoningLevel: .deep), metadata: [:])
        let remote = try AppleRemoteTranscript.request(request, model: model, effort: "low")
        guard case .user(let content)? = remote.items.first, case .image(let png)? = content.last else { return XCTFail("Image is sent") }
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(remote.effort, "high", "A request's own reasoning level wins")
        XCTAssertEqual(remote.toolChoice, .none)
        XCTAssertEqual(AppleRemoteTranscript.effort(nil, selected: "bogus", model: model), "medium")
    }

    func testUnknownModelsAndMissingKeysAreRefusedBeforeAnyRequest() throws {
        guard #available(macOS 27, *) else { return }
        let provider = ScriptedProvider([])
        let unknown = RemoteModelID(providerID: "openai", accountID: UUID(), modelID: "gpt-3.5-turbo")
        XCTAssertThrowsError(try AppleModelBackend.remote(unknown, access: AppleRemoteAccess(apiKey: "k", effort: nil), transport: provider))
        XCTAssertThrowsError(try AppleModelBackend.remote(luna, access: nil, transport: provider))
        XCTAssertTrue(provider.requests.isEmpty)
    }

    // MARK: Responses streams

    static let completed: [String: Any] = ["type": "response.completed", "response": ["usage": [
        "input_tokens": 40, "input_tokens_details": ["cached_tokens": 0], "output_tokens": 5, "output_tokens_details": ["reasoning_tokens": 0]]]]

    static func sse(_ events: [[String: Any]]) -> String {
        events.map { event in
            let data = String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
            return "event: \(event["type"] as! String)\ndata: \(data)\n"
        }.joined(separator: "\n")
    }

    static func text(_ text: String) -> String { sse([["type": "response.output_text.delta", "delta": text], completed]) }

    static func call(_ id: String, _ name: String, _ arguments: String) -> String {
        sse([["type": "response.output_item.done", "item": ["type": "function_call", "call_id": id, "name": name, "arguments": arguments]], completed])
    }
}

@available(macOS 27, *)
@Generable private struct Weather {
    var city: String
    var celsius: Int
}

@available(macOS 27, *)
private struct EchoTool: Tool {
    let name = "echo"
    let description = "Echo text back."
    @Generable struct Arguments {
        @Guide(description: "Text to echo.")
        var text: String
    }
    func call(arguments: Arguments) async throws -> String { "echo: \(arguments.text)" }
}

final class ScriptedProvider: RemoteTransport, @unchecked Sendable {
    enum Reply { case ok(String), status(Int, String) }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }

    func body(_ index: Int) throws -> [String: Any] {
        let request = lock.withLock { requests.indices.contains(index) ? requests[index] : nil }
        let data = try XCTUnwrap(request?.httpBody, "Request \(index) was sent")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func send(_ request: URLRequest) async throws -> RemoteHTTPResponse {
        let reply = lock.withLock { () -> Reply in
            requests.append(request)
            return replies.isEmpty ? .status(500, "No scripted reply") : replies.removeFirst()
        }
        let (status, body): (Int, String) = switch reply {
        case .ok(let body): (200, body)
        case .status(let status, let body): (status, body)
        }
        let lines = body.components(separatedBy: "\n")
        return RemoteHTTPResponse(status: status, headers: [:], lines: AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }
}
#endif
