import Foundation

/// Antigravity's headless stream: one JSON object per line in each direction,
/// one process per conversation, one `result` event per turn.
public enum AntigravityProtocol {
    public struct TurnResult: Equatable, Sendable {
        public let succeeded: Bool
        /// The CLI's own error text, when it gave one.
        public let detail: String?
    }

    /// Headless runs cannot ask, so every tool request would otherwise be denied.
    /// A restricted bot is confined by the host's sandbox, not by these prompts.
    public static func launchArguments(conversationID: UUID?, model: String?) throws -> [String] {
        guard model.map(FxProtocol.validIdentifier) ?? true else {
            throw HarnessSetupError("Unsupported Antigravity model identifier.")
        }
        var arguments = ["--input-format", "stream-json", "--output-format", "stream-json",
                         "--dangerously-skip-permissions", "--print-timeout", "0s"]
        if let conversationID { arguments += ["--conversation", conversationID.uuidString.lowercased()] }
        if let model { arguments += ["--model", model] }
        return arguments
    }

    public static func userMessage(_ text: String) -> Data {
        let object: [String: Any] = ["event": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))! + Data([0x0A])
    }

    public static func conversationID(initialization message: [String: Any]) -> UUID? {
        guard message["event"] as? String == "init" else { return nil }
        return (message["conversation_id"] as? String).flatMap(UUID.init(uuidString:))
    }

    public static func turnResult(_ message: [String: Any]) -> TurnResult? {
        guard message["event"] as? String == "result", let result = message["result"] as? [String: Any],
              let status = result["status"] as? String else { return nil }
        let detail = (result["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TurnResult(succeeded: status == "SUCCESS", detail: detail.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// `agy models`: an identifier, a tab, and a name per line. The CLI does not
    /// say which one it would choose, so the first is offered as the default.
    public static func models(from listing: String) -> [HarnessModel] {
        var seen: Set<String> = []
        return listing.split(whereSeparator: \.isNewline).compactMap { line -> HarnessModel? in
            let fields = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, !fields[1].isEmpty, FxProtocol.validIdentifier(fields[0]),
                  seen.insert(fields[0]).inserted else { return nil }
            return HarnessModel(id: fields[0], displayName: fields[1], description: "Available through your Antigravity account.",
                                supportedEfforts: [], defaultEffort: "", isDefault: seen.count == 1)
        }
    }

    /// Only the CLI's own sign-in messages, never network, quota or model failures.
    public static func isAuthenticationFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["authentication required", "please sign in", "not logged into antigravity"].contains(where: lower.contains)
    }

    /// The Keychain item holds what the login file holds, wrapped the way the
    /// CLI's keyring library stores values on macOS.
    public static func fileLogin(fromKeychain data: Data) -> Data? {
        let prefix = Data("go-keyring-base64:".utf8)
        guard data.starts(with: prefix) else { return data.isEmpty ? nil : data }
        return Data(base64Encoded: data.dropFirst(prefix.count)).flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct AntigravityInspectionResult: Codable, Sendable {
    public let executablePath: String?
    public let authenticated: Bool
    public let models: [HarnessModel]
    public init(executablePath: String?, authenticated: Bool, models: [HarnessModel]) {
        self.executablePath = executablePath
        self.authenticated = authenticated
        self.models = models
    }
}
