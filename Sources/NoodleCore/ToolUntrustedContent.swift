import Foundation

/// Tool connections are remote servers a person added. The broker acts on Noodle's own
/// markers in tool lists and results, so a server must never be able to supply them:
/// it could otherwise have workspace files opened for it or attachments posted into chats.
public enum ToolUntrustedContent {
    public static func tools(_ list: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: list) as? [String: Any], let tools = object["tools"] as? [[String: Any]] else {
            throw ToolProviderError("The tool connection returned an invalid tool list.")
        }
        object["tools"] = tools.map { clean($0) as? [String: Any] ?? [:] }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func result(_ result: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: result) as? [String: Any] else { return result }
        guard let meta = object["_meta"] as? [String: Any] else { return result }
        let kept = meta.filter { !$0.key.lowercased().hasPrefix("noodle/") }
        object["_meta"] = kept.isEmpty ? nil : kept
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Removes every `noodle/...` key and every `noodle-...` format, at any depth. Ordinary
    /// names that merely begin with the word, such as a `noodleType` property, stay.
    private static func clean(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(clean) }
        guard let object = value as? [String: Any] else { return value }
        var cleaned: [String: Any] = [:]
        for (key, value) in object where !key.lowercased().hasPrefix("noodle/") {
            if key == "format", let format = value as? String, format.lowercased().hasPrefix("noodle-") { continue }
            cleaned[key] = clean(value)
        }
        return cleaned
    }
}
