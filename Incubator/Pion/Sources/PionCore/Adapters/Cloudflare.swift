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
        and the firewall events for a zone, such as blocked requests by IP address, country, path and rule source; and to \
        audit who holds what, members lists everyone in the account with their roles and whether they use 2FA, and \
        api-tokens the account's own API tokens, what each may do, from where and when it was last used. \
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
        "Add the permissions **Account › Audit Logs › Read**, **Account › Account Settings › Read**, **Account › Account API Tokens › Read**, **Zone › Zone › Read**, **Zone › DNS › Read** and **Zone › Analytics › Read**.",
        "Limit **Account Resources** to your account and **Zone Resources** to its zones, then create the token, copy it and paste it here.",
        "The Account ID is in the **API** section of any zone's **Overview** page.",
    ]

    public static let adapter = OperationAdapter(operations: [ZoneDNS(), AuditLog(), FirewallEvents(), Members(), APITokens()])

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

extension Cloudflare {
    /// Who is in the account and with which roles, from Account Settings Read: administrators first, then the rest,
    /// each with whether they sign in with 2FA, which does not cover API tokens.
    struct Members: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "members"
        static let summary = "Everyone in the account with their roles and whether they use 2FA, administrators first."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct User: Codable { let email: String?; let two_factor_authentication_enabled: Bool? }
            struct Role: Codable { let id: String?; let name: String? }
            struct Member: Codable { let id: String; let status: String?; let user: User?; let email: String?; let roles: [Role]? }
            struct Info: Decodable { let total_count: Int? }
            struct Page: Decodable { let result: [Member]?; let result_info: Info? }
            let account = try service.setting("account")
            var members: [Member] = []
            // Fifty a page at most; an account with more than a thousand members is cut short.
            for page in 1...20 {
                let answer = try await service.get(["accounts", account, "members"], query: ["page": String(page), "per_page": "50"], as: Page.self)
                members += answer.result ?? []
                guard (answer.result ?? []).count == 50 || members.count < (answer.result_info?.total_count ?? 0), !(answer.result ?? []).isEmpty else { break }
            }
            func administrator(_ member: Member) -> Bool { (member.roles ?? []).contains { ($0.name ?? "").contains("Administrator") } }
            let ordered = members.filter(administrator) + members.filter { !administrator($0) }
            let text = ordered.isEmpty ? "The account has no members listed." : ordered.map { member in
                let who = member.user?.email ?? member.email ?? member.id
                let roles = (member.roles ?? []).compactMap(\.name).joined(separator: ", ")
                let twoFactor = member.user?.two_factor_authentication_enabled == false ? ", no 2FA" : ""
                return "\(who)\(member.status == "pending" ? " (invited)" : ""): \(roles.isEmpty ? "no roles" : roles)\(twoFactor)"
            }.joined(separator: "\n")
            struct Kept: Encodable { let members: [Member] }
            return try ServiceResult(text: text, structured: Kept(members: ordered))
        }
    }
}

extension Cloudflare {
    /// The account's own API tokens, from Account API Tokens Read: what each may do, from where, and when it was last
    /// used. Tokens people made under their own profiles are theirs alone and are not listed.
    struct APITokens: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "api-tokens"
        static let summary = "The account's own API tokens: what each may do, from which addresses, when it was last used and when it expires."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Group: Codable { let name: String? }
            struct Policy: Codable { let effect: String?; let permission_groups: [Group]? }
            struct Addresses: Codable { let `in`: [String]?; let not_in: [String]? }
            struct Condition: Codable { let request_ip: Addresses? }
            struct Token: Codable {
                let id: String, name: String?, status: String?, issued_on: String?, last_used_on: String?, expires_on: String?
                let policies: [Policy]?, condition: Condition?
            }
            struct Info: Decodable { let total_count: Int? }
            struct Page: Decodable { let result: [Token]?; let result_info: Info? }
            let account = try service.setting("account")
            var tokens: [Token] = []
            for page in 1...20 {
                let answer = try await service.get(["accounts", account, "tokens"], query: ["page": String(page), "per_page": "50"], as: Page.self)
                tokens += answer.result ?? []
                guard !(answer.result ?? []).isEmpty, tokens.count < (answer.result_info?.total_count ?? 0) else { break }
            }
            let text = tokens.isEmpty ? "The account has no API tokens of its own." : tokens.map { token in
                let allowed = (token.policies ?? []).filter { $0.effect != "deny" }.flatMap { $0.permission_groups ?? [] }.compactMap(\.name)
                let from = token.condition?.request_ip?.in.map { "from " + $0.joined(separator: ", ") } ?? "from anywhere"
                return "\(token.name ?? token.id) (\(token.status ?? "?")): \(allowed.isEmpty ? "no permissions listed" : allowed.joined(separator: ", ")), \(from), "
                    + (token.last_used_on.map { "last used \($0)" } ?? "never used") + ", " + (token.expires_on.map { "expires \($0)" } ?? "never expires")
            }.joined(separator: "\n")
            struct Kept: Encodable { let tokens: [Token] }
            return try ServiceResult(text: text, structured: Kept(tokens: tokens))
        }
    }
}

