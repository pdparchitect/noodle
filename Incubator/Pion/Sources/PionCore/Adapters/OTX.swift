import Foundation
import NoodleCore
import NoodleMCP

/// AlienVault OTX: the community threat reports, called pulses, that mention an indicator.
public enum OTX {
    public static let preset = ToolDefinition(
        id: "2e9c0952-23e1-469c-8b2a-a4b29b67635b", name: "AlienVault OTX", summary: "Community threat reports that mention an IP address, domain, hostname or file hash.",
        defaultInstructions: """
        Use AlienVault OTX to see which community threat reports, called pulses, mention an IP address, domain, hostname \
        or file hash, with their names, tags, adversaries and malware families. Pulses are shared by anyone and vary in \
        quality: cite them as leads, not proof. Record each lookup as evidence.
        """,
        iconName: "otx",
        configuration: .connection(.init(endpoint: URL(string: "https://otx.alienvault.com/api/v1")!, tokenHeader: "X-OTX-API-KEY", adapter: "otx")),
        setup: setup)

    static let setup = [
        "Sign in at [otx.alienvault.com](https://otx.alienvault.com), or create a free account.",
        "Open the [API page](https://otx.alienvault.com/api), copy **Your OTX Key** and paste it here.",
    ]

    public static let adapter = OperationAdapter(operations: [Indicator()])
}

extension OTX {
    struct Indicator: ServiceOperation {
        struct Input: Decodable, Sendable { let indicator: String, kind: String? }
        static let name = "indicator"
        static let summary = "The pulses that mention an IP address, domain, hostname or file hash, with their tags, adversaries and malware families."
        static let input = JSONSchema.object([
            "indicator": .string("An IP address, domain, hostname or file hash."),
            "kind": .string("What it is, when it is not clear from the value.", oneOf: ["IPv4", "IPv6", "domain", "hostname", "file"]),
        ], required: ["indicator"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let value = input.indicator.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: String
            if let given = input.kind { kind = try ServiceInput.oneOf(given, ["IPv4", "IPv6", "domain", "hostname", "file"], "kind") }
            else if (try? ServiceInput.ip(value)) != nil { kind = value.contains(":") ? "IPv6" : "IPv4" }
            else if [32, 40, 64].contains(value.count), value.allSatisfy(\.isHexDigit) { kind = "file" }
            else { kind = "domain" }
            let indicator = switch kind {
            case "IPv4", "IPv6": try ServiceInput.ip(value)
            case "file": value.lowercased()
            default: try ServiceInput.domain(value)
            }
            struct Family: Codable { let display_name: String? }
            struct Pulse: Codable { let name: String?, created: String?, tags: [String]?, adversary: String?, malware_families: [Family]? }
            struct Info: Codable { let count: Int?; let pulses: [Pulse]? }
            struct Answer: Codable { let reputation: Int?, country_name: String?, pulse_info: Info? }
            let answer = try await service.get(["indicators", kind, indicator, "general"], as: Answer.self)
            let pulses = answer.pulse_info?.pulses ?? []
            let count = answer.pulse_info?.count ?? pulses.count
            var text = count == 0 ? "\(indicator) is in no pulses." : "\(indicator) is in \(count) pulse\(count == 1 ? "" : "s")"
            if count > 0 {
                text += ": " + pulses.prefix(10).map { pulse in
                    var line = pulse.name ?? "unnamed"
                    let families = (pulse.malware_families ?? []).compactMap(\.display_name)
                    let details = [pulse.adversary.flatMap { $0.isEmpty ? nil : $0 }] + families.map(Optional.some)
                    let shown = details.compactMap { $0 }
                    if !shown.isEmpty { line += " (\(shown.joined(separator: ", ")))" }
                    return line
                }.joined(separator: "; ") + "."
            }
            return try ServiceResult(text: text, structured: answer)
        }
    }
}
