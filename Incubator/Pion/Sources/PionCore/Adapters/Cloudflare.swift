import Foundation
import NoodleCore
import NoodleToolConnections

/// Cloudflare: an account's zones and DNS records, its audit log, and the firewall events at a zone's edge,
/// read with an API token. Each account is one Cloudflare account.
public enum Cloudflare {
    public static let preset = ToolDefinition(
        id: "a975fdab-e1f0-486c-abf6-d941d667d6f7", name: "Cloudflare Security", summary: "DNS records, the account audit log, and firewall events at the edge.",
        defaultInstructions: """
        Use Cloudflare to see a domain from the edge: its DNS records, who changed what in the account and from where, \
        and the firewall events for a zone, such as blocked requests by IP address, country, path and rule source. \
        Record each finding as evidence, citing the zone and time window. These tools only read: recommend blocking an \
        address or changing a rule to the champion.
        """,
        iconName: "cloudflare",
        configuration: .connection(.init(endpointTemplate: "https://api.cloudflare.com/client/v4",
            fields: [ToolField(key: "account", title: "Account ID", placeholder: "023e105f4ecef8ad9ca31a8372d0c353", kind: .identifier)],
            tokenHeader: "Authorization", adapter: "cloudflare")),
        setup: setup)

    /// Cloudflare Radar's MCP server: the Internet as Cloudflare's network sees it, through any Cloudflare account's
    /// sign-in. It knows nothing of the account's own zones, which Cloudflare Security reads.
    public static let radar = ToolDefinition(
        id: "1a8b84b4-61cf-489c-9674-7dd239072a2e", name: "Cloudflare Radar",
        summary: "Internet-wide attacks, traffic, BGP routing, outages and domain and IP intelligence.",
        defaultInstructions: """
        Use Cloudflare Radar for context from across the Internet: DDoS and application-layer attack trends, traffic \
        anomalies and outages, BGP hijacks and route leaks, an autonomous system's or IP address's details, domain \
        rankings, and URL scans. Radar reports Internet-wide figures, not the user's own zones or traffic. Cite the \
        time window, location or network of each figure and record what matters as evidence. Use only tools actually \
        offered by this connection and only within the user's request and granted permissions.
        """,
        iconName: "cloudflare",
        configuration: .connection(.init(endpoint: URL(string: "https://radar.mcp.cloudflare.com/mcp")!)))

    static let setup = [
        "In the Cloudflare dashboard, open **My Profile › API Tokens** and choose **Create Token › Create Custom Token**.",
        "Add the permissions **Account › Audit Logs › Read**, **Zone › Zone › Read**, **Zone › DNS › Read** and **Zone › Analytics › Read**.",
        "Limit **Account Resources** to your account and **Zone Resources** to its zones, then create the token, copy it and paste it here.",
        "The Account ID is in the **API** section of any zone's **Overview** page.",
    ]

    public static let adapter = OperationAdapter(operations: [ZoneDNS(), AuditLog(), FirewallEvents()])

    /// Cloudflare wraps its answers in their result.
    struct Envelope<Result: Decodable>: Decodable { let result: Result? }

    /// A zone's ID from its name.
    static func zone(_ name: String, on service: ServiceClient) async throws -> String {
        let domain = try ServiceInput.domain(name)
        struct Zone: Decodable { let id: String }
        guard let zone = try await service.get(["zones"], query: ["name": domain], as: Envelope<[Zone]>.self).result?.first else {
            throw ServiceError.input("This account has no zone \(domain).")
        }
        return zone.id
    }
}

extension Cloudflare {
    struct ZoneDNS: ServiceOperation {
        struct Input: Decodable, Sendable { let zone: String }
        static let name = "zone-dns"
        static let summary = "A zone's DNS records, with whether each is proxied and when it last changed."
        static let input = JSONSchema.object(["zone": .string("The zone's domain, such as example.com.")], required: ["zone"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try await Cloudflare.zone(input.zone, on: service)
            struct Record: Codable { let type: String?, name: String?, content: String?, proxied: Bool?, ttl: Int?, modified_on: String? }
            struct Records: Encodable { let records: [Record] }
            let records = try await service.get(["zones", id, "dns_records"], query: ["per_page": "100"], as: Envelope<[Record]>.self).result ?? []
            let text = records.isEmpty ? "The zone has no DNS records." : records.map { record in
                "\(record.type ?? "?") \(record.name ?? "?") → \(record.content ?? "?")\(record.proxied == true ? " (proxied)" : "")\(record.modified_on.map { ", changed \($0)" } ?? "")"
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Records(records: records))
        }
    }

    struct AuditLog: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, actor: String?, limit: Int? }
        static let name = "audit-log"
        static let summary = "Changes in the account, newest first: who did what, to which resource, from which IP address."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "actor": .string("Only changes by this email address."),
            "limit": .integer("How many entries, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 50
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 entries.") }
            var query: [String: String?] = ["since": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7),
                                            "per_page": String(limit), "direction": "desc"]
            if let actor = input.actor { query["actor.email"] = try ServiceInput.quoted(actor, "the actor's email address") }
            struct Action: Codable { let type: String?; let result: Bool? }
            struct Actor: Codable { let email: String?; let ip: String?; let type: String? }
            struct Resource: Codable { let type: String?; let id: String? }
            struct Entry: Codable { let id: String?, when: String?, action: Action?, actor: Actor?, resource: Resource? }
            struct Entries: Encodable { let entries: [Entry] }
            let entries = try await service.get(["accounts", try service.setting("account"), "audit_logs"], query: query,
                                                as: Envelope<[Entry]>.self).result ?? []
            let text = entries.isEmpty ? "No changes match." : entries.prefix(30).map { entry in
                var line = "\(entry.when ?? "?") \(entry.action?.type ?? "?")"
                if entry.action?.result == false { line += " (failed)" }
                if let who = entry.actor?.email ?? entry.actor?.type { line += " by \(who)" }
                if let ip = entry.actor?.ip { line += " from \(ip)" }
                if let resource = entry.resource?.type { line += " on \(resource)\(entry.resource?.id.map { " \($0)" } ?? "")" }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Entries(entries: entries))
        }
    }

    struct FirewallEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let zone: String, ip: String?, since: String?, until: String?, limit: Int? }
        static let name = "firewall-events"
        static let summary = "Firewall events at a zone's edge, newest first, by client IP address and time, with the action, country, path and rule source."
        static let input = JSONSchema.object([
            "zone": .string("The zone's domain, such as example.com."),
            "ip": .string("Only events from this client IP address."),
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out."),
            "until": .string("The latest time, in ISO 8601."),
            "limit": .integer("How many events, at most.", minimum: 1, maximum: 100),
        ], required: ["zone"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 50
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 events.") }
            var filter = ["datetime_geq": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(1)]
            if let until = input.until { filter["datetime_leq"] = try ServiceInput.time(until) }
            if let ip = input.ip { filter["clientIP"] = try ServiceInput.ip(ip) }
            let id = try await Cloudflare.zone(input.zone, on: service)
            struct Variables: Encodable { let zoneTag: String; let filter: [String: String]; let limit: Int }
            struct Event: Codable {
                let datetime: String?, action: String?, clientIP: String?, clientCountryName: String?, clientAsn: String?
                let clientRequestPath: String?, clientRequestQuery: String?, source: String?, userAgent: String?
            }
            struct Zone: Decodable { let firewallEventsAdaptive: [Event]? }
            struct Viewer: Decodable { let zones: [Zone]? }
            struct Data: Decodable { let viewer: Viewer? }
            struct Events: Encodable { let events: [Event] }
            let query = """
            query FirewallEvents($zoneTag: string, $filter: FirewallEventsAdaptiveFilter_InputObject, $limit: uint64!) {
              viewer { zones(filter: { zoneTag: $zoneTag }) {
                firewallEventsAdaptive(filter: $filter, limit: $limit, orderBy: [datetime_DESC]) {
                  datetime action clientIP clientCountryName clientAsn clientRequestPath clientRequestQuery source userAgent
                } } }
            }
            """
            let events = try await service.graphQL(["graphql"], query: query, variables: Variables(zoneTag: id, filter: filter, limit: limit),
                                                   as: Data.self).viewer?.zones?.first?.firewallEventsAdaptive ?? []
            let text = events.isEmpty ? "No firewall events match." : events.prefix(30).map { event in
                "\(event.datetime ?? "?") \(event.action ?? "?") \(event.clientIP ?? "?")\(event.clientCountryName.map { " (\($0))" } ?? "") \(event.clientRequestPath ?? "")\(event.source.map { " — \($0)" } ?? "")"
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Events(events: events))
        }
    }
}
