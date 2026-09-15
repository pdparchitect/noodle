import Foundation
import FoundationModels
import ImageIO
import NoodleCore
#if canImport(FoundationModels, _version: 2)
import MLXFoundationModels
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

@available(macOS 26, *)
struct AppleModelBackend {
    let identifier: String
    let contextSize: Int
    let supportsImages: Bool
    let responseTokens: Int
    #if canImport(FoundationModels, _version: 2)
    // The box keeps macOS 27 types out of the macOS 26 stored-property layout.
    private let local: Any?
    #endif

    static func prepare(identifier: String?, workspace: URL) async throws -> Self {
        let id = identifier ?? "default"
        if id == "default" {
            if let reason = AppleModel.systemUnavailableReason { throw HarnessSetupError(reason) }
            #if canImport(FoundationModels, _version: 2)
            if #available(macOS 27, *) {
                await AppleMLXCache.shared.evict()
                return .init(identifier: id, contextSize: max(4_096, SystemLanguageModel.default.contextSize),
                             supportsImages: SystemLanguageModel.default.capabilities.contains(.vision), responseTokens: 768, local: nil)
            }
            return .init(identifier: id, contextSize: 4_096, supportsImages: false, responseTokens: 768, local: nil)
            #else
            return .init(identifier: id, contextSize: 4_096, supportsImages: false, responseTokens: 768)
            #endif
        }
        #if canImport(FoundationModels, _version: 2)
        if #available(macOS 27, *) {
            let layout = try AgentStorageLayout.containing(workspace)
            let repository = layout.package.deletingLastPathComponent().deletingLastPathComponent()
            let store = AppleLocalModelStore(repository: repository)
            let descriptor = try store.model(id: id)
            let model = try await AppleMLXCache.shared.load(descriptor, store: store)
            try Task.checkCancellation()
            return .init(identifier: id, contextSize: min(descriptor.contextSize, 32_768), supportsImages: false,
                         responseTokens: min(2_048, descriptor.contextSize / 4), local: model)
        }
        #endif
        throw HarnessSetupError("Local models require macOS 27 and a Noodle build made with the macOS 27 SDK.")
    }

    func session(tools: [any FoundationModels.Tool] = [], instructions: String, entries: [Transcript.Entry] = [],
                 requireTool: Bool = false) -> LanguageModelSession {
        #if canImport(FoundationModels, _version: 2)
        if #available(macOS 27, *) {
            let model: any FoundationModels.LanguageModel = (local as? MLXLanguageModel).map { $0 as any FoundationModels.LanguageModel }
                ?? SystemLanguageModel.default
            return LanguageModelSession(profile: AppleTurnProfile(model: model, tools: tools,
                instructions: instructions, requireTool: requireTool), history: entries)
        }
        #endif
        let seed = LanguageModelSession(model: .default, tools: tools, instructions: instructions)
        guard !entries.isEmpty else { return seed }
        return LanguageModelSession(model: .default, tools: tools, transcript: Transcript(entries: Array(seed.transcript) + entries))
    }

    func prompt(_ text: String, images: [URL]) throws -> Prompt {
        guard !images.isEmpty else { return Prompt(text) }
        guard supportsImages else { throw HarnessSetupError("The selected model cannot read images. Select an Apple model with image support on macOS 27.") }
        #if canImport(FoundationModels, _version: 2)
        if #available(macOS 27, *) {
            // Decode within the helper's workspace grant. Passing a file URL
            // through the model service can leave it unable to read the image.
            let attachments = try images.enumerated().map { index, url -> Attachment<ImageAttachmentContent> in
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2_048]
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    throw HarnessSetupError("Could not decode image \(url.lastPathComponent). Use a supported image file.")
                }
                return Attachment(image).label("Image \(index + 1)")
            }
            return Prompt {
                text
                for attachment in attachments { attachment }
            }
        }
        #endif
        return Prompt(text)
    }

    func tokenCount(_ text: String) async throws -> Int {
        #if canImport(FoundationModels, _version: 2)
        if #available(macOS 27, *), let model = local as? MLXLanguageModel {
            let container = try await model.loadContainer()
            return await container.tokenizer.encode(text: text).count
        }
        #endif
        if #available(macOS 26.4, *) { return try await SystemLanguageModel.default.tokenCount(for: text) }
        return text.utf8.count
    }

    func recentEntries(_ saved: AppleConversationSession?, prompt: String, instructions: String,
                       tools: [any FoundationModels.Tool]) async throws -> [Transcript.Entry] {
        guard let saved else { return [] }
        var entries = saved.recentEntries(reservingPromptBytes: prompt.utf8.count)
        if #available(macOS 26.4, *), identifier == "default" {
            let fixed = try await SystemLanguageModel.default.tokenCount(for: prompt)
                + SystemLanguageModel.default.tokenCount(for: Instructions(instructions))
                + SystemLanguageModel.default.tokenCount(for: tools)
            while !entries.isEmpty {
                let history = try await SystemLanguageModel.default.tokenCount(for: entries)
                if fixed + history + responseTokens + 256 <= contextSize { break }
                entries.removeFirst()
                while let first = entries.first {
                    if case .prompt = first { break }
                    entries.removeFirst()
                }
            }
        }
        return entries
    }
}

#if canImport(FoundationModels, _version: 2)
@available(macOS 27, *)
private enum AppleToolCalledKey: SessionPropertyKey { static let defaultValue = false }

@available(macOS 27, *)
private extension SessionPropertyValues {
    var appleToolCalled: Bool {
        get { self[AppleToolCalledKey.self] }
        set { self[AppleToolCalledKey.self] = newValue }
    }
}

@available(macOS 27, *)
private struct AppleTurnProfile: LanguageModelSession.DynamicProfile {
    let model: any FoundationModels.LanguageModel
    let tools: [any FoundationModels.Tool]
    let instructions: String
    let requireTool: Bool
    @SessionProperty(\.appleToolCalled) private var called

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions(instructions)
            tools
        }
        .model(model)
        .toolCallingMode(tools.isEmpty ? .disallowed : (requireTool && !called ? .required : .allowed))
        .onPrompt { called = false }
        // Required mode must end after a call, or the framework keeps calling tools.
        .onToolOutput { called = true }
    }
}

@available(macOS 27, *)
private actor AppleMLXCache {
    static let shared = AppleMLXCache()
    private var selected: MLXLanguageModel?
    private var selectedID: String?

    func evict() async {
        let previous = selected
        selected = nil
        selectedID = nil
        await previous?.evict()
    }

    func load(_ descriptor: AppleLocalModel, store: AppleLocalModelStore) async throws -> MLXLanguageModel {
        if selectedID == descriptor.id, let selected { return selected }
        await evict()
        try store.validateResources(id: descriptor.id)
        let folder = try store.folder(id: descriptor.id)
        var capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration, .toolCalling]
        if descriptor.modelType.hasPrefix("qwen3") { capabilities.append(.reasoning) }
        let model = MLXLanguageModel(configuration: ModelConfiguration(directory: folder), capabilities: capabilities,
            weightsLocation: { _ in folder }, load: { _, _ in
                try await LLMModelFactory.shared.loadContainer(from: folder, using: AppleTokenizerLoader())
            })
        do {
            try await model.preload()
            try Task.checkCancellation()
        } catch {
            await model.evict()
            throw error
        }
        selected = model
        selectedID = descriptor.id
        return model
    }
}

@available(macOS 27, *)
private struct AppleTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        AppleTokenizer(upstream: try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

@available(macOS 27, *)
private struct AppleTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        do { return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext) }
        catch Tokenizers.TokenizerError.missingChatTemplate { throw MLXLMCommon.TokenizerError.missingChatTemplate }
    }
}
#endif
