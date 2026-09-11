import Foundation

public enum GrokProtocol {
    public static let efforts: Set<String> = ["low", "medium", "high", "xhigh"]

    /// Classify the provider's billing failure without displaying its raw payload,
    /// which can include private account or request data. ACP uses an internal
    /// JSON-RPC error with the HTTP status in `data`, not in the RPC error code.
    public static func usageLimitDescription(_ error: [String: Any]) -> String? {
        let data = error["data"] as? [String: Any] ?? [:]
        guard data["http_status"] as? Int == 402 ||
                isUsageLimitMessage(data["message"] as? String) ||
                isUsageLimitMessage(error["message"] as? String) else { return nil }
        return usageLimitDetail
    }

    /// Grok also reports terminal failures through its extended session updates
    /// before completing the prompt's JSON-RPC request.
    public static func usageLimitDescription(fromUpdate update: [String: Any]) -> String? {
        switch update["sessionUpdate"] as? String {
        case "retry_state":
            guard update["type"] as? String == "failed",
                  update["error_type"] as? String == "api",
                  isUsageLimitMessage(update["message"] as? String) else { return nil }
        case "turn_completed":
            guard update["stop_reason"] as? String == "error",
                  isUsageLimitMessage(update["agent_result"] as? String) else { return nil }
        default: return nil
        }
        return usageLimitDetail
    }

    private static let usageLimitDetail = "Grok Build's usage limit has been reached. Once usage is available again, right-click the bot and choose Kick to resume. Unfinished work is preserved."

    private static func isUsageLimitMessage(_ message: String?) -> Bool {
        message?.localizedCaseInsensitiveContains("Grok Build usage balance exhausted") == true
    }

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
