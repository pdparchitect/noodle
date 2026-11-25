import Foundation
import NoodleCore
import NoodleToolConnections

/// CrowdStrike Falcon: its hosts, the alerts its sensors raised, who used Real Time Response on which host, its host
/// groups, the container images it assessed, and its prevention policies and exclusions, read through an API client's
/// ID and secret. Each account is one Falcon
/// cloud and customer (CID). CrowdStrike Falcon Detection only reads; CrowdStrike Falcon Containment, a tool of its own with
/// an API client of its own, contains hosts, blocks indicators, runs two fixed Real Time Response commands and closes
/// alerts. Falcon's incidents API was retired in 2026, so incidents are read as the alerts they gathered.
///
/// Falcon has no delegated sign-in for an admin: each tool gets an OAuth2 client-credentials token for its own API
/// client, whose API scopes are all it may do, so each tool's client is made with only the scopes its Setup Steps list.
/// Neither the token nor any API tells a client which scopes it holds, so check-access tries each read it needs, and
/// shows a write scope only where a read needs it; it never sends a change, so other write scopes go unverified.
///
/// Both tools' guide is Incubator/Pion/docs/tools/crowdstrike.md. Change it with the setup steps, scopes or operations here.
public enum CrowdStrike {
    public static let preset = ToolDefinition(
        id: "fc56ba9d-c4aa-4ff9-80cf-507f21273249", name: "CrowdStrike Falcon Detection",
        summary: "Hosts, alerts, Real Time Response sessions, host groups, container image assessments, prevention policies and exclusions in CrowdStrike Falcon, read-only.",
        defaultInstructions: """
        Use CrowdStrike Falcon Detection to see endpoints as Falcon's sensors do. hosts finds hosts by name, IP address, \
        platform, containment status or host group, and host reads one in full: its sensor, when it was last seen, \
        whether it is online, its containment status, tags and groups, any hint that it runs Kubernetes workloads or \
        containers, which suggests but does not verify what runs there, and the alerts that named it. alerts lists \
        alerts by host, severity, status and time, and alert reads one with its process, parent and grandparent, \
        command lines, hashes, user and MITRE technique. rtr-sessions \
        lists who opened Real Time Response sessions on which host and every command they ran. host-groups lists host \
        groups and their members, container-images the container images Falcon assessed with their vulnerabilities, \
        and users who can use the Falcon console with their roles. To assess how Falcon is set up, prevention-policies \
        lists each platform's prevention policies with their protections and the hosts they reach, led by disabled \
        policies, hosts on a default policy and protections turned off; exclusions lists machine learning, IOA and \
        sensor visibility exclusions, led by those for every host or with broad patterns. Each host's 32-character \
        device ID, and each alert's composite ID, are what CrowdStrike Falcon Containment acts on. The alert watch checks every five minutes and \
        wakes you with a note naming security-events, which reads what it found for the note's window: new high and \
        critical alerts not closed, Real Time Response sessions opened, and hosts newly contained. A note may name a \
        feed the watch could not read: security-events says why, so tell the champion and treat that feed's silence as \
        unknown. When a tool is refused or something you need seems missing, run check-access and tell the champion \
        exactly what it says to change. Silence is not proof: every result says when it stopped before reading \
        everything or matched more than it kept. Record each finding as evidence, citing the host and alert. These \
        tools only read: recommend containing a host or other responses to the champion, or use CrowdStrike Falcon \
        Containment, with the host, why, and how to undo it.
        """,
        iconName: "crowdstrike",
        configuration: .connection(.init(endpointTemplate: "https://{region}", fields: [regionField],
                                         clientCredentials: ClientCredentialsPreset(tokenEndpointTemplate: "https://{region}/oauth2/token"),
                                         adapter: "crowdstrike")),
        setup: setup)

    /// The Falcon clouds, by their API host, each with its own token service; nothing else may be chosen, and requests
    /// reach only the chosen one.
    static let clouds: [(host: String, title: String, console: String)] = [
        ("api.crowdstrike.com", "US-1", "falcon.crowdstrike.com"), ("api.us-2.crowdstrike.com", "US-2", "falcon.us-2.crowdstrike.com"),
        ("api.eu-1.crowdstrike.com", "EU-1", "falcon.eu-1.crowdstrike.com"), ("api.laggar.gcw.crowdstrike.com", "US-GOV-1", "falcon.laggar.gcw.crowdstrike.com"),
    ]
    static let regionField = ToolField(key: "region", title: "Falcon cloud", placeholder: "api.crowdstrike.com",
                                       kind: .choice(clouds.map { .init(value: $0.host, title: $0.title) }))
    static let cloudStep = "For the Falcon cloud, choose the one your console's address names: \(clouds.map { "`\($0.console)` is \($0.title)" }.joined(separator: ", ")). Then ask an agent to run check-access."

    /// An API scope, as the Falcon console's API client page names it.
    struct Scope: Sendable, Equatable, Hashable {
        let name: String
        let access: String
        var shown: String { "**\(name): \(access)**" }
        var plain: String { "\(name): \(access)" }
    }

    /// Detection's scopes, every one Read. Hosts and Alerts are the tool; the rest each serve one part of it.
    static let hostsRead = Scope(name: "Hosts", access: "Read")
    static let alertsRead = Scope(name: "Alerts", access: "Read")
    static let rtrAuditRead = Scope(name: "Real time response audit", access: "Read")
    static let hostGroupsRead = Scope(name: "Host groups", access: "Read")
    static let imagesRead = Scope(name: "Falcon Container Image", access: "Read")
    static let usersRead = Scope(name: "User management", access: "Read")
    static let auditScopes = [hostsRead, alertsRead, rtrAuditRead, hostGroupsRead, imagesRead, usersRead, preventionRead, mlExclusionsRead, ioaExclusionsRead,
                              svExclusionsRead]

    static let setup = [
        "In the Falcon console, open **Support and resources › API clients and keys** and choose **Create API client**. Name it Pion Falcon Detection, kept for this tool alone.",
        "Give it only these scopes, each **Read** and nothing else: \(auditScopes.map(\.shown).joined(separator: ", ")). Hosts and Alerts are needed; leave out any other to go without what it reads. Give it no **Write** scope at all: Falcon offers no way to check a client's scopes without trying a change, so check them on the client's page.",
        "Choose **Create**, and copy the **Client ID** and **Secret** here; Falcon shows the secret only once.",
        cloudStep,
    ]

    /// Every operation of both tools, each naming the jobs it serves; each tool offers those of its own job.
    static let operations: [any ServiceOperation] = [
        Hosts(), HostDetails(), Alerts(), AlertDetails(), RTRSessions(), HostGroups(), ContainerImages(), Users(), PreventionPolicies(), Exclusions(),
        SecurityEvents(), CheckAccess(),
        ContainmentHost(), ActionStatus(), ContainHost(), LiftContainment(), BlockIOC(), UnblockIOC(), RTRKillProcess(), CloseAlert(),
        UpdateAlertStatus(), ContainmentCheckAccess(),
    ]

    public static let adapter = OperationAdapter(operations: operations, job: .detection, trigger: NewSecurityEvents(),
                                                 // Paced, as users asks for each user's roles in turn; Falcon allows each customer so
                                                 // many requests a minute, shared by every API client.
                                                 simultaneousRequests: 8)

    // MARK: Limits

    /// The most pages one listing reads.
    static let maximumPages = 10
    /// How far back alerts may be searched, as Falcon keeps them by default.
    static let keptDays = 90.0
    /// The furthest Falcon's offset paging reaches: offset and limit together at most this.
    static let offsetLimit = 10_000

    // MARK: Requests

    /// The cloud the connection reaches, by its API host, or a refusal when it is none of Falcon's.
    static func cloud(_ service: ServiceClient) throws -> (host: String, title: String, console: String) {
        guard service.base.scheme?.lowercased() == "https", let host = service.base.host?.lowercased(), service.base.port == nil,
              let cloud = clouds.first(where: { $0.host == host }) else {
            throw ServiceError.input("This connection does not name a Falcon cloud Pion knows (\(clouds.map(\.title).joined(separator: ", "))); choose it again in Settings › Tools.")
        }
        return cloud
    }

    /// How long Pion itself waits, at most, for Falcon's rate limit to reset before trying once more, after the transport
    /// has tried again as its own back-off said.
    static let patience = 20.0
    /// How Pion waits; tests pass time without it.
    @TaskLocal static var pause: @Sendable (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }

    /// How long Falcon asked to wait, from X-RateLimit-RetryAfter, the moment its limit resets, which its API reference
    /// gives in milliseconds since 1970 and Pion also reads in seconds; or from Retry-After, in seconds.
    static func retryWait(_ response: HTTPURLResponse, now: Date = Date()) -> Double? {
        if let reset = response.value(forHTTPHeaderField: "X-RateLimit-RetryAfter").flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
            let seconds = reset > 100_000_000_000 ? reset / 1_000 : reset
            return max(0, seconds > 1_000_000_000 ? seconds - now.timeIntervalSince1970 : seconds)
        }
        return response.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.map { max(0, $0) }
    }

    /// What Falcon said when it refused: the messages in its errors list, or the usual fields, on one short line.
    static func reason(_ data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let errors = object["errors"] as? [[String: Any]] {
            let said = errors.compactMap { $0["message"] as? String }.filter { !$0.isEmpty }
            if !said.isEmpty { return String(said.prefix(3).joined(separator: "; ").prefix(300)) }
        }
        return ServiceClient.reason(data)
    }

    /// One request to the connection's Falcon cloud, with every answer back for the caller to judge.
    static func raw(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], repeated: [String: [String]] = [:], method: String = "GET",
                    body: Data? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        _ = try cloud(service)
        var answer = try await service.exchange(path, query: query, repeated: repeated, method: method, body: body, returning: Set(300...599))
        // The transport has tried a 429 again on its own back-off; Falcon says when its limit resets, so wait for that
        // once, when it is soon. A 429 means Falcon did nothing with the request, so even a change may go again.
        if answer.response.statusCode == 429, let wait = retryWait(answer.response), wait <= patience {
            await pause(wait)
            answer = try await service.exchange(path, query: query, repeated: repeated, method: method, body: body, returning: Set(300...599))
        }
        return answer
    }

    /// One request, its refusals in Falcon's own words, and when it throttles, how long it asked to wait.
    static func exchange(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], repeated: [String: [String]] = [:], method: String = "GET",
                         body: Data? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        let answer = try await raw(service, path, query: query, repeated: repeated, method: method, body: body)
        try check(answer)
        return answer
    }

    /// Throws for any answer but a success, as said in what Falcon refused.
    static func check(_ answer: (data: Data, response: HTTPURLResponse)) throws {
        let status = answer.response.statusCode, said = reason(answer.data)
        switch status {
        case 200..<300: return
        case 429:
            let wait = retryWait(answer.response).map { "Falcon asked to wait \(Int($0.rounded(.up))) seconds before trying again" }
            throw ServiceError.rateLimited([wait, said].compactMap { $0 }.joined(separator: "; "))
        case 401: throw ServiceError.rejected(said)
        case 403: throw ServiceError.forbidden(said)
        case 404: throw ServiceError.notFound
        case 400, 405, 409, 412, 422: throw said.map(ServiceError.refused) ?? ServiceError.status(status)
        default: throw ServiceError.status(status, said)
        }
    }

    /// Falcon's answer: its resources, errors and paging. A list Falcon leaves out is unreadable, never an empty one,
    /// unless its paging says nothing matched.
    struct Envelope<Item: Decodable>: Decodable {
        /// One error Falcon gave, read loosely, as an entry without a message is an error all the same.
        struct Problem: Decodable {
            let code: Int?, message: String?, id: String?
            enum Keys: String, CodingKey { case code, message, id }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                code = ((try? container.decodeIfPresent(Int.self, forKey: .code)) ?? nil)
                    ?? ((try? container.decodeIfPresent(String.self, forKey: .code)) ?? nil).flatMap { Int($0) }
                message = ((try? container.decodeIfPresent(String.self, forKey: .message)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
                id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil
            }
            var said: String { message ?? code.map { "error \($0) without a message" } ?? "an error without a message or code" }
            /// Whether it says only that something was not found.
            var notFound: Bool {
                code == 404 || ["not found", "could not find", "does not exist", "no such"].contains { (message ?? "").lowercased().contains($0) }
            }
        }
        struct Meta: Decodable {
            let pagination: Pagination?
            /// Falcon's ID for the request, which its support can trace.
            let trace_id: String?
        }
        struct Pagination: Decodable {
            /// A number for offset paging.
            let offset: Offset?
            let limit: Int?
            let total: Int?
            let after: String?
        }
        enum Offset: Decodable, Equatable {
            case number(Int), token(String)
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) { self = .number(number) } else { self = .token(try container.decode(String.self)) }
            }
        }
        let meta: Meta?
        let resources: [Item]?
        let errors: [Problem]?

        /// Whether Falcon gave any error at all, with a message or without.
        var hasErrors: Bool { !(errors ?? []).isEmpty }

        /// What Falcon said went wrong, for every answer that carries an error, whether or not it says why.
        var problems: String? {
            hasErrors ? (errors ?? []).prefix(3).map(\.said).joined(separator: "; ") : nil
        }

        /// The resources, or why there are none: errors Falcon gave, or nothing at all. A list that comes with errors is
        /// never taken as whole, nor an empty one as nothing.
        func items() throws -> [Item] {
            if let problems { throw ServiceError.refused(problems) }
            if let resources { return resources }
            if meta?.pagination?.total == 0 { return [] }
            throw ServiceError.unreadable
        }
    }

    static func get<Item: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], repeated: [String: [String]] = [:],
                                     as: Item.Type) async throws -> Envelope<Item> {
        try decode(try await exchange(service, path, query: query, repeated: repeated).data)
    }

    static func post<Item: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], body: some Encodable,
                                      method: String = "POST", as: Item.Type) async throws -> Envelope<Item> {
        try decode(try await exchange(service, path, query: query, method: method, body: try JSONEncoder().encode(body)).data)
    }

    static func decode<Item: Decodable>(_ data: Data) throws -> Envelope<Item> {
        do { return try JSONDecoder().decode(Envelope<Item>.self, from: data) } catch { throw ServiceError.unreadable }
    }

    // MARK: Paging

    /// Where a listing goes on from: the offset of its next page, or the token Falcon gave for it.
    enum Cursor: Equatable, Sendable { case offset(Int), after(String) }

    /// How an endpoint pages: by offset in its query; by the `after` token in its query; or, for the alerts Falcon
    /// lists whole, by `after` in a JSON body that carries the search too.
    enum Paging: Sendable { case offset, after, afterInBody }

    struct Listing<Item> {
        var value: [Item] = []
        /// Whether more remained when it stopped.
        var more = false
        var pages = 0
        /// How many Falcon said match, when it said.
        var total: Int? = nil
        /// Why it stopped before the end, when not for its page or item limit, such as a page that failed.
        var stopped: String? = nil
        var stoppedAt: Int? = nil
        /// Where the next page starts, when it stopped at its page or item limit with more to read.
        var next: Cursor? = nil
        var complete: Bool { !more && stopped == nil }
    }

    /// A token Falcon gave for a next page, taken only when it looks like one: short, printable, without spaces.
    static func token(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 4_096,
              value.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }) else { return nil }
        return value
    }

    /// A listing, page after page of `size`, up to `pages` or until `limit` items are kept. Each next page asks the same
    /// path with the same search and the offset or token that goes on from the last; `from` starts from one a listing
    /// stopped at before, with the search it came from. Offset paging ends at the total Falcon gives, or at a short page
    /// when it gives none, and stops, saying so, where Falcon lets offsets reach no further; token paging ends at a page
    /// without a token.
    ///
    /// When a page after the first fails, what earlier pages held is kept and the listing says where and why it
    /// stopped, unless `partial` is false, for a reader that must have all or nothing.
    static func list<Item: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?], as: Item.Type, paging: Paging,
                                      size: Int, pages: Int = maximumPages, limit: Int? = nil, from: Cursor? = nil, partial: Bool = true,
                                      matching: (Item) -> Bool = { _ in true }) async throws -> Listing<Item> {
        var cursor = from
        var found = Listing<Item>()
        func stop(_ reason: String) -> Listing<Item> {
            found.more = true
            found.next = nil
            found.stoppedAt = found.pages + 1
            found.stopped = reason
            return found
        }
        while found.pages < pages {
            let items: [Item], envelope: Envelope<Item>
            do {
                switch paging {
                case .offset, .after:
                    var asked = query
                    asked["limit"] = String(size)
                    switch cursor {
                    case .offset(let offset)?: asked["offset"] = String(offset)
                    case .after(let token)?: asked["after"] = token
                    case nil: break
                    }
                    envelope = try await get(service, path, query: asked, as: Item.self)
                case .afterInBody:
                    var body = query.compactMapValues { $0 }.mapValues { $0 as Any }
                    body["limit"] = size
                    if case .after(let token)? = cursor { body["after"] = token }
                    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                    envelope = try decode(try await exchange(service, path, method: "POST", body: data).data)
                }
                items = try envelope.items()
            } catch {
                guard partial, found.pages > 0 else { throw error }
                return stop(error.localizedDescription)
            }
            found.pages += 1
            found.value += items.filter(matching)
            let pagination = envelope.meta?.pagination
            if let total = pagination?.total { found.total = total }
            var next: Cursor?
            switch paging {
            case .offset:
                let start: Int = if case .offset(let offset)? = cursor { offset } else { 0 }
                let reached = start + items.count
                if let total = pagination?.total {
                    if reached < total {
                        guard !items.isEmpty else { return stop("Falcon gave an empty page at \(start) of the \(total) it said match") }
                        next = .offset(reached)
                    }
                } else if items.count >= size { next = .offset(reached) }
                if next != nil, reached + size > offsetLimit {
                    return stop("Falcon pages through only the first \(offsetLimit) of a search, so narrow it")
                }
            case .after, .afterInBody:
                if let after = pagination?.after, !after.isEmpty {
                    guard let token = token(after) else { return stop("Falcon gave a next page Pion does not follow") }
                    guard Cursor.after(token) != cursor else { return stop("Falcon gave the same next page again") }
                    next = .after(token)
                }
            }
            guard let next else {
                found.more = false
                found.next = nil
                return found
            }
            found.more = true
            found.next = next
            cursor = next
            if let limit, found.value.count >= limit { return found }
        }
        return found
    }

    static func stopped<Item>(_ listing: Listing<Item>, _ name: String) -> String {
        if let reason = listing.stopped {
            return "\nIncomplete: stopped at page \(listing.stoppedAt ?? listing.pages + 1) reading \(name) because \(reason); what the \(plural(listing.pages, "page")) before held is kept."
        }
        return listing.more ? "\nIncomplete: stopped after \(plural(listing.pages, "page")) reading \(name), the most read at once; more remain\(listing.total.map { ", of \($0) Falcon said match" } ?? "")." : ""
    }

    /// Items by ID, fetched in batches of `batch`, each answer checked to be for an ID asked for. What Falcon did not
    /// return is listed as not returned, never taken for nothing; an answer for some IDs with errors that say only that
    /// the rest were not found keeps what it gave, and any other error fails the read.
    static func entities<Item: Decodable>(_ ids: [String], batch: Int, id: (Item) -> String,
                                          fetch: ([String]) async throws -> Envelope<Item>) async throws -> (found: [Item], missing: [String]) {
        var found: [String: Item] = [:]
        for start in stride(from: 0, to: ids.count, by: batch) {
            let asked = Array(ids[start..<min(start + batch, ids.count)])
            let envelope: Envelope<Item>
            do { envelope = try await fetch(asked) } catch ServiceError.notFound { continue }
            if envelope.resources == nil, !envelope.hasErrors { throw ServiceError.unreadable }
            if let problems = envelope.problems, !(envelope.errors ?? []).allSatisfy(\.notFound) { throw ServiceError.refused(problems) }
            for item in envelope.resources ?? [] where asked.contains(id(item)) { found[id(item)] = item }
        }
        return (ids.compactMap { found[$0] }, ids.filter { found[$0] == nil })
    }

    /// A window of at most `maximum` days, since before until; `days` back from now when since is left out.
    static func window(_ since: String?, _ until: String?, days: Double, maximum: Double = keptDays) throws -> (since: Date, until: Date) {
        let now = Date()
        let from: Date? = try since.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantPast } ?? now.addingTimeInterval(-days * 86_400)
        let to: Date? = try until.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantFuture } ?? now
        guard let from, let to, from <= to, from >= now.addingTimeInterval(-maximum * 86_400 - 60), to <= now.addingTimeInterval(60) else {
            throw ServiceError.input("Give a time range within the last \(Int(maximum)) days, with since before until.")
        }
        return (from, to)
    }

    static func iso(_ date: Date) -> String { Entra.iso(date) }

    // MARK: Refusals

    /// What one thing a tool reads or does needs, to say what to change when it is refused.
    struct Need: Sendable {
        let title: String
        let scope: Scope
    }

    static let hostsNeed = Need(title: "Hosts", scope: hostsRead)
    static let alertsNeed = Need(title: "Alerts", scope: alertsRead)
    static let rtrAuditNeed = Need(title: "Real Time Response sessions", scope: rtrAuditRead)
    static let hostGroupsNeed = Need(title: "Host groups", scope: hostGroupsRead)
    static let imagesNeed = Need(title: "Container image assessments", scope: imagesRead)
    static let usersNeed = Need(title: "Console users", scope: usersRead)

    /// Whether Falcon refused for want of a subscription, rather than a scope.
    static func unlicensed(_ error: Error) -> Bool {
        let said: String
        switch error {
        case ServiceError.forbidden(let reason?), ServiceError.refused(let reason): said = reason.lowercased()
        default: return false
        }
        return said.contains("subscription") || said.contains("licen") || said.contains("not entitled") || said.contains("entitlement")
    }

    /// What to change when a request was refused, from what Falcon said; nil for any other failure.
    static func fix(for error: Error, _ need: Need) -> String? {
        switch error {
        case ServiceError.rejected:
            return "Falcon did not accept the API client's ID and secret: the secret was reset, or the client was deleted. Make a new secret in Support and resources › API clients and keys, and give it in Settings › Tools."
        case ServiceError.forbidden where unlicensed(error):
            return "this needs a Falcon subscription the customer lacks, so it cannot be read."
        case ServiceError.forbidden:
            return "the API client lacks the scope \(need.scope.plain). Add it to this tool's client in Support and resources › API clients and keys (editing a client keeps its ID and secret), then try again."
        default: return nil
        }
    }

    /// A request, with a refusal said as what to change.
    static func read<Value>(_ need: Need, _ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch {
            guard let fix = fix(for: error, need) else { throw error }
            let said: String? = switch error {
            case ServiceError.forbidden(let reason), ServiceError.rejected(let reason): reason
            default: nil
            }
            throw ServiceError.input("Falcon refused \(need.title.lowercased())\(said.map { " (it said: \($0))" } ?? ""): \(fix) Running check-access shows everything this tool can and cannot do.")
        }
    }

    // MARK: Inputs

    /// A host's device ID, as Falcon gives it: 32 hexadecimal characters.
    static func deviceID(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.count == 32 && value.allSatisfy(\.isHexDigit) ? value : nil
    }

    /// A host's name as Falcon's filters take it: a host name's letters, digits, dots, hyphens and underscores.
    static func hostname(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...255).contains(value.count),
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains) else {
            throw ServiceError.input("Give the host's name as Falcon shows it, such as LT-0423, or its 32-character device ID.")
        }
        return value
    }

    /// An alert's composite ID, as Falcon gives it: the customer's ID, a kind and the alert's own ID, joined by colons.
    static func compositeID(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (5...300).contains(value.count), parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }),
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_:.").contains) else { return nil }
        return value
    }

    /// An ID Falcon gives for a session, group or user: letters, digits and hyphens.
    static func plainID(_ value: String, _ name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...100).contains(value.count),
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains) else {
            throw ServiceError.input("Give \(name) exactly as Falcon lists it.")
        }
        return value.lowercased()
    }

    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
}

// MARK: - Hosts

extension CrowdStrike {
    /// A host as Falcon describes it, read field by field so a field Falcon leaves out or gives in another shape is
    /// unknown rather than a failure; only its device ID must be there, and a host without one is unreadable.
    struct Host: Sendable, Decodable {
        let fields: [String: CellValue]
        let id: String

        init?(_ fields: [String: CellValue]) {
            guard case .text(let id)? = fields["device_id"], let device = CrowdStrike.deviceID(id) else { return nil }
            self.fields = fields
            self.id = device
        }

        init(from decoder: Decoder) throws {
            guard let host = Host(try [String: CellValue](from: decoder)) else { throw ServiceError.unreadable }
            self = host
        }

        func text(_ key: String) -> String? { if case .text(let value)? = fields[key], !value.isEmpty { return value }; return nil }
        func list(_ key: String) -> [String] {
            switch fields[key] {
            case .list(let list)?: list.filter { !$0.isEmpty }
            case .text(let text)?: text.isEmpty ? [] : [text]
            default: []
            }
        }

        var name: String? { text("hostname") }
        var named: String { "\(name ?? "an unnamed host") [\(id)]" }
        /// Falcon's containment status: normal, containment_pending, contained or lift_containment_pending.
        var status: String? { text("status")?.lowercased() }
        var platform: String? { text("platform_name") }
        var tags: [String] { list("tags") }
        var groups: [String] { list("groups") }

        var line: String {
            var parts = [platform ?? "platform unknown"]
            if let os = text("os_version") { parts.append(os) }
            if let kind = text("product_type_desc") { parts.append(kind) }
            parts.append("containment \(CrowdStrike.containment(status))")
            parts.append("sensor \(text("agent_version") ?? "version unknown")")
            if let ip = text("local_ip") { parts.append("local IP \(ip)") }
            if let ip = text("external_ip") { parts.append("external IP \(ip)") }
            if let mode = text("reduced_functionality_mode"), mode.lowercased() == "yes" { parts.append("in reduced functionality mode") }
            parts.append("last seen \(text("last_seen") ?? "unknown")")
            return "\(named): " + parts.joined(separator: ", ")
        }
    }

    /// A containment status, said plainly: pending is not done, and none given is unknown.
    static func containment(_ status: String?) -> String {
        switch status {
        case "normal": "normal (not contained)"
        case "contained": "contained"
        case "containment_pending": "containment pending (asked for, not yet in force)"
        case "lift_containment_pending": "lift pending (still contained until the sensor lifts it)"
        case let other?: "\(other) (a status Pion does not know)"
        case nil: "not given, so unknown"
        }
    }

    /// What a host's record hints of the workloads on it, which containing it cuts off too. A hint suggests what runs
    /// there; nothing in Falcon's record verifies that a host is a Kubernetes node.
    enum Workloads: String, CaseIterable, Sendable {
        case kubernetes = "kubernetes-suggested", containers = "containers-suggested", cannotTell = "cannot-tell"
    }

    /// Whether Falcon's record of a host holds a hint that it runs Kubernetes workloads or containers, with the hints;
    /// with none, Pion cannot tell, which is not proof it runs none.
    static func workloads(_ host: Host) -> (kind: Workloads, signs: [String]) {
        var kubernetes: [String] = [], containers: [String] = []
        let words = ["kubernetes", "k8s", "eks", "aks", "gke", "openshift", "rancher", "kubelet"]
        for key in host.fields.keys.sorted() where key.hasPrefix("pod_") || key.hasPrefix("k8s_") || key.hasPrefix("kubernetes_") || key == "cluster_name" {
            if let value = host.text(key) ?? host.list(key).first { kubernetes.append("\(key) \(value)") }
        }
        if let deployment = host.text("deployment_type"), ["daemonset", "kubernetes"].contains(where: deployment.lowercased().contains) {
            kubernetes.append("deployment type \(deployment)")
        }
        if let kind = host.text("product_type_desc"), kind.lowercased() == "pod" { kubernetes.append("product type Pod") }
        for tag in host.tags {
            let lower = tag.lowercased()
            let parts = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            if parts.contains(where: words.contains) { kubernetes.append("tag \(tag)") }
            else if parts.contains(where: ["docker", "container", "containers", "containerd", "ecs", "podman"].contains) { containers.append("tag \(tag)") }
        }
        if let image = host.text("container_image") ?? host.text("image_name") { containers.append("container image \(image)") }
        if !kubernetes.isEmpty { return (.kubernetes, kubernetes) }
        if !containers.isEmpty { return (.containers, containers) }
        return (.cannotTell, [])
    }

    static func workloadsLine(_ host: Host) -> String {
        let (kind, signs) = workloads(host)
        switch kind {
        case .kubernetes: return "Kubernetes: Falcon's record suggests this host runs Kubernetes workloads (hint: \(signs.joined(separator: "; "))), not verified. Containing a host cuts off every workload on it, so every pod it runs would be cut off too."
        case .containers: return "Containers: Falcon's record suggests this host runs containers (hint: \(signs.joined(separator: "; "))), not verified. Containing a host cuts off every workload on it, so every container it runs would be cut off too."
        case .cannotTell: return "Kubernetes and containers: Falcon's record holds no hint of either, so Pion cannot tell; that is not proof it runs none. Containing a host cuts off every workload on it, whatever runs there."
        }
    }

    /// Hosts by ID, every one asked for read or the IDs Falcon did not return listed.
    static func hosts(_ ids: [String], _ service: ServiceClient) async throws -> (found: [Host], missing: [String]) {
        struct Request: Encodable { let ids: [String] }
        return try await entities(ids, batch: 500, id: { (host: Host) in host.id }) { asked in
            try await post(service, ["devices", "entities", "devices", "v2"], body: Request(ids: asked), as: Host.self)
        }
    }

    /// Whether each host's sensor is connected to Falcon now: online, offline or unknown, as Falcon says; a host Falcon
    /// leaves out is not in the answer, so its state is unknown.
    static func onlineStates(_ ids: [String], _ service: ServiceClient) async throws -> [String: String] {
        struct State: Decodable { let id: String; let state: String? }
        var states: [String: String] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            for state in try await get(service, ["devices", "entities", "online-state", "v1"], repeated: ["ids": batch], as: State.self).items() {
                if let id = deviceID(state.id), batch.contains(id), let said = state.state?.lowercased() { states[id] = said }
            }
        }
        return states
    }

    static let platforms = ["Windows", "Mac", "Linux"]
    static let statuses = ["normal", "containment_pending", "contained", "lift_containment_pending"]

    struct Hosts: ServiceOperation {
        struct Input: Decodable, Sendable { let name: String?, ip: String?, platform: String?, status: String?, group: String?, seenSince: String?, limit: Int? }
        static let name = "hosts"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Find hosts by the start of their name, an IP address, platform, containment status or host group, most recently seen first, with each one's device ID, sensor, containment status and when last seen, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "name": .string("The start of the host's name, such as LT-04."),
            "ip": .string("A local or external IP address of the host."),
            "platform": .string("The platform.", oneOf: CrowdStrike.platforms),
            "status": .string("The containment status.", oneOf: CrowdStrike.statuses),
            "group": .string("A host group's ID, as host-groups lists it."),
            "seenSince": .string("Only hosts seen since this time, in ISO 8601."),
            "limit": .integer("How many hosts, at most. 50 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter: [String] = []
            if let name = input.name { filter.append("hostname:*'\(try CrowdStrike.hostname(name))*'") }
            if let ip = input.ip { let ip = try ServiceInput.ip(ip); filter.append("(local_ip:'\(ip)',external_ip:'\(ip)')") }
            if let platform = input.platform { filter.append("platform_name:'\(try ServiceInput.oneOf(platform, CrowdStrike.platforms, "platform"))'") }
            if let status = input.status { filter.append("status:'\(try ServiceInput.oneOf(status, CrowdStrike.statuses, "status"))'") }
            if let group = input.group { filter.append("groups:'\(try CrowdStrike.plainID(group, "the host group's ID"))'") }
            if let since = input.seenSince { filter.append("last_seen:>='\(try ServiceInput.time(since))'") }
            let limit = input.limit ?? 50
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 hosts.") }
            let (listing, hosts, missing) = try await CrowdStrike.read(CrowdStrike.hostsNeed) {
                let listing = try await CrowdStrike.list(service, ["devices", "queries", "devices", "v1"],
                                                         query: ["filter": filter.isEmpty ? nil : filter.joined(separator: "+"), "sort": "last_seen.desc"],
                                                         as: String.self, paging: .offset, size: min(limit, 500), limit: limit)
                let ids = Array(NSOrderedSet(array: listing.value.compactMap(CrowdStrike.deviceID)).compactMap { $0 as? String }.prefix(limit))
                let (hosts, missing) = ids.isEmpty ? ([], []) : try await CrowdStrike.hosts(ids, service)
                return (listing, hosts, missing)
            }
            var text = hosts.isEmpty ? "No host matches\(listing.complete ? "" : " in what was read")."
                : "\(CrowdStrike.plural(hosts.count, "host")), most recently seen first:\n" + hosts.prefix(40).map(\.line).joined(separator: "\n")
            if hosts.count > 40 { text += "\n\(hosts.count - 40) more in the structured result." }
            if !missing.isEmpty { text += "\nFalcon listed \(CrowdStrike.plural(missing.count, "host")) it then did not describe: \(missing.prefix(10).joined(separator: ", "))." }
            let cut = listing.more && listing.stopped == nil
            text += cut ? "\nMore hosts match than the \(hosts.count) kept\(listing.total.map { " (Falcon says \($0) match)" } ?? ""): narrow the name, platform or status." : CrowdStrike.stopped(listing, "hosts")
            struct Kept: Encodable { let hosts: [[String: CellValue]]; let total: Int?; let missing: [String]; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(hosts: hosts.map(\.fields), total: listing.total, missing: missing, complete: listing.complete && missing.isEmpty))
        }
    }

    /// One host by its device ID or exact name: the device IDs that answer to the name, at most `most`.
    static func resolve(_ value: String, _ service: ServiceClient, most: Int = 5) async throws -> [String] {
        if let id = deviceID(value) { return [id] }
        let name = try hostname(value)
        let listing = try await list(service, ["devices", "queries", "devices", "v1"], query: ["filter": "hostname:'\(name)'", "sort": "last_seen.desc"],
                                     as: String.self, paging: .offset, size: most, pages: 1)
        return listing.value.compactMap(deviceID)
    }

    struct HostDetails: ServiceOperation {
        struct Input: Decodable, Sendable { let host: String }
        static let name = "host"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "One host in full: its sensor, OS, addresses, when first and last seen, whether its sensor is online, its containment status, tags and host groups, any hint that it runs Kubernetes workloads or containers, not verified, and the newest alerts that named it, saying what it could not read."
        static let input = JSONSchema.object(["host": .string("The host's 32-character device ID, or its exact name.")], required: ["host"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let ids = try await CrowdStrike.read(CrowdStrike.hostsNeed) { try await CrowdStrike.resolve(input.host, service) }
            guard let id = ids.first else {
                return try ServiceResult(text: "Falcon has no host named \(input.host). It may be named otherwise, or removed from Falcon; hosts finds hosts by the start of their name.",
                                         structured: ["found": false])
            }
            let (found, _) = try await CrowdStrike.read(CrowdStrike.hostsNeed) { try await CrowdStrike.hosts([id], service) }
            guard let host = found.first else {
                return try ServiceResult(text: "Falcon did not return host \(id): it may have been removed or hidden.", structured: ["found": false])
            }
            var lines = [host.line]
            if ids.count > 1 { lines.append("⚠ \(ids.count) hosts answer to that name: \(ids.joined(separator: ", ")). This reads the one seen most recently; give a device ID.") }
            lines.append("First seen \(host.text("first_seen") ?? "unknown"); domain \(host.text("machine_domain") ?? "none given"); MAC \(host.text("mac_address") ?? "not given"); \(host.text("system_manufacturer") ?? "maker unknown") \(host.text("system_product_name") ?? "").")
            lines.append("Tags: \(host.tags.isEmpty ? "none given" : host.tags.joined(separator: ", ")); host groups: \(host.groups.isEmpty ? "none given" : host.groups.joined(separator: ", ")).")
            lines.append(CrowdStrike.workloadsLine(host))
            var gaps: [String] = []
            var online: String?
            do {
                online = try await CrowdStrike.onlineStates([id], service)[id]
                lines.append("Sensor \(online.map { $0 == "online" ? "online now" : $0 == "offline" ? "offline now" : "state \($0)" } ?? "state not given, so unknown").")
            } catch { gaps.append("whether its sensor is online (\(error.localizedDescription))") }
            var alertLines: [String] = []
            do {
                let alerts = try await CrowdStrike.alerts(filter: "device.device_id:'\(id)'", limit: 20, pages: 1, service)
                alertLines = alerts.value.prefix(20).map { KeptAlert($0).line }
                lines.append(alertLines.isEmpty ? "No alert named it\(alerts.complete ? "" : " in what was read")." : "Newest alerts that named it:\n" + alertLines.joined(separator: "\n"))
                if alerts.more { lines.append("More alerts named it than the \(alertLines.count) shown\(alerts.total.map { " (Falcon says \($0))" } ?? ""): use alerts with this host.") }
            } catch { gaps.append("the alerts that named it (\(CrowdStrike.fix(for: error, CrowdStrike.alertsNeed) ?? error.localizedDescription))") }
            if !gaps.isEmpty { lines.append("Could not read: \(gaps.joined(separator: "; ")).") }
            lines.append("Read at \(CrowdStrike.iso(Date())).")
            struct Kept: Encodable { let found: Bool; let host: [String: CellValue]; let online: String?; let workloads: String; let alerts: [String]; let couldNotRead: [String] }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(found: true, host: host.fields, online: online, workloads: CrowdStrike.workloads(host).kind.rawValue, alerts: alertLines, couldNotRead: gaps))
        }
    }
}

// MARK: - Alerts

extension CrowdStrike {
    /// An alert as Falcon gives it; only its composite ID must be there, and anything else Falcon leaves out is unknown.
    struct Alert: Decodable, Sendable {
        struct Device: Decodable, Sendable { let device_id: String?; let hostname: String? }
        struct Process: Decodable, Sendable { let filename: String?; let cmdline: String?; let sha256: String?; let user_name: String? }
        let composite_id: String
        let name: String?, display_name: String?, description: String?, severity_name: String?, severity: Int?, status: String?
        let created_timestamp: String?, updated_timestamp: String?, tactic: String?, technique: String?, technique_id: String?, objective: String?
        let filename: String?, filepath: String?, cmdline: String?, sha256: String?, md5: String?, user_name: String?, product: String?
        let pattern_disposition_description: String?, falcon_host_link: String?, device: Device?
        let parent_details: Process?, grandparent_details: Process?

        enum CodingKeys: String, CodingKey {
            case composite_id, name, display_name, description, severity_name, severity, status, created_timestamp, updated_timestamp, tactic, technique
            case technique_id, objective, filename, filepath, cmdline, sha256, md5, user_name, product, pattern_disposition_description, falcon_host_link
            case device, parent_details, grandparent_details
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            composite_id = try container.decode(String.self, forKey: .composite_id)
            func text(_ key: CodingKeys) -> String? { ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
            name = text(.name); display_name = text(.display_name); description = text(.description); severity_name = text(.severity_name)
            severity = (try? container.decodeIfPresent(Int.self, forKey: .severity)) ?? nil; status = text(.status)
            created_timestamp = text(.created_timestamp); updated_timestamp = text(.updated_timestamp); tactic = text(.tactic); technique = text(.technique)
            technique_id = text(.technique_id); objective = text(.objective); filename = text(.filename); filepath = text(.filepath); cmdline = text(.cmdline)
            sha256 = text(.sha256); md5 = text(.md5); user_name = text(.user_name); product = text(.product)
            pattern_disposition_description = text(.pattern_disposition_description); falcon_host_link = text(.falcon_host_link)
            device = (try? container.decodeIfPresent(Device.self, forKey: .device)) ?? nil
            parent_details = (try? container.decodeIfPresent(Process.self, forKey: .parent_details)) ?? nil
            grandparent_details = (try? container.decodeIfPresent(Process.self, forKey: .grandparent_details)) ?? nil
        }

        var title: String { display_name ?? name ?? composite_id }
        var hostID: String? { device?.device_id.flatMap(CrowdStrike.deviceID) }
    }

    struct KeptAlert: Encodable {
        let id: String, title: String, severity: String?, status: String?, created: String?, host: String?, hostID: String?
        var technique: String?
        let file: String?, commandLine: String?, sha256: String?, link: String?
        init(_ alert: Alert) {
            id = alert.composite_id; title = alert.title; severity = alert.severity_name; status = alert.status; created = alert.created_timestamp
            host = alert.device?.hostname; hostID = alert.hostID; technique = [alert.technique_id, alert.technique].compactMap { $0 }.joined(separator: " ")
            if technique?.isEmpty == true { technique = nil }
            file = alert.filepath ?? alert.filename; commandLine = alert.cmdline.map { String($0.prefix(300)) }; sha256 = alert.sha256; link = alert.falcon_host_link
        }
        var line: String {
            var line = "\(created ?? "?") \(severity ?? "severity unknown") \(status ?? "status unknown"): \(title)"
            if let host { line += " on \(host)" }
            if let file { line += " — \(file)" }
            if let commandLine { line += " `\(commandLine.prefix(200))`" }
            if let technique { line += " (\(technique))" }
            return line + " [\(id)]"
        }
    }

    static let severities = ["Informational", "Low", "Medium", "High", "Critical"]
    static let alertStatuses = ["new", "in_progress", "reopened", "closed"]

    /// Alerts matching a filter, newest first, read whole from Falcon's combined listing, which pages by token, at most
    /// `limit`.
    static func alerts(filter: String, limit: Int, pages: Int = maximumPages, _ service: ServiceClient) async throws -> Listing<Alert> {
        try await read(alertsNeed) {
            try await list(service, ["alerts", "combined", "alerts", "v1"], query: ["filter": filter, "sort": "created_timestamp|desc"],
                           as: Alert.self, paging: .afterInBody, size: min(limit, 1_000), pages: pages, limit: limit)
        }
    }

    static func alertDetails(_ ids: [String], _ service: ServiceClient) async throws -> (found: [Alert], missing: [String]) {
        guard !ids.isEmpty else { return ([], []) }
        struct Request: Encodable { let composite_ids: [String] }
        return try await entities(ids, batch: 1_000, id: { (alert: Alert) in alert.composite_id }) { asked in
            try await post(service, ["alerts", "entities", "alerts", "v2"], body: Request(composite_ids: asked), as: Alert.self)
        }
    }

    struct Alerts: ServiceOperation {
        struct Input: Decodable, Sendable { let host: String?, severity: String?, status: String?, since: String?, until: String?, limit: Int? }
        static let name = "alerts"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Alerts Falcon raised, newest first, by host, least severity, status and time, with the host, file, command line and MITRE technique, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "host": .string("The host's 32-character device ID, or its exact name."),
            "severity": .string("The least severity: this and above.", oneOf: CrowdStrike.severities),
            "status": .string("The status.", oneOf: CrowdStrike.alertStatuses),
            "since": .string("The earliest time it was raised, in ISO 8601. The last 7 days when left out, at most 90 days."),
            "until": .string("The latest time it was raised, in ISO 8601. Now when left out."),
            "limit": .integer("How many alerts, at most. 50 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try CrowdStrike.window(input.since, input.until, days: 7)
            var filter = ["created_timestamp:>='\(CrowdStrike.iso(since))'", "created_timestamp:<='\(CrowdStrike.iso(until))'"]
            if let host = input.host {
                if let id = CrowdStrike.deviceID(host) { filter.append("device.device_id:'\(id)'") }
                else { filter.append("device.hostname:'\(try CrowdStrike.hostname(host))'") }
            }
            if let severity = input.severity {
                let index = CrowdStrike.severities.firstIndex(of: try ServiceInput.oneOf(severity, CrowdStrike.severities, "severity"))!
                filter.append("severity_name:[\(CrowdStrike.severities[index...].map { "'\($0)'" }.joined(separator: ","))]")
            }
            if let status = input.status { filter.append("status:'\(try ServiceInput.oneOf(status, CrowdStrike.alertStatuses, "status"))'") }
            let limit = input.limit ?? 50
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 alerts.") }
            let listing = try await CrowdStrike.alerts(filter: filter.joined(separator: "+"), limit: limit, service)
            let alerts = listing.value.prefix(limit).map(KeptAlert.init)
            let window = "raised from \(CrowdStrike.iso(since)) to \(CrowdStrike.iso(until))"
            var text = alerts.isEmpty ? "No alerts \(window) match\(listing.complete ? "" : " in what was read")."
                : "\(CrowdStrike.plural(alerts.count, "alert")) \(window), newest first:\n" + alerts.prefix(30).map(\.line).joined(separator: "\n")
            if alerts.count > 30 { text += "\n\(alerts.count - 30) more in the structured result." }
            let cut = listing.value.count > limit || (listing.more && listing.stopped == nil)
            text += cut ? "\nMore alerts match than the \(alerts.count) kept, the newest\(listing.total.map { " (Falcon says \($0) match)" } ?? ""): narrow the window, host or severity." : CrowdStrike.stopped(listing, "alerts")
            struct Kept: Encodable { let alerts: [KeptAlert]; let since: String; let until: String; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(alerts: Array(alerts), since: CrowdStrike.iso(since), until: CrowdStrike.iso(until), total: listing.total,
                                                                  complete: listing.complete && !cut))
        }
    }

    struct AlertDetails: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "alert"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "One alert in full: what it says, the host with its device ID, the process, its parent and grandparent with their command lines and SHA256s, the user, the MITRE tactic and technique, and what Falcon did about it."
        static let input = JSONSchema.object(["id": .string("The alert's composite ID, as alerts lists it.")], required: ["id"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard let id = CrowdStrike.compositeID(input.id) else { throw ServiceError.input("Give the alert's composite ID exactly as alerts lists it.") }
            let (found, _) = try await CrowdStrike.read(CrowdStrike.alertsNeed) { try await CrowdStrike.alertDetails([id], service) }
            guard let alert = found.first else { throw ServiceError.input("Falcon did not return alert \(id): it may not exist, or the ID was mistyped.") }
            let kept = KeptAlert(alert)
            var lines = [kept.line]
            lines.append("Host \(alert.device?.hostname ?? "unknown") [device ID \(alert.hostID ?? "not given")]; product \(alert.product ?? "unknown"); severity \(alert.severity.map(String.init) ?? "?")/100; user \(alert.user_name ?? "not given"); last updated \(alert.updated_timestamp ?? "unknown").")
            if let description = alert.description { lines.append("Description: " + String(description.prefix(1_500))) }
            if let tactic = alert.tactic { lines.append("MITRE: \(tactic)\(kept.technique.map { ", \($0)" } ?? "")\(alert.objective.map { "; objective \($0)" } ?? "").") }
            func process(_ label: String, _ details: Alert.Process?) -> String? {
                guard let details, details.filename != nil || details.cmdline != nil else { return nil }
                return "\(label): \(details.filename ?? "?")\(details.cmdline.map { " `\(String($0.prefix(500)))`" } ?? "")\(details.sha256.map { ", SHA256 \($0)" } ?? "")\(details.user_name.map { ", as \($0)" } ?? "")"
            }
            lines.append("Process: \(alert.filepath ?? alert.filename ?? "?")\(alert.cmdline.map { " `\(String($0.prefix(500)))`" } ?? "")\(alert.sha256.map { ", SHA256 \($0)" } ?? "")\(alert.md5.map { ", MD5 \($0)" } ?? "")")
            lines += [process("Parent", alert.parent_details), process("Grandparent", alert.grandparent_details)].compactMap { $0 }
            lines.append("Falcon's response: \(alert.pattern_disposition_description ?? "not given").")
            if let link = alert.falcon_host_link { lines.append("In the Falcon console: \(link)") }
            struct Kept: Encodable { let alert: KeptAlert; let parent: String?; let grandparent: String?; let product: String?; let response: String? }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(alert: kept, parent: process("Parent", alert.parent_details), grandparent: process("Grandparent", alert.grandparent_details),
                                                      product: alert.product, response: alert.pattern_disposition_description))
        }
    }
}

// MARK: - Real Time Response sessions

extension CrowdStrike {
    /// A Real Time Response session as Falcon's audit keeps it, with the commands run in it.
    struct Session: Decodable, Sendable {
        struct Command: Decodable, Sendable {
            let base_command: String?, command_string: String?, current_directory: String?, created_at: String?
            enum CodingKeys: String, CodingKey { case base_command, command_string, current_directory, created_at }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                func text(_ key: CodingKeys) -> String? { ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
                base_command = text(.base_command); command_string = text(.command_string); current_directory = text(.current_directory); created_at = text(.created_at)
            }
            var line: String { "\(created_at ?? "?") \(String((command_string ?? base_command ?? "?").prefix(300)))\(current_directory.map { " (in \($0))" } ?? "")" }
        }
        let id: String
        let device_id: String?, hostname: String?, user_id: String?, user_uuid: String?, origin: String?, created_at: String?, deleted_at: String?
        let logs: [Command]?

        enum CodingKeys: String, CodingKey { case id, device_id, hostname, user_id, user_uuid, origin, created_at, deleted_at, logs }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            func text(_ key: CodingKeys) -> String? { ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
            device_id = text(.device_id); hostname = text(.hostname); user_id = text(.user_id); user_uuid = text(.user_uuid); origin = text(.origin)
            created_at = text(.created_at); deleted_at = text(.deleted_at)
            logs = (try? container.decodeIfPresent([Command].self, forKey: .logs)) ?? nil
        }

        var who: String { user_id ?? user_uuid ?? "someone not named" }
        var line: String {
            "\(created_at ?? "?") \(who) opened a session on \(hostname ?? "?") [\(device_id ?? "device not given")]\(origin.map { " from \($0)" } ?? "")\(deleted_at.map { ", closed \($0)" } ?? ""), \(logs.map { CrowdStrike.plural($0.count, "command") } ?? "commands not given") [\(id)]"
        }
    }

    /// Sessions matching a filter, newest first, with their commands.
    static func sessions(filter: String, sort: String = "created_at|desc", pages: Int, size: Int = 100, limit: Int? = nil, from: Cursor? = nil, partial: Bool = true,
                         _ service: ServiceClient) async throws -> Listing<Session> {
        try await list(service, ["real-time-response-audit", "combined", "sessions", "v1"], query: ["filter": filter, "sort": sort, "with_command_info": "true"],
                       as: Session.self, paging: .offset, size: size, pages: pages, limit: limit, from: from, partial: partial)
    }

    struct RTRSessions: ServiceOperation {
        struct Input: Decodable, Sendable { let host: String?, user: String?, since: String?, until: String?, limit: Int? }
        static let name = "rtr-sessions"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Real Time Response sessions, newest first, by host, user and time: who opened each on which host, and every command they ran in it, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "host": .string("Only sessions on this host, by its 32-character device ID."),
            "user": .string("Only sessions opened by this user or API client, as Falcon names them."),
            "since": .string("The earliest time a session was opened, in ISO 8601. The last 7 days when left out, at most 90 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many sessions, at most. 50 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try CrowdStrike.window(input.since, input.until, days: 7)
            var filter = ["created_at:>='\(CrowdStrike.iso(since))'", "created_at:<='\(CrowdStrike.iso(until))'"]
            if let host = input.host {
                guard let id = CrowdStrike.deviceID(host) else { throw ServiceError.input("Give the host's 32-character device ID, as hosts or host gives it.") }
                filter.append("device_id:'\(id)'")
            }
            if let user = input.user { filter.append("user_id:'\(try ServiceInput.quoted(user, "the user"))'") }
            let limit = input.limit ?? 50
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 sessions.") }
            let listing = try await CrowdStrike.read(CrowdStrike.rtrAuditNeed) {
                try await CrowdStrike.sessions(filter: filter.joined(separator: "+"), pages: CrowdStrike.maximumPages, size: min(limit, 100), limit: limit, service)
            }
            let sessions = Array(listing.value.prefix(limit))
            let window = "opened from \(CrowdStrike.iso(since)) to \(CrowdStrike.iso(until))"
            var lines = [sessions.isEmpty ? "No Real Time Response sessions \(window) match\(listing.complete ? "" : " in what was read")." : "\(CrowdStrike.plural(sessions.count, "session")) \(window), newest first:"]
            var shown = 0
            for session in sessions.prefix(30) {
                lines.append(session.line)
                for command in (session.logs ?? []).prefix(max(0, 200 - shown)) { lines.append("  " + command.line); shown += 1 }
            }
            if sessions.count > 30 { lines.append("\(sessions.count - 30) more sessions in the structured result.") }
            if shown >= 200 { lines.append("Commands past the first 200 are in the structured result.") }
            let cut = listing.more && listing.stopped == nil
            let said = cut ? "More sessions match than the \(sessions.count) kept\(listing.total.map { " (Falcon says \($0) match)" } ?? ""): narrow the window, host or user." : String(CrowdStrike.stopped(listing, "sessions").dropFirst())
            if !said.isEmpty { lines.append(said) }
            struct Kept: Encodable { let id: String; let host: String?; let device: String?; let user: String; let origin: String?; let opened: String?; let closed: String?; let commands: [String] }
            struct All: Encodable { let sessions: [Kept]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: All(sessions: sessions.map { Kept(id: $0.id, host: $0.hostname, device: $0.device_id, user: $0.who, origin: $0.origin, opened: $0.created_at,
                                                                                    closed: $0.deleted_at, commands: ($0.logs ?? []).map(\.line)) },
                                                     total: listing.total, complete: listing.complete))
        }
    }
}

// MARK: - Host groups and container images

extension CrowdStrike {
    struct HostGroup: Decodable, Sendable {
        let id: String
        let name: String?, description: String?, group_type: String?, assignment_rule: String?, created_by: String?, modified_timestamp: String?
        var line: String {
            "\(name ?? "unnamed") [\(id)]: \(group_type ?? "type unknown")\(assignment_rule.map { ", rule `\(String($0.prefix(200)))`" } ?? "")\(description.map { " — \(String($0.prefix(200)))" } ?? "")"
        }
    }

    struct HostGroups: ServiceOperation {
        struct Input: Decodable, Sendable { let group: String?, limit: Int? }
        static let name = "host-groups"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Host groups, with each one's type and assignment rule; or, given a group, the hosts in it, saying when more matched than it kept."
        static let input = JSONSchema.object([
            "group": .string("A host group's ID, to list the hosts in it."),
            "limit": .integer("How many, at most. 100 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 100
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500.") }
            if let group = input.group {
                let id = try CrowdStrike.plainID(group, "the host group's ID")
                let listing = try await CrowdStrike.read(CrowdStrike.hostGroupsNeed) {
                    try await CrowdStrike.list(service, ["devices", "queries", "host-group-members", "v1"], query: ["id": id], as: String.self, paging: .offset,
                                               size: min(limit, 500), limit: limit)
                }
                let ids = Array(listing.value.compactMap(CrowdStrike.deviceID).prefix(limit))
                let (hosts, missing) = ids.isEmpty ? ([], []) : try await CrowdStrike.read(CrowdStrike.hostsNeed) { try await CrowdStrike.hosts(ids, service) }
                var text = hosts.isEmpty ? "Host group \(id) has no hosts\(listing.complete ? "" : " in what was read")." : "\(CrowdStrike.plural(hosts.count, "host")) in host group \(id):\n" + hosts.prefix(50).map(\.line).joined(separator: "\n")
                if hosts.count > 50 { text += "\n\(hosts.count - 50) more in the structured result." }
                if !missing.isEmpty { text += "\nFalcon listed \(CrowdStrike.plural(missing.count, "host")) it then did not describe." }
                text += listing.more && listing.stopped == nil ? "\nMore hosts are in it than the \(hosts.count) kept\(listing.total.map { " (Falcon says \($0))" } ?? "")." : CrowdStrike.stopped(listing, "the group's hosts")
                struct Kept: Encodable { let group: String; let hosts: [[String: CellValue]]; let total: Int?; let complete: Bool }
                return try ServiceResult(text: text, structured: Kept(group: id, hosts: hosts.map(\.fields), total: listing.total, complete: listing.complete && missing.isEmpty))
            }
            let listing = try await CrowdStrike.read(CrowdStrike.hostGroupsNeed) {
                try await CrowdStrike.list(service, ["devices", "combined", "host-groups", "v1"], query: ["sort": "name.asc"], as: HostGroup.self, paging: .offset,
                                           size: min(limit, 500), limit: limit)
            }
            let groups = Array(listing.value.prefix(limit))
            var text = groups.isEmpty ? "Falcon lists no host groups\(listing.complete ? "" : " in what was read")." : "\(CrowdStrike.plural(groups.count, "host group")):\n" + groups.map(\.line).joined(separator: "\n")
            text += listing.more && listing.stopped == nil ? "\nThere are more host groups than the \(groups.count) kept\(listing.total.map { " (Falcon says \($0))" } ?? "")." : CrowdStrike.stopped(listing, "host groups")
            struct Kept: Encodable { let id: String; let name: String?; let type: String?; let rule: String? }
            struct All: Encodable { let groups: [Kept]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: All(groups: groups.map { Kept(id: $0.id, name: $0.name, type: $0.group_type, rule: $0.assignment_rule) },
                                                                 total: listing.total, complete: listing.complete))
        }
    }

    struct ContainerImages: ServiceOperation {
        struct Input: Decodable, Sendable { let repository: String?, minimumSeverity: String?, limit: Int? }
        static let name = "container-images"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Container images Falcon assessed, by repository and least vulnerability severity, with each one's registry, tag, highest vulnerability severity, vulnerability and detection counts, base OS and when first and last seen, saying when more matched than it kept. Read-only."
        static let input = JSONSchema.object([
            "repository": .string("Only images of this repository, such as library/nginx."),
            "minimumSeverity": .string("Only images with a vulnerability of this severity or above.", oneOf: ["Critical", "High", "Medium", "Low"]),
            "limit": .integer("How many images, at most. 50 when left out.", minimum: 1, maximum: 200),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter: [String] = []
            if let repository = input.repository { filter.append("repository:'\(try ServiceInput.quoted(repository, "the repository", limit: 300))'") }
            if let severity = input.minimumSeverity {
                let order = ["Critical", "High", "Medium", "Low"]
                let index = order.firstIndex(of: try ServiceInput.oneOf(severity, order, "minimumSeverity"))!
                filter.append("(" + order[...index].map { "vulnerability_severity:'\($0.uppercased())'" }.joined(separator: ",") + ")")
            }
            let limit = input.limit ?? 50
            guard (1...200).contains(limit) else { throw ServiceError.input("Ask for between 1 and 200 images.") }
            let listing = try await CrowdStrike.read(CrowdStrike.imagesNeed) {
                try await CrowdStrike.list(service, ["container-security", "combined", "image-assessment", "images", "v1"],
                                           query: ["filter": filter.isEmpty ? nil : filter.joined(separator: "+")],
                                           as: [String: CellValue].self, paging: .offset, size: min(limit, 100), limit: limit)
            }
            let images = Array(listing.value.prefix(limit))
            func text(_ row: [String: CellValue], _ keys: String...) -> String? {
                for key in keys { if let value = row[key]?.shown, !value.isEmpty, value != "…" { return value } }
                return nil
            }
            let lines = images.map { row in
                "\(text(row, "registry") ?? "?")/\(text(row, "repository") ?? "?"):\(text(row, "tag") ?? "?") [\(text(row, "image_id") ?? "?")]: highest vulnerability \(text(row, "highest_vulnerability_severity") ?? "not given"), vulnerabilities \(text(row, "vulnerabilities") ?? "?"), detections \(text(row, "detections") ?? "?"), base OS \(text(row, "base_os") ?? "unknown"), first seen \(text(row, "first_seen") ?? "?"), last seen \(text(row, "last_seen") ?? "?")"
            }
            var result = images.isEmpty ? "No assessed images match\(listing.complete ? "" : " in what was read"). Images Falcon never assessed are not listed." : "\(CrowdStrike.plural(images.count, "image")):\n" + lines.prefix(40).joined(separator: "\n")
            if images.count > 40 { result += "\n\(images.count - 40) more in the structured result." }
            result += listing.more && listing.stopped == nil ? "\nMore images match than the \(images.count) kept\(listing.total.map { " (Falcon says \($0))" } ?? ""): narrow by repository or severity." : CrowdStrike.stopped(listing, "images")
            struct Kept: Encodable { let images: [[String: CellValue]]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: result, structured: Kept(images: images, total: listing.total, complete: listing.complete))
        }
    }
}

// MARK: - Console users

extension CrowdStrike {
    /// Who can use the Falcon console and with which roles, administrators first. Falcon lists one user's roles at a time.
    struct Users: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "users"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Everyone who can use the Falcon console, with their roles, administrators first, saying what it could not read."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let listing = try await CrowdStrike.read(CrowdStrike.usersNeed) {
                try await CrowdStrike.list(service, ["user-management", "queries", "users", "v1"], query: [:], as: String.self, paging: .offset, size: 500)
            }
            let ids = Array(NSOrderedSet(array: listing.value).compactMap { $0 as? String })
            guard !ids.isEmpty else {
                return try ServiceResult(text: "Falcon lists no console users\(listing.complete ? "" : " in what was read").\(CrowdStrike.stopped(listing, "users"))", structured: ["users": [String]()])
            }
            struct User: Decodable { let uuid: String; let uid: String? }
            struct Request: Encodable { let ids: [String] }
            let (users, _) = try await CrowdStrike.read(CrowdStrike.usersNeed) {
                try await CrowdStrike.entities(ids, batch: 100, id: { (user: User) in user.uuid }) { asked in
                    try await CrowdStrike.post(service, ["user-management", "entities", "users", "GET", "v1"], body: Request(ids: asked), as: User.self)
                }
            }
            let named = Dictionary(users.map { ($0.uuid, $0.uid ?? $0.uuid) }, uniquingKeysWith: { first, _ in first })
            struct Role: Decodable { let role_id: String?; let role_name: String? }
            let roles = await withTaskGroup(of: (String, [String]?).self) { group in
                for id in ids {
                    group.addTask {
                        let held = try? await CrowdStrike.get(service, ["user-management", "combined", "user-roles", "v1"], query: ["user_uuid": id], as: Role.self).items()
                        return (id, held.map { $0.compactMap { $0.role_name ?? $0.role_id } })
                    }
                }
                return await group.reduce(into: [String: [String]?]()) { $0[$1.0] = $1.1 }
            }
            struct Kept: Encodable { let uuid: String; let user: String; let roles: [String]?; let rolesRead: Bool }
            let kept = ids.map { Kept(uuid: $0, user: named[$0] ?? $0, roles: roles[$0] ?? nil, rolesRead: (roles[$0] ?? nil) != nil) }
            func administrator(_ user: Kept) -> Bool { (user.roles ?? []).contains { $0.localizedCaseInsensitiveContains("administrator") } }
            let ordered = kept.filter(administrator) + kept.filter { !administrator($0) }
            var text = ordered.map { "\($0.user): \($0.roles.map { $0.isEmpty ? "no roles" : $0.joined(separator: ", ") } ?? "roles could not be read")" }.joined(separator: "\n")
            let unread = ordered.filter { !$0.rolesRead }.count
            if unread > 0 { text += "\nThe roles of \(CrowdStrike.plural(unread, "user")) could not be read, so whether they are administrators is unknown." }
            text += CrowdStrike.stopped(listing, "users")
            struct Listed: Encodable { let users: [Kept]; let complete: Bool }
            return try ServiceResult(text: text, structured: Listed(users: ordered, complete: listing.complete && unread == 0))
        }
    }
}

// MARK: - Access

extension CrowdStrike {
    /// A read only a client holding a write scope may make: Real Time Response's command status, asked of a request
    /// that does not exist, which Falcon refuses with a 403 when the client lacks the scope. It changes nothing.
    struct ScopeRead: Sendable {
        let scope: Scope
        let path: [String]
        var query: [String: String?] = [:]
    }

    static let noRequest = "00000000-0000-0000-0000-000000000000"

    static let writeReads: [ScopeRead] = [
        ScopeRead(scope: Scope(name: "Real time response", access: "Write"), path: ["real-time-response", "entities", "active-responder-command", "v1"],
                  query: ["cloud_request_id": noRequest, "sequence_id": "0"]),
        ScopeRead(scope: Scope(name: "Real time response (admin)", access: "Write"), path: ["real-time-response", "entities", "admin-command", "v1"],
                  query: ["cloud_request_id": noRequest, "sequence_id": "0"]),
    ]

    /// Write scopes no read shows: Falcon would say whether a client holds one only to a request that tries a change,
    /// which check-access never sends.
    static let unverifiableWrites = [Scope(name: "Hosts", access: "Write"), Scope(name: "Host groups", access: "Write"), Scope(name: "Alerts", access: "Write"),
                                     Scope(name: "IOC Management", access: "Write")]

    static func notVerified(_ scopes: [Scope]) -> String {
        "· \(scopes.map(\.plain).joined(separator: ", ")): write access not verified — Falcon offers no way to list a client's scopes without attempting a change, and check-access attempts none."
    }

    enum Held: Equatable { case yes(Int), no, rejected, unknown(String) }

    /// Whether the client holds a write scope, by what Falcon answers its read: a 403 is the scope missing; an answer
    /// past the scope check, such as no such request, is the scope held; anything else leaves it unknown.
    static func holds(_ probe: ScopeRead, _ service: ServiceClient) async -> Held {
        do {
            let answer = try await raw(service, probe.path, query: probe.query)
            switch answer.response.statusCode {
            case 403: return .no
            case 401: return .rejected
            case 200..<300, 400, 404, 422: return .yes(answer.response.statusCode)
            case let status: return .unknown("Falcon answered HTTP \(status)\(reason(answer.data).map { ": \($0)" } ?? "")")
            }
        } catch { return .unknown(error.localizedDescription) }
    }

    /// A line for each write scope a client must not hold that a read shows.
    static func unwanted(_ reads: [ScopeRead], tool: String, _ service: ServiceClient) async -> [String] {
        var lines: [String] = []
        for probe in reads {
            switch await holds(probe, service) {
            case .no: lines.append("✓ Holds no \(probe.scope.plain), which \(tool) must not.")
            case .yes(let status): lines.append("⚠ Appears to hold \(probe.scope.plain), which \(tool) must not have: Falcon answered a read that needs it past its scope check (HTTP \(status)). Remove it from this tool's API client in Support and resources › API clients and keys.")
            case .rejected: lines.append("✗ Whether it holds \(probe.scope.plain) could not be told: Falcon did not accept the API client's ID and secret.")
            case .unknown(let why): lines.append("? Whether it holds \(probe.scope.plain) could not be told (\(why)); check the client in Support and resources › API clients and keys.")
            }
        }
        return lines
    }

    /// Tries each thing Detection reads once and says what works and what to change, and warns of a write scope its client
    /// holds where a read shows it. It sends only reads.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Tries each thing this tool reads once and says what works and, for what does not, which scope to add; which Falcon cloud it reads; and warns when a read shows the API client holds Real Time Response's write or admin scope, which Detection must not. It sends only reads, so other write scopes are not verified."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let cloud = try CrowdStrike.cloud(service)
            var lines = ["· Falcon cloud \(cloud.title), \(cloud.host), whose console is \(cloud.console)."]
            let reads: [(Need, [String], [String: String?])] = [
                (CrowdStrike.hostsNeed, ["devices", "queries", "devices", "v1"], ["limit": "1"]),
                (CrowdStrike.alertsNeed, ["alerts", "queries", "alerts", "v2"], ["limit": "1"]),
                (CrowdStrike.rtrAuditNeed, ["real-time-response-audit", "combined", "sessions", "v1"], ["limit": "1"]),
                (CrowdStrike.hostGroupsNeed, ["devices", "queries", "host-groups", "v1"], ["limit": "1"]),
                (CrowdStrike.imagesNeed, ["container-security", "combined", "image-assessment", "images", "v1"], ["limit": "1"]),
                (CrowdStrike.usersNeed, ["user-management", "queries", "users", "v1"], ["limit": "1"]),
                (CrowdStrike.preventionNeed, ["policy", "queries", "prevention", "v1"], ["limit": "1"]),
                (CrowdStrike.mlExclusionsNeed, ["policy", "queries", "ml-exclusions", "v1"], ["limit": "1"]),
                (CrowdStrike.ioaExclusionsNeed, ["policy", "queries", "ioa-exclusions", "v1"], ["limit": "1"]),
                (CrowdStrike.svExclusionsNeed, ["policy", "queries", "sv-exclusions", "v1"], ["limit": "1"]),
            ]
            var working: [String] = []
            for (need, path, query) in reads {
                do {
                    _ = try await CrowdStrike.get(service, path, query: query, as: CellValue.self).items()
                    lines.append("✓ \(need.title) (\(need.scope.plain))")
                    working.append(need.title)
                } catch {
                    let required = need.scope == CrowdStrike.hostsRead || need.scope == CrowdStrike.alertsRead
                    lines.append("\(required ? "✗" : "⚠") \(need.title): " + (CrowdStrike.fix(for: error, need) ?? error.localizedDescription))
                }
            }
            if !working.contains(CrowdStrike.rtrAuditNeed.title) || !working.contains(CrowdStrike.alertsNeed.title) || !working.contains(CrowdStrike.hostsNeed.title) {
                lines.append("· The alert watch reads alerts, Real Time Response sessions and contained hosts; what it cannot read it says once, and security-events says why.")
            }
            lines += await CrowdStrike.unwanted(CrowdStrike.writeReads, tool: "Detection", service)
            lines.append(CrowdStrike.notVerified(CrowdStrike.unverifiableWrites))
            lines.append("· Pion Falcon Detection's client should hold only \(CrowdStrike.auditScopes.map(\.plain).joined(separator: ", ")), and no Write scope at all: check it in Support and resources › API clients and keys.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
