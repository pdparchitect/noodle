import Foundation

// A provider-neutral request and event stream. The Apple harness converts its
// transcript to a `RemoteRequest`; each wire format turns that into HTTP and
// its stream back into `RemoteEvent`s.

public enum RemoteContent: Sendable, Equatable {
    case text(String)
    /// PNG data.
    case image(Data)
}

public enum RemoteItem: Sendable, Equatable {
    case user([RemoteContent])
    case assistant(String)
    case toolCall(id: String, name: String, arguments: String)
    case toolResult(id: String, output: String)
    /// Reasoning as the provider returned it, replayed only to the wire format that produced it.
    case reasoning(Data)
}

public struct RemoteTool: Sendable, Equatable {
    public let name: String
    public let description: String
    /// A JSON Schema object.
    public let parameters: Data

    public init(name: String, description: String, parameters: Data) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public enum RemoteToolChoice: Sendable, Equatable { case auto, required, none }

public struct RemoteSchema: Sendable, Equatable {
    public let name: String
    /// A JSON Schema object.
    public let json: Data

    public init(name: String, json: Data) {
        self.name = name
        self.json = json
    }
}

public struct RemoteRequest: Sendable, Equatable {
    public var model: String
    public var instructions: String?
    public var items: [RemoteItem]
    public var tools: [RemoteTool]
    public var toolChoice: RemoteToolChoice
    public var schema: RemoteSchema?
    public var maximumOutputTokens: Int?
    public var effort: String?

    public init(model: String, instructions: String?, items: [RemoteItem], tools: [RemoteTool], toolChoice: RemoteToolChoice,
                schema: RemoteSchema? = nil, maximumOutputTokens: Int?, effort: String?) {
        self.model = model
        self.instructions = instructions
        self.items = items
        self.tools = tools
        self.toolChoice = toolChoice
        self.schema = schema
        self.maximumOutputTokens = maximumOutputTokens
        self.effort = effort
    }
}

public struct RemoteUsage: Sendable, Equatable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningTokens: Int

    public init(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int, reasoningTokens: Int) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }
}

public enum RemoteEvent: Sendable, Equatable {
    case text(String)
    case reasoningText(String)
    case reasoning(Data)
    /// A complete call; arguments are a JSON object in text.
    case toolCall(id: String, name: String, arguments: String)
    case usage(RemoteUsage)
}

public enum RemoteModelError: Error, Equatable, LocalizedError {
    case contextOverflow(tokenCount: Int?)
    case authentication(String)
    case rateLimited(retryAfter: TimeInterval?)
    case provider(status: Int, message: String)
    case invalidStream(String)

    public var errorDescription: String? {
        switch self {
        case .contextOverflow: "the request is larger than the model’s context"
        case .authentication(let message): "the provider rejected the account’s API key (\(message)); update it in Settings › Harnesses › Apple Intelligence › Remote Models"
        case .rateLimited: "the provider is limiting requests; try again shortly"
        case .provider(let status, let message): "the provider returned an error (\(status)): \(message)"
        case .invalidStream(let detail): "the provider sent a response Noodle could not read (\(detail))"
        }
    }
}

/// A server-sent event: the `event:` name, if any, and its joined `data:` lines.
public struct ServerSentEvent: Sendable, Equatable {
    public let event: String?
    public let data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

public struct ServerSentEvents: Sendable {
    private var event: String?
    private var data: [String] = []

    public init() {}

    public mutating func feed(_ line: String) -> [ServerSentEvent] {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return [] }
        let field = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? line
        var value = line.count > field.count ? String(line.dropFirst(field.count + 1)) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event":
            let flushed = data.isEmpty ? [] : flush()
            event = value
            return flushed
        case "data":
            data.append(value)
        default: break
        }
        return []
    }

    public mutating func finish() -> [ServerSentEvent] { flush() }

    private mutating func flush() -> [ServerSentEvent] {
        defer { event = nil; data = [] }
        return data.isEmpty ? [] : [ServerSentEvent(event: event, data: data.joined(separator: "\n"))]
    }
}

/// Turns one stream's events into `RemoteEvent`s. One decoder per response.
open class RemoteStreamDecoder {
    public init() {}
    open func decode(_ event: ServerSentEvent) throws -> [RemoteEvent] { [] }
    open func finish() throws -> [RemoteEvent] { [] }

    public static func object(_ data: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            throw RemoteModelError.invalidStream("event is not a JSON object")
        }
        return object
    }
}

/// One wire format. Subclass and override what a provider or model does differently.
open class RemoteAPI {
    public init() {}

    open var path: String { "chat/completions" }

    open func headers(apiKey: String) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json", "Accept": "text/event-stream"]
    }

    open func body(for request: RemoteRequest) throws -> [String: Any] { [:] }

    open func makeDecoder() -> RemoteStreamDecoder { RemoteStreamDecoder() }

    open func urlRequest(for request: RemoteRequest, baseURL: URL, apiKey: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        urlRequest.httpMethod = "POST"
        // Reasoning can take minutes; the stream's own events keep it alive.
        urlRequest.timeoutInterval = 600
        for (field, value) in headers(apiKey: apiKey) { urlRequest.setValue(value, forHTTPHeaderField: field) }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(for: request), options: [.withoutEscapingSlashes])
        return urlRequest
    }

    /// Maps a rejected request to an error the harness can act on.
    open func error(status: Int, body: Data, headers: [String: String]) -> Error {
        let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any]
        let message = detail?["message"] as? String
            ?? String(String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        if let overflow = Self.overflow(code: detail?["code"] as? String, message: message) { return overflow }
        switch status {
        case 401, 403: return RemoteModelError.authentication(message)
        case 429:
            let retry = headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }.flatMap { TimeInterval($0.value) }
            return RemoteModelError.rateLimited(retryAfter: retry)
        default: return RemoteModelError.provider(status: status, message: message)
        }
    }

    static func overflow(code: String?, message: String) -> RemoteModelError? {
        guard code == "context_length_exceeded" || message.localizedCaseInsensitiveContains("context window")
                || message.localizedCaseInsensitiveContains("maximum context length") else { return nil }
        // "Your messages resulted in 1000007 tokens."
        let count = message.range(of: #"resulted in ([\d,]+) tokens"#, options: .regularExpression).flatMap { range -> Int? in
            Int(message[range].filter(\.isNumber))
        }
        return .contextOverflow(tokenCount: count)
    }

    static func dataURL(_ png: Data) -> String { "data:image/png;base64," + png.base64EncodedString() }

    static func json(_ data: Data) throws -> Any { try JSONSerialization.jsonObject(with: data) }
}

/// OpenAI's Responses API. Reasoning returns encrypted, so it can be replayed
/// across tool calls without the provider storing the conversation.
open class ResponsesAPI: RemoteAPI {
    open override var path: String { "responses" }

    open override func body(for request: RemoteRequest) throws -> [String: Any] {
        var body: [String: Any] = ["model": request.model, "stream": true, "store": false,
                                   "include": ["reasoning.encrypted_content"], "input": try input(request.items)]
        if let instructions = request.instructions { body["instructions"] = instructions }
        if request.toolChoice != .none, !request.tools.isEmpty {
            body["tools"] = try request.tools.map { tool in
                ["type": "function", "name": tool.name, "description": tool.description,
                 "parameters": try Self.json(tool.parameters), "strict": false] as [String: Any]
            }
            if request.toolChoice == .required { body["tool_choice"] = "required" }
        }
        if let maximum = request.maximumOutputTokens { body["max_output_tokens"] = maximum }
        if let effort = request.effort {
            body["reasoning"] = effort == "none" ? ["effort": effort] : ["effort": effort, "summary": "auto"]
        }
        if let schema = request.schema {
            body["text"] = ["format": ["type": "json_schema", "name": schema.name, "schema": try Self.json(schema.json), "strict": false]]
        }
        return body
    }

    open func input(_ items: [RemoteItem]) throws -> [[String: Any]] {
        items.compactMap { item -> [String: Any]? in
            switch item {
            case .user(let content):
                return ["role": "user", "content": content.map { part -> [String: Any] in
                    switch part {
                    case .text(let text): ["type": "input_text", "text": text]
                    case .image(let png): ["type": "input_image", "image_url": Self.dataURL(png)]
                    }
                }]
            case .assistant(let text):
                return ["role": "assistant", "content": [["type": "output_text", "text": text]]]
            case .toolCall(let id, let name, let arguments):
                return ["type": "function_call", "call_id": id, "name": name, "arguments": arguments]
            case .toolResult(let id, let output):
                return ["type": "function_call_output", "call_id": id, "output": output]
            case .reasoning(let data):
                guard let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      item["type"] as? String == "reasoning" else { return nil }
                return item
            }
        }
    }

    open override func makeDecoder() -> RemoteStreamDecoder { Decoder(api: self) }

    final class Decoder: RemoteStreamDecoder {
        let api: ResponsesAPI
        init(api: ResponsesAPI) { self.api = api }

        override func decode(_ event: ServerSentEvent) throws -> [RemoteEvent] {
            let object = try Self.object(event.data)
            switch object["type"] as? String ?? event.event {
            case "response.output_text.delta":
                return (object["delta"] as? String).map { [.text($0)] } ?? []
            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                return (object["delta"] as? String).map { [.reasoningText($0)] } ?? []
            case "response.output_item.done":
                guard let item = object["item"] as? [String: Any] else { return [] }
                switch item["type"] as? String {
                case "function_call":
                    guard let id = item["call_id"] as? String, let name = item["name"] as? String else {
                        throw RemoteModelError.invalidStream("tool call without an id or name")
                    }
                    return [.toolCall(id: id, name: name, arguments: item["arguments"] as? String ?? "{}")]
                case "reasoning":
                    guard item["encrypted_content"] is String else { return [] }
                    let replay = item.filter { ["type", "id", "encrypted_content", "summary"].contains($0.key) }
                    return [.reasoning(try JSONSerialization.data(withJSONObject: replay, options: [.sortedKeys]))]
                default: return []
                }
            case "response.completed", "response.incomplete":
                guard let usage = (object["response"] as? [String: Any])?["usage"] as? [String: Any] else { return [] }
                return [.usage(RemoteUsage(inputTokens: usage["input_tokens"] as? Int ?? 0,
                    cachedInputTokens: (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0,
                    outputTokens: usage["output_tokens"] as? Int ?? 0,
                    reasoningTokens: (usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0))]
            case "error":
                throw failure(object["error"] as? [String: Any] ?? object)
            case "response.failed":
                throw failure((object["response"] as? [String: Any])?["error"] as? [String: Any] ?? [:])
            default:
                return []
            }
        }

        private func failure(_ error: [String: Any]) -> Error {
            let message = error["message"] as? String ?? "The response failed."
            return RemoteAPI.overflow(code: error["code"] as? String, message: message)
                ?? RemoteModelError.provider(status: 200, message: message)
        }
    }
}

/// Chat Completions, which most OpenAI-compatible providers implement.
open class ChatCompletionsAPI: RemoteAPI {
    open override var path: String { "chat/completions" }

    open override func body(for request: RemoteRequest) throws -> [String: Any] {
        var body: [String: Any] = ["model": request.model, "stream": true, "stream_options": ["include_usage": true],
                                   "messages": try messages(request)]
        if request.toolChoice != .none, !request.tools.isEmpty {
            body["tools"] = try request.tools.map { tool in
                ["type": "function", "function": ["name": tool.name, "description": tool.description,
                                                  "parameters": try Self.json(tool.parameters)] as [String: Any]] as [String: Any]
            }
            if request.toolChoice == .required { body["tool_choice"] = "required" }
        }
        if let maximum = request.maximumOutputTokens { body["max_completion_tokens"] = maximum }
        if let effort = request.effort { body.merge(reasoningFields(effort: effort)) { $1 } }
        if let schema = request.schema {
            body["response_format"] = ["type": "json_schema",
                                       "json_schema": ["name": schema.name, "schema": try Self.json(schema.json), "strict": false] as [String: Any]]
        }
        return body
    }

    /// How the effort is asked for.
    open func reasoningFields(effort: String) -> [String: Any] { ["reasoning_effort": effort] }

    /// What an assistant message carries of the reasoning that preceded it.
    open func assistantFields(reasoning: Data) -> [String: Any] { [:] }

    open func messages(_ request: RemoteRequest) throws -> [[String: Any]] {
        var messages: [[String: Any]] = request.instructions.map { [["role": "developer", "content": $0]] } ?? []
        var reasoning: Data?
        func assistant(_ message: [String: Any]) {
            messages.append(message.merging(reasoning.map(assistantFields(reasoning:)) ?? [:]) { $1 })
            reasoning = nil
        }
        for item in request.items {
            switch item {
            case .user(let content):
                messages.append(["role": "user", "content": content.map { part -> [String: Any] in
                    switch part {
                    case .text(let text): ["type": "text", "text": text]
                    case .image(let png): ["type": "image_url", "image_url": ["url": Self.dataURL(png)]]
                    }
                }])
            case .assistant(let text):
                assistant(["role": "assistant", "content": text])
            case .toolCall(let id, let name, let arguments):
                let call: [String: Any] = ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
                // Calls made together belong to one assistant message.
                if reasoning == nil, var last = messages.last, last["role"] as? String == "assistant",
                   var calls = last["tool_calls"] as? [[String: Any]] {
                    calls.append(call)
                    last["tool_calls"] = calls
                    messages[messages.count - 1] = last
                } else {
                    assistant(["role": "assistant", "content": NSNull(), "tool_calls": [call]])
                }
            case .toolResult(let id, let output):
                messages.append(["role": "tool", "tool_call_id": id, "content": output])
            case .reasoning(let data):
                reasoning = data
            }
        }
        return messages
    }

    open override func makeDecoder() -> RemoteStreamDecoder { Decoder() }

    final class Decoder: RemoteStreamDecoder {
        private var calls: [Int: (id: String, name: String, arguments: String)] = [:]
        /// Gateways stream `reasoning_details` in pieces, keyed by `index`.
        private var details: [Int: [String: Any]] = [:]

        override func decode(_ event: ServerSentEvent) throws -> [RemoteEvent] {
            if event.data == "[DONE]" { return try finish() }
            let object = try Self.object(event.data)
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "The response failed."
                throw RemoteAPI.overflow(code: error["code"] as? String, message: message)
                    ?? RemoteModelError.provider(status: 200, message: message)
            }
            var events: [RemoteEvent] = []
            for choice in object["choices"] as? [[String: Any]] ?? [] {
                let delta = choice["delta"] as? [String: Any] ?? [:]
                if let reasoning = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String, !reasoning.isEmpty {
                    events.append(.reasoningText(reasoning))
                }
                for detail in delta["reasoning_details"] as? [[String: Any]] ?? [] {
                    let index = detail["index"] as? Int ?? details.count
                    var merged = details[index] ?? [:]
                    for (key, value) in detail {
                        if ["text", "summary", "data"].contains(key), let piece = value as? String, let earlier = merged[key] as? String {
                            merged[key] = earlier + piece
                        } else { merged[key] = value }
                    }
                    details[index] = merged
                }
                if let text = delta["content"] as? String, !text.isEmpty { events.append(.text(text)) }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = call["index"] as? Int ?? 0
                    let function = call["function"] as? [String: Any] ?? [:]
                    var pending = calls[index] ?? (id: "", name: "", arguments: "")
                    if let id = call["id"] as? String, !id.isEmpty { pending.id = id }
                    if let name = function["name"] as? String, !name.isEmpty { pending.name = name }
                    pending.arguments += function["arguments"] as? String ?? ""
                    calls[index] = pending
                }
                if choice["finish_reason"] is String { events += try flushCalls() }
            }
            if let usage = object["usage"] as? [String: Any] {
                events.append(.usage(RemoteUsage(inputTokens: usage["prompt_tokens"] as? Int ?? 0,
                    cachedInputTokens: (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0,
                    outputTokens: usage["completion_tokens"] as? Int ?? 0,
                    reasoningTokens: (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0)))
            }
            return events
        }

        override func finish() throws -> [RemoteEvent] { try flushCalls() }

        /// Reasoning first, so it is replayed ahead of the calls it led to.
        private func flushCalls() throws -> [RemoteEvent] {
            var events: [RemoteEvent] = []
            if !details.isEmpty {
                let ordered = details.keys.sorted().map { details[$0]! }
                events.append(.reasoning(try JSONSerialization.data(withJSONObject: ["reasoning_details": ordered], options: [.sortedKeys])))
                details = [:]
            }
            defer { calls = [:] }
            return events + (try calls.keys.sorted().map { index in
                let call = calls[index]!
                guard !call.id.isEmpty, !call.name.isEmpty else { throw RemoteModelError.invalidStream("tool call without an id or name") }
                return .toolCall(id: call.id, name: call.name, arguments: call.arguments.isEmpty ? "{}" : call.arguments)
            })
        }
    }
}

/// OpenRouter and Vercel AI Gateway: Chat Completions with a `reasoning`
/// object, and `reasoning_details` that must return unchanged on the
/// assistant message they came with, or the model loses its place between tool calls.
open class GatewayChatAPI: ChatCompletionsAPI {
    open override func reasoningFields(effort: String) -> [String: Any] { ["reasoning": ["effort": effort]] }

    open override func assistantFields(reasoning: Data) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: reasoning) as? [String: Any],
              let details = object["reasoning_details"] as? [[String: Any]] else { return [:] }
        return ["reasoning_details": details]
    }
}

open class OpenRouterChatAPI: GatewayChatAPI {
    open override func headers(apiKey: String) -> [String: String] {
        super.headers(apiKey: apiKey).merging(["X-Title": "Noodle"]) { $1 }
    }
}

public struct RemoteHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    /// Body lines without their line breaks, blank lines included.
    public let lines: AsyncThrowingStream<String, Error>

    public init(status: Int, headers: [String: String], lines: AsyncThrowingStream<String, Error>) {
        self.status = status
        self.headers = headers
        self.lines = lines
    }
}

public protocol RemoteTransport: Sendable {
    func send(_ request: URLRequest) async throws -> RemoteHTTPResponse
}

public struct URLSessionRemoteTransport: RemoteTransport {
    private let session: URLSession
    /// Nothing is cached on disk: responses are private, and the bot's sandbox has no cache folder.
    public init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    public func send(_ request: URLRequest) async throws -> RemoteHTTPResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteModelError.invalidStream("not an HTTP response") }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
            if let key = field.key as? String, let value = field.value as? String { result[key] = value }
        }
        // AsyncBytes.lines drops blank lines, which end server-sent events.
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    var line = Data()
                    for try await byte in bytes {
                        if byte == 10 {
                            if line.last == 13 { line.removeLast() }
                            continuation.yield(String(decoding: line, as: UTF8.self))
                            line.removeAll(keepingCapacity: true)
                        } else { line.append(byte) }
                    }
                    if !line.isEmpty { continuation.yield(String(decoding: line, as: UTF8.self)) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return RemoteHTTPResponse(status: http.statusCode, headers: headers, lines: lines)
    }
}

/// Sends one request for one account's model and streams back its events.
public struct RemoteClient: Sendable {
    public let provider: RemoteProvider
    public let model: RemoteModelInfo
    private let apiKey: String
    private let transport: any RemoteTransport

    public init(provider: RemoteProvider, model: RemoteModelInfo, apiKey: String,
                transport: any RemoteTransport = URLSessionRemoteTransport()) {
        self.provider = provider
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
    }

    public func stream(_ request: RemoteRequest) -> AsyncThrowingStream<RemoteEvent, Error> {
        let provider = provider, model = model, apiKey = apiKey, transport = transport
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = request
                    request.model = model.id
                    let api = provider.api(for: model)
                    let response = try await transport.send(api.urlRequest(for: request, baseURL: provider.baseURL, apiKey: apiKey))
                    guard response.status == 200 else {
                        var body = [String]()
                        for try await line in response.lines where body.count < 1_000 { body.append(line) }
                        throw api.error(status: response.status, body: Data(body.joined(separator: "\n").utf8), headers: response.headers)
                    }
                    let decoder = api.makeDecoder()
                    var parser = ServerSentEvents()
                    for try await line in response.lines {
                        for message in parser.feed(line) {
                            for event in try decoder.decode(message) { continuation.yield(event) }
                        }
                    }
                    for message in parser.finish() {
                        for event in try decoder.decode(message) { continuation.yield(event) }
                    }
                    for event in try decoder.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
