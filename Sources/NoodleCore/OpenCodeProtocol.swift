import Foundation

public struct OpenCodeInspectionResult: Codable, Sendable {
    public let executablePath: String?
    public let authenticated: Bool
    public let models: [HarnessModel]
}

public enum OpenCodeProtocol {
    /// The native catalogue fetch has a ten-second timeout, followed by provider reload.
    public static let catalogueRefreshWindow: TimeInterval = 12

    /// Classify only the native ACP error envelope; never expose arbitrary
    /// provider text, which can contain request or account details.
    public static func turnFailureDescription(_ error: [String: Any]) -> String {
        let recovery = "Use Kick in Settings → Harness to resume. Your unfinished work is preserved."
        guard error["code"] as? Int == -32603,
              let data = error["data"] as? [String: Any], data["service"] as? String == "session" else {
            return "OpenCode could not complete the turn. \(recovery)"
        }
        switch data["errorName"] as? String {
        case "provider.invalid-output":
            return "OpenCode's provider returned an incomplete or invalid response. \(recovery)"
        case "provider.timeout":
            return "OpenCode's model request timed out. \(recovery)"
        case "provider.transport":
            return "OpenCode's model connection failed. \(recovery)"
        case "provider.rate-limit":
            return "OpenCode's model provider is rate limiting requests. Wait before retrying. \(recovery)"
        default:
            return "OpenCode could not complete the turn. \(recovery)"
        }
    }

    public static func supportsVersion(_ value: String) -> Bool {
        guard let version = HarnessVersion(value) else { return false }
        return version >= HarnessVersion("2.0.0")! && version < HarnessVersion("3.0.0")!
    }

    public static func validModel(_ value: String) -> Bool {
        let parts = value.split(separator: "/", maxSplits: 1)
        return parts.count == 2 && FxProtocol.validIdentifier(value) && !value.contains("#")
    }

    public static func models(from data: Data, defaultIdentifier: String? = nil) throws -> [HarnessModel] {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = envelope["data"] as? [[String: Any]], rows.count <= 10_000 else {
            throw HarnessSetupError("OpenCode returned an unsupported model catalogue.")
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let provider = row["providerID"] as? String, let model = row["id"] as? String,
                  validModel(provider + "/" + model), seen.insert(provider + "/" + model).inserted,
                  (row["capabilities"] as? [String: Any])?["tools"] as? Bool != false else { return nil }
            var variants = ((row["variants"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
                .filter(FxProtocol.validIdentifier)
            if !variants.isEmpty, !variants.contains("default") { variants.append("default") }
            var efforts = Set<String>()
            return HarnessModel(id: provider + "/" + model,
                displayName: provider + "/" + ((row["name"] as? String) ?? model),
                description: "Available through OpenCode.",
                supportedEfforts: variants.filter { efforts.insert($0).inserted }.map { .init(id: $0, description: "OpenCode model variant.") },
                defaultEffort: variants.isEmpty ? "" : "default", isDefault: provider + "/" + model == defaultIdentifier)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public static func missingSession(_ error: [String: Any], sessionID: String) -> Bool {
        error["code"] as? Int == -32602 &&
            (error["data"] as? [String: Any])?["sessionId"] as? String == sessionID &&
            error["message"] as? String == "session not found: \(sessionID)"
    }
}
