import Foundation

public enum GrokProtocol {
    public static let efforts: Set<String> = ["low", "medium", "high", "xhigh"]

    /// ACP metadata is the source of truth, including model-specific efforts.
    /// Never return account metadata, tokens, machine details, or raw errors.
    public static func models(from initialization: [String: Any]) throws -> [HarnessModel] {
        guard let meta = initialization["_meta"] as? [String: Any],
              let state = meta["modelState"] as? [String: Any],
              let entries = state["availableModels"] as? [[String: Any]] else {
            throw HarnessSetupError("Grok Build returned no model catalogue.")
        }
        var seen: Set<String> = []
        return entries.compactMap { entry in
            guard let id = entry["modelId"] as? String, FxProtocol.validIdentifier(id),
                  seen.insert(id).inserted else { return nil }
            let details = entry["_meta"] as? [String: Any] ?? [:]
            var seenEfforts: Set<String> = []
            let options = (details["reasoningEfforts"] as? [[String: Any]] ?? []).compactMap { option -> HarnessEffort? in
                guard let id = option["id"] as? String, efforts.contains(id), seenEfforts.insert(id).inserted else { return nil }
                return HarnessEffort(id: id, description: option["description"] as? String ?? "")
            }
            let preferred = details["reasoningEffort"] as? String ?? ""
            return HarnessModel(id: id, displayName: entry["name"] as? String ?? id,
                                description: entry["description"] as? String ?? "Available through Grok Build.",
                                supportedEfforts: options,
                                defaultEffort: options.contains { $0.id == preferred } ? preferred : (options.first?.id ?? ""),
                                isDefault: id == state["currentModelId"] as? String)
        }
    }
}

public struct GrokInspectionResult: Codable, Sendable {
    public let executablePath: String?
    public let authenticated: Bool
    public let models: [HarnessModel]
    public init(executablePath: String?, authenticated: Bool, models: [HarnessModel]) {
        self.executablePath = executablePath
        self.authenticated = authenticated
        self.models = models
    }
}
