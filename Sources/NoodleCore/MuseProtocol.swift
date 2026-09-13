import Foundation

/// Muse's embedded stable MSP v1 schema is the contract, not ACP.
public enum MuseProtocol {
    public static let initialize: [String: Any] = ["clientInfo": ["name": "noodle", "version": "1"]]
    public static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// MSP mutation idempotency handles must be UUIDv7, not Foundation's UUIDv4.
    public static func commandID(now: Date = Date()) -> String {
        let millis = UInt64(max(0, now.timeIntervalSince1970 * 1_000))
        var bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        for index in 0..<6 { bytes[index] = UInt8(truncatingIfNeeded: millis >> ((5 - index) * 8)) }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let chars = Array(hex)
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-")
    }

    public static func validateInitialization(_ result: [String: Any], durable: Bool) throws {
        guard let schema = result["schema"] as? [String: Any], schema["version"] as? Int == 1,
              let server = result["serverInfo"] as? [String: Any], server["name"] as? String == "muse",
              !durable || result["sessionDurability"] as? String != "ephemeral" else {
            throw HarnessSetupError("Muse Code returned an unsupported MSP session host. Update Muse and try again.")
        }
    }

    public static func models(_ result: [String: Any]) throws -> [HarnessModel] {
        guard result["providerId"] as? String == "meta", let rows = result["models"] as? [[String: Any]] else {
            throw HarnessSetupError("Muse Code returned an unsupported model catalogue.")
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard row["providerId"] as? String == "meta", let id = row["modelId"] as? String,
                  FxProtocol.validIdentifier(id), seen.insert(id).inserted else { return nil }
            return HarnessModel(id: id, displayName: row["displayLabel"] as? String ?? id,
                description: row["description"] as? String ?? "Available through Muse Code.",
                supportedEfforts: efforts.map { .init(id: $0, description: "Muse reasoning effort: \($0).") },
                defaultEffort: "high", isDefault: row["isDefault"] as? Bool == true)
        }
    }

    public static func turnParameters(sessionID: String, commandID: String, text: String, effort: String?) -> [String: Any] {
        var params: [String: Any] = ["sessionId": sessionID, "commandId": commandID,
            "ifBusy": "queue", "input": [["type": "text", "text": text]]]
        if let effort, efforts.contains(effort) { params["reasoningEffort"] = effort }
        return params
    }

    public static func turnFailureDetail(_ params: [String: Any]) -> String {
        let error = params["error"] as? [String: Any]
        let message = error?["message"] as? String ?? params["reason"] as? String ?? "The turn did not complete."
        let bounded = String(String.UnicodeScalarView(message.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(500)))
        return "Muse Code stopped: \(bounded) Retry Startup to try again. Unfinished work is preserved."
    }

    public static func retryDetail(_ params: [String: Any]) -> String? {
        guard let next = params["nextAttempt"] as? Int, let max = params["maxAttempts"] as? Int,
              let delay = params["retryDelayMs"] as? Int, next > 0, max >= next, delay >= 0 else { return nil }
        let reason = String((params["reason"] as? String ?? "Service temporarily unavailable").prefix(160))
        return "Muse: \(reason). Retry \(next)/\(max) scheduled in \(delay / 1000)s."
    }

    /// Autonomous access or the host's immutable OS sandbox may satisfy only
    /// the current offered once-only choice. Never persist approvals or bypass
    /// Muse's staged requirement; approval cannot widen the OS sandbox.
    public static func approvalParameters(_ params: [String: Any], sessionID: String?, extendedAccess: Bool,
                                          restrictedAccess: Bool = false) -> [String: Any]? {
        guard extendedAccess || restrictedAccess, let sessionID, params["sessionId"] as? String == sessionID,
              let approvalID = params["approvalId"] as? String,
              let requirement = params["currentRequirementId"] as? [String: Any],
              requirement["approvalId"] as? String == approvalID, let index = requirement["sourceIndex"] as? Int, index >= 0,
              let choices = params["availableChoices"] as? [[String: Any]],
              let choice = choices.first(where: { $0["decision"] as? String == "approved" && $0["scope"] as? String == "once" }),
              let choiceID = choice["choiceId"] as? String else { return nil }
        return ["commandId": commandID(), "sessionId": sessionID, "approvalId": approvalID,
                "requirementId": requirement, "choiceId": choiceID]
    }
}

public struct MuseInspectionResult: Codable, Sendable {
    public let executablePath: String?
    public let models: [HarnessModel]
    public let authentication: HarnessAuthenticationStatus?
    public init(executablePath: String?, models: [HarnessModel], authentication: HarnessAuthenticationStatus? = nil) {
        self.executablePath = executablePath; self.models = models
        self.authentication = authentication
    }
}
