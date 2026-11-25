import Foundation
import NoodleCore
import NoodleToolConnections

/// Tenable Vulnerability Management: what it knows of an asset and its vulnerabilities, read with an access key and
/// secret key. check-access looks one reserved address up and reads the keys' own session.
///
/// The tool's guide is Incubator/Pion/docs/tools/tenable.md. Change it with the setup steps or operations here.
public enum Tenable {
    public static let preset = ToolDefinition(
        id: "6b90d060-bfa0-4f10-9aa1-a326505d7957", name: "Tenable", summary: "An asset's details and known vulnerabilities, by IP address.",
        defaultInstructions: """
        Use Tenable to see how exposed an asset is: find it by IP address, with its hostnames, operating system and when \
        last seen, and its vulnerabilities by severity. Record each finding as evidence, citing the asset and plugin. These \
        tools only read. When a tool is refused, run check-access and tell the champion exactly what it says to change.
        """,
        iconName: "tenable",
        configuration: .connection(.init(endpoint: URL(string: "https://cloud.tenable.com")!, tokenHeader: "X-ApiKeys",
            composedToken: ComposedToken(first: "Access Key", second: "Secret Key", format: .template("accessKey={first};secretKey={second}")),
            adapter: "tenable")),
        setup: setup)

    static let setup = [
        "In Tenable Vulnerability Management, open **Settings › Access Control › Users** and create a user for Pion with the **Basic** role and **Can View** on the assets to investigate, through an access group.",
        "Open that user, choose **API Keys › Generate**, and copy the **Access Key** and **Secret Key** here. Generating replaces any keys it had. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [AssetVulnerabilities(), CheckAccess()])
}

extension Tenable {
    struct AssetVulnerabilities: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String, days: Int? }
        static let name = "asset-vulnerabilities"
        static let jobs: Set<ToolJob> = [.detection, .audit]
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

extension Tenable {
    static let fixes = AccessCheck.Fixes(
        rejected: "Tenable did not accept the keys: they are wrong, were replaced when new keys were generated, or the user was disabled or lost API access. Generate new keys for the user and enter both again in Settings › Tools.",
        forbidden: "the user's role or access groups may not read this: give it the Basic role or higher, with Can View on the assets through an access group.",
        rateLimited: "Tenable is rate limiting these keys: wait before trying again.")

    /// The roles Tenable gives as a number in a session.
    static let roles = [0: "Read-Only", 16: "Basic", 24: "Scan Operator", 32: "Standard", 40: "Scan Manager", 64: "Administrator"]

    /// Looks up an address reserved for documentation, which no asset has, to try the keys and the workbench the tool
    /// reads, then says whose keys they are and their role, where Tenable still answers that.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Tries the keys once on the asset workbench, with an address no asset has, and says whose they are and their role, and what to change for what does not work. It sends only reads."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var check = AccessCheck(Tenable.fixes)
            guard await check.probe("Keys and the asset workbench", { () async throws -> String in
                struct Asset: Decodable {}
                struct Assets: Decodable { let assets: [Asset]? }
                _ = try await service.get(["workbenches", "assets"], query: [
                    "date_range": "1", "filter.0.filter": "ipv4", "filter.0.quality": "eq", "filter.0.value": "192.0.2.1",
                ], as: Assets.self)
                return "assets can be searched; which ones it shows depends on the user's access groups"
            }) else { return try check.result() }
            // Whose keys they are and their role, where Tenable still answers it; nothing is said when it does not.
            struct Session: Decodable { let username: String?; let permissions: Int?; let container_name: String? }
            if let session = try? await service.get(["session"], as: Session.self) {
                let role = session.permissions.map { Tenable.roles[$0].map { "the \($0) role" } ?? "role \($0)" }
                check.note("The keys belong to \(session.username ?? "?")" + (role.map { ", with \($0)" } ?? "") + (session.container_name.map { ", in \($0)" } ?? "") + ".")
                if let permissions = session.permissions, permissions > 24 {
                    check.note("That role may change Tenable, which these tools never do: Basic, with Can View on the assets, is enough.")
                }
            }
            return try check.result()
        }
    }
}
