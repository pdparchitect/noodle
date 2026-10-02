import XCTest
@testable import NoodleCore

final class RemoteModelAPITests: XCTestCase {
    private let weather = RemoteTool(name: "weather", description: "Current weather for a city.",
        parameters: Data(#"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#.utf8))

    private func conversation(reasoning: Data? = nil) -> RemoteRequest {
        var items: [RemoteItem] = [.user([.text("What is the weather in Paris?"), .image(Data([1, 2, 3]))])]
        if let reasoning { items.append(.reasoning(reasoning)) }
        items += [.toolCall(id: "call_1", name: "weather", arguments: #"{"city":"Paris"}"#),
                  .toolResult(id: "call_1", output: "18°C, light rain"),
                  .assistant("Paris: 18°C."),
                  .user([.text("Thanks")])]
        return RemoteRequest(model: "gpt-6-luna", instructions: "You are terse.", items: items, tools: [weather],
                             toolChoice: .auto, maximumOutputTokens: 2_000, effort: "low")
    }

    private func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    func testResponsesRequestReplaysReasoningAndToolResults() throws {
        let item = Data(#"{"type":"reasoning","id":"rs_1","encrypted_content":"gAAA","summary":[]}"#.utf8)
        let request = try ResponsesAPI().urlRequest(for: conversation(reasoning: item), baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: "sk-test")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["store"] as? Bool, false, "Noodle keeps the conversation; the provider keeps nothing")
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
        XCTAssertEqual(body["instructions"] as? String, "You are terse.")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2_000)
        XCTAssertEqual(json(body["reasoning"]!), #"{"effort":"low","summary":"auto"}"#)
        XCTAssertEqual(json(body["tools"]!), #"[{"description":"Current weather for a city.","name":"weather","parameters":{"properties":{"city":{"type":"string"}},"required":["city"],"type":"object"},"strict":false,"type":"function"}]"#)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.map(json), [
            #"{"content":[{"text":"What is the weather in Paris?","type":"input_text"},{"image_url":"data:image/png;base64,AQID","type":"input_image"}],"role":"user"}"#,
            #"{"encrypted_content":"gAAA","id":"rs_1","summary":[],"type":"reasoning"}"#,
            #"{"arguments":"{\"city\":\"Paris\"}","call_id":"call_1","name":"weather","type":"function_call"}"#,
            #"{"call_id":"call_1","output":"18°C, light rain","type":"function_call_output"}"#,
            #"{"content":[{"text":"Paris: 18°C.","type":"output_text"}],"role":"assistant"}"#,
            #"{"content":[{"text":"Thanks","type":"input_text"}],"role":"user"}"#
        ])
    }

    func testResponsesRequestMapsToolChoiceAndSchema() throws {
        var request = conversation()
        request.toolChoice = .required
        request.schema = RemoteSchema(name: "Answer", json: Data(#"{"type":"object"}"#.utf8))
        request.effort = nil
        var body = try ResponsesAPI().body(for: request)
        XCTAssertEqual(body["tool_choice"] as? String, "required")
        XCTAssertEqual(json(body["text"]!), #"{"format":{"name":"Answer","schema":{"type":"object"},"strict":false,"type":"json_schema"}}"#)
        XCTAssertNil(body["reasoning"])
        request.toolChoice = .none
        body = try ResponsesAPI().body(for: request)
        XCTAssertNil(body["tools"], "With tools off, the model is not shown them")
    }

    func testChatCompletionsRequestUsesMessages() throws {
        var request = conversation(reasoning: Data("ignored".utf8))
        request.schema = RemoteSchema(name: "Answer", json: Data(#"{"type":"object"}"#.utf8))
        let url = try ChatCompletionsAPI().urlRequest(for: request, baseURL: URL(string: "https://example.com/v1")!, apiKey: "k")
        XCTAssertEqual(url.url?.absoluteString, "https://example.com/v1/chat/completions")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(url.httpBody)) as? [String: Any])
        XCTAssertEqual(json(body["stream_options"]!), #"{"include_usage":true}"#)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 2_000)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertEqual(json(body["response_format"]!), #"{"json_schema":{"name":"Answer","schema":{"type":"object"},"strict":false},"type":"json_schema"}"#)
        XCTAssertEqual(json(body["tools"]!), #"[{"function":{"description":"Current weather for a city.","name":"weather","parameters":{"properties":{"city":{"type":"string"}},"required":["city"],"type":"object"}},"type":"function"}]"#)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map(json), [
            #"{"content":"You are terse.","role":"developer"}"#,
            #"{"content":[{"text":"What is the weather in Paris?","type":"text"},{"image_url":{"url":"data:image/png;base64,AQID"},"type":"image_url"}],"role":"user"}"#,
            #"{"content":null,"role":"assistant","tool_calls":[{"function":{"arguments":"{\"city\":\"Paris\"}","name":"weather"},"id":"call_1","type":"function"}]}"#,
            #"{"content":"18°C, light rain","role":"tool","tool_call_id":"call_1"}"#,
            #"{"content":"Paris: 18°C.","role":"assistant"}"#,
            #"{"content":[{"text":"Thanks","type":"text"}],"role":"user"}"#
        ], "Reasoning from another wire format is not replayed")
    }

    func testChatCompletionsGroupsParallelToolCallsIntoOneMessage() throws {
        let request = RemoteRequest(model: "m", instructions: nil, items: [
            .user([.text("Both")]),
            .toolCall(id: "a", name: "weather", arguments: "{}"), .toolCall(id: "b", name: "weather", arguments: "{}"),
            .toolResult(id: "a", output: "1"), .toolResult(id: "b", output: "2")
        ], tools: [weather], toolChoice: .auto, maximumOutputTokens: nil, effort: nil)
        let messages = try XCTUnwrap(ChatCompletionsAPI().body(for: request)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual((messages[1]["tool_calls"] as? [[String: Any]])?.count, 2)
    }

    func testGatewaysTakeAReasoningObjectAndGetTheirReasoningDetailsBack() throws {
        let details = Data(#"{"reasoning_details":[{"type":"reasoning.text","text":"Check the weather.","signature":"sig","format":"anthropic-claude-v1","index":0}]}"#.utf8)
        var request = conversation(reasoning: details)
        request.effort = "high"
        let api = GatewayChatAPI()
        let body = try api.body(for: request)
        XCTAssertEqual(json(body["reasoning"]!), #"{"effort":"high"}"#)
        XCTAssertNil(body["reasoning_effort"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertNotNil(messages[2]["tool_calls"])
        XCTAssertEqual(json(messages[2]["reasoning_details"]!),
                       #"[{"format":"anthropic-claude-v1","index":0,"signature":"sig","text":"Check the weather.","type":"reasoning.text"}]"#,
                       "Reasoning goes back unchanged on the message that made the calls")
        XCTAssertNil(messages[4]["reasoning_details"], "Only the message it came with")

        let responses = Data(#"{"type":"reasoning","id":"rs_1","encrypted_content":"gAAA","summary":[]}"#.utf8)
        let other = try XCTUnwrap(api.body(for: conversation(reasoning: responses))["messages"] as? [[String: Any]])
        XCTAssertNil(other[2]["reasoning_details"], "Reasoning from another wire format is not sent")
    }

    func testOpenRouterNamesNoodleAsTheApp() throws {
        let openRouter = try XCTUnwrap(RemoteProviders.provider(id: "openrouter"))
        let api = openRouter.api(for: try XCTUnwrap(openRouter.models.first))
        let request = try api.urlRequest(for: conversation(), baseURL: openRouter.baseURL, apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Noodle")
    }

    func testDecodesGatewayReasoningDetailsBeforeTheCallsTheyLedTo() throws {
        // Shaped after the OpenRouter and Vercel AI Gateway streaming documentation.
        let stream = [
            #"data: {"choices":[{"index":0,"delta":{"role":"assistant","reasoning":"Check ","reasoning_details":[{"type":"reasoning.text","text":"Check ","format":"unknown","index":0}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"reasoning":"the weather.","reasoning_details":[{"type":"reasoning.text","text":"the weather.","signature":"sig","format":"unknown","index":0}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"weather","arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":20,"completion_tokens_details":{"reasoning_tokens":8}}}"#,
            "data: [DONE]"
        ].joined(separator: "\n\n")
        let events = try decode(stream, with: GatewayChatAPI())
        XCTAssertEqual(Array(events.prefix(2)), [.reasoningText("Check "), .reasoningText("the weather.")])
        guard case .reasoning(let replay) = events[2] else { return XCTFail("Reasoning details come before the calls: \(events)") }
        XCTAssertEqual(String(decoding: replay, as: UTF8.self),
                       #"{"reasoning_details":[{"format":"unknown","index":0,"signature":"sig","text":"Check the weather.","type":"reasoning.text"}]}"#)
        XCTAssertEqual(events[3], .toolCall(id: "call_1", name: "weather", arguments: #"{"city":"Paris"}"#))
        XCTAssertEqual(events.last, .usage(RemoteUsage(inputTokens: 50, cachedInputTokens: 0, outputTokens: 20, reasoningTokens: 8)))
    }

    func testDecodesRecordedResponsesToolCall() throws {
        XCTAssertEqual(try decode(RemoteModelFixtures.responsesToolCall, with: ResponsesAPI()), [
            .toolCall(id: "call_DBocUZDGlQsX1zzvurYSN28r", name: "weather", arguments: #"{"city":"Paris"}"#),
            .usage(RemoteUsage(inputTokens: 60, cachedInputTokens: 0, outputTokens: 17, reasoningTokens: 0))
        ])
    }

    func testDecodesRecordedResponsesText() throws {
        let events = try decode(RemoteModelFixtures.responsesTextAfterTool, with: ResponsesAPI())
        XCTAssertEqual(events.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(), "Paris: 18°C with light rain.")
        XCTAssertEqual(events.last, .usage(RemoteUsage(inputTokens: 92, cachedInputTokens: 0, outputTokens: 13, reasoningTokens: 0)))
    }

    func testDecodesRecordedResponsesReasoningForReplay() throws {
        let events = try decode(RemoteModelFixtures.responsesReasoning, with: ResponsesAPI())
        XCTAssertEqual(events.compactMap { if case .reasoningText(let text) = $0 { return text }; return nil }.joined(),
                       "**Counting prime numbers**\n\nI'm looking to")
        let replay = try XCTUnwrap(events.compactMap { if case .reasoning(let data) = $0 { return data }; return nil }.first)
        let item = try XCTUnwrap(JSONSerialization.jsonObject(with: replay) as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "reasoning")
        XCTAssertEqual(item["id"] as? String, "rs_0b0c7b463072274d016abef7c4e51887d2b262cdc70b83d1e3")
        XCTAssertNotNil(item["encrypted_content"] as? String)
        XCTAssertEqual(events.compactMap { if case .text(let text) = $0 { return text }; return nil }, ["12"])
    }

    func testRecordedResponsesOverflowIsAContextError() throws {
        XCTAssertThrowsError(try decode(RemoteModelFixtures.responsesContextOverflow, with: ResponsesAPI())) { error in
            XCTAssertEqual(error as? RemoteModelError, .contextOverflow(tokenCount: nil))
        }
    }

    func testDecodesRecordedChatToolCallAndText() throws {
        XCTAssertEqual(try decode(RemoteModelFixtures.chatToolCall, with: ChatCompletionsAPI()).first,
                       .toolCall(id: "call_JrsktptUWIkYluo0rlksPbkK", name: "weather", arguments: #"{"city":"Paris"}"#))
        let events = try decode(RemoteModelFixtures.chatTextAfterTool, with: ChatCompletionsAPI())
        XCTAssertFalse(events.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined().isEmpty)
        guard case .usage(let usage)? = events.last else { return XCTFail("Usage arrives last") }
        XCTAssertGreaterThan(usage.inputTokens, 0)
    }

    func testRejectionsMapToErrorsTheHarnessUnderstands() {
        let api = ChatCompletionsAPI()
        XCTAssertEqual(api.error(status: 400, body: Data(RemoteModelFixtures.chatContextOverflowBody.utf8), headers: [:]) as? RemoteModelError,
                       .contextOverflow(tokenCount: 1_000_007))
        XCTAssertEqual(api.error(status: 401, body: Data(#"{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}"#.utf8), headers: [:]) as? RemoteModelError,
                       .authentication("Incorrect API key provided"))
        XCTAssertEqual(api.error(status: 429, body: Data(#"{"error":{"message":"Slow down"}}"#.utf8), headers: ["Retry-After": "7"]) as? RemoteModelError,
                       .rateLimited(retryAfter: 7))
        XCTAssertEqual(api.error(status: 500, body: Data("oops".utf8), headers: [:]) as? RemoteModelError,
                       .provider(status: 500, message: "oops"))
    }

    func testClientStreamsThroughTransportAndReportsRejections() async throws {
        let transport = StubTransport(responses: [(200, RemoteModelFixtures.responsesTextAfterTool),
                                                  (401, #"{"error":{"message":"Incorrect API key provided"}}"#)])
        let provider = try XCTUnwrap(RemoteProviders.provider(id: "openai"))
        let model = try XCTUnwrap(provider.model(id: "gpt-6-luna"))
        let client = RemoteClient(provider: provider, model: model, apiKey: "sk-test", transport: transport)
        var text = ""
        for try await event in client.stream(conversation()) { if case .text(let delta) = event { text += delta } }
        XCTAssertEqual(text, "Paris: 18°C with light rain.")
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.openai.com/v1/responses")
        do {
            for try await _ in client.stream(conversation()) {}
            XCTFail("A rejected key ends the stream")
        } catch { XCTAssertEqual(error as? RemoteModelError, .authentication("Incorrect API key provided")) }
    }

    func testServerSentEventsSplitOnBlankLines() {
        var parser = ServerSentEvents()
        XCTAssertEqual(parser.feed("event: a"), [])
        XCTAssertEqual(parser.feed("data: {\"x\":1}"), [])
        XCTAssertEqual(parser.feed(""), [ServerSentEvent(event: "a", data: "{\"x\":1}")])
        XCTAssertEqual(parser.feed(": keep-alive"), [])
        XCTAssertEqual(parser.feed("data: [DONE]"), [])
        XCTAssertEqual(parser.finish(), [ServerSentEvent(event: nil, data: "[DONE]")])
    }

    private func decode(_ stream: String, with api: RemoteAPI) throws -> [RemoteEvent] {
        let decoder = api.makeDecoder()
        var parser = ServerSentEvents()
        var events: [RemoteEvent] = []
        for line in stream.components(separatedBy: "\n") {
            for message in parser.feed(line) { events += try decoder.decode(message) }
        }
        for message in parser.finish() { events += try decoder.decode(message) }
        return events + (try decoder.finish())
    }
}

final class StubTransport: RemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String)]
    private(set) var requests: [URLRequest] = []
    init(responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> RemoteHTTPResponse {
        let (status, body) = lock.withLock { () -> (Int, String) in
            requests.append(request)
            return responses.isEmpty ? (500, "No scripted response") : responses.removeFirst()
        }
        let lines = body.components(separatedBy: "\n")
        return RemoteHTTPResponse(status: status, headers: [:], lines: AsyncThrowingStream { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        })
    }
}
