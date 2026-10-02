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

    /// Gateways name models `vendor/model`, so only the model part may contain a slash.
    private static func validPart(_ value: String, separators: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.hasPrefix("/") && !value.hasSuffix("/")
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-._:\(separators)".unicodeScalars.contains($0) }
    }
}

/// What Noodle knows about a model it offers. Only models with tool calling
/// are listed: a bot does all of its work through tools.
public struct RemoteModelInfo: Hashable, Sendable {
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
    public static func efforts(_ ids: String...) -> [HarnessEffort] {
        let descriptions = [
            "none": "No reasoning, fastest replies.", "low": "Faster responses with less reasoning.",
            "medium": "Balanced reasoning.", "high": "More thorough reasoning.",
            "xhigh": "Extended reasoning for difficult work.", "max": "Maximum available reasoning effort."
        ]
        return ids.map { HarnessEffort(id: $0, description: descriptions[$0] ?? $0) }
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

    /// A request that fails without a valid key.
    open var keyCheckPath: String { "models" }

    /// One cheap authenticated request, so a wrong key fails when it is added.
    open func checkKey(_ apiKey: String, transport: any RemoteTransport = URLSessionRemoteTransport()) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(keyCheckPath))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

public enum RemoteProviders {
    public static let all: [RemoteProvider] = [OpenAIProvider(), OpenRouterProvider(), VercelAIGatewayProvider()]
    public static func provider(id: String) -> RemoteProvider? { all.first { $0.id == id } }
}

/// One sign-in with a provider. A person can hold several with the same provider.
public struct RemoteModelAccount: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let providerID: String
    public var name: String
    public var enabledModels: [String]

    public var provider: RemoteProvider? { RemoteProviders.provider(id: providerID) }
    /// Shown beside each of the account's models, so two accounts with one provider stay apart.
    public var tag: String { "\(provider?.displayName ?? providerID) · \(name)" }
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
    public func add(providerID: String, name: String, apiKey: String) throws -> RemoteModelAccount {
        guard RemoteProviders.provider(id: providerID) != nil else { throw HarnessSetupError("Noodle does not support this provider.") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HarnessSetupError("Enter a name for the account.") }
        guard !key.isEmpty else { throw HarnessSetupError("Enter the account’s API key.") }
        let account = RemoteModelAccount(id: UUID(), providerID: providerID, name: name, enabledModels: [])
        try secrets.write(key, account: account.id)
        try save(accounts() + [account])
        return account
    }

    public func rename(_ id: UUID, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HarnessSetupError("Enter a name for the account.") }
        try update(id) { $0.name = name }
    }

    public func replaceKey(_ id: UUID, with apiKey: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw HarnessSetupError("Enter the account’s API key.") }
        _ = try account(id)
        try secrets.write(key, account: id)
    }

    public func setModel(_ modelID: String, enabled: Bool, account id: UUID) throws {
        let account = try account(id)
        guard account.provider?.model(id: modelID) != nil else { throw HarnessSetupError("Noodle does not offer this model.") }
        try update(id) { account in
            account.enabledModels.removeAll { $0 == modelID }
            if enabled { account.enabledModels.append(modelID) }
        }
    }

    public func remove(_ id: UUID) throws {
        try save(accounts().filter { $0.id != id })
        try secrets.delete(id)
    }

    public func apiKey(for id: UUID) throws -> String {
        guard let key = try secrets.read(id), !key.isEmpty else {
            throw HarnessSetupError("The API key for this account is missing. Add it again in Settings › Harnesses › Apple Intelligence › Remote Models.")
        }
        return key
    }

    /// The enabled models of every account, as a bot's model picker lists them.
    public func harnessModels() throws -> [HarnessModel] {
        try accounts().flatMap { account -> [HarnessModel] in
            guard let provider = account.provider else { return [] }
            return provider.models.filter { account.enabledModels.contains($0.id) }.map { model in
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
