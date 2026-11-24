import Foundation
import NoodleCore
import NoodleToolConnections

/// Cloudflare Audit's reads of Zero Trust: Access authentication logs, applications, policies, users and their
/// sessions, Gateway activity, rules and lists, WARP devices and Cloudflare Tunnels.
extension Cloudflare {
    // MARK: Access authentication logs

    /// One Access login as Cloudflare logs it, field by field; only its time must be there, as a login that cannot be
    /// placed in time cannot be told to be in a window.
    struct AccessLogin: Decodable, Sendable {
        let fields: Value
        let date: Date?

        init(from decoder: Decoder) throws {
            let fields = try Value(from: decoder)
            guard case .object = fields, let date = ServiceAlert.time(fields["created_at"]?.text) else { throw ServiceError.unreadable }
            self.fields = fields
            self.date = date
        }

        var email: String? { fields["user_email"]?.text?.lowercased() }
        var ip: String? { fields["ip_address"]?.text }
        var app: String? { fields["app_domain"]?.text }
        var allowed: Bool? { fields["allowed"]?.flag }
        var country: String? { fields["country_code"]?.text ?? fields["country"]?.text }
        /// What tells one login from another read again: Cloudflare gives no ID of its own.
        var id: String { ["created_at", "ray_id", "user_email", "ip_address", "app_uid", "action", "allowed", "connection"].map { fields[$0]?.text ?? "-" }.joined(separator: "|") }

        var line: String {
            let verdict: String = switch allowed { case true?: "allowed"; case false?: "BLOCKED"; case nil: "allowed or blocked not given" }
            var line = "\(fields["created_at"]?.text ?? "?") \(verdict): \(email ?? "a person not named") to \(app ?? fields["app_uid"]?.text ?? "an application not named")"
            line += " from \(ip ?? "an address not given")\(country.map { " (\($0))" } ?? "")"
            if let action = fields["action"]?.text { line += ", \(action)" }
            if let connection = fields["connection"]?.text { line += " via \(connection)" }
            if let ray = fields["ray_id"]?.text { line += ", Ray \(ray)" }
            return String(line.prefix(500))
        }
    }

    /// Access logins from `since` to `until`, newest first. Cloudflare gives the log without paging details, so Pion
    /// reads it by time: each next request asks up to a second after the oldest login the last gave, and logins read
    /// twice are counted once. It is whole only once a request brings nothing new and is shorter than asked for, or
    /// than the longest answer Cloudflare gave. It stops, saying so, at its page budget or where more logins share one
    /// second than Cloudflare gives at once.
    static func accessLogins(_ service: ServiceClient, since: Date, until: Date, query extra: [String: String?] = [:], pages: Int, size: Int = 500,
                             limit: Int? = nil, partial: Bool) async throws -> Listing<AccessLogin> {
        var found = Listing<AccessLogin>()
        var upper = until
        var seen = Set<String>()
        var longest = 0
        let path = ["accounts", try account(service), "access", "logs", "access_requests"]
        func stop(_ reason: String) throws -> Listing<AccessLogin> {
            guard partial, found.pages > 0 else { throw ServiceError.input("Cloudflare's answer could not be relied on: \(reason).") }
            found.more = true
            found.stoppedAt = found.pages + 1
            found.stopped = reason
            return found
        }
        while found.pages < pages {
            var asked = extra
            asked["since"] = iso(since); asked["until"] = iso(upper); asked["direction"] = "desc"; asked["limit"] = String(size)
            let items: [AccessLogin]
            do {
                let envelope: Envelope<[AccessLogin]> = try decode(try await exchange(service, path, query: asked).data)
                items = try envelope.value()
            } catch {
                guard partial, found.pages > 0 else { throw error }
                return try stop(error.localizedDescription)
            }
            if items.count > size { return try stop("Cloudflare gave \(items.count) logins when asked for at most \(size)") }
            found.pages += 1
            let fresh = items.filter { seen.insert($0.id).inserted }
            found.value += fresh.filter { ($0.date ?? .distantPast) >= since.addingTimeInterval(-1) && ($0.date ?? .distantFuture) <= until.addingTimeInterval(1) }
            longest = max(longest, items.count)
            if items.isEmpty || (fresh.isEmpty && (items.count < longest || items.count < size)) {
                found.more = false
                return found
            }
            guard let oldest = items.compactMap(\.date).min() else { return try stop("Cloudflare gave logins without a time") }
            if fresh.isEmpty {
                return try stop("more logins at \(iso(oldest)) than Cloudflare gives at once, so those after them could not be read")
            }
            found.more = true
            upper = min(upper, oldest.addingTimeInterval(1))
            if let limit, found.value.count >= limit { return found }
        }
        return found
    }

    struct AccessLogs: ServiceOperation {
        struct Input: Decodable, Sendable { let email: String?, blocked: Bool?, since: String?, until: String?, limit: Int? }
        static let name = "access-logs"
        static let summary = "Access authentication logs, newest first: who signed in to which Access application, allowed or blocked, from which IP address and country, by person, outcome and time; says when more matched than it kept."
        static let input = JSONSchema.object([
            "email": .string("Only logins by this email address, exactly."),
            "blocked": .boolean("Only blocked logins, or only allowed ones."),
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 30 days; Cloudflare keeps less on some plans."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many logins, at most. 200 when left out.", minimum: 1, maximum: 5_000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try Cloudflare.window(input.since, input.until, days: 1, maximum: 30)
            var query: [String: String?] = [:]
            if let email = input.email { query["email"] = try ServiceInput.email(email); query["email_exact"] = "true" }
            let limit = try Cloudflare.limit(input.limit, default: 200, maximum: 5_000, "logins")
            let listing = try await Cloudflare.read(Cloudflare.accessLogsNeed) {
                try await Cloudflare.accessLogins(service, since: since, until: until, query: query, pages: Cloudflare.maximumPages,
                                                  limit: input.blocked == nil ? limit : nil, partial: true)
            }
            // Filtered here: Cloudflare documents no parameter that takes the outcome, only its operator.
            let matching = listing.value.filter { input.blocked == nil || $0.allowed == !input.blocked! }
                .filter { input.email == nil || $0.email == (try? ServiceInput.email(input.email!)) }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            let kept = Array(matching.prefix(limit))
            let blocked = kept.filter { $0.allowed == false }.count
            let window = "from \(Cloudflare.iso(since)) to \(Cloudflare.iso(until))"
            var text = kept.isEmpty ? "No Access logins \(window) match\(listing.complete ? "" : " in what was read")."
                : "\(Cloudflare.plural(kept.count, "login")) \(window), \(blocked) blocked, newest first:\n" + kept.prefix(80).map(\.line).joined(separator: "\n")
            if kept.count > 80 { text += "\n\(kept.count - 80) more in the structured result." }
            let cut = matching.count > limit || (listing.more && listing.stopped == nil)
            text += cut ? "\nMore logins match than the \(kept.count) kept, the newest: narrow the window or give an email." : ""
            if listing.stopped != nil || !cut { text += Cloudflare.stopped(listing, "Access logins") }
            struct Kept: Encodable { let logins: [String]; let blocked: Int; let since: String; let until: String; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(logins: kept.map(\.line), blocked: blocked, since: Cloudflare.iso(since), until: Cloudflare.iso(until),
                                                                  complete: listing.complete && !cut))
        }
    }

    // MARK: Access applications and policies

    /// An Access rule, such as {"email": {"email": "a@b.example"}}, said as words: its kind and what it names.
    static func rule(_ value: Value) -> String {
        guard let object = value.object, let (kind, body) = object.first else { return "a rule Pion cannot read" }
        let named = body.words.filter { !$0.isEmpty }
        return named.isEmpty ? kind : "\(kind) \(named.joined(separator: " "))"
    }

    static func policyLine(_ policy: Item) -> String {
        func rules(_ key: String) -> String? {
            let list = policy.fields[key]?.items ?? []
            return list.isEmpty ? nil : list.prefix(10).map(Cloudflare.rule).joined(separator: " or ")
        }
        var line = "\(policy.text("precedence").map { "#\($0) " } ?? "")\(policy.text("decision")?.uppercased() ?? "DECISION NOT GIVEN") \(policy.text("name") ?? "unnamed")"
        line += ": include \(rules("include") ?? "nothing given")"
        if let require = rules("require") { line += "; require \(require)" }
        if let exclude = rules("exclude") { line += "; exclude \(exclude)" }
        if policy.flag("reusable") == true { line += " (reusable)" }
        if let duration = policy.text("session_duration") { line += ", session \(duration)" }
        line += ", updated \(policy.text("updated_at") ?? "at a time not given")"
        return String(line.prefix(700)) + " [\(policy.id)]"
    }

    static func appLine(_ app: Item) -> String {
        var line = "\(app.text("name") ?? "unnamed") (\(app.text("type") ?? "type not given")) at \(app.text("domain") ?? "no domain given")"
        if let duration = app.text("session_duration") { line += ", session \(duration)" }
        let idps = app.texts("allowed_idps")
        if !idps.isEmpty { line += ", \(Cloudflare.plural(idps.count, "identity provider"))" }
        line += ", updated \(app.text("updated_at") ?? "at a time not given")"
        return line + " [\(app.id)]"
    }

    struct AccessApps: ServiceOperation {
        struct Input: Decodable, Sendable { let search: String?, limit: Int? }
        static let name = "access-apps"
        static let summary = "Access applications, with each one's ID, type, domain, session length and when it last changed, optionally whose name or domain contains some words; access-app reads one with its policies. Says when it read only part."
        static let input = JSONSchema.object([
            "search": .string("Only applications whose name or domain contains this."),
            "limit": .integer("How many applications, at most. 200 when left out.", minimum: 1, maximum: 2_000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = [:]
            if let search = input.search { query["search"] = try ServiceInput.quoted(search, "the words") }
            let limit = try Cloudflare.limit(input.limit, default: 200, maximum: 2_000, "applications")
            let listing = try await Cloudflare.read(Cloudflare.accessAppsNeed) {
                try await Cloudflare.list(service, ["accounts", try Cloudflare.account(service), "access", "apps"], query: query, as: Item.self, size: 200, pages: 10, limit: limit)
            }
            let (apps, cut, notice) = Cloudflare.summary(listing, limit: limit, name: "applications", narrow: "give words to search for")
            let lines = apps.map(Cloudflare.appLine)
            let text = (lines.isEmpty ? "No Access application matches\(listing.complete ? "" : " in what was read")." : "\(Cloudflare.plural(lines.count, "application")):\n" + lines.joined(separator: "\n")) + notice
            struct Kept: Encodable { let apps: [String]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(apps: lines, total: listing.total, complete: listing.complete && !cut))
        }
    }

    struct AccessApp: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "access-app"
        static let summary = "One Access application by its ID, with every policy that applies to it in order, reusable ones included: each one's decision (allow, deny, bypass or service auth), who it includes, requires and excludes, and when it last changed. Bypass and service-auth policies are evaluated first, then the rest in order."
        static let input = JSONSchema.object(["id": .string("The application's ID, a UUID, as access-apps lists it.")], required: ["id"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = try Cloudflare.requireUUID(input.id, "the application's ID")
            let account = try Cloudflare.account(service)
            let app: Item
            switch try await Cloudflare.read(Cloudflare.accessAppsNeed, { try await Cloudflare.fetch(service, ["accounts", account, "access", "apps", id], id: id, what: "Access application") }) {
            case .present(let found): app = found
            case .absent, .inconclusive:
                // Cloudflare documents no answer meaning an application is not there, so only the whole list can say so.
                switch try await Cloudflare.read(Cloudflare.accessAppsNeed, { try await Cloudflare.find(service, ["accounts", account, "access", "apps"], query: [:], id: id, what: "Access application", size: 200) }) {
                case .present(let found): app = found
                case .absent: return try ServiceResult(text: "This account has no Access application \(id): the whole list of its applications was read and does not name it.", structured: ["found": false])
                case .inconclusive(let why): throw ServiceError.input("Access application \(id) could not be read: \(why).")
                }
            }
            var lines = [Cloudflare.appLine(app)]
            let listing = try await Cloudflare.read(Cloudflare.accessAppsNeed) {
                try await Cloudflare.list(service, ["accounts", account, "access", "apps", id, "policies"], query: [:], as: Item.self, size: 200, pages: 5)
            }
            let ordered = listing.value.sorted { ($0.number("precedence") ?? .max, $0.id) < ($1.number("precedence") ?? .max, $1.id) }
            let first = ordered.filter { ["bypass", "non_identity"].contains($0.text("decision")?.lowercased() ?? "") }
            let rest = ordered.filter { !["bypass", "non_identity"].contains($0.text("decision")?.lowercased() ?? "") }
            let policies = (first + rest).map(Cloudflare.policyLine)
            lines.append(policies.isEmpty ? "No policy applies to it\(listing.complete ? "" : " in what was read"), so no one is let in." : "Its policies, in the order Access evaluates them (bypass and service auth first):\n" + policies.joined(separator: "\n"))
            if ordered.contains(where: { $0.number("precedence") == nil }) { lines.append("Some policies give no precedence, so their place in the order is not known.") }
            lines.append(String(Cloudflare.stopped(listing, "policies").drop { $0 == "\n" }))
            lines.append("Read at \(Cloudflare.iso(Date())).")
            struct Kept: Encodable { let found: Bool; let app: String; let policies: [String]; let complete: Bool }
            return try ServiceResult(text: lines.filter { !$0.isEmpty }.joined(separator: "\n"), structured: Kept(found: true, app: Cloudflare.appLine(app), policies: policies, complete: listing.complete))
        }
    }

    // MARK: Access users

    static func userLine(_ user: Item) -> String {
        var parts: [String] = []
        parts.append("last login \(user.text("last_successful_login") ?? "not given")")
        parts.append(user.number("active_device_count").map { "\(Cloudflare.plural($0, "active device"))" } ?? "active devices not given")
        if user.flag("access_seat") == true { parts.append("Access seat") }
        if user.flag("gateway_seat") == true { parts.append("Gateway seat") }
        parts.append("made \(user.text("created_at") ?? "at a time not given")")
        return "\(user.text("email") ?? "no email given")\(user.text("name").map { " (\($0))" } ?? ""): " + parts.joined(separator: ", ") + " [\(user.id)]"
    }

    struct AccessUsers: ServiceOperation {
        struct Input: Decodable, Sendable { let search: String?, limit: Int? }
        static let name = "access-users"
        static let summary = "Zero Trust users, with each one's ID, email, last successful login, active devices and seats, optionally whose name or email contains some words; access-user reads one with its sessions. Says when it read only part."
        static let input = JSONSchema.object([
            "search": .string("Only users whose name or email contains this."),
            "limit": .integer("How many users, at most. 200 when left out.", minimum: 1, maximum: 5_000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = [:]
            if let search = input.search { query["search"] = try ServiceInput.quoted(search, "the words") }
            let limit = try Cloudflare.limit(input.limit, default: 200, maximum: 5_000, "users")
            let listing = try await Cloudflare.read(Cloudflare.accessUsersNeed) {
                try await Cloudflare.list(service, ["accounts", try Cloudflare.account(service), "access", "users"], query: query, as: Item.self, size: 500, pages: 10, limit: limit)
            }
            let (users, cut, notice) = Cloudflare.summary(listing, limit: limit, name: "users", narrow: "give words to search for")
            let lines = users.map(Cloudflare.userLine)
            let text = (lines.isEmpty ? "No Zero Trust user matches\(listing.complete ? "" : " in what was read")." : "\(Cloudflare.plural(lines.count, "user")):\n" + lines.joined(separator: "\n")) + notice
            struct Kept: Encodable { let users: [String]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(users: lines, total: listing.total, complete: listing.complete && !cut))
        }
    }

    /// One user by email or ID, read from the whole list of users with that email, or of all users for an ID.
    static func accessUser(_ value: String, _ service: ServiceClient, need: Need = accessUsersNeed) async throws -> Lookup<Item> {
        let account = try account(service)
        let path = ["accounts", account, "access", "users"]
        if let id = uuid(value) {
            return try await read(need) { try await find(service, path, query: [:], id: id, what: "user", size: 500) }
        }
        let email = try ServiceInput.email(value)
        let listing: Listing<Item>
        do {
            listing = try await read(need) { try await list(service, path, query: ["email": email], as: Item.self, size: 100, pages: 5, partial: false) }
        } catch let error as ServiceError {
            if case .input(let reason) = error, reason.hasPrefix("Cloudflare refused") { throw error }
            return .inconclusive("reading the user \(email): \(error.localizedDescription)")
        }
        guard listing.complete else { return .inconclusive("Cloudflare listed more users for \(email) than Pion reads at once") }
        let named = listing.value.filter { $0.text("email")?.lowercased() == email }
        switch named.count {
        case 0: return .absent
        case 1: return .present(named[0])
        default: return .inconclusive("Cloudflare names \(named.count) users with the email \(email)")
        }
    }

    /// A user's active Access sessions, read whole, or the reason they could not be.
    static func sessions(_ user: String, _ service: ServiceClient, need: Need = accessUsersNeed) async throws -> Listing<Value> {
        try await read(need) {
            try await list(service, ["accounts", try account(service), "access", "users", user, "active_sessions"], query: [:], as: Value.self, size: 100, pages: 5, partial: false)
        }
    }

    static func sessionLine(_ session: Value) -> String {
        let apps = (session["metadata.apps"]?.object ?? [:]).values.compactMap { $0["hostname"]?.text ?? $0["name"]?.text }.sorted()
        let seconds = { (value: Value?) in value?.text.flatMap { Double($0) }.map { Cloudflare.iso(Date(timeIntervalSince1970: $0)) } }
        let expires = seconds(session["expiration"]) ?? session["expiration"]?.text ?? seconds(session["metadata.expires"])
        let issued = session["metadata.iat"]?.text.flatMap { Double($0) }.map { Cloudflare.iso(Date(timeIntervalSince1970: $0)) }
        return "session \(session["name"]?.text.map { String($0.prefix(16)) } ?? "not named")\(issued.map { ", issued \($0)" } ?? ""), expires \(expires ?? "at a time not given")\(apps.isEmpty ? "" : ", to \(apps.prefix(10).joined(separator: ", "))")"
    }

    struct AccessUser: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "access-user"
        static let summary = "One Zero Trust user by email or ID: last successful login, active devices and seats, every active Access session with the applications it reaches and when it expires, and what Cloudflare last saw of their identity: address, country, identity provider, device and its posture results. Says what it could not read."
        static let input = JSONSchema.object(["user": .string("The user's email address, or their ID as access-users gives it.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user: Item
            switch try await Cloudflare.accessUser(input.user, service) {
            case .present(let found): user = found
            case .absent: return try ServiceResult(text: "Zero Trust has no user \(input.user): every user it lists for that was read, and none matches. A person who never signed in through Access or WARP is not a user.", structured: ["found": false])
            case .inconclusive(let why): throw ServiceError.input("The user \(input.user) could not be read: \(why).")
            }
            var lines = [Cloudflare.userLine(user)]
            var gaps: [String] = []
            var sessions: [String] = []
            do {
                let listing = try await Cloudflare.sessions(user.id, service)
                sessions = listing.value.map(Cloudflare.sessionLine)
                lines.append(sessions.isEmpty ? "No active Access session." : "\(Cloudflare.plural(sessions.count, "active Access session")):\n" + sessions.joined(separator: "\n"))
            } catch { gaps.append("their sessions (\(error.localizedDescription))") }
            do {
                let identity = try await Cloudflare.read(Cloudflare.accessUsersNeed) {
                    try await Cloudflare.get(service, ["accounts", try Cloudflare.account(service), "access", "users", user.id, "last_seen_identity"], as: Value.self)
                }
                var seen = "Last seen identity: \(identity["email"]?.text ?? "email not given"), from \(identity["ip"]?.text ?? "an address not given")\(identity["geo.country"]?.text.map { " (\($0))" } ?? "")"
                seen += ", identity provider \(identity["idp.type"]?.text ?? identity["idp.id"]?.text ?? "not given"), device \(identity["device_id"]?.text ?? "not given")"
                seen += identity["is_warp"]?.flag == true ? ", through WARP" : ""
                lines.append(seen + ".")
                if let posture = identity["devicePosture"]?.object, !posture.isEmpty {
                    let checks = posture.sorted { $0.key < $1.key }.map { key, check in
                        "\(check["rule_name"]?.text ?? check["type"]?.text ?? key): \(check["success"]?.flag.map { $0 ? "passed" : "FAILED" } ?? "result not given")\(check["timestamp"]?.text.map { " at \($0)" } ?? "")"
                    }
                    lines.append("Device posture of that device: " + checks.prefix(20).joined(separator: "; ") + ".")
                } else { lines.append("No device posture result was given for that device.") }
            } catch { gaps.append("what Cloudflare last saw of their identity (\(error.localizedDescription))") }
            if !gaps.isEmpty { lines.append("Could not read: \(gaps.joined(separator: "; ")).") }
            lines.append("Read at \(Cloudflare.iso(Date())).")
            struct Kept: Encodable { let found: Bool; let id: String; let email: String?; let sessions: [String]; let couldNotRead: [String] }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(found: true, id: user.id, email: user.text("email"), sessions: sessions, couldNotRead: gaps))
        }
    }

    // MARK: Gateway

    static let gatewayKinds = ["dns", "http", "network"]

    struct GatewayActivity: ServiceOperation {
        struct Input: Decodable, Sendable { let kind: String?, since: String?, until: String?, limit: Int? }
        static let name = "gateway-activity"
        static let summary = "Gateway's decisions for a window, from Cloudflare's GraphQL Analytics API, which gives them only as counts by group: DNS queries by domain and resolver decision, HTTP requests by host and action, or how many network sessions there were. Cloudflare samples these, so counts are estimates; per-person and per-device logs come only from Logpush or the dashboard."
        static let input = JSONSchema.object([
            "kind": .string("Which decisions. dns when left out.", oneOf: Cloudflare.gatewayKinds),
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out, at most 30 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many groups, most first, at most. 100 when left out.", minimum: 1, maximum: 1_000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let kind = try ServiceInput.oneOf(input.kind ?? "dns", Cloudflare.gatewayKinds, "kind")
            let (since, until) = try Cloudflare.window(input.since, input.until, days: 1, maximum: 30)
            let limit = try Cloudflare.limit(input.limit, default: 100, maximum: 1_000, "groups")
            let dataset: String, dimensions: String
            switch kind {
            case "dns": (dataset, dimensions) = ("gatewayResolverQueriesAdaptiveGroups", "dimensions { queryNameReversed resolverDecision }")
            case "http": (dataset, dimensions) = ("gatewayL7RequestsAdaptiveGroups", "dimensions { httpHost action }")
            default: (dataset, dimensions) = ("gatewayL4SessionsAdaptiveGroups", "")
            }
            let query = """
            query GatewayActivity($accountTag: string!, $since: Time!, $until: Time!, $limit: uint64!) {
              viewer { accounts(filter: { accountTag: $accountTag }) {
                \(dataset)(filter: { datetime_geq: $since, datetime_leq: $until }, limit: $limit, orderBy: [count_DESC]) { count \(dimensions) }
              } }
            }
            """
            struct Variables: Encodable { let accountTag: String; let since: String; let until: String; let limit: Int }
            struct Account: Decodable {
                let groups: [Value]?
                struct Key: CodingKey { var stringValue: String; init?(stringValue: String) { self.stringValue = stringValue }; var intValue: Int? { nil }; init?(intValue: Int) { nil } }
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: Key.self)
                    groups = try container.allKeys.first.map { try container.decodeIfPresent([Value].self, forKey: $0) } ?? nil
                }
            }
            struct Viewer: Decodable { let accounts: [Account]? }
            struct Answer: Decodable { let viewer: Viewer? }
            let answer = try await Cloudflare.read(Cloudflare.gatewayActivityNeed) {
                try await Cloudflare.graphQL(service, query: query, variables: Variables(accountTag: try Cloudflare.account(service), since: Cloudflare.iso(since),
                                                                                         until: Cloudflare.iso(until), limit: limit + 1), as: Answer.self)
            }
            guard let accounts = answer.viewer?.accounts, accounts.count == 1, let groups = accounts[0].groups else {
                throw ServiceError.input("Cloudflare's answer for Gateway's \(kind) activity did not hold this one account's groups, so whether there was any is unknown.")
            }
            let kept = Array(groups.prefix(limit))
            let lines = kept.map { group -> String in
                let count = group["count"]?.text ?? "?"
                switch kind {
                case "dns":
                    let name = group["dimensions.queryNameReversed"]?.text.map { $0.split(separator: ".").reversed().joined(separator: ".") } ?? "a domain not given"
                    return "\(count) × \(name): resolver decision \(group["dimensions.resolverDecision"]?.text ?? "not given")"
                case "http": return "\(count) × \(group["dimensions.httpHost"]?.text ?? "a host not given"): action \(group["dimensions.action"]?.text ?? "not given")"
                default: return "\(count) network sessions"
                }
            }
            let window = "from \(Cloudflare.iso(since)) to \(Cloudflare.iso(until))"
            var text = kept.isEmpty ? "Gateway logged no \(kind) activity \(window)." : "Gateway's \(kind) activity \(window), most first (sampled, so counts are estimates):\n" + lines.joined(separator: "\n")
            if groups.count > limit { text += "\nMore groups than the \(limit) kept: narrow the window." }
            struct Kept: Encodable { let kind: String; let groups: [String]; let since: String; let until: String; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(kind: kind, groups: lines, since: Cloudflare.iso(since), until: Cloudflare.iso(until), complete: groups.count <= limit))
        }
    }

    static func gatewayRuleLine(_ rule: Item) -> String {
        var line = "\(rule.text("precedence").map { "#\($0) " } ?? "")\(rule.text("name") ?? "unnamed"): \(rule.text("action") ?? "action not given") on \(rule.texts("filters").joined(separator: ", ").nilIfEmpty ?? "traffic not given")"
        switch rule.flag("enabled") {
        case false?: line += ", TURNED OFF"
        case nil: line += ", whether on not given"
        case true?: break
        }
        if let traffic = rule.text("traffic") { line += " — traffic \(String(traffic.prefix(300)))" }
        if let identity = rule.text("identity") { line += "; identity \(String(identity.prefix(200)))" }
        if let posture = rule.text("device_posture") { line += "; posture \(String(posture.prefix(200)))" }
        line += ", updated \(rule.text("updated_at") ?? "at a time not given")"
        return line + " [\(rule.id)]"
    }

    static func gatewayRules(_ service: ServiceClient) async throws -> Listing<Item> {
        try await read(gatewayNeed) { try await list(service, ["accounts", try account(service), "gateway", "rules"], query: [:], as: Item.self, paging: .single, size: 0) }
    }

    struct GatewayRules: ServiceOperation {
        struct Input: Decodable, Sendable { let kind: String? }
        static let name = "gateway-rules"
        static let summary = "Gateway's policies in order of precedence: each one's action, the traffic it applies to (DNS, HTTP, network), its expression, identity and device posture conditions, whether it is turned off, and when it last changed; a rule turned off or an allow ahead of a block can open a path. Says when it read only part."
        static let input = JSONSchema.object(["kind": .string("Only rules on this traffic.", oneOf: ["dns", "http", "l4", "egress", "dns_resolver"])])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let kind = try input.kind.map { try ServiceInput.oneOf($0, ["dns", "http", "l4", "egress", "dns_resolver"], "kind") }
            let listing = try await Cloudflare.gatewayRules(service)
            let rules = listing.value.filter { $0.text("deleted_at") == nil && (kind == nil || $0.texts("filters").contains(kind!)) }
                .sorted { ($0.number("precedence") ?? .max, $0.id) < ($1.number("precedence") ?? .max, $1.id) }
            let lines = rules.map(Cloudflare.gatewayRuleLine)
            let off = rules.filter { $0.flag("enabled") == false }.count
            let text = (lines.isEmpty ? "No Gateway rule\(kind.map { " on \($0)" } ?? "")\(listing.complete ? "" : " in what was read")." : "\(Cloudflare.plural(lines.count, "rule")), \(off) turned off, lowest precedence number (evaluated first) first:\n" + lines.joined(separator: "\n"))
                + Cloudflare.stopped(listing, "Gateway rules")
            struct Kept: Encodable { let rules: [String]; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(rules: lines, complete: listing.complete))
        }
    }

    struct GatewayLists: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String? }
        static let name = "gateway-lists"
        static let summary = "Gateway's lists, such as domains, IP addresses or URLs that rules name, with each one's ID, type, how many items it holds and when it changed; with an ID, that list's items in full. Says when it read only part."
        static let input = JSONSchema.object(["id": .string("A list's ID, a UUID, to read its items.")])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let account = try Cloudflare.account(service)
            if let raw = input.id {
                let id = try Cloudflare.requireUUID(raw, "the list's ID")
                let listing = try await Cloudflare.read(Cloudflare.gatewayNeed) {
                    try await Cloudflare.list(service, ["accounts", account, "gateway", "lists", id, "items"], query: [:], as: Value.self, size: 1_000, pages: 10)
                }
                let items = listing.value.map { "\($0["value"]?.text ?? "?")\($0["description"]?.text.map { " — \(String($0.prefix(200)))" } ?? "")\($0["created_at"]?.text.map { ", added \($0)" } ?? "")" }
                var text = items.isEmpty ? "List \(id) holds no items\(listing.complete ? "" : " in what was read")." : "List \(id), \(Cloudflare.plural(items.count, "item")):\n" + items.prefix(300).joined(separator: "\n")
                if items.count > 300 { text += "\n\(items.count - 300) more in the structured result." }
                text += Cloudflare.stopped(listing, "the list's items")
                struct Kept: Encodable { let list: String; let items: [String]; let complete: Bool }
                return try ServiceResult(text: text, structured: Kept(list: id, items: items, complete: listing.complete))
            }
            let listing = try await Cloudflare.read(Cloudflare.gatewayNeed) {
                try await Cloudflare.list(service, ["accounts", account, "gateway", "lists"], query: [:], as: Item.self, paging: .single, size: 0)
            }
            let lines = listing.value.map { list in
                "\(list.text("name") ?? "unnamed") (\(list.text("type") ?? "type not given")): \(list.number("count").map { Cloudflare.plural($0, "item") } ?? "items not counted"), updated \(list.text("updated_at") ?? "at a time not given")\(list.text("description").map { " — \(String($0.prefix(200)))" } ?? "") [\(list.id)]"
            }
            let text = (lines.isEmpty ? "Gateway has no lists\(listing.complete ? "" : " in what was read")." : "\(Cloudflare.plural(lines.count, "list")):\n" + lines.joined(separator: "\n")) + Cloudflare.stopped(listing, "Gateway lists")
            struct Kept: Encodable { let lists: [String]; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(lists: lines, complete: listing.complete))
        }
    }

    // MARK: Devices

    /// A WARP registration said on one line: the device, its user, whether it is revoked, and when last seen.
    static func registrationLine(_ registration: Item) -> String {
        var parts = [registration.text("revoked_at").map { "REVOKED \($0)" } ?? (registration.fields["revoked_at"] == .null ? "not revoked" : "whether revoked not given")]
        if let deleted = registration.text("deleted_at") { parts.append("deleted \(deleted)") }
        parts.append("user \(registration.text("user.email") ?? "not given")")
        parts.append("last seen \(registration.text("last_seen_at") ?? "not given")")
        parts.append("\(registration.text("registration_type") ?? "client") \(registration.text("device.client_version") ?? "version not given")")
        if let profile = registration.text("policy.name") { parts.append("profile \(profile)") }
        return "\(registration.text("device.name") ?? "an unnamed device") [device \(registration.text("device.id") ?? "not given"), registration \(registration.id)]: " + parts.joined(separator: ", ")
    }

    struct Devices: ServiceOperation {
        struct Input: Decodable, Sendable { let search: String?, status: String?, seenSince: String?, limit: Int? }
        static let name = "devices"
        static let summary = "WARP device registrations, most recently seen first: each device and its registration ID, its user, whether it is revoked or deleted, its client and version, its device profile and when last seen, by search, status and time. Cloudflare gives no posture results per device; access-user gives those of a user's last seen device. Says when more matched than it kept."
        static let input = JSONSchema.object([
            "search": .string("Only registrations whose details, such as the device's name or user's email, contain this."),
            "status": .string("active, revoked or all. all when left out.", oneOf: ["active", "revoked", "all"]),
            "seenSince": .string("Only devices last seen after this time, in ISO 8601."),
            "limit": .integer("How many, at most. 200 when left out.", minimum: 1, maximum: 5_000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = ["status": try ServiceInput.oneOf(input.status ?? "all", ["active", "revoked", "all"], "status"), "sort_by": "last_seen_at", "sort_order": "desc"]
            if let search = input.search { query["search"] = try ServiceInput.quoted(search, "the words") }
            if let since = input.seenSince { query["seen_after"] = try ServiceInput.time(since) }
            let limit = try Cloudflare.limit(input.limit, default: 200, maximum: 5_000, "devices")
            let listing = try await Cloudflare.read(Cloudflare.devicesNeed) {
                try await Cloudflare.list(service, ["accounts", try Cloudflare.account(service), "devices", "registrations"], query: query, as: Item.self, paging: .cursor,
                                          size: 500, pages: 10, limit: limit)
            }
            let (registrations, cut, notice) = Cloudflare.summary(listing, limit: limit, name: "devices", narrow: "give a search or status")
            let lines = registrations.map(Cloudflare.registrationLine)
            var text = lines.isEmpty ? "No WARP device matches\(listing.complete ? "" : " in what was read")." : "\(Cloudflare.plural(lines.count, "registration")), most recently seen first:\n" + lines.prefix(100).joined(separator: "\n")
            if lines.count > 100 { text += "\n\(lines.count - 100) more in the structured result." }
            text += notice + "\nCloudflare gives no posture results per device; access-user gives those of a user's last seen device."
            struct Kept: Encodable { let devices: [String]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(devices: lines, total: listing.total, complete: listing.complete && !cut))
        }
    }

    // MARK: Tunnels

    struct Tunnels: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String?, includeDeleted: Bool? }
        static let name = "tunnels"
        static let summary = "Cloudflare Tunnels, with each one's ID, status (healthy, degraded, down or inactive), when it was made and last connected or disconnected; with an ID, that tunnel's connectors and their connections: the data centre, origin IP address, version and when each opened. A tunnel nobody expected is a way into the network. Says when it read only part."
        static let input = JSONSchema.object([
            "id": .string("A tunnel's ID, a UUID, to read its connections."),
            "includeDeleted": .boolean("Also deleted tunnels."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let account = try Cloudflare.account(service)
            if let raw = input.id {
                let id = try Cloudflare.requireUUID(raw, "the tunnel's ID")
                let listing = try await Cloudflare.read(Cloudflare.tunnelsNeed) {
                    try await Cloudflare.list(service, ["accounts", account, "cfd_tunnel", id, "connections"], query: [:], as: Value.self, paging: .single, size: 0)
                }
                let lines = listing.value.flatMap { connector -> [String] in
                    let head = "connector \(connector["id"]?.text ?? "not given") \(connector["version"]?.text ?? "version not given") on \(connector["arch"]?.text ?? "an architecture not given"), running since \(connector["run_at"]?.text ?? "a time not given")"
                    let conns = (connector["conns"]?.items ?? []).map { "  \($0["colo_name"]?.text ?? "?") from origin \($0["origin_ip"]?.text ?? "not given"), opened \($0["opened_at"]?.text ?? "?")\($0["is_pending_reconnect"]?.flag == true ? ", reconnecting" : "")" }
                    return [head] + conns
                }
                let text = (lines.isEmpty ? "Tunnel \(id) has no connector connected\(listing.complete ? "" : " in what was read")." : "Tunnel \(id):\n" + lines.joined(separator: "\n")) + Cloudflare.stopped(listing, "connections")
                struct Kept: Encodable { let tunnel: String; let connections: [String]; let complete: Bool }
                return try ServiceResult(text: text, structured: Kept(tunnel: id, connections: lines, complete: listing.complete))
            }
            var query: [String: String?] = [:]
            if input.includeDeleted != true { query["is_deleted"] = "false" }
            let listing = try await Cloudflare.read(Cloudflare.tunnelsNeed) {
                try await Cloudflare.list(service, ["accounts", account, "cfd_tunnel"], query: query, as: Item.self, size: 500, pages: 10)
            }
            let lines = listing.value.sorted { ($0.text("created_at") ?? "") > ($1.text("created_at") ?? "") }.map { tunnel in
                let origins = Set((tunnel.fields["connections"]?.items ?? []).compactMap { $0["origin_ip"]?.text }).sorted()
                return "\(tunnel.text("name") ?? "unnamed") (\(tunnel.text("tun_type") ?? "type not given")): \(tunnel.text("status") ?? "status not given"), made \(tunnel.text("created_at") ?? "at a time not given"), last connected \(tunnel.text("conns_active_at") ?? "never or not given")\(tunnel.text("conns_inactive_at").map { ", disconnected \($0)" } ?? "")\(tunnel.text("deleted_at").map { ", DELETED \($0)" } ?? "")\(origins.isEmpty ? "" : ", origins \(origins.prefix(5).joined(separator: ", "))") [\(tunnel.id)]"
            }
            let text = (lines.isEmpty ? "No tunnel\(listing.complete ? "" : " in what was read")." : "\(Cloudflare.plural(lines.count, "tunnel")), newest first:\n" + lines.joined(separator: "\n")) + Cloudflare.stopped(listing, "tunnels")
            struct Kept: Encodable { let tunnels: [String]; let total: Int?; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(tunnels: lines, total: listing.total, complete: listing.complete))
        }
    }
}

extension String {
    /// Nil for an empty string, for chaining a fallback.
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
