import Foundation
import NoodleCore
import NoodleToolConnections

/// CrowdSec's CTI: what the machines in CrowdSec's network have seen an IP address do, from the behaviours and attacks
/// that caught it to how aggressive it has been lately.
public enum CrowdSec {
    public static let cti = ToolDefinition(
        id: "5f0d3c2a-8e4b-4a91-b7c6-2d9e1f8a6b34", name: "CrowdSec CTI",
        summary: "What CrowdSec's network has seen an IP address do: its reputation, behaviours, attacks, CVEs and scores.",
        defaultInstructions: """
        Use CrowdSec CTI to see what the machines in CrowdSec's network have seen an IP address do: its reputation, \
        the behaviours and attacks that caught it, the MITRE ATT&CK techniques and CVEs involved, whether it is background \
        noise, and when it was first and last seen. Look up several addresses at once when you have them. An address \
        CrowdSec has not seen is a finding too. Record each lookup as evidence.
        """,
        iconName: "crowdsec",
        configuration: .connection(.init(endpoint: URL(string: "https://cti.api.crowdsec.net/v2")!, tokenHeader: "x-api-key", adapter: "crowdsec-cti")),
        setup: setup)

    static let setup = [
        "Sign in to the [CrowdSec Console](https://app.crowdsec.net), or create a free account.",
        "Open **Settings › CTI API Keys**, create a key, then copy it and paste it here; it is shown only once.",
    ]

    public static let adapter = OperationAdapter(operations: [Lookup(), Lookups()])

    struct Named: Codable { let name: String?; let label: String? }
    struct Classifications: Codable { let classifications: [Named]?; let false_positives: [Named]? }
    struct Location: Codable { let country: String?; let city: String? }
    struct History: Codable { let first_seen: String?; let last_seen: String? }
    struct Score: Codable { let aggressiveness: Int?; let threat: Int?; let trust: Int?; let anomaly: Int? }
    struct Scores: Codable { let last_day: Score?; let last_week: Score?; let last_month: Score?; let overall: Score? }
    struct Item: Codable {
        let ip: String?, reputation: String?, confidence: String?, background_noise: String?
        let ip_range: String?, as_name: String?, as_num: Int?, reverse_dns: String?, location: Location?
        let behaviors: [Named]?, attack_details: [Named]?, mitre_techniques: [Named]?, classifications: Classifications?
        let cves: [String]?, history: History?, scores: Scores?, target_countries: [String: Int]?
    }

    /// What CrowdSec says of one address, a line for each thing it knows.
    static func describe(_ item: Item) -> String {
        func labels(_ named: [Named]?) -> String? {
            let list = (named ?? []).compactMap { $0.label ?? $0.name }
            return list.isEmpty ? nil : list.joined(separator: ", ")
        }
        var first = "\(item.ip ?? "?"): \(item.reputation ?? "unknown")"
        if let confidence = item.confidence { first += " (confidence \(confidence))" }
        if let noise = item.background_noise { first += ", background noise \(noise)" }
        var lines = [first]
        let network = [item.as_name.map { name in item.as_num.map { "\(name) (AS\($0))" } ?? name }, item.ip_range.map { "range \($0)" },
                       item.location?.country.map { country in item.location?.city.map { "\($0), \(country)" } ?? country },
                       item.reverse_dns.map { "reverse DNS \($0)" }].compactMap { $0 }
        if !network.isEmpty { lines.append("Network: " + network.joined(separator: "; ")) }
        if let behaviours = labels(item.behaviors) { lines.append("Behaviours: " + behaviours) }
        if let attacks = labels(item.attack_details) { lines.append("Caught by: " + attacks) }
        let techniques = (item.mitre_techniques ?? []).compactMap { technique in technique.name.map { "\($0) \(technique.label ?? "")".trimmingCharacters(in: .whitespaces) } }
        if !techniques.isEmpty { lines.append("MITRE ATT&CK: " + techniques.joined(separator: ", ")) }
        if let classified = labels(item.classifications?.classifications) { lines.append("Classified: " + classified) }
        if let benign = labels(item.classifications?.false_positives) { lines.append("Likely false positive: " + benign) }
        if let cves = item.cves, !cves.isEmpty { lines.append("CVEs: " + cves.prefix(20).joined(separator: ", ")) }
        if let history = item.history, history.first_seen != nil || history.last_seen != nil {
            lines.append("First seen \(history.first_seen ?? "?"), last seen \(history.last_seen ?? "?")")
        }
        if let week = item.scores?.last_week {
            lines.append("Last week: aggressiveness \(week.aggressiveness ?? 0), threat \(week.threat ?? 0), trust \(week.trust ?? 0), anomaly \(week.anomaly ?? 0) (of 5)")
        }
        if let targets = item.target_countries, !targets.isEmpty {
            lines.append("Targets: " + targets.sorted { $0.value > $1.value }.prefix(5).map(\.key).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    /// CrowdSec's CTI answers 403 for a key it does not know, which is a wrong key rather than one short of permissions.
    static func asked<Answer>(_ request: () async throws -> Answer) async throws -> Answer {
        do { return try await request() } catch ServiceError.forbidden(let reason) { throw ServiceError.rejected(reason) }
    }
}

extension CrowdSec {
    struct Lookup: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String }
        static let name = "ip"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "What CrowdSec's network has seen an IP address do: reputation, behaviours, attacks, MITRE techniques, CVEs, history and scores."
        static let input = JSONSchema.object(["ip": .string("An IPv4 or IPv6 address.")], required: ["ip"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let ip = try ServiceInput.ip(input.ip)
            let item: Item
            do { item = try await CrowdSec.asked { try await service.get(["smoke", ip], as: Item.self) } }
            catch ServiceError.notFound {
                return try ServiceResult(text: "CrowdSec has not seen \(ip) in its network.", structured: ["ip": ip, "seen": "false"])
            }
            return try ServiceResult(text: CrowdSec.describe(item), structured: item)
        }
    }

    struct Lookups: ServiceOperation {
        struct Input: Decodable, Sendable { let ips: [String] }
        static let name = "ips"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Several IP addresses at once, up to 20, each as ip describes it, and which ones CrowdSec has not seen."
        static let input = JSONSchema.object(["ips": .array(.string("An IPv4 or IPv6 address."), "Up to 20 addresses.")], required: ["ips"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard (1...20).contains(input.ips.count) else { throw ServiceError.input("Give between 1 and 20 addresses.") }
            let ips = try input.ips.map(ServiceInput.ip)
            struct Answer: Codable { let items: [Item]? }
            let items = try await CrowdSec.asked {
                try await service.get(["smoke"], query: ["ips": ips.joined(separator: ",")], as: Answer.self)
            }.items ?? []
            let found = Set(items.compactMap(\.ip))
            let unseen = ips.filter { !found.contains($0) }
            var text = items.map(CrowdSec.describe).joined(separator: "\n\n")
            if !unseen.isEmpty { text += (text.isEmpty ? "" : "\n\n") + "Not seen: " + unseen.joined(separator: ", ") }
            struct Kept: Encodable { let items: [Item]; let unseen: [String] }
            return try ServiceResult(text: text, structured: Kept(items: items, unseen: unseen))
        }
    }
}
