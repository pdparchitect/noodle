import Foundation
import NoodleCore
import NoodleToolConnections

/// Cloudflare: one account's edge (its zones with their DNS records and security settings, firewall events, audit log
/// and members) and its Zero Trust (Access authentication logs, applications, policies, users and their sessions,
/// Gateway activity, rules and lists, WARP devices with their posture, and Cloudflare Tunnels), read as the account
/// member who signs in. Cloudflare Detection only reads; Cloudflare Containment, a tool of its own with a sign-in of its
/// own, blocks addresses, networks and countries at the edge, revokes a user's Access sessions, blocks domains and
/// addresses in Gateway, and revokes WARP devices.
///
/// Both sign in through OAuth at Cloudflare's dashboard, with an authorization code and PKCE, through a private OAuth
/// client the account made, which keeps no client secret. Cloudflare allows a request only when both the sign-in's
/// scopes and the member's role allow it, and only in the accounts the member chose when signing in, so Cloudflare
/// Detection's scopes only read, whatever the member may do. check-access tries each read once, and sends no change.
///
/// Every request, and every next page, which Cloudflare gives as a page number or a cursor rather than an address,
/// goes to api.cloudflare.com under /client/v4, and nowhere else; only dns-exposure also looks the targets of a zone's
/// records up, at Cloudflare's own DNS-over-HTTPS resolver, cloudflare-dns.com, carrying no token and nothing of the
/// connection. Cloudflare Radar is a separate tool on Cloudflare's own MCP server.
///
/// Both tools' guide is Incubator/Pion/docs/tools/cloudflare.md. Change it with the setup steps, scopes or operations
/// here.
public enum Cloudflare {
    public static let preset = ToolDefinition(
        id: "a975fdab-e1f0-486c-abf6-d941d667d6f7", name: "Cloudflare Detection",
        summary: "Zones, their DNS and security settings, firewall events, the audit log and members at the edge, and Access logins, apps, users, Gateway activity and rules, WARP devices and tunnels in Zero Trust, read-only.",
        defaultInstructions: """
        Use Cloudflare Detection to see an account from Cloudflare's side. At the edge: zones and zone-dns list zones and \
        their DNS records; firewall-events reads what the WAF and firewall did to requests, by client IP, country, \
        path and rule; audit-log reads who changed what in the account and from where; members lists who holds which \
        role and whether they use 2FA. To audit how zones are set up, \
        zone-settings reads each zone's SSL/TLS mode, minimum TLS, HTTPS enforcement, HSTS, DNSSEC and WAF managed rules, \
        weak ones first; dns-exposure groups a zone's records that point outside it by provider, for the champion to \
        confirm each is still in use, and marks CNAMEs whose target doesn't resolve, which is a lead to confirm and never \
        proof of a takeover. In Zero Trust: access-logs reads who \
        signed in to which Access application, allowed or blocked, from which IP address and country; access-apps and \
        access-app read applications and their policies; access-users and access-user read users, their last login \
        and active sessions; gateway-activity reads Gateway's DNS, HTTP and network decisions; gateway-rules and \
        gateway-lists read Gateway's policies and lists; devices reads WARP devices with their posture results; \
        tunnels reads Cloudflare Tunnels and their connections. The alert watch checks every five minutes and wakes \
        you with a note naming security-events, which reads what it found for the note's window: high-risk changes in \
        the audit log, such as API tokens made, members and roles added, DNS changes on a zone's apex, MX or NS \
        records, firewall or Gateway rules turned off or deleted, Access policies changed, devices revoked and tunnels \
        made, and bursts of blocked Access logins. A note may name a feed the watch could not read: security-events \
        says why, so tell the champion and treat that feed's silence as unknown. When a tool is refused or something \
        you need seems missing, run check-access and tell the champion exactly what it says to change: an account may \
        use only the edge or only Zero Trust, and the sign-in may cover only part. Silence is not proof: every result \
        says when it stopped before reading everything or matched more than it kept. Record each finding as evidence, \
        citing the zone, application, user or device and the time window. These tools only read: recommend blocking \
        an address or revoking a session to the champion, or use Cloudflare Containment, with the target, why, and \
        how to undo it.
        """,
        iconName: "cloudflare",
        configuration: .connection(.init(endpointTemplate: "https://api.cloudflare.com/client/v4", fields: fields,
                                         oauth: oauth(scopes: auditScopes), oauthClientField: "clientID", adapter: "cloudflare")),
        setup: setup)

    /// Cloudflare Radar's MCP server: the Internet as Cloudflare's network sees it, through any Cloudflare account's
    /// sign-in. It knows nothing of the account's own zones, which Cloudflare Detection reads.
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

    static let fields = [ToolField(key: "account", title: "Account ID", placeholder: "023e105f4ecef8ad9ca31a8372d0c353", kind: .identifier),
                         ToolField(key: "clientID", title: "Client ID", placeholder: "54d11594-84e4-41aa-b438-e81b8fa78ee7", kind: .identifier)]

    /// Cloudflare's authorization server, the dashboard's, which alone issues tokens for its API. Every sign-in asks for
    /// the member's password again, so a browser already signed in to the dashboard as someone else never answers for
    /// them.
    static func oauth(scopes: [String]) -> MCPOAuthConfiguration {
        MCPOAuthConfiguration(issuer: URL(string: "https://dash.cloudflare.com")!,
                              authorizationEndpoint: URL(string: "https://dash.cloudflare.com/oauth2/auth")!,
                              tokenEndpoint: URL(string: "https://dash.cloudflare.com/oauth2/token")!, clients: [],
                              scopes: scopes, authorizationParameters: ["prompt": "login"],
                              usesResourceIndicator: false, revocationEndpoint: URL(string: "https://dash.cloudflare.com/oauth2/revoke")!,
                              unlistedScopes: ["offline_access"])
    }

    /// Only reading scopes, by Cloudflare's names, which are its API token permissions': the account's settings, with
    /// its audit log and members; Zero Trust; account analytics, for Gateway activity; tunnels; and each zone, its DNS,
    /// analytics, settings and WAF.
    static let auditScopes = ["account-settings.read", "teams.read", "account-analytics.read", "argotunnel.read",
                              "zone.read", "dns.read", "analytics.read", "zone-settings.read", "zone-waf.read"]

    static func clientSteps(_ name: String, scopes: [String]) -> [String] {
        [
            "In the Cloudflare dashboard, open **Manage Account › OAuth clients** and choose **Create client**. Name it \(name), kept for this tool alone. Making one takes the Super Administrator, Administrator or OAuth Client Write role. Keep it private, the default, so only members of this account can sign in through it.",
            "Choose the response type **code**, the grant types **Authorization Code** and **Refresh Token**, and the token authentication method **None**: Pion signs in with PKCE and keeps no client secret. Give exactly \(Okta.redirects) as the **Redirect URL**.",
            "Choose **Continue** and add exactly these scopes, marking them required if the dashboard offers it: \(scopes.map { "`\($0)`" }.joined(separator: ", ")). Pion asks for these and `offline_access`, and refuses a sign-in that lacks any of these. Then choose **Create client**.",
        ]
    }

    /// The last step of each tool's setup: the account, the client and the member who signs in.
    static let connectStep = "Give the **Account ID**, on the account's **Overview** page or in the **API** section of any zone's **Overview** page (32 hexadecimal characters), and the client's **Client ID**. Choose **Add & Connect** and sign in as that member; when Cloudflare asks which accounts the client may reach, choose only this one. Then ask an agent to run check-access."

    static let setup = clientSteps("Pion Detection", scopes: auditScopes) + [
        "Cloudflare allows a request only when both the client's scopes and the signed-in member's role allow it, so Pion Detection's scopes only read, whatever the member may do. Keep a member of this account for Pion Detection alone, such as pion-detection@example.com, with the **Administrator Read Only** role under **Manage Account › Members**. An account that uses only the edge, or only Zero Trust, still adds every scope; check-access says which parts the sign-in reaches.",
        connectStep,
    ]

    /// Every operation of both tools, each naming the jobs it serves; each tool offers those of its own job.
    static let operations: [any ServiceOperation] = [
        Zones(), ZoneDNS(), ZoneSettings(), DNSExposure(), FirewallEvents(), AuditLog(), Members(), AccessLogs(), AccessApps(), AccessApp(), AccessUsers(),
        AccessUser(), GatewayActivity(), GatewayRules(), GatewayLists(), Devices(), Tunnels(), SecurityEvents(), CheckAccess(),
        ContainmentAccessUser(), ContainmentDevice(), ActionStatus(), BlockIP(), BlockASN(), BlockCountry(), Unblock(), RevokeAccessSessions(),
        GatewayBlock(), GatewayUnblock(), RevokeDevice(), ContainmentCheckAccess(),
    ]

    public static let adapter = OperationAdapter(operations: operations, job: .detection, trigger: NewSecurityEvents(), simultaneousRequests: 4)

    // MARK: Limits

    /// The most pages one listing reads.
    static let maximumPages = 10
    /// How far back searches by time may reach.
    static let keptDays = 365.0

    // MARK: Requests

    static let host = "api.cloudflare.com"
    static let basePath = "/client/v4"

    /// The API the connection reaches, or a refusal before anything is sent: https, no port or user, api.cloudflare.com
    /// and /client/v4.
    static func api(_ service: ServiceClient) throws {
        guard service.base.scheme?.lowercased() == "https", service.base.host?.lowercased() == host, service.base.port == nil, service.base.user == nil,
              service.base.path == basePath else {
            throw ServiceError.input("Nothing was sent: this connection does not reach https://\(host)\(basePath), which is all Pion reaches for Cloudflare. Add the tool again in Settings › Tools.")
        }
    }

    /// The account the connection names: 32 hexadecimal characters, lowercased, or a refusal before anything is sent.
    static func account(_ service: ServiceClient) throws -> String {
        let value = try service.setting("account").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let id = hex32(value) else {
            throw ServiceError.input("Nothing was sent: this connection's Account ID is not 32 hexadecimal characters as Cloudflare gives it. Copy it from the account's Overview page into Settings › Tools.")
        }
        return id
    }

    /// How long Pion itself waits, at most, for Cloudflare's rate limit before trying once more.
    static let patience = 20.0
    /// How Pion waits; tests pass time without it.
    @TaskLocal static var pause: @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }

    /// One request to api.cloudflare.com, with every answer back for the caller to judge.
    static func raw(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], method: String = "GET",
                    body: Data? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        try api(service)
        var answer = try await service.exchange(path, query: query, method: method, body: body, returning: Set(300...599))
        // The transport has tried a 429 again on its own back-off; when Cloudflare says how long to wait and it is soon,
        // wait once more. A 429 means it did nothing with the request, so even a change may go again.
        if answer.response.statusCode == 429, let wait = CrowdStrike.retryWait(answer.response), wait <= patience {
            await pause(wait)
            answer = try await service.exchange(path, query: query, method: method, body: body, returning: Set(300...599))
        }
        return answer
    }

    static func exchange(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], method: String = "GET",
                         body: Data? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        let answer = try await raw(service, path, query: query, method: method, body: body)
        try check(answer)
        return answer
    }

    /// Error codes Cloudflare gives for an Authorization header it cannot read as a token at all.
    static let malformedTokenCodes: Set<Int> = [6003, 6100, 6101, 6102, 6103, 6111]

    /// What Cloudflare said when it refused: each error in its list, or the usual fields.
    static func reason(_ data: Data) -> String? {
        if let errors = try? JSONDecoder().decode(Errors.self, from: data), let problems = errors.problems { return String(problems.prefix(300)) }
        return ServiceClient.reason(data)
    }

    /// Throws for any answer but a success, in Cloudflare's own words.
    static func check(_ answer: (data: Data, response: HTTPURLResponse)) throws {
        let status = answer.response.statusCode, said = reason(answer.data)
        switch status {
        case 200..<300: return
        case 429:
            let wait = CrowdStrike.retryWait(answer.response).map { "Cloudflare asked to wait \(Int($0.rounded(.up))) seconds before trying again" }
            throw ServiceError.rateLimited([wait, said].compactMap { $0 }.joined(separator: "; "))
        case 401: throw ServiceError.rejected(said)
        case 403: throw ServiceError.forbidden(said)
        case 404: throw ServiceError.notFound
        case 400 where !((try? JSONDecoder().decode(Errors.self, from: answer.data))?.codes ?? []).isDisjoint(with: malformedTokenCodes):
            throw ServiceError.rejected(said)
        case 400, 405, 409, 412, 422: throw said.map(ServiceError.refused) ?? ServiceError.status(status)
        default: throw ServiceError.status(status, said)
        }
    }

    // MARK: Answers

    /// One error Cloudflare listed, read loosely, as an entry without a message is an error all the same.
    struct Problem: Decodable, Sendable {
        let code: Int?, message: String?
        enum Keys: String, CodingKey { case code, message }
        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Keys.self) else { code = nil; message = nil; return }
            code = ((try? container.decodeIfPresent(Int.self, forKey: .code)) ?? nil)
                ?? ((try? container.decodeIfPresent(String.self, forKey: .code)) ?? nil).flatMap { Int($0) }
            message = ((try? container.decodeIfPresent(String.self, forKey: .message)) ?? nil).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
        }
        var said: String {
            switch (code, message) {
            case let (code?, message?): "\(message) (code \(code))"
            case let (nil, message?): message
            case let (code?, nil): "error \(code) without a message"
            case (nil, nil): "an error without a message or code"
            }
        }
    }

    static func problems(_ errors: [Problem]?) -> String? {
        (errors ?? []).isEmpty ? nil : (errors ?? []).prefix(3).map(\.said).joined(separator: "; ")
    }

    /// Cloudflare's paging, read strictly: each field null, left out, or of its own type. A count that is not a whole
    /// number, or a cursor that is not text, makes the whole answer unreadable rather than one without them.
    struct Info: Decodable, Sendable {
        let page: Int?, perPage: Int?, count: Int?, totalCount: Int?, totalPages: Int?, cursor: String?
        enum Keys: String, CodingKey { case page, per_page, count, total_count, total_pages, cursor }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            page = try container.decodeIfPresent(Int.self, forKey: .page)
            perPage = try container.decodeIfPresent(Int.self, forKey: .per_page)
            count = try container.decodeIfPresent(Int.self, forKey: .count)
            totalCount = try container.decodeIfPresent(Int.self, forKey: .total_count)
            totalPages = try container.decodeIfPresent(Int.self, forKey: .total_pages)
            cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        }
    }

    /// Cloudflare's envelope: whether it succeeded, its errors, its result and its paging. An answer that does not say
    /// it succeeded, or carries any error, with a message or without, is never taken as a result; a result it leaves
    /// out is unreadable, never empty.
    struct Envelope<Result: Decodable>: Decodable {
        let success: Bool?
        let errors: [Problem]?
        let result: Result?
        let info: Info?
        enum Keys: String, CodingKey { case success, errors, result, result_info }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            success = try container.decodeIfPresent(Bool.self, forKey: .success)
            errors = try container.decodeIfPresent([Problem].self, forKey: .errors)
            result = try container.decodeIfPresent(Result.self, forKey: .result)
            info = try container.decodeIfPresent(Info.self, forKey: .result_info)
        }
        var problems: String? { Cloudflare.problems(errors) }

        func value() throws -> Result {
            if let problems { throw ServiceError.refused(problems) }
            guard success == true else {
                throw success == false ? ServiceError.refused("Cloudflare said the request did not succeed, without saying why") : ServiceError.unreadable
            }
            guard let result else { throw ServiceError.unreadable }
            return result
        }
    }

    /// Only the errors of an answer, whatever its result.
    struct Errors: Decodable {
        let errors: [Problem]?
        var problems: String? { Cloudflare.problems(errors) }
        var codes: Set<Int> { Set((errors ?? []).compactMap(\.code)) }
    }

    static func decode<Value: Decodable>(_ data: Data, as: Value.Type = Value.self) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) } catch { throw ServiceError.unreadable }
    }

    /// One result, read whole: a success with no error and a result.
    static func get<Result: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], as: Result.Type) async throws -> Result {
        let envelope: Envelope<Result> = try decode(try await exchange(service, path, query: query).data)
        return try envelope.value()
    }

    // MARK: Values

    /// Any JSON value, so a resource is read field by field and a field Cloudflare leaves out or gives in another
    /// shape is unknown rather than a failure.
    indirect enum Value: Decodable, Sendable, Equatable {
        case text(String), number(Double), flag(Bool), list([Value]), object([String: Value]), null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let flag = try? container.decode(Bool.self) { self = .flag(flag) }
            else if let number = try? container.decode(Double.self) { self = .number(number) }
            else if let text = try? container.decode(String.self) { self = .text(text) }
            else if let list = try? container.decode([Value].self) { self = .list(list) }
            else { self = .object(try container.decode([String: Value].self)) }
        }

        /// The value at a dotted path, such as configuration.value.
        subscript(_ path: String) -> Value? {
            var value: Value? = self
            for key in path.split(separator: ".") {
                guard case .object(let object)? = value else { return nil }
                value = object[String(key)]
            }
            return value
        }

        var text: String? {
            switch self {
            case .text(let text): text.isEmpty ? nil : text
            case .number(let number): number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
            case .flag(let flag): String(flag)
            default: nil
            }
        }
        var flag: Bool? { if case .flag(let flag) = self { return flag }; return nil }
        var number: Int? { if case .number(let number) = self, number.rounded() == number, abs(number) < 1e15 { return Int(number) }; return nil }
        var items: [Value]? { if case .list(let list) = self { return list }; return nil }
        var texts: [String] { items?.compactMap(\.text) ?? [] }
        var object: [String: Value]? { if case .object(let object) = self { return object }; return nil }

        /// Every text, number and flag in it, at any depth, without the keys that hold them.
        var words: [String] {
            switch self {
            case .text, .number, .flag: [text].compactMap { $0 }
            case .list(let list): list.flatMap(\.words)
            case .object(let object): object.sorted { $0.key < $1.key }.flatMap { $0.value.words }
            case .null: []
            }
        }
    }

    /// A resource as Cloudflare gives it, field by field; only its ID must be there, in the shape `valid` takes, and
    /// one without it is unreadable.
    struct Item: Decodable, Sendable {
        let fields: Value
        let id: String

        init(fields: Value, id: String) { self.fields = fields; self.id = id }

        init(from decoder: Decoder) throws {
            let fields = try Value(from: decoder)
            guard case .object = fields, let raw = fields["id"]?.text?.lowercased(), Cloudflare.anyID(raw) != nil else { throw ServiceError.unreadable }
            self.fields = fields
            id = raw
        }

        func text(_ path: String) -> String? { fields[path]?.text }
        func flag(_ path: String) -> Bool? { fields[path]?.flag }
        func number(_ path: String) -> Int? { fields[path]?.number }
        func texts(_ path: String) -> [String] { fields[path]?.texts ?? [] }
    }

    // MARK: Paging

    /// How a listing pages: by page number, by cursor, or not at all, for the few lists Cloudflare gives in one answer.
    enum Paging: Sendable { case pages, cursor, single }

    /// Where a listing that stopped at its page or item limit goes on: a page number or a cursor, each good only with
    /// the query it came from.
    struct Resume: Sendable, Equatable {
        var page: Int? = nil
        var cursor: String? = nil
    }

    struct Listing<Item> {
        var value: [Item] = []
        /// Whether more remained when it stopped.
        var more = false
        var pages = 0
        /// How many Cloudflare said match, when it said.
        var total: Int? = nil
        /// Why it stopped before the end, when not for its page or item limit, such as a page that failed or paging
        /// that contradicted itself.
        var stopped: String? = nil
        var stoppedAt: Int? = nil
        /// Where the next page starts, when it stopped at its page or item limit with more to read.
        var next: Resume? = nil
        var complete: Bool { !more && stopped == nil }
    }

    /// A listing, page after page of `size`, up to `pages` or until `limit` items are kept. Each next page asks the same
    /// path with the same query and the next page number, or the cursor the last page gave; `from` goes on from where a
    /// listing stopped before, which must come with the query it came from.
    ///
    /// Page paging ends at the total pages or count Cloudflare gives, or at a short page when it gives neither; cursor
    /// paging ends at a page without a cursor. It stops, saying so, where the paging contradicts itself: a page other
    /// than the one asked for, a count that differs from what the page holds, a total of none with items or a cursor,
    /// items beyond the total, a total not reached when the pages end, an empty page that says more follow, or a cursor
    /// Pion will not follow or given twice. When a page after the first fails, what earlier pages held is kept and the
    /// listing says where and why it stopped, unless `partial` is false, for a reader that must have all or nothing; a
    /// first page that fails or contradicts itself fails the listing.
    static func list<Element: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?], as: Element.Type, paging: Paging = .pages,
                                         size: Int, sizeKey: String = "per_page", pages: Int = maximumPages, limit: Int? = nil, from: Resume? = nil,
                                         partial: Bool = true) async throws -> Listing<Element> {
        var page = from?.page ?? 1
        var cursor = from?.cursor
        var found = Listing<Element>()
        func stop(_ reason: String) throws -> Listing<Element> {
            guard partial, found.pages > 0 else { throw ServiceError.input("Cloudflare's answer could not be relied on: \(reason).") }
            found.more = true
            found.next = nil
            found.stoppedAt = found.pages + 1
            found.stopped = reason
            return found
        }
        if paging == .single {
            let envelope: Envelope<[Element]> = try decode(try await exchange(service, path, query: query).data)
            let items = try envelope.value()
            if let count = envelope.info?.count, count != items.count { return try stop("Cloudflare counted \(count) in an answer that held \(items.count)") }
            if let total = envelope.info?.totalCount, total < items.count || (total == 0 && !items.isEmpty) {
                return try stop("Cloudflare said \(total) match but gave \(items.count)")
            }
            found.pages = 1
            found.value = items
            found.total = envelope.info?.totalCount
            // Any sign of more, even from a list that normally comes in one answer, leaves it incomplete.
            let more: String? = if let total = envelope.info?.totalCount, total > items.count { "Cloudflare said \(total) match but gave \(items.count) in the one answer it gives" }
                else if let pages = envelope.info?.totalPages, pages > 1 { "Cloudflare said there are \(pages) pages but gave one answer" }
                else if let cursor = envelope.info?.cursor, !cursor.isEmpty { "Cloudflare gave a next page that a list given in one answer does not follow" }
                else { nil }
            if let more {
                found.more = true
                found.stoppedAt = 2
                found.stopped = more
            }
            return found
        }
        // How many came before this listing's first page, for page paging resumed from a later page.
        let before = paging == .pages ? (page - 1) * size : 0
        while found.pages < pages {
            var asked = query
            asked[sizeKey] = String(size)
            switch paging {
            case .pages: asked["page"] = String(page)
            case .cursor: if let cursor { asked["cursor"] = cursor }
            case .single: break
            }
            let items: [Element], info: Info?
            do {
                let envelope: Envelope<[Element]> = try decode(try await exchange(service, path, query: asked).data)
                items = try envelope.value()
                info = envelope.info
            } catch {
                guard partial, found.pages > 0 else { throw error }
                return try stop(error.localizedDescription)
            }
            if let count = info?.count, count != items.count { return try stop("Cloudflare counted \(count) on a page that held \(items.count)") }
            if let total = info?.totalCount, total == 0, !items.isEmpty { return try stop("Cloudflare counted none but gave \(plural(items.count, "item"))") }
            if paging == .pages, let echoed = info?.page, echoed != page { return try stop("Cloudflare answered with page \(echoed) when asked for page \(page)") }
            if let total = info?.totalCount, before + found.value.count + items.count > total {
                return try stop("Cloudflare said \(total) match but gave more")
            }
            found.pages += 1
            found.value += items
            if let total = info?.totalCount { found.total = total }
            // A sign of more the listing's own paging does not follow leaves it incomplete.
            if paging == .pages, let cursor = info?.cursor, !cursor.isEmpty { return try stop("Cloudflare gave a cursor for a next page, which page paging does not follow") }
            if paging == .cursor, from == nil, (info?.cursor ?? "").isEmpty, let total = info?.totalPages, total > found.pages {
                return try stop("Cloudflare said there are \(total) pages but gave no next page after \(found.pages)")
            }
            let read = before + found.value.count
            switch paging {
            case .pages:
                let more: Bool
                if let totalPages = info?.totalPages {
                    if totalPages == 0, !items.isEmpty { return try stop("Cloudflare said there are no pages but gave \(plural(items.count, "item"))") }
                    more = page < totalPages
                } else if let total = info?.totalCount {
                    more = read < total
                } else {
                    more = items.count >= size
                }
                if more {
                    guard !items.isEmpty else { return try stop("Cloudflare gave an empty page that said more follow") }
                    page += 1
                    found.more = true
                    found.next = Resume(page: page)
                    if let limit, found.value.count >= limit { return found }
                } else {
                    if let total = info?.totalCount, read < total { return try stop("Cloudflare said \(total) match but its pages ended after \(read)") }
                    found.more = false
                    found.next = nil
                    return found
                }
            case .single:
                return found
            case .cursor:
                if let next = info?.cursor, !next.isEmpty {
                    if info?.totalCount == 0 { return try stop("Cloudflare gave a next page while counting none") }
                    guard let token = CrowdStrike.token(next) else { return try stop("Cloudflare gave a next page Pion does not follow") }
                    guard token != cursor else { return try stop("Cloudflare gave the same next page again") }
                    guard !items.isEmpty else { return try stop("Cloudflare gave an empty page that said more follow") }
                    cursor = token
                    found.more = true
                    found.next = Resume(cursor: token)
                    if let limit, found.value.count >= limit { return found }
                } else {
                    if from == nil, let total = found.total, found.value.count < total {
                        return try stop("Cloudflare said \(total) match but gave no next page after \(found.value.count)")
                    }
                    found.more = false
                    found.next = nil
                    return found
                }
            }
        }
        return found
    }

    static func stopped<Element>(_ listing: Listing<Element>, _ name: String) -> String {
        if let reason = listing.stopped {
            return "\nIncomplete: stopped at page \(listing.stoppedAt ?? listing.pages + 1) reading \(name) because \(reason); what the \(plural(listing.pages, "page")) before held is kept."
        }
        return listing.more ? "\nIncomplete: stopped after \(plural(listing.pages, "page")) reading \(name), the most read at once; more remain\(listing.total.map { ", of \($0) Cloudflare said match" } ?? "")." : ""
    }

    /// What a listing kept, said: the lines, and when more matched than it kept or it stopped early.
    static func summary<Element>(_ listing: Listing<Element>, limit: Int, name: String, narrow: String) -> (kept: [Element], cut: Bool, notice: String) {
        let kept = Array(listing.value.prefix(limit))
        let cut = listing.value.count > limit || (listing.more && listing.stopped == nil)
        var notice = cut ? "\nMore \(name) match than the \(kept.count) kept\(listing.total.map { " (Cloudflare says \($0) match)" } ?? ""): \(narrow)." : ""
        if listing.stopped != nil || !cut { notice += stopped(listing, name) }
        return (kept, cut, notice)
    }

    /// What Cloudflare says of one thing asked for by its exact ID.
    enum Lookup<Element> {
        case present(Element)
        /// Cloudflare said plainly it holds none: a whole, error-free listing that does not name it.
        case absent
        /// Anything else, which shows neither: errors, the same ID twice, a listing cut short or contradicting itself,
        /// or an answer that could not be read.
        case inconclusive(String)
    }

    /// One thing by its exact ID, from a listing read whole: absent only when every page was read without error and
    /// the paging agreed with itself, present only when exactly one item has the ID.
    ///
    /// `filtered` is for a listing asked for that ID alone: then any other item, or a count other than what it gave,
    /// shows the filter was not applied as asked, and nothing is concluded.
    static func find(_ service: ServiceClient, _ path: [String], query: [String: String?], id: String, what: String, size: Int = 50,
                     sizeKey: String = "per_page", pages: Int = maximumPages, paging: Paging = .pages, filtered: Bool = false) async throws -> Lookup<Item> {
        let listing: Listing<Item>
        do {
            listing = try await list(service, path, query: query, as: Item.self, paging: paging, size: size, sizeKey: sizeKey, pages: pages, partial: false)
        } catch let error as ServiceError {
            switch error {
            case .rejected, .forbidden, .rateLimited: throw error
            default: return .inconclusive("reading \(what) \(id): \(error.localizedDescription)")
            }
        }
        guard listing.complete else { return .inconclusive("Cloudflare listed more than Pion reads at once, so \(what) \(id) may be among those not read") }
        let named = listing.value.filter { $0.id == id }
        if filtered {
            let others = listing.value.filter { $0.id != id }.map(\.id)
            if !others.isEmpty { return .inconclusive("Cloudflare answered for \(others.prefix(3).joined(separator: ", ")), not \(what) \(id) alone") }
            if let total = listing.total, total != listing.value.count { return .inconclusive("Cloudflare counted \(total) for \(what) \(id) but gave \(plural(listing.value.count, "item"))") }
        }
        switch named.count {
        case 0: return .absent
        case 1: return .present(named[0])
        default: return .inconclusive("Cloudflare names \(what) \(id) \(named.count) times")
        }
    }

    /// One thing by its exact ID, from its own address: present only when Cloudflare answers with success, no error,
    /// and that very ID. Cloudflare documents no error code meaning that a resource of these kinds is not there, so a
    /// 404 or any error is never taken for absence.
    static func fetch(_ service: ServiceClient, _ path: [String], id: String, what: String) async throws -> Lookup<Item> {
        let answer = try await raw(service, path)
        switch answer.response.statusCode {
        case 401, 403, 429: try check(answer)
        case 200..<300: break
        default:
            return .inconclusive("Cloudflare answered \(answer.response.statusCode) for \(what) \(id)\(reason(answer.data).map { " (it said: \($0))" } ?? ""), which does not say it is gone")
        }
        guard let envelope = try? JSONDecoder().decode(Envelope<Item>.self, from: answer.data) else {
            return .inconclusive("Cloudflare's answer for \(what) \(id) could not be read")
        }
        if let problems = envelope.problems { return .inconclusive("Cloudflare's answer for \(what) \(id) carried errors: \(problems)") }
        guard envelope.success == true, let item = envelope.result else { return .inconclusive("Cloudflare's answer for \(what) \(id) did not say it succeeded with a result") }
        guard item.id == id else { return .inconclusive("Cloudflare answered for \(item.id), not \(what) \(id)") }
        return .present(item)
    }

    /// A window of at most `maximum` days, since before until; `days` back from now when since is left out.
    static func window(_ since: String?, _ until: String?, days: Double, maximum: Double = keptDays) throws -> (since: Date, until: Date) {
        try CrowdStrike.window(since, until, days: days, maximum: maximum)
    }

    static func iso(_ date: Date) -> String { Entra.iso(date) }

    // MARK: Refusals

    /// What one thing a tool reads or does needs: the sign-in's scope, by Cloudflare's name, which is also its API
    /// token permission's.
    struct Need: Sendable {
        let title: String
        let scope: String
        /// Whether it belongs to Zero Trust, which an account may not use.
        var zeroTrust = false
        /// Whether it is read per zone, so the member's role must reach the zone.
        var zone = false
    }

    static let zonesNeed = Need(title: "Zones", scope: "zone.read", zone: true)
    static let dnsNeed = Need(title: "DNS records", scope: "dns.read", zone: true)
    static let firewallNeed = Need(title: "Firewall events", scope: "analytics.read", zone: true)
    static let auditNeed = Need(title: "The account audit log", scope: "account-settings.read")
    static let membersNeed = Need(title: "Members", scope: "account-settings.read")
    static let accessLogsNeed = Need(title: "Access authentication logs", scope: "teams.read", zeroTrust: true)
    static let accessAppsNeed = Need(title: "Access applications and policies", scope: "teams.read", zeroTrust: true)
    static let accessUsersNeed = Need(title: "Access users and their sessions", scope: "teams.read", zeroTrust: true)
    static let gatewayActivityNeed = Need(title: "Gateway activity", scope: "account-analytics.read", zeroTrust: true)
    static let gatewayNeed = Need(title: "Gateway rules and lists", scope: "teams.read", zeroTrust: true)
    static let devicesNeed = Need(title: "WARP devices", scope: "teams.read", zeroTrust: true)
    static let tunnelsNeed = Need(title: "Cloudflare Tunnels", scope: "argotunnel.read", zeroTrust: true)

    /// Whether Cloudflare refused because the account lacks what is asked for, such as Zero Trust or a plan's
    /// feature, rather than a permission.
    static func unlicensed(_ error: Error) -> Bool {
        let said: String
        switch error {
        case ServiceError.forbidden(let reason?), ServiceError.refused(let reason), ServiceError.status(_, let reason?): said = reason.lowercased()
        default: return false
        }
        return ["not entitled", "entitlement", "not enabled", "subscription", "upgrade your plan", "plan does not", "not available on your plan",
                "does not have access to the path", "zero trust is not", "teams account"].contains(where: said.contains)
    }

    /// What to change when a request was refused; nil for any other failure.
    static func fix(for error: Error, _ need: Need) -> String? {
        switch error {
        case ServiceError.rejected:
            return "Cloudflare did not accept the sign-in: it expired or was revoked, the OAuth client was deleted or lost its Refresh Token grant, or the member left the account. Connect the tool again in Settings › Tools."
        case _ where unlicensed(error):
            return need.zeroTrust ? "the account does not have this part of Zero Trust, or Zero Trust is not set up for it, so it cannot be read."
                : "the account or zone does not have this on its plan, so it cannot be read."
        case ServiceError.forbidden:
            // Cloudflare does not say which: a scope the sign-in lacks, the member's role, or an account left out at sign-in.
            return "the sign-in lacks the scope \(need.scope), or the signed-in member's role does not allow this \(need.zone ? "in this zone" : "in this account"), or this account was not chosen when signing in. Add the scope to the Cloudflare OAuth client (Manage Account › OAuth clients) if it is missing and connect the tool again in Settings › Tools, choosing this account; otherwise give the member a role that allows it."
        default: return nil
        }
    }

    /// A request, with a refusal said as what to change.
    static func read<Result>(_ need: Need, _ body: () async throws -> Result) async throws -> Result {
        do { return try await body() } catch {
            guard let fix = fix(for: error, need) else { throw error }
            let said: String? = switch error {
            case ServiceError.forbidden(let reason), ServiceError.rejected(let reason): reason
            default: nil
            }
            throw ServiceError.input("Cloudflare refused \(need.title.lowercased())\(said.map { " (it said: \($0))" } ?? ""): \(fix) Running check-access shows which parts the sign-in reaches.")
        }
    }

    // MARK: Inputs

    /// An ID as Cloudflare gives accounts, zones, IP Access rules and tokens: 32 hexadecimal characters.
    static func hex32(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.count == 32 && value.allSatisfy(\.isHexDigit) && value.allSatisfy(\.isASCII) ? value : nil
    }

    /// An ID as Cloudflare gives Zero Trust's applications, policies, users, lists, rules, devices and tunnels: a UUID,
    /// lowercased.
    static func uuid(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.count == 36 && UUID(uuidString: value) != nil ? value : nil
    }

    /// Either kind of ID, for a resource read before it is known which.
    static func anyID(_ value: String) -> String? {
        if let id = hex32(value) ?? uuid(value) { return id }
        // Some resources, such as audit log entries and members, give other printable IDs.
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...128).contains(value.count) && value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:".contains($0)) }) ? value : nil
    }

    static func requireUUID(_ value: String, _ name: String) throws -> String {
        guard let id = uuid(value) else { throw ServiceError.input("Give \(name) as Cloudflare gives it: a UUID, such as 6f9d2a3c-1b2e-4f5a-8c7d-0e1f2a3b4c5d.") }
        return id
    }

    static func requireHex(_ value: String, _ name: String) throws -> String {
        guard let id = hex32(value) else { throw ServiceError.input("Give \(name) as Cloudflare gives it: 32 hexadecimal characters.") }
        return id
    }

    static func plural(_ count: Int, _ word: String) -> String {
        guard count != 1 else { return "1 \(word)" }
        if word.hasSuffix("y"), let before = word.dropLast().last, !"aeiou".contains(before) { return "\(count) \(word.dropLast())ies" }
        return "\(count) \(word)s"
    }

    /// A limit given, or its default, within its bounds.
    static func limit(_ value: Int?, default fallback: Int, maximum: Int, _ name: String) throws -> Int {
        let limit = value ?? fallback
        guard (1...maximum).contains(limit) else { throw ServiceError.input("Ask for between 1 and \(maximum) \(name).") }
        return limit
    }

    /// A zone's ID from its name: the one zone of this account with exactly that name, read whole.
    static func zone(_ name: String, on service: ServiceClient) async throws -> String {
        let domain = try ServiceInput.domain(name)
        let account = try account(service)
        let listing = try await read(zonesNeed) {
            try await list(service, ["zones"], query: ["name": domain, "account.id": account], as: Item.self, size: 50, pages: 2, partial: false)
        }
        let named = listing.value.filter { $0.text("name")?.lowercased() == domain }
        guard listing.complete, named.count == listing.value.count else {
            throw ServiceError.input("Cloudflare's answer for zone \(domain) named other zones too, so which one is meant could not be told.")
        }
        switch named.count {
        case 0: throw ServiceError.input("This account has no zone \(domain) that the sign-in can see: check the name, or that the signed-in member's role reaches it.")
        case 1:
            guard let id = hex32(named[0].id) else { throw ServiceError.input("Cloudflare gave zone \(domain) an ID Pion does not recognise.") }
            return id
        default: throw ServiceError.input("Cloudflare named zone \(domain) \(named.count) times, so which one is meant could not be told.")
        }
    }

    // MARK: GraphQL

    struct GraphQLRequest<Variables: Encodable>: Encodable { let query: String; let variables: Variables }
    struct GraphQLResponse<Answer: Decodable>: Decodable { let data: Answer?; let errors: [Problem]? }

    /// A GraphQL query to Cloudflare's Analytics API and its data: an answer carrying any error, with a message or
    /// without, is an error, and one without data is unreadable.
    static func graphQL<Answer: Decodable, Variables: Encodable>(_ service: ServiceClient, query: String, variables: Variables, as: Answer.Type) async throws -> Answer {
        let body = try JSONEncoder().encode(GraphQLRequest(query: query, variables: variables))
        let answer = try await exchange(service, ["graphql"], method: "POST", body: body)
        let response: GraphQLResponse<Answer> = try decode(answer.data)
        if let problems = problems(response.errors) { throw ServiceError.refused(problems) }
        guard let data = response.data else { throw ServiceError.unreadable }
        return data
    }
}

// MARK: - Edge

extension Cloudflare {
    struct Zones: ServiceOperation {
        struct Input: Decodable, Sendable { let name: String?, limit: Int? }
        static let name = "zones"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The account's zones the sign-in can see, with each one's ID, status, plan, type, whether it is paused, its name servers and when it was activated, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "name": .string("Only the zone with this exact domain, such as example.com."),
            "limit": .integer("How many zones, at most. 200 when left out.", minimum: 1, maximum: 1_000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = ["account.id": try Cloudflare.account(service)]
            if let name = input.name { query["name"] = try ServiceInput.domain(name) }
            let limit = try Cloudflare.limit(input.limit, default: 200, maximum: 1_000, "zones")
            let listing = try await Cloudflare.read(Cloudflare.zonesNeed) {
                try await Cloudflare.list(service, ["zones"], query: query, as: Item.self, size: 50, pages: 20, limit: limit)
            }
            let (zones, cut, notice) = Cloudflare.summary(listing, limit: limit, name: "zones", narrow: "give a name")
            let lines = zones.map { zone in
                var parts = [zone.text("status") ?? "status not given", "plan \(zone.text("plan.name") ?? "not given")", "\(zone.text("type") ?? "type not given") setup"]
                if zone.flag("paused") == true { parts.append("paused, so Cloudflare passes its traffic through unprotected") }
                let servers = zone.texts("name_servers")
                if !servers.isEmpty { parts.append("name servers \(servers.joined(separator: ", "))") }
                parts.append("activated \(zone.text("activated_on") ?? "not given")")
                return "\(zone.text("name") ?? "unnamed") [\(zone.id)]: " + parts.joined(separator: ", ")
            }
            let text = (zones.isEmpty ? "The sign-in sees no zone in this account\(listing.complete ? "" : " in what was read")." : "\(Cloudflare.plural(zones.count, "zone")):\n" + lines.joined(separator: "\n")) + notice
            struct Kept: Encodable { let zones: [String]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(zones: lines, total: listing.total, complete: listing.complete && !cut))
        }
    }

    static let dnsTypes = ["A", "AAAA", "CNAME", "MX", "NS", "TXT", "SRV", "CAA", "PTR", "HTTPS", "SVCB", "DS", "DNSKEY", "CERT", "LOC", "NAPTR", "SMIMEA", "SSHFP", "TLSA", "URI"]

    struct ZoneDNS: ServiceOperation {
        struct Input: Decodable, Sendable { let zone: String, type: String?, name: String?, limit: Int? }
        static let name = "zone-dns"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "A zone's DNS records, read whole, with whether each is proxied, its TTL and when it last changed, the apex, MX and NS records first, optionally of one type or whose name contains some words; says when it read only part."
        static let input = JSONSchema.object([
            "zone": .string("The zone's domain, such as example.com."),
            "type": .string("Only records of this type.", oneOf: Cloudflare.dnsTypes),
            "name": .string("Only records whose name contains this, such as mail."),
            "limit": .integer("How many records to show, at most. 300 when left out.", minimum: 1, maximum: 5_000),
        ], required: ["zone"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let domain = try ServiceInput.domain(input.zone)
            var query: [String: String?] = [:]
            if let type = input.type { query["type"] = try ServiceInput.oneOf(type.uppercased(), Cloudflare.dnsTypes, "type") }
            let words = try input.name.map { try ServiceInput.quoted($0, "the name").lowercased() }
            let limit = try Cloudflare.limit(input.limit, default: 300, maximum: 5_000, "records")
            let id = try await Cloudflare.zone(domain, on: service)
            let listing = try await Cloudflare.read(Cloudflare.dnsNeed) {
                try await Cloudflare.list(service, ["zones", id, "dns_records"], query: query, as: Item.self, size: 500, pages: 10)
            }
            let matching = listing.value.filter { words == nil || ($0.text("name")?.lowercased().contains(words!) ?? false) }
            func key(_ record: Item) -> Bool { record.text("name")?.lowercased() == domain || ["MX", "NS"].contains(record.text("type")?.uppercased() ?? "") }
            let ordered = matching.filter(key) + matching.filter { !key($0) }
            let shown = Array(ordered.prefix(limit))
            let lines = shown.map { record in
                "\(record.text("type") ?? "?") \(record.text("name") ?? "?") → \(String((record.text("content") ?? "?").prefix(300)))\(record.flag("proxied") == true ? " (proxied)" : "")\(record.number("ttl").map { ", TTL \($0 == 1 ? "auto" : String($0))" } ?? ""), changed \(record.text("modified_on") ?? "at a time not given")\(record.text("comment").map { " — \(String($0.prefix(200)))" } ?? "") [\(record.id)]"
            }
            var text = shown.isEmpty ? "No DNS record in \(domain) matches\(listing.complete ? "" : " in what was read")." : "\(Cloudflare.plural(shown.count, "record")) in \(domain), the apex, MX and NS first:\n" + lines.prefix(150).joined(separator: "\n")
            if shown.count > 150 { text += "\n\(shown.count - 150) more in the structured result." }
            if ordered.count > limit { text += "\n\(ordered.count - limit) more records were read but not kept." }
            text += Cloudflare.stopped(listing, "DNS records")
            struct Kept: Encodable { let zone: String; let records: [String]; let read: Int; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(zone: id, records: lines, read: listing.value.count, complete: listing.complete))
        }
    }

    static let firewallActions = ["block", "challenge", "jschallenge", "managed_challenge", "log", "allow", "bypass", "skip", "connection_close", "challenge_solved", "challenge_failed", "jschallenge_solved", "jschallenge_failed", "managed_challenge_skipped", "managed_challenge_non_interactive_solved", "managed_challenge_interactive_solved", "managed_challenge_bypassed"]

    struct FirewallEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let zone: String, ip: String?, action: String?, since: String?, until: String?, limit: Int? }
        static let name = "firewall-events"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Firewall events at a zone's edge, newest first, by client IP address, action and time, each with its action, client IP, country and network, host, method, path and query, the rule and the product that acted, and its Ray ID; says when more matched than it kept."
        static let input = JSONSchema.object([
            "zone": .string("The zone's domain, such as example.com."),
            "ip": .string("Only events from this client IP address."),
            "action": .string("Only events with this action.", oneOf: Cloudflare.firewallActions),
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 30 days back; the zone's plan may keep less."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many events, at most. 100 when left out.", minimum: 1, maximum: 1_000),
        ], required: ["zone"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try Cloudflare.window(input.since, input.until, days: 1, maximum: 30)
            var filter = ["datetime_geq": Cloudflare.iso(since), "datetime_leq": Cloudflare.iso(until)]
            if let ip = input.ip { filter["clientIP"] = try ServiceInput.ip(ip) }
            if let action = input.action { filter["action"] = try ServiceInput.oneOf(action, Cloudflare.firewallActions, "action") }
            let limit = try Cloudflare.limit(input.limit, default: 100, maximum: 1_000, "events")
            let id = try await Cloudflare.zone(input.zone, on: service)
            struct Variables: Encodable { let zoneTag: String; let filter: [String: String]; let limit: Int }
            struct Zone: Decodable { let firewallEventsAdaptive: [Value]? }
            struct Viewer: Decodable { let zones: [Zone]? }
            struct Answer: Decodable { let viewer: Viewer? }
            let query = """
            query FirewallEvents($zoneTag: string, $filter: FirewallEventsAdaptiveFilter_InputObject, $limit: uint64!) {
              viewer { zones(filter: { zoneTag: $zoneTag }) {
                firewallEventsAdaptive(filter: $filter, limit: $limit, orderBy: [datetime_DESC]) {
                  datetime action clientIP clientCountryName clientAsn clientASNDescription clientRequestHTTPHost clientRequestHTTPMethodName
                  clientRequestPath clientRequestQuery source ruleId rayName userAgent
                } } }
            }
            """
            // One more than asked for, so a result says when more matched than it kept.
            let answer = try await Cloudflare.read(Cloudflare.firewallNeed) {
                try await Cloudflare.graphQL(service, query: query, variables: Variables(zoneTag: id, filter: filter, limit: limit + 1), as: Answer.self)
            }
            guard let zones = answer.viewer?.zones, zones.count == 1, let events = zones[0].firewallEventsAdaptive else {
                throw ServiceError.input("Cloudflare's answer for \(input.zone)'s firewall events did not hold that one zone's events, so whether there were any is unknown.")
            }
            let kept = Array(events.prefix(limit))
            let lines = kept.map { event in
                var line = "\(event["datetime"]?.text ?? "?") \(event["action"]?.text ?? "?") \(event["clientIP"]?.text ?? "?")"
                let origin = [event["clientCountryName"]?.text, event["clientAsn"]?.text.map { "AS\($0)" }, event["clientASNDescription"]?.text].compactMap { $0 }
                if !origin.isEmpty { line += " (\(origin.joined(separator: ", ")))" }
                line += " \(event["clientRequestHTTPMethodName"]?.text ?? "") \(event["clientRequestHTTPHost"]?.text ?? "")\(event["clientRequestPath"]?.text ?? "")\(event["clientRequestQuery"]?.text ?? "")"
                line += " — \(event["source"]?.text ?? "product not given")\(event["ruleId"]?.text.map { " rule \($0)" } ?? "")\(event["rayName"]?.text.map { ", Ray \($0)" } ?? "")"
                return String(line.prefix(600))
            }
            let window = "from \(Cloudflare.iso(since)) to \(Cloudflare.iso(until))"
            var text = kept.isEmpty ? "No firewall events \(window) match." : "\(Cloudflare.plural(kept.count, "event")) \(window), newest first:\n" + lines.prefix(60).joined(separator: "\n")
            if kept.count > 60 { text += "\n\(kept.count - 60) more in the structured result." }
            if events.count > limit { text += "\nMore events match than the \(limit) kept, the newest: narrow the window, address or action." }
            struct Kept: Encodable { let zone: String; let events: [String]; let since: String; let until: String; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(zone: id, events: lines, since: Cloudflare.iso(since), until: Cloudflare.iso(until), complete: events.count <= limit))
        }
    }

    /// An account audit log entry, said on one line: when, what, whether it failed, who and from where, on what, and
    /// the names it gives of the zone, record or resource.
    static func auditLine(_ entry: Item) -> String {
        var line = "\(entry.text("when") ?? "?") \(entry.text("action.type") ?? "?")"
        if entry.flag("action.result") == false { line += " (failed)" }
        if let who = entry.text("actor.email") ?? entry.text("actor.type") { line += " by \(who)" }
        if let ip = entry.text("actor.ip") { line += " from \(ip)" }
        if let via = entry.text("interface") { line += " via \(via)" }
        if let resource = entry.text("resource.type") { line += " on \(resource)\(entry.text("resource.id").map { " \($0)" } ?? "")" }
        let details = ["metadata.zone_name", "metadata.name", "metadata.type", "metadata.content"].compactMap { entry.text($0) }
        if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
        return String(line.prefix(500)) + " [\(entry.id)]"
    }

    struct AuditLog: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String?, actor: String?, actionType: String?, zone: String?, limit: Int? }
        static let name = "audit-log"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Changes in the account, newest first: who did what, to which resource, from which IP address and through the dashboard or the API, by time, person, action and zone; says when more matched than it kept."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out, at most a year."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "actor": .string("Only changes by this email address."),
            "actionType": .string("Only changes of this action type, such as add, delete, update, rec_add, rec_set or rec_del."),
            "zone": .string("Only changes to this zone, by its domain."),
            "limit": .integer("How many entries, at most. 100 when left out.", minimum: 1, maximum: 1_000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try Cloudflare.window(input.since, input.until, days: 7)
            var query: [String: String?] = ["since": Cloudflare.iso(since), "before": Cloudflare.iso(until), "direction": "desc"]
            if let actor = input.actor { query["actor.email"] = try ServiceInput.email(actor) }
            if let type = input.actionType {
                let type = type.trimmingCharacters(in: .whitespaces)
                guard (1...60).contains(type.count), type.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }) else {
                    throw ServiceError.input("Give the action type as the audit log shows it, such as rec_add.")
                }
                query["action.type"] = type
            }
            if let zone = input.zone { query["zone.name"] = try ServiceInput.domain(zone) }
            let limit = try Cloudflare.limit(input.limit, default: 100, maximum: 1_000, "entries")
            let listing = try await Cloudflare.read(Cloudflare.auditNeed) {
                try await Cloudflare.list(service, ["accounts", try Cloudflare.account(service), "audit_logs"], query: query, as: Item.self, size: min(limit, 500), limit: limit)
            }
            let (entries, cut, notice) = Cloudflare.summary(listing, limit: limit, name: "entries", narrow: "narrow the window, person, action or zone")
            let lines = entries.map(Cloudflare.auditLine)
            let window = "from \(Cloudflare.iso(since)) to \(Cloudflare.iso(until))"
            var text = entries.isEmpty ? "No changes \(window) match\(listing.complete ? "" : " in what was read")." : "\(Cloudflare.plural(entries.count, "change")) \(window), newest first:\n" + lines.prefix(60).joined(separator: "\n")
            if entries.count > 60 { text += "\n\(entries.count - 60) more in the structured result." }
            text += notice
            struct Kept: Encodable { let entries: [String]; let since: String; let until: String; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(entries: lines, since: Cloudflare.iso(since), until: Cloudflare.iso(until), total: listing.total, complete: listing.complete && !cut))
        }
    }

    /// Who is in the account and with which roles, from Account Settings Read: administrators first, then the rest,
    /// each with whether they sign in with 2FA, which does not cover API tokens.
    struct Members: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "members"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Everyone in the account with their roles or permission policies and whether they use 2FA, administrators first; says when it read only part."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let listing = try await Cloudflare.read(Cloudflare.membersNeed) {
                try await Cloudflare.list(service, ["accounts", try Cloudflare.account(service), "members"], query: [:], as: Item.self, size: 50, pages: 20)
            }
            func roles(_ member: Item) -> [String] {
                let named = (member.fields["roles"]?.items ?? []).compactMap { $0["name"]?.text }
                return named.isEmpty ? (member.fields["policies"]?.items ?? []).flatMap { ($0["permission_groups"]?.items ?? []).compactMap { $0["name"]?.text } } : named
            }
            func administrator(_ member: Item) -> Bool { roles(member).contains { $0.localizedCaseInsensitiveContains("Administrator") || $0.localizedCaseInsensitiveContains("Super") } }
            let ordered = listing.value.filter(administrator) + listing.value.filter { !administrator($0) }
            let lines = ordered.map { member in
                let who = member.text("user.email") ?? member.text("email") ?? member.id
                let named = roles(member)
                let twoFactor: String = switch member.flag("user.two_factor_authentication_enabled") {
                case false?: ", no 2FA"
                case true?: ", 2FA on"
                case nil: ", 2FA not given"
                }
                return "\(who)\(member.text("status") == "pending" ? " (invited, not yet accepted)" : ""): \(named.isEmpty ? "no roles given" : named.joined(separator: ", "))\(twoFactor)"
            }
            let text = (lines.isEmpty ? "The account has no members listed\(listing.complete ? "" : " in what was read")." : lines.joined(separator: "\n")) + Cloudflare.stopped(listing, "members")
            struct Kept: Encodable { let members: [String]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(members: lines, total: listing.total, complete: listing.complete))
        }
    }
}

// MARK: - Access

extension Cloudflare {
    enum Probe { case works, refused, off, failed }

    /// Tries a read once, and says whether it works.
    static func probe(_ need: Need, required: Bool, _ body: () async throws -> Void) async -> (state: Probe, line: String) {
        do {
            try await body()
            return (.works, "✓ \(need.title) (\(need.scope))")
        } catch {
            if unlicensed(error) { return (.off, "· \(need.title): " + (fix(for: error, need) ?? error.localizedDescription)) }
            let refused = fix(for: error, need)
            return (refused == nil ? .failed : .refused, "\(required ? "✗" : "⚠") \(need.title): " + (refused ?? error.localizedDescription))
        }
    }

    /// What one part of the account the sign-in reaches, said as a line: edge or Zero Trust.
    static func coverage(_ part: String, _ states: [Probe]) -> String {
        if states.allSatisfy({ $0 == .works }) { return "· \(part): every read works." }
        if states.allSatisfy({ $0 == .off }) { return "· \(part): the account does not use it, so it is not read." }
        if !states.contains(.works) { return "· \(part): no read works, so nothing of it is read; if the account uses it, change what is said above." }
        return "· \(part): only part of it can be read; see above for what to add."
    }

    /// Tries each thing Detection reads once and says what works and what to change, and which scopes the sign-in holds.
    /// It sends only reads. Cloudflare documents no way for an OAuth token to verify itself, so none is tried.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Tries each thing this tool reads once, at the edge and in Zero Trust, and says what works and, for what does not, what to change, in the OAuth client's scopes or the member's role; which parts of the account the sign-in reaches; and which scopes it holds. It sends only reads."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try Cloudflare.api(service)
            let account = try Cloudflare.account(service)
            var lines = ["· Account \(account), reached at https://\(Cloudflare.host)\(Cloudflare.basePath) and nowhere else."]
            var edge: [Probe] = [], zeroTrust: [Probe] = []
            func record(_ result: (state: Probe, line: String), zt: Bool) { lines.append(result.line); if zt { zeroTrust.append(result.state) } else { edge.append(result.state) } }
            var firstZone: String?
            record(await Cloudflare.probe(Cloudflare.zonesNeed, required: true) {
                let listing = try await Cloudflare.list(service, ["zones"], query: ["account.id": account], as: Item.self, size: 5, pages: 1)
                firstZone = listing.value.first.flatMap { Cloudflare.hex32($0.id) }
            }, zt: false)
            if let zone = firstZone {
                record(await Cloudflare.probe(Cloudflare.dnsNeed, required: true) {
                    _ = try await Cloudflare.list(service, ["zones", zone, "dns_records"], query: [:], as: Item.self, size: 5, pages: 1)
                }, zt: false)
                record(await Cloudflare.probe(Cloudflare.zoneSettingsNeed, required: false) {
                    _ = try await Cloudflare.get(service, ["zones", zone, "settings", "ssl"], as: Value.self)
                }, zt: false)
                record(await Cloudflare.probe(Cloudflare.dnssecNeed, required: false) {
                    _ = try await Cloudflare.get(service, ["zones", zone, "dnssec"], as: Value.self)
                }, zt: false)
                record(await Cloudflare.probe(Cloudflare.wafNeed, required: false) {
                    // A zone whose managed rules were never deployed answers 404, which the sign-in was allowed to ask.
                    do { _ = try await Cloudflare.get(service, ["zones", zone, "rulesets", "phases", "http_request_firewall_managed", "entrypoint"], as: Value.self) }
                    catch ServiceError.notFound {}
                }, zt: false)
                record(await Cloudflare.probe(Cloudflare.firewallNeed, required: false) {
                    struct Variables: Encodable { let zoneTag: String; let since: String }
                    struct Answer: Decodable { let viewer: Value? }
                    _ = try await Cloudflare.graphQL(service, query: "query Probe($zoneTag: string, $since: Time!) { viewer { zones(filter: { zoneTag: $zoneTag }) { firewallEventsAdaptive(filter: { datetime_geq: $since }, limit: 1) { datetime } } } }",
                                                     variables: Variables(zoneTag: zone, since: Cloudflare.iso(Date().addingTimeInterval(-3_600))), as: Answer.self)
                }, zt: false)
            } else {
                lines.append("· DNS records, zone settings, DNSSEC, WAF managed rules and firewall events were not tried: the sign-in sees no zone. If the account has zones, give the signed-in member a role that reads them.")
            }
            record(await Cloudflare.probe(Cloudflare.auditNeed, required: true) {
                _ = try await Cloudflare.list(service, ["accounts", account, "audit_logs"], query: ["since": Cloudflare.iso(Date().addingTimeInterval(-3_600))], as: Item.self, size: 1, pages: 1)
            }, zt: false)
            record(await Cloudflare.probe(Cloudflare.membersNeed, required: false) {
                _ = try await Cloudflare.list(service, ["accounts", account, "members"], query: [:], as: Item.self, size: 5, pages: 1)
            }, zt: false)
            record(await Cloudflare.probe(Cloudflare.accessLogsNeed, required: false) {
                _ = try await Cloudflare.accessLogins(service, since: Date().addingTimeInterval(-3_600), until: Date(), pages: 1, size: 1, partial: true)
            }, zt: true)
            record(await Cloudflare.probe(Cloudflare.accessAppsNeed, required: false) {
                _ = try await Cloudflare.list(service, ["accounts", account, "access", "apps"], query: [:], as: Item.self, size: 1, pages: 1)
            }, zt: true)
            record(await Cloudflare.probe(Cloudflare.accessUsersNeed, required: false) {
                _ = try await Cloudflare.list(service, ["accounts", account, "access", "users"], query: [:], as: Item.self, size: 1, pages: 1)
            }, zt: true)
            record(await Cloudflare.probe(Cloudflare.gatewayNeed, required: false) {
                _ = try await Cloudflare.list(service, ["accounts", account, "gateway", "rules"], query: [:], as: Item.self, paging: .single, size: 0)
            }, zt: true)
            record(await Cloudflare.probe(Cloudflare.devicesNeed, required: false) {
                _ = try await Cloudflare.list(service, ["accounts", account, "devices", "registrations"], query: ["status": "all"], as: Item.self, paging: .cursor, size: 1, pages: 1)
            }, zt: true)
            record(await Cloudflare.probe(Cloudflare.gatewayActivityNeed, required: false) {
                struct Variables: Encodable { let accountTag: String; let since: String }
                struct Answer: Decodable { let viewer: Value? }
                _ = try await Cloudflare.graphQL(service, query: "query Probe($accountTag: string!, $since: Time!) { viewer { accounts(filter: { accountTag: $accountTag }) { gatewayResolverQueriesAdaptiveGroups(filter: { datetime_geq: $since }, limit: 1) { count } } } }",
                                                 variables: Variables(accountTag: account, since: Cloudflare.iso(Date().addingTimeInterval(-3_600))), as: Answer.self)
            }, zt: true)
            record(await Cloudflare.probe(Cloudflare.tunnelsNeed, required: false) {
                _ = try await Cloudflare.list(service, ["accounts", account, "cfd_tunnel"], query: [:], as: Item.self, size: 1, pages: 1)
            }, zt: true)
            lines.append(Cloudflare.coverage("The edge", edge))
            lines.append(Cloudflare.coverage("Zero Trust", zeroTrust))
            lines.append("· The alert watch reads the account audit log and the Access logins; what it cannot read it says once, and security-events says why.")
            lines.append(Cloudflare.scopesLine(Cloudflare.auditScopes, service))
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }

    /// The scopes a sign-in holds, as a line of check-access: those its tool asks for, as Pion refuses a sign-in
    /// Cloudflare grants fewer, and the client they are granted to.
    static func scopesLine(_ scopes: [String], _ service: ServiceClient) -> String {
        let client = service.settings["clientID"].map { " to the Cloudflare OAuth client \($0)" } ?? ""
        return "· The sign-in holds the scopes \(scopes.joined(separator: ", ")), granted\(client); Pion refuses a sign-in that lacks any. It also asks for offline_access, which renews the sign-in. Cloudflare allows a request only when the signed-in member's role allows it too, and only in the accounts chosen at sign-in."
    }
}
