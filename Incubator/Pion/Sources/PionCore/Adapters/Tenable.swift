import Foundation
import NoodleCore
import NoodleMCP

/// Tenable Vulnerability Management: what it knows of an asset and its vulnerabilities, read with an access key and
/// secret key.
public enum Tenable {
    public static let preset = ToolDefinition(
        id: "tenable", name: "Tenable", summary: "An asset's details and known vulnerabilities, by IP address.",
        defaultInstructions: """
        Use Tenable to see how exposed an asset is: find it by IP address, with its hostnames, operating system and when \
        last seen, and its vulnerabilities by severity. Record each finding as evidence, citing the asset and plugin. These \
        tools only read.
        """,
        iconName: "tenable",
        configuration: .connection(.init(endpoint: URL(string: "https://cloud.tenable.com")!, tokenHeader: "X-ApiKeys",
            composedToken: ComposedToken(first: "Access Key", second: "Secret Key", format: .template("accessKey={first};secretKey={second}")),
            adapter: "tenable")),
        setup: setup)

    static let setup = [
        "In Tenable Vulnerability Management, open **Settings › Access Control › Users** and create a user for Pion with the **Basic** role and **Can View** on the assets to investigate, through an access group.",
        "Open that user, choose **API Keys › Generate**, and copy the **Access Key** and **Secret Key** here. Generating replaces any keys it had.",
    ]

    public static let adapter = OperationAdapter(operations: [AssetVulnerabilities()])
}

extension Tenable {
    struct AssetVulnerabilities: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String, days: Int? }
        static let name = "asset-vulnerabilities"
        static let summary = "The asset at an IP address, with its hostnames, operating system and last scan, and its vulnerabilities by severity."
        static let input = JSONSchema.object([
            "ip": .string("The asset's IPv4 address."),
            "days": .integer("How many days of findings. 30 when left out.", minimum: 1, maximum: 180),
        ], required: ["ip"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let ip = try ServiceInput.ip(input.ip)
            let days = input.days ?? 30
            guard (1...180).contains(days) else { throw ServiceError.input("Look back between 1 and 180 days.") }
            struct Asset: Codable { let id: String, ipv4: [String]?, fqdn: [String]?, operating_system: [String]?, last_seen: String? }
            struct Assets: Decodable { let assets: [Asset]? }
            guard let asset = try await service.get(["workbenches", "assets"], query: [
                "date_range": String(days), "filter.0.filter": "ipv4", "filter.0.quality": "eq", "filter.0.value": ip,
            ], as: Assets.self).assets?.first else {
                return try ServiceResult(text: "Tenable knows no asset at \(ip).", structured: ["ip": ip])
            }
            struct Vulnerability: Codable { let plugin_id: Int?, plugin_name: String?, severity: Int?, count: Int?, vulnerability_state: String? }
            struct Vulnerabilities: Decodable { let vulnerabilities: [Vulnerability]? }
            struct Report: Encodable { let asset: Asset; let vulnerabilities: [Vulnerability] }
            let vulnerabilities = (try await service.get(["workbenches", "assets", asset.id, "vulnerabilities"], query: ["date_range": String(days)],
                                                         as: Vulnerabilities.self).vulnerabilities ?? []).sorted { ($0.severity ?? 0) > ($1.severity ?? 0) }
            let levels = ["info", "low", "medium", "high", "critical"]
            var text = "\(ip): \((asset.fqdn ?? []).first ?? "no hostname"), \((asset.operating_system ?? []).first ?? "unknown OS"), last seen \(asset.last_seen ?? "?")."
            let serious = vulnerabilities.filter { ($0.severity ?? 0) >= 2 }
            text += serious.isEmpty ? " No medium or worse vulnerabilities." : "\n" + serious.prefix(20).map { item in
                "\(levels[min(max(item.severity ?? 0, 0), 4)]): \(item.plugin_name ?? "plugin \(item.plugin_id ?? 0)")\(item.vulnerability_state.map { " (\($0))" } ?? "")"
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Report(asset: asset, vulnerabilities: vulnerabilities))
        }
    }
}
