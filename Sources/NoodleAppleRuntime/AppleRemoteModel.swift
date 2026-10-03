import Foundation
import NoodleCore

/// What the app hands the harness with a remote model selection. The key
/// stays in this process's memory; it is never written to the workspace.
public struct AppleRemoteAccess: Sendable {
    public let apiKey: String
    public let effort: String?
    /// A model found on a server; Noodle's own list describes the rest.
    public let model: RemoteModelInfo?

    public init(apiKey: String, effort: String?, model: RemoteModelInfo? = nil) {
        self.apiKey = apiKey
        self.effort = effort
        self.model = model
    }
}

#if canImport(FoundationModels, _version: 2)
import CoreGraphics
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

/// A provider's model behind the Foundation Models custom-model interface,
/// so remote models get the same tools, history and recovery as local ones.
@available(macOS 27, *)
struct AppleRemoteModel: LanguageModel {
    let client: RemoteClient
    let effort: String?
    let calibration: AppleRemoteCalibration

    var executorConfiguration: String { client.provider.id + "/" + client.model.id }

    var capabilities: LanguageModelCapabilities {
        var capabilities: [LanguageModelCapabilities.Capability] = [.toolCalling, .guidedGeneration]
        if client.model.supportsImages { capabilities.append(.vision) }
        if !client.model.efforts.isEmpty { capabilities.append(.reasoning) }
        return .init(capabilities)
    }

    /// Before each generation, until the provider reports real counts.
    /// Serialized JSON at three bytes per token overestimates typical text.
    func count(_ request: LanguageModelExecutorGenerationRequest) async throws -> Int {
        let (entries, imageTokens) = AppleContextBudget.textAndImageBudget(Array(request.transcript))
        var bytes = try JSONEncoder().encode(Transcript(entries: entries)).count
        bytes += try request.enabledToolDefinitions.reduce(0) { $0 + (try JSONEncoder().encode($1.parameters).count) + $1.description.utf8.count }
        if let schema = request.schema { bytes += try JSONEncoder().encode(schema).count }
        return await calibration.scaled(bytes / 3) + imageTokens
    }

    struct Executor: LanguageModelExecutor {
        typealias Model = AppleRemoteModel
        init(configuration: String) {}

        func respond(to request: LanguageModelExecutorGenerationRequest, model: AppleRemoteModel,
                     streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            let remote = try AppleRemoteTranscript.request(request, model: model.client.model, effort: model.effort)
            let estimate = try await model.count(request)
            let responseID = UUID().uuidString, callsID = UUID().uuidString
            var reasoningID = UUID().uuidString
            var answered = false, called = false
            do {
                for try await event in model.client.stream(remote) {
                    switch event {
                    case .text(let text):
                        answered = true
                        await channel.send(.response(entryID: responseID, action: .appendText(text, tokenCount: 1)))
                    case .reasoningText(let text):
                        await channel.send(.reasoning(entryID: reasoningID, action: .appendText(text, tokenCount: 1)))
                    case .reasoning(let replay):
                        // Each reasoning item is its own entry, so it is replayed in place.
                        await channel.send(.reasoning(entryID: reasoningID, action: .updateSignature(replay, tokenCount: 0)))
                        reasoningID = UUID().uuidString
                    case .toolCall(let id, let name, let arguments):
                        called = true
                        await channel.send(.toolCalls(entryID: callsID, action: .toolCall(id: id, name: name,
                            action: .appendArguments(arguments, tokenCount: 1))))
                    case .usage(let usage):
                        await model.calibration.record(estimate: estimate, actual: usage.inputTokens)
                        let input = LanguageModelExecutorGenerationChannel.Usage.Input(totalTokenCount: usage.inputTokens,
                                                                                         cachedTokenCount: usage.cachedInputTokens)
                        let output = LanguageModelExecutorGenerationChannel.Usage.Output(totalTokenCount: usage.outputTokens,
                                                                                           reasoningTokenCount: usage.reasoningTokens)
                        if called && !answered {
                            await channel.send(.toolCalls(entryID: callsID, action: .updateUsage(input: input, output: output)))
                        } else {
                            await channel.send(.response(entryID: responseID, action: .updateUsage(input: input, output: output)))
                        }
                    }
                }
                // A model that already replied through a tool may end with no
                // text. The session needs an answer entry, even an empty one.
                if !answered && !called {
                    await channel.send(.response(entryID: responseID, action: .appendText("", tokenCount: 0)))
                }
            } catch let error as RemoteModelError {
                throw Self.languageModelError(error, model: model.client.model)
            }
        }

        static func languageModelError(_ error: RemoteModelError, model: RemoteModelInfo) -> Error {
            switch error {
            case .contextOverflow(let count):
                return LanguageModelError.contextSizeExceeded(.init(contextSize: model.contextSize, tokenCount: count ?? 0,
                                                                     debugDescription: error.localizedDescription))
            case .rateLimited(let retry):
                return LanguageModelError.rateLimited(.init(resetDate: retry.map { Date(timeIntervalSinceNow: $0) },
                                                             debugDescription: error.localizedDescription))
            default:
                return error
            }
        }
    }
}

/// The provider's own input counts correct the byte estimate for later requests.
@available(macOS 27, *)
actor AppleRemoteCalibration {
    private var ratio = 1.0

    func scaled(_ estimate: Int) -> Int { Int((Double(estimate) * ratio).rounded(.up)) }

    func record(estimate: Int, actual: Int) {
        guard estimate > 0, actual > 0 else { return }
        // Never fall far below the estimate: one short request must not let a long one through.
        ratio = min(4, max(0.5, (ratio + Double(actual) / Double(estimate)) / 2))
    }
}

@available(macOS 27, *)
enum AppleRemoteTranscript {
    static func request(_ request: LanguageModelExecutorGenerationRequest, model: RemoteModelInfo, effort: String?) throws -> RemoteRequest {
        var instructions: [String] = []
        var items: [RemoteItem] = []
        for entry in request.transcript {
            switch entry {
            case .instructions(let entry):
                if let text = text(entry.segments) { instructions.append(text) }
            case .prompt(let prompt):
                var content: [RemoteContent] = []
                for segment in prompt.segments {
                    switch segment {
                    case .text(let text): content.append(.text(text.content))
                    case .structure(let structure): content.append(.text(structure.content.jsonString))
                    case .attachment(let attachment):
                        guard case .image(let image) = attachment.content else { continue }
                        guard model.supportsImages else {
                            throw LanguageModelError.unsupportedCapability(.init(capability: .vision,
                                debugDescription: "\(model.displayName) cannot view images."))
                        }
                        content.append(.image(try png(image.cgImage)))
                    @unknown default: continue
                    }
                }
                if !content.isEmpty { items.append(.user(content)) }
            case .response(let response):
                if let text = text(response.segments) { items.append(.assistant(text)) }
            case .reasoning(let reasoning):
                if let signature = reasoning.signature { items.append(.reasoning(signature)) }
            case .toolCalls(let calls):
                items += calls.map { .toolCall(id: $0.id, name: $0.toolName, arguments: $0.arguments.jsonString) }
            case .toolOutput(let output):
                items.append(.toolResult(id: output.id, output: text(output.segments) ?? ""))
            @unknown default:
                continue
            }
        }
        let mode = request.generationOptions.toolCallingMode
        let choice: RemoteToolChoice = request.enabledToolDefinitions.isEmpty || mode == .disallowed ? .none
            : mode == .required ? .required : .auto
        let tools = try request.enabledToolDefinitions.map { tool in
            RemoteTool(name: tool.name, description: tool.description, parameters: try JSONEncoder().encode(tool.parameters))
        }
        return RemoteRequest(model: model.id, instructions: instructions.isEmpty ? nil : instructions.joined(separator: "\n\n"),
                             items: items, tools: choice == .none ? [] : tools, toolChoice: choice,
                             schema: try request.schema.map { RemoteSchema(name: "response", json: try JSONEncoder().encode($0)) },
                             maximumOutputTokens: request.generationOptions.maximumResponseTokens,
                             effort: self.effort(request.contextOptions.reasoningLevel, selected: effort, model: model))
    }

    /// The bot's chosen effort, unless this request asks for a level the model offers.
    static func effort(_ level: ContextOptions.ReasoningLevel?, selected: String?, model: RemoteModelInfo) -> String? {
        guard !model.efforts.isEmpty else { return nil }
        let offered = Set(model.efforts.map(\.id))
        let requested: String? = switch level {
        case .light: "low"
        case .moderate: "medium"
        case .deep: "high"
        case .custom(let value): value
        case nil: nil
        @unknown default: nil
        }
        if let requested, offered.contains(requested) { return requested }
        if let selected, offered.contains(selected) { return selected }
        return model.defaultEffort
    }

    private static func text(_ segments: [Transcript.Segment]) -> String? {
        let text = segments.compactMap { segment -> String? in
            switch segment {
            case .text(let text): text.content
            case .structure(let structure): structure.content.jsonString
            default: nil
            }
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw HarnessSetupError("Could not prepare an image for the model.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw HarnessSetupError("Could not prepare an image for the model.") }
        return data as Data
    }
}
#endif
