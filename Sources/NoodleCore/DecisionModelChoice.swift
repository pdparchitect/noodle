import Foundation

/// The decision model a person chose, as app data: which account reaches it and
/// the model's request id. Kept next to the remote-model accounts so the choice
/// dies with the account it points at.
public struct DecisionModelChoice: Codable, Equatable, Sendable {
    public let accountID: UUID
    /// `DiscoveredDecisionModel.requestID` — the pinned spelling the server answers.
    public let modelID: String
    public let displayName: String

    public init(accountID: UUID, modelID: String, displayName: String) {
        self.accountID = accountID
        self.modelID = modelID
        self.displayName = displayName
    }
}

public struct DecisionModelChoiceStore: Sendable {
    public let file: URL

    public init(repository: URL) {
        file = repository.appendingPathComponent("DecisionModel.json")
    }

    public func load() -> DecisionModelChoice? {
        guard FileManager.default.fileExists(atPath: file.path),
            let choice = try? JSONDecoder().decode(DecisionModelChoice.self, from: Data(contentsOf: file))
        else { return nil }
        return choice
    }

    public func save(_ choice: DecisionModelChoice?) throws {
        guard let choice else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try JSONEncoder().encode(choice).write(to: file, options: .atomic)
    }
}

/// Resolves the chosen decision model to a serving: the account's provider
/// base, key and probed wire format, routed with the Mac's on-device model as
/// the text-state fallback when the account's model is unavailable.
public enum DecisionModelResolver {
    /// Throws when the account is gone, the key is missing, or the chosen model
    /// left the catalog; callers treat decision serving as unavailable.
    public static func serving(_ choice: DecisionModelChoice, accounts: RemoteModelAccountStore,
                               secrets: any RemoteModelSecrets = RemoteModelKeychain(),
                               transport: any RemoteTransport = URLSessionRemoteTransport()) async throws -> any DecisionModelServing {
        let account = try accounts.account(choice.accountID)
        guard let key = (try? secrets.read(choice.accountID)) ?? nil,
            !key.isEmpty || account.provider?.requiresKey == false else {
            throw HarnessSetupError("The decision model's account has no API key.")
        }
        let catalog = RemoteDecisionsCatalog(account: account, key: key, transport: transport)
        let models = try await catalog.decisionModels()
        guard let model = models.first(where: { $0.requestID == choice.modelID }) else {
            throw HarnessSetupError("\(choice.displayName) no longer appears in this account's decision catalog.")
        }
        return DecisionModelRouter(preferred: try await catalog.client(for: model))
    }
}
