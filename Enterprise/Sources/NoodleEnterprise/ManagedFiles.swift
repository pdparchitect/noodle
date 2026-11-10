// Noodle Enterprise. Source-available under Enterprise/LICENSE, not Apache-2.0.
import Foundation

/// The files generated from the key registry for administrators. They are never edited by hand:
/// `swift run NoodleEnterpriseFiles` writes them, and a test fails while they differ.
public enum ManagedFiles {
    /// For Jamf Pro's Application & Custom Settings payload.
    public static let schemaPath = "Enterprise/Profiles/com.pdparchitect.noodle.json"
    public static let profilePath = "Enterprise/Profiles/Noodle.mobileconfig"
    /// Every key ever published, one per line. Only ever added to, so a key that disappears from
    /// the registry fails a test instead of silently changing what a deployed profile means.
    public static let ledgerPath = "Enterprise/Profiles/published-keys.txt"
    public static let guidePath = "Enterprise/Deployment.md"
    static let tableStart = "<!-- BEGIN GENERATED KEYS: swift run NoodleEnterpriseFiles -->"
    static let tableEnd = "<!-- END GENERATED KEYS -->"

    struct GenerationError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Each generated file's path from the repository root and what it should hold, given the
    /// files there now: the ledger and the guide keep what they have besides the generated parts.
    public static func expected(root: URL) throws -> [(path: String, contents: String)] {
        let ledger = try? String(contentsOf: root.appendingPathComponent(ledgerPath), encoding: .utf8)
        let guideText = try String(contentsOf: root.appendingPathComponent(guidePath), encoding: .utf8)
        return [(schemaPath, try jamfSchema()), (profilePath, try sampleProfile()),
                (ledgerPath, self.ledger(existing: ledger)), (guidePath, try guide(guideText))]
    }

    public static func write(root: URL) throws {
        for (path, contents) in try expected(root: root) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url, options: .atomic)
        }
    }

    static func describe(_ key: ManagedKey) -> String {
        (key.deprecated ? "Deprecated. " : "") + key.description + " Since Noodle \(key.since)."
    }

    static func plistValue(_ value: ManagedValue) -> Any {
        switch value {
        case .boolean(let flag): return flag
        case .strings(let entries): return entries
        }
    }

    public static func jamfSchema() throws -> String {
        var properties: [String: Any] = [:]
        for (index, key) in ManagedKeys.all.enumerated() {
            var property: [String: Any] = ["title": key.title, "description": describe(key), "property_order": (index + 1) * 5]
            switch key.type {
            case .boolean:
                property["type"] = "boolean"
            case .strings:
                property["type"] = "array"
                var items: [String: Any] = ["type": "string"]
                if let choices = key.choices {
                    items["enum"] = choices.map(\.value)
                    items["options"] = ["enum_titles": choices.map(\.title)]
                }
                property["items"] = items
            }
            if let value = key.defaultValue { property["default"] = plistValue(value) }
            properties[key.name] = property
        }
        let schema: [String: Any] = [
            "title": "Noodle",
            "description": "Restrictions for Noodle (\(ManagedKeys.domain)). Every key is optional and a missing key allows. Generated from Noodle's key registry.",
            "properties": properties,
        ]
        let data = try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// A profile that sets every key to what Noodle does without it, so installing it unchanged
    /// changes nothing but shows the keys as managed. Allow lists are left out: one present means
    /// only what it lists.
    public static func sampleProfile() throws -> String {
        var settings: [String: Any] = [:]
        for key in ManagedKeys.all where !key.deprecated {
            if let value = key.defaultValue { settings[key.name] = plistValue(value) }
            else if key.name.hasSuffix("DenyList") { settings[key.name] = [String]() }
        }
        let payload: [String: Any] = [
            "PayloadType": "com.apple.ManagedClient.preferences",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(ManagedKeys.domain).managed.preferences",
            "PayloadUUID": "6E0F5B7C-2A47-4C1B-9E39-2B6C1F0D7A11",
            "PayloadDisplayName": "Noodle",
            "PayloadContent": [ManagedKeys.domain: ["Forced": [["mcx_preference_settings": settings]]]],
        ]
        let profile: [String: Any] = [
            "PayloadContent": [payload],
            "PayloadDisplayName": "Noodle managed settings (sample)",
            "PayloadDescription": "Sets every Noodle key to its default. Change the values your organisation needs before deploying.",
            "PayloadIdentifier": "\(ManagedKeys.domain).managed",
            "PayloadOrganization": "Your organisation",
            "PayloadScope": "System",
            "PayloadType": "Configuration",
            "PayloadUUID": "3B1E2C4D-8F6A-4E2B-A1C7-5D9E0F2B4C63",
            "PayloadVersion": 1,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    static func defaultText(_ key: ManagedKey) -> String {
        switch key.defaultValue {
        case .boolean(let flag)?: return "`\(flag)`"
        case .strings(let entries)? where key.choices?.map(\.value) == entries: return "All"
        case .strings(let entries)?: return entries.map { "`\($0)`" }.joined(separator: ", ")
        case nil: return "Not set"
        }
    }

    public static func keyTable() -> String {
        var lines = ["| Key | Type | Default | Since | What it does |", "| --- | --- | --- | --- | --- |"]
        for key in ManagedKeys.all {
            let type = key.type == .boolean ? "Boolean" : "Array of strings"
            lines.append("| `\(key.name)` | \(type) | \(defaultText(key)) | \(key.since) | \(key.deprecated ? "Deprecated. " : "")\(key.description) |")
        }
        for key in ManagedKeys.all {
            guard let choices = key.choices, ManagedKeys.all.first(where: { $0.choices == choices })?.name == key.name else { continue }
            let users = ManagedKeys.all.filter { $0.choices == choices }.map { "`\($0.name)`" }.joined(separator: " and ")
            lines.append("")
            lines.append("Values for \(users):")
            lines.append("")
            lines.append(choices.map { "`\($0.value)` (\($0.title))" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    public static func ledger(existing: String?) -> String {
        let published = Set((existing ?? "").split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty })
        return published.union(ManagedKeys.all.map(\.name)).sorted().joined(separator: "\n") + "\n"
    }

    /// The guide with its key table replaced.
    public static func guide(_ text: String) throws -> String {
        guard let start = text.range(of: tableStart), let end = text.range(of: tableEnd), start.upperBound <= end.lowerBound else {
            throw GenerationError("\(guidePath) has no generated key table markers.")
        }
        return String(text[..<start.upperBound]) + "\n\n" + keyTable() + "\n\n" + String(text[end.lowerBound...])
    }
}
