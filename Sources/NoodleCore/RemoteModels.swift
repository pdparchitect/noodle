import Foundation
import Security

/// A remote model as a bot selects it: `remote/<provider>/<account>/<model>`.
/// The account names whose key the app hands over; the provider and model are
/// checked against Noodle's own list before anything is sent.
public struct RemoteModelID: Hashable, Sendable {
    public let providerID: String
    public let accountID: UUID
    public let modelID: String

    public init(providerID: String, accountID: UUID, modelID: String) {
        self.providerID = providerID
        self.accountID = accountID
        self.modelID = modelID
    }

    public init?(_ string: String) {
        let parts = string.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "remote", let account = UUID(uuidString: parts[2]),
              parts[2] == parts[2].lowercased(), Self.validPart(parts[1], separators: ""),
              Self.validPart(parts[3], separators: "/") else { return nil }
        self.init(providerID: parts[1], accountID: account, modelID: parts[3])
    }

    public var rawValue: String { "remote/\(providerID)/\(accountID.uuidString.lowercased())/\(modelID)" }

    /// The model, when Noodle still offers it.
    public var model: RemoteModelInfo? { RemoteProviders.provider(id: providerID)?.model(id: modelID) }

    /// Whether a bot may select it. A server's own models are known only to the app.
    public var isOffered: Bool {
        guard let provider = RemoteProviders.provider(id: providerID) else { return false }
        return provider.keepsModelsOnAccount || provider.model(id: modelID) != nil
    }

    /// Gateways name models `vendor/model`, so only the model part may contain a slash.
    private static func validPart(_ value: String, separators: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.hasPrefix("/") && !value.hasSuffix("/")
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-._:\(separators)".unicodeScalars.contains($0) }
    }
}

/// What Noodle knows about a model it offers. Only models with tool calling
/// are listed: a bot does all of its work through tools.
public struct RemoteModelInfo: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    /// The most input the provider accepts, in its tokens.
    public let contextSize: Int
    public let maximumOutputTokens: Int
    public let supportsImages: Bool
    public let efforts: [HarnessEffort]
    public let defaultEffort: String

    public init(id: String, displayName: String, contextSize: Int, maximumOutputTokens: Int,
                supportsImages: Bool, efforts: [HarnessEffort], defaultEffort: String) {
        self.id = id
        self.displayName = displayName
        self.contextSize = contextSize
        self.maximumOutputTokens = maximumOutputTokens
        self.supportsImages = supportsImages
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }

    /// Reasoning levels as providers name them, in the order a picker offers them.
    public static func efforts(_ ids: String...) -> [HarnessEffort] { efforts(ids) }

    /// Every level a provider may name, from least to most reasoning.
    public static let effortLevels = ["none", "low", "medium", "high", "xhigh", "max"]

    public static func efforts(_ ids: [String]) -> [HarnessEffort] {
        let descriptions = [
            "none": "No reasoning, fastest replies.", "low": "Faster responses with less reasoning.",
            "medium": "Balanced reasoning.", "high": "More thorough reasoning.",
            "xhigh": "Extended reasoning for difficult work.", "max": "Maximum available reasoning effort."
        ]
        return ids.map { HarnessEffort(id: $0, description: descriptions[$0] ?? $0) }
    }

    /// Where a person describing a server's model starts.
    public static func custom(id: String, contextSize: Int = 32_768, maximumOutputTokens: Int = 8_192) -> RemoteModelInfo {
        RemoteModelInfo(id: id, displayName: id, contextSize: contextSize, maximumOutputTokens: maximumOutputTokens,
                        supportsImages: false, efforts: [], defaultEffort: "")
    }

    /// How the model is described where a bot's model is chosen.
    public var summary: String {
        var details = ["\(contextSize.formatted()) token context", "Tools", "Structured output"]
        if supportsImages { details.insert("Images", at: 1) }
        if !efforts.isEmpty { details.append("Reasoning") }
        return details.joined(separator: " · ")
    }
}

/// A provider owns its model list and decides how each model is reached.
/// Subclasses override `api(for:)`, or return an API subclass, where a
/// provider or one of its models departs from the shared wire formats.
open class RemoteProvider: @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let baseURL: URL
    public let models: [RemoteModelInfo]

    public init(id: String, displayName: String, baseURL: URL, models: [RemoteModelInfo]) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.models = models
    }

    public func model(id: String) -> RemoteModelInfo? { models.first { $0.id == id } }

    open func api(for model: RemoteModelInfo) -> RemoteAPI { ChatCompletionsAPI() }

    open var requiresKey: Bool { true }

    /// Whether the models come from the server rather than from `models`.
    open var findsModels: Bool { false }

    /// Whether the person describes each model, because the server cannot.
    open var describesModels: Bool { false }

    /// Whether each account keeps its own models, which the app then hands to bots.
    public var keepsModelsOnAccount: Bool { findsModels || describesModels }

    open func findModels(apiKey: String = "", transport: any RemoteTransport = URLSessionRemoteTransport()) async throws -> [RemoteModelInfo] {
        models
    }

    /// A request that fails without a valid key.
    open var keyCheckPath: String { "models" }

    /// One cheap authenticated request, so a wrong key fails when it is added.
    open func checkKey(_ apiKey: String, transport: any RemoteTransport = URLSessionRemoteTransport()) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(keyCheckPath))
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 30
        let response = try await transport.send(request)
        guard response.status != 200 else { return }
        var body = [String]()
        for try await line in response.lines where body.count < 1_000 { body.append(line) }
        let error = (models.first.map(api(for:)) ?? ChatCompletionsAPI())
            .error(status: response.status, body: Data(body.joined(separator: "\n").utf8), headers: response.headers)
        if case .authentication(let message)? = error as? RemoteModelError {
            throw HarnessSetupError("\(displayName) rejected this API key: \(message)")
        }
        throw error
    }
}

public final class OpenAIProvider: RemoteProvider, @unchecked Sendable {
    public init() {
        let reasoning = RemoteModelInfo.efforts("low", "medium", "high", "xhigh", "max")
        let optional = RemoteModelInfo.efforts("none", "low", "medium", "high", "xhigh", "max")
        func model(_ id: String, _ name: String, efforts: [HarnessEffort]) -> RemoteModelInfo {
            RemoteModelInfo(id: id, displayName: name, contextSize: 922_000, maximumOutputTokens: 128_000,
                            supportsImages: true, efforts: efforts, defaultEffort: "medium")
        }
        super.init(id: "openai", displayName: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!, models: [
            model("gpt-6-astra", "GPT-6 Astra", efforts: reasoning),
            model("gpt-6.1-sol", "GPT-6.1 Sol", efforts: reasoning),
            model("gpt-6-luna", "GPT-6 Luna", efforts: optional),
            model("gpt-5.6-terra", "GPT-5.6 Terra", efforts: optional)
        ])
    }

    /// Chat Completions rejects tools together with reasoning on these models,
    /// and only Responses can carry reasoning between tool calls.
    public override func api(for model: RemoteModelInfo) -> RemoteAPI { ResponsesAPI() }
}

/// GLM, DeepSeek and Qwen, newest generation, as both gateways offer them.
/// Each gateway names them its own way and has its own limits.
private struct GatewayModel {
    let name: String
    let images: Bool
    let efforts: [HarnessEffort]
    let defaultEffort: String

    static let all = [
        GatewayModel(name: "GLM-5.3", images: false, efforts: RemoteModelInfo.efforts("low", "high", "max"), defaultEffort: "high"),
        GatewayModel(name: "GLM-5.3 Flash", images: true, efforts: RemoteModelInfo.efforts("low", "high", "max"), defaultEffort: "high"),
        GatewayModel(name: "DeepSeek V4 Pro", images: false, efforts: RemoteModelInfo.efforts("none", "low", "high", "max"), defaultEffort: "high"),
        GatewayModel(name: "DeepSeek V4.1 Flash", images: true, efforts: RemoteModelInfo.efforts("none", "low", "high", "max"), defaultEffort: "high"),
        GatewayModel(name: "Qwen3.8 Max Prime", images: true, efforts: RemoteModelInfo.efforts("low", "medium", "xhigh"), defaultEffort: "medium"),
        GatewayModel(name: "Qwen3.8 Flash", images: true, efforts: RemoteModelInfo.efforts("low", "medium", "xhigh"), defaultEffort: "medium")
    ]

    /// Identifiers and context/output limits, in the order of `all`.
    static func models(_ listed: [(id: String, context: Int, output: Int)]) -> [RemoteModelInfo] {
        zip(all, listed).map { model, listed in
            RemoteModelInfo(id: listed.id, displayName: model.name, contextSize: listed.context, maximumOutputTokens: listed.output,
                            supportsImages: model.images, efforts: model.efforts, defaultEffort: model.defaultEffort)
        }
    }
}

public final class OpenRouterProvider: RemoteProvider, @unchecked Sendable {
    public init() {
        super.init(id: "openrouter", displayName: "OpenRouter", baseURL: URL(string: "https://openrouter.ai/api/v1")!,
                   models: GatewayModel.models([
                    ("z-ai/glm-5.3", 1_048_576, 131_072), ("z-ai/glm-5.3-flash", 1_048_576, 943_717),
                    ("deepseek/deepseek-v4-pro-0813", 1_048_576, 393_216), ("deepseek/deepseek-v4.1-flash", 1_048_576, 943_718),
                    ("qwen/qwen3.8-max-prime", 1_000_000, 131_072), ("qwen/qwen3.8-flash", 1_000_000, 131_072)
                   ]))
    }

    public override func api(for model: RemoteModelInfo) -> RemoteAPI { OpenRouterChatAPI() }
    public override var keyCheckPath: String { "key" }
}

public final class VercelAIGatewayProvider: RemoteProvider, @unchecked Sendable {
    public init() {
        super.init(id: "vercel", displayName: "Vercel AI Gateway", baseURL: URL(string: "https://ai-gateway.vercel.sh/v1")!,
                   models: GatewayModel.models([
                    ("zai/glm-5.3", 1_000_000, 1_000_000), ("zai/glm-5.3-flash", 1_000_000, 131_000),
                    ("deepseek/deepseek-v4-pro-0813", 1_000_000, 384_000), ("deepseek/deepseek-v4.1-flash", 1_048_576, 32_768),
                    ("alibaba/qwen3.8-max-prime", 1_000_000, 131_072), ("alibaba/qwen3.8-flash", 991_000, 128_000)
                   ]))
    }

    public override func api(for model: RemoteModelInfo) -> RemoteAPI { GatewayChatAPI() }
    public override var keyCheckPath: String { "credits" }
}

/// Ollama on this Mac, with whichever models it has pulled that can call tools.
public final class OllamaProvider: RemoteProvider, @unchecked Sendable {
    public init() {
        super.init(id: "ollama", displayName: "Ollama", baseURL: URL(string: "http://localhost:11434/v1")!, models: [])
    }

    public override func api(for model: RemoteModelInfo) -> RemoteAPI { OllamaChatAPI() }
    public override var requiresKey: Bool { false }
    public override var findsModels: Bool { true }

    public override func findModels(apiKey: String = "",
                                    transport: any RemoteTransport = URLSessionRemoteTransport()) async throws -> [RemoteModelInfo] {
        let root = baseURL.deletingLastPathComponent()
        let tags = try await object(URLRequest(url: root.appendingPathComponent("api/tags")), transport: transport)
        var found: [RemoteModelInfo] = []
        for case let name as String in (tags["models"] as? [[String: Any]] ?? []).map({ $0["name"] }) {
            // Names a model identifier cannot carry are left out.
            guard RemoteModelID("remote/\(id)/\(UUID().uuidString.lowercased())/\(name)") != nil else { continue }
            var request = URLRequest(url: root.appendingPathComponent("api/show"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name])
            let shown = try await object(request, transport: transport)
            let capabilities = shown["capabilities"] as? [String] ?? []
            guard capabilities.contains("tools") else { continue }
            let trained = (shown["model_info"] as? [String: Any])?.first { $0.key.hasSuffix(".context_length") }?.value as? Int
            // The OpenAI-compatible API cannot set the context, and past it Ollama
            // silently drops the start of the prompt. Its default depends on the
            // Mac's memory; 32K is the default from 24 GB.
            let configured = (shown["parameters"] as? String)?.split(separator: "\n")
                .first { $0.hasPrefix("num_ctx ") }.flatMap { Int($0.dropFirst(8).trimmingCharacters(in: .whitespaces)) }
            let context = configured ?? min(trained ?? 32_768, 32_768)
            let thinks = capabilities.contains("thinking")
            found.append(RemoteModelInfo(id: name, displayName: name, contextSize: context, maximumOutputTokens: min(context / 4, 8_192),
                                         supportsImages: capabilities.contains("vision"),
                                         efforts: thinks ? RemoteModelInfo.efforts("none", "low", "medium", "high") : [],
                                         defaultEffort: thinks ? "medium" : ""))
        }
        return found
    }

    private func object(_ request: URLRequest, transport: any RemoteTransport) async throws -> [String: Any] {
        var request = request
        request.timeoutInterval = 30
        let response: RemoteHTTPResponse
        do { response = try await transport.send(request) } catch let error as URLError where error.code == .cannotConnectToHost {
            throw HarnessSetupError("Ollama is not running on this Mac. Open Ollama, then try again.")
        }
        var body = [String]()
        for try await line in response.lines { body.append(line) }
        let data = Data(body.joined(separator: "\n").utf8)
        guard response.status == 200 else { throw ChatCompletionsAPI().error(status: response.status, body: data, headers: response.headers) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteModelError.invalidStream("Ollama sent something other than a JSON object")
        }
        return object
    }
}

/// Any server with an OpenAI-compatible Chat Completions API, at the account's
/// own address. Such a server names its models but cannot say what they can
/// do, so the person describes each one they add.
public final class CustomProvider: RemoteProvider, @unchecked Sendable {
    public static let id = "custom"

    public init(baseURL: URL) {
        super.init(id: Self.id, displayName: "Custom", baseURL: baseURL, models: [])
    }

    public override var requiresKey: Bool { false }
    public override var describesModels: Bool { true }

    /// An address requests can go to, or an error saying what is wrong with it.
    public static func address(_ url: URL?) throws -> URL {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false else {
            throw HarnessSetupError("Enter the server’s address, starting with http:// or https://.")
        }
        return url
    }

    /// The server's models with default details, to choose from rather than type.
    public override func findModels(apiKey: String = "",
                                    transport: any RemoteTransport = URLSessionRemoteTransport()) async throws -> [RemoteModelInfo] {
        let response = try await transport.send(modelsRequest(apiKey: apiKey))
        var body = [String]()
        for try await line in response.lines { body.append(line) }
        let data = Data(body.joined(separator: "\n").utf8)
        guard response.status == 200 else { throw ChatCompletionsAPI().error(status: response.status, body: data, headers: response.headers) }
        let listed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return listed.compactMap { row -> RemoteModelInfo? in
            guard let id = row["id"] as? String,
                  RemoteModelID("remote/\(id)/\(UUID().uuidString.lowercased())/\(id)") != nil else { return nil }
            // vLLM reports max_model_len; TensorFold and other servers
            // context_length. Without either, details stay at the defaults
            // a person adjusts by hand.
            guard let context = (row["context_length"] ?? row["max_model_len"]) as? Int, context > 0 else {
                return RemoteModelInfo.custom(id: id)
            }
            return RemoteModelInfo.custom(id: id, contextSize: context, maximumOutputTokens: min(context / 4, 8_192))
        }
    }

    /// A server without a model list is let through; only a refused key stops the account.
    public override func checkKey(_ apiKey: String, transport: any RemoteTransport = URLSessionRemoteTransport()) async throws {
        let response = try await transport.send(modelsRequest(apiKey: apiKey))
        guard [401, 403].contains(response.status) else { return }
        var body = [String]()
        for try await line in response.lines where body.count < 1_000 { body.append(line) }
        let error = ChatCompletionsAPI().error(status: response.status, body: Data(body.joined(separator: "\n").utf8), headers: response.headers)
        if case .authentication(let message)? = error as? RemoteModelError {
            throw HarnessSetupError("\(baseURL.host ?? displayName) rejected this API key: \(message)")
        }
        throw error
    }

    private func modelsRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 30
        return request
    }
}

public enum RemoteProviders {
    /// The custom entry stands for every custom server; its address is only an example.
    public static let all: [RemoteProvider] = [OpenAIProvider(), OpenRouterProvider(), VercelAIGatewayProvider(), OllamaProvider(),
                                               CustomProvider(baseURL: URL(string: "http://localhost:8000/v1")!)]
    public static func provider(id: String) -> RemoteProvider? { all.first { $0.id == id } }

    /// The provider an account reaches: a custom one only at the account's own address.
    public static func provider(id: String, baseURL: URL?) -> RemoteProvider? {
        guard id == CustomProvider.id else { return provider(id: id) }
        return baseURL.map(CustomProvider.init)
    }
}

/// One sign-in with a provider. A person can hold several with the same provider.
public struct RemoteModelAccount: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let providerID: String
    public var name: String
    public var enabledModels: [String]
    /// What the server had when last asked, for providers that find their models,
    /// or what the person described, for those that cannot.
    public var foundModels: [RemoteModelInfo]?
    /// A custom server's address.
    public var baseURL: URL?

    public var provider: RemoteProvider? { RemoteProviders.provider(id: providerID, baseURL: baseURL) }
    public var models: [RemoteModelInfo] { foundModels ?? provider?.models ?? [] }
    /// Shown beside each of the account's models, so two accounts with one provider stay apart.
    public var tag: String { "\(provider?.displayName ?? providerID) · \(name)" }
}

/// What the app hands a bot's harness with a remote model: the account's key
/// and, for a model the account keeps, what that model can do and, for a
/// custom server, where it is.
public struct RemoteModelAccess: Equatable, Sendable {
    public let apiKey: String
    public let model: RemoteModelInfo?
    public let baseURL: URL?

    public init(apiKey: String, model: RemoteModelInfo?, baseURL: URL? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
    }

    /// As it travels in `session/set_model`.
    public var wire: [String: Any] {
        var wire: [String: Any] = ["apiKey": apiKey]
        if let model, let data = try? JSONEncoder().encode(model) { wire["model"] = try? JSONSerialization.jsonObject(with: data) }
        if let baseURL { wire["baseURL"] = baseURL.absoluteString }
        return wire
    }

    public init(_ wire: [String: Any]) throws {
        guard let key = wire["apiKey"] as? String else { throw HarnessSetupError("Noodle did not pass this bot the account’s API key.") }
        apiKey = key
        model = try wire["model"].map { try JSONDecoder().decode(RemoteModelInfo.self, from: JSONSerialization.data(withJSONObject: $0)) }
        baseURL = (wire["baseURL"] as? String).flatMap(URL.init(string:))
    }
}

public protocol RemoteModelSecrets: Sendable {
    func read(_ account: UUID) throws -> String?
    func write(_ key: String, account: UUID) throws
    func delete(_ account: UUID) throws
}

/// API keys live in the login Keychain, readable by the app that saved them.
/// The app passes a key to the bot's Apple harness when a session starts.
public struct RemoteModelKeychain: RemoteModelSecrets {
    private let service = "Noodle remote model account"
    public init() {}

    private func query(_ account: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account.uuidString.lowercased()]
    }

    public func read(_ account: UUID) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw Self.failure(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ key: String, account: UUID) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query(account)
            addition[kSecValueData as String] = data
            addition[kSecAttrLabel as String] = "Noodle remote model account"
            let added = SecItemAdd(addition as CFDictionary, nil)
            guard added == errSecSuccess else { throw Self.failure(added) }
        } else if status != errSecSuccess { throw Self.failure(status) }
    }

    public func delete(_ account: UUID) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    private static func failure(_ status: OSStatus) -> HarnessSetupError {
        HarnessSetupError("macOS did not allow Noodle to use the API key (\(status)). Unlock the login keychain, then try again.")
    }
}

/// Accounts are app data; their keys are in `secrets`.
public struct RemoteModelAccountStore: Sendable {
    public let file: URL
    private let secrets: any RemoteModelSecrets

    public init(repository: URL, secrets: any RemoteModelSecrets = RemoteModelKeychain()) {
        file = repository.appendingPathComponent("RemoteModels.json")
        self.secrets = secrets
    }

    public func accounts() throws -> [RemoteModelAccount] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([RemoteModelAccount].self, from: Data(contentsOf: file))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func account(_ id: UUID) throws -> RemoteModelAccount {
        guard let account = try accounts().first(where: { $0.id == id }) else {
            throw HarnessSetupError("The account for this model was removed. Choose another model in the bot’s settings.")
        }
        return account
    }

    @discardableResult
    public func add(providerID: String, name: String, apiKey: String, models: [RemoteModelInfo]? = nil,
                    baseURL: URL? = nil) throws -> RemoteModelAccount {
        guard let provider = RemoteProviders.provider(id: providerID) else { throw HarnessSetupError("Noodle does not support this provider.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HarnessSetupError("Enter a name for the account.") }
        guard !key.isEmpty || !provider.requiresKey else { throw HarnessSetupError("Enter the account’s API key.") }
        let address = providerID == CustomProvider.id ? try CustomProvider.address(baseURL) : nil
        let account = RemoteModelAccount(id: UUID(), providerID: providerID, name: name, enabledModels: [],
                                         foundModels: provider.findsModels ? models ?? [] : provider.describesModels ? [] : nil,
                                         baseURL: address)
        if !key.isEmpty { try secrets.write(key, account: account.id) }
        try save(accounts() + [account])
        return account
    }

    public func rename(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HarnessSetupError("Enter a name for the account.") }
        try update(id) { $0.name = name }
    }

    /// A provider that needs no key also takes an empty one, removing the key.
    public func replaceKey(_ id: UUID, with apiKey: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            guard try account(id).provider?.requiresKey == false else { throw HarnessSetupError("Enter the account’s API key.") }
            try secrets.delete(id)
        } else {
            _ = try account(id)
            try secrets.write(key, account: id)
        }
    }

    public func setModel(_ modelID: String, enabled: Bool, account id: UUID) throws {
        let account = try account(id)
        guard account.models.contains(where: { $0.id == modelID }) else { throw HarnessSetupError("Noodle does not offer this model.") }
        try update(id) { account in
            account.enabledModels.removeAll { $0 == modelID }
            if enabled { account.enabledModels.append(modelID) }
        }
    }

    public func setFoundModels(_ models: [RemoteModelInfo], account id: UUID) throws {
        try update(id) { $0.foundModels = models }
    }

    /// Adds a model the person described, or replaces the one it was edited from,
    /// and offers it to bots.
    public func saveModel(_ model: RemoteModelInfo, replacing previous: String? = nil, account id: UUID) throws {
        let account = try account(id)
        guard account.provider?.describesModels == true else { throw HarnessSetupError("Noodle describes this provider’s models itself.") }
        guard RemoteModelID("remote/\(account.providerID)/\(id.uuidString.lowercased())/\(model.id)") != nil else {
            throw HarnessSetupError("Enter the model’s ID as the server names it, without spaces.")
        }
        guard model.contextSize > 0, model.maximumOutputTokens > 0 else { throw HarnessSetupError("Enter the model’s context and output limits.") }
        guard model.maximumOutputTokens <= model.contextSize else { throw HarnessSetupError("The output limit cannot be larger than the context.") }
        guard model.efforts.isEmpty ? model.defaultEffort.isEmpty : model.efforts.contains(where: { $0.id == model.defaultEffort }) else {
            throw HarnessSetupError("Choose a default reasoning level from the ones the model supports.")
        }
        guard model.id == previous || !account.models.contains(where: { $0.id == model.id }) else {
            throw HarnessSetupError("\(account.name) already has \(model.id).")
        }
        let name = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = RemoteModelInfo(id: model.id, displayName: name.isEmpty ? model.id : name, contextSize: model.contextSize,
                                    maximumOutputTokens: model.maximumOutputTokens, supportsImages: model.supportsImages,
                                    efforts: model.efforts, defaultEffort: model.defaultEffort)
        try update(id) { account in
            var models = account.foundModels ?? []
            if let index = models.firstIndex(where: { $0.id == previous }) { models[index] = saved } else { models.append(saved) }
            account.foundModels = models
            account.enabledModels.removeAll { $0 == previous || $0 == saved.id }
            account.enabledModels.append(saved.id)
        }
    }

    public func removeModel(_ modelID: String, account id: UUID) throws {
        guard try account(id).provider?.describesModels == true else { throw HarnessSetupError("Noodle describes this provider’s models itself.") }
        try update(id) { account in
            account.foundModels?.removeAll { $0.id == modelID }
            account.enabledModels.removeAll { $0 == modelID }
        }
    }

    public func remove(_ id: UUID) throws {
        try save(accounts().filter { $0.id != id })
        try secrets.delete(id)
    }

    public func apiKey(for id: UUID) throws -> String {
        guard try account(id).provider?.requiresKey ?? true else { return try secrets.read(id) ?? "" }
        guard let key = try secrets.read(id), !key.isEmpty else {
            throw HarnessSetupError("The API key for this account is missing. Add it again in Settings › Harnesses › Apple Intelligence › Remote Models.")
        }
        return key
    }

    public func access(for id: RemoteModelID) throws -> RemoteModelAccess {
        let account = try account(id.accountID)
        guard let provider = account.provider, provider.keepsModelsOnAccount else {
            return RemoteModelAccess(apiKey: try apiKey(for: account.id), model: nil)
        }
        guard let model = account.models.first(where: { $0.id == id.modelID }) else {
            throw HarnessSetupError("\(id.modelID) is no longer on \(account.tag). Choose another model in the bot’s settings.")
        }
        return RemoteModelAccess(apiKey: try apiKey(for: account.id), model: model, baseURL: account.baseURL)
    }

    /// The enabled models of every account, as a bot's model picker lists them.
    public func harnessModels() throws -> [HarnessModel] {
        try accounts().flatMap { account -> [HarnessModel] in
            guard let provider = account.provider else { return [] }
            return account.models.filter { account.enabledModels.contains($0.id) }.map { model in
                HarnessModel(id: RemoteModelID(providerID: provider.id, accountID: account.id, modelID: model.id).rawValue,
                             displayName: model.displayName, description: model.summary, supportedEfforts: model.efforts,
                             defaultEffort: model.defaultEffort, isDefault: false, tag: account.tag)
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout RemoteModelAccount) -> Void) throws {
        var accounts = try accounts()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { _ = try account(id); return }
        change(&accounts[index])
        try save(accounts)
    }

    private func save(_ accounts: [RemoteModelAccount]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(encoder.encode(accounts), to: file)
    }
}

extension AppleHarnessInspection {
    /// Remote models run through the same custom-model support as local ones,
    /// so they need macOS 27, but not Apple Intelligence.
    public func adding(remote: [HarnessModel]) -> AppleHarnessInspection {
        guard localModelsSupported == true, !remote.isEmpty else { return self }
        var models = self.models + remote
        if unavailableReason != nil { models.removeAll { $0.id == "default" } }
        return .init(models: models, unavailableReason: models.isEmpty ? unavailableReason : nil,
                     version: version, localModelsSupported: localModelsSupported)
    }
}
