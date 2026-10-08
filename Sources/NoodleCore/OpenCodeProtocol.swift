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

    /// The shared catalogue plus the providers a bot's own opencode.json adds,
    /// limited the way that file limits providers. Reading the file needs no
    /// OpenCode process; an unreadable file leaves the shared catalogue.
    public static func models(_ shared: [HarnessModel], configuration: Data?) -> [HarnessModel] {
        guard let configuration, configuration.count <= 1_048_576,
              let config = (try? JSONSerialization.jsonObject(with: Data(json(fromJSONC: configuration).utf8))) as? [String: Any]
        else { return shared }
        var seen = Set(shared.map(\.id))
        let providers = config["provider"] as? [String: Any] ?? [:]
        let added = providers.keys.sorted().flatMap { provider -> [HarnessModel] in
            let models = (providers[provider] as? [String: Any])?["models"] as? [String: Any] ?? [:]
            return models.keys.sorted().compactMap { model in
                let entry = models[model] as? [String: Any] ?? [:]
                let id = provider + "/" + model
                guard entry["tool_call"] as? Bool != false, validModel(id), seen.insert(id).inserted else { return nil }
                return HarnessModel(id: id, displayName: provider + "/" + ((entry["name"] as? String) ?? model),
                    description: "Set in this bot’s opencode.json.", supportedEfforts: [], defaultEffort: "", isDefault: false)
            }
        }
        let enabled = (config["enabled_providers"] as? [String]).map(Set.init)
        let disabled = Set(config["disabled_providers"] as? [String] ?? [])
        return (shared + added).filter { model in
            let provider = String(model.id.prefix { $0 != "/" })
            return enabled?.contains(provider) ?? true && !disabled.contains(provider)
        }
    }

    /// OpenCode accepts comments and trailing commas in its configuration.
    static func json(fromJSONC data: Data) -> String {
        func outsideStrings(_ text: String, _ visit: (Character, inout Substring, inout String) -> Void) -> String {
            var output = "", string = false, escaped = false, rest = text[...]
            while let character = rest.first {
                rest = rest.dropFirst()
                if string {
                    output.append(character)
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { string = false }
                } else if character == "\"" {
                    string = true; output.append(character)
                } else {
                    visit(character, &rest, &output)
                }
            }
            return output
        }
        let uncommented = outsideStrings(String(decoding: data, as: UTF8.self)) { character, rest, output in
            if character == "/", rest.first == "/" {
                rest = rest.drop { $0 != "\n" }
            } else if character == "/", rest.first == "*" {
                rest = rest.dropFirst()
                while !rest.isEmpty, !rest.hasPrefix("*/") { rest = rest.dropFirst() }
                rest = rest.dropFirst(2)
            } else {
                output.append(character)
            }
        }
        return outsideStrings(uncommented) { character, rest, output in
            let next = rest.first { !$0.isWhitespace }
            if character != "," || (next != "}" && next != "]") { output.append(character) }
        }
    }

    public static func missingSession(_ error: [String: Any], sessionID: String) -> Bool {
        error["code"] as? Int == -32602 &&
            (error["data"] as? [String: Any])?["sessionId"] as? String == sessionID &&
            error["message"] as? String == "session not found: \(sessionID)"
    }
}
