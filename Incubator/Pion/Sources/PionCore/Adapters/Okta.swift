import Foundation
import NoodleCore
import NoodleToolConnections

/// An Okta org's users, their groups, apps, sign-in factors and grants, its admins and API tokens, its policies and
/// authenticators, and its System Log, read as the admin who signs in. Each account is its own org, named by its
/// domain. Okta Detection only reads; Okta Containment, a tool of its own with a sign-in of its own, acts.
///
/// Both sign in through OAuth at the org's own authorization server, with an authorization code and PKCE, through a
/// native app the org made, which keeps no client secret. Okta allows a request only when both the sign-in's scopes and
/// the admin's role allow it, so Okta Detection's scopes only read, whatever the admin may do, and each tool's setup gives
/// its admin only the role the tool needs, which check-access reports.
///
/// Both tools' guide is Incubator/Pion/docs/tools/okta.md. Change it with the setup steps, permissions or operations here.
public enum Okta {
    public static let preset = ToolDefinition(
        // The ID and adapter key stay as they were, so connections made before keep working.
        id: "bdc65def-9c77-4503-9d57-eac000822cce", name: "Okta Detection",
        summary: "Users, groups, apps, sign-in factors, grants, admins, API tokens, sign-on, MFA and password policies and the System Log of an Okta org, read-only.",
        defaultInstructions: """
        Use Okta Detection to learn who an identity is and what happened to it: find-user, then user-groups, user-apps, \
        user-factors and user-grants (the apps a user let act for them, which keep working after a password change); \
        sign-in-events searches the System Log by the user who acted, the user acted on (target), IP address, event \
        type, failures and time; admin-roles says who holds which admin role, api-tokens every API token, who made it \
        and where it works from. To assess how the org is set up, sign-on-policies reads the global session and \
        authentication policies with every rule, mfa-policies the authenticators and who must enroll which, and \
        password-policies the password, lockout and recovery rules, each leading with the gaps an assessment asks about, \
        such as a password alone letting people in, sessions that never end, SMS or a security question allowed, or no \
        lockout; they say what the rules allow, not who signed in under them, which sign-in-events shows. The alert \
        watch checks every five minutes and wakes you with a note naming security-events, which reads what it reads for \
        the note's window: admin roles granted, API tokens made, a user's sign-in factors changed or reset by someone \
        else, policies or their rules turned off or changed, an admin impersonating a user, identity providers and apps \
        added, network zones changed, threats Okta ThreatInsight detected, suspicious activity a user reported, and org \
        rate limits hit. A note may name the System Log as unreadable: security-events says why, so tell the champion \
        what to change and treat its silence as unknown. When a tool is refused or something you need seems missing, run \
        check-access and tell the champion exactly what it says to change. Silence is not proof: every result says when \
        it stopped before reading everything or matched more than it kept; report those gaps with what you found. Okta \
        keeps the System Log for 90 days. An event's actor is the account used, not who held it. Record what you find as \
        evidence, citing the org, the user and the time window you searched. These tools only read: recommend suspending \
        a user, clearing their sessions or resetting their factors to the champion, or use Okta Containment, with the \
        user's login, why, and how to undo it.
        """,
        iconName: "okta",
        configuration: .connection(.init(endpointTemplate: "https://{domain}/api/v1", fields: fields,
                                  oauth: oauth(scopes: auditScopes), oauthClientField: "clientID", oauthHostField: "domain",
                                  adapter: "okta")),
        setup: setup)

    static let fields = [ToolField(key: "domain", title: "Okta domain", placeholder: "acme.okta.com", kind: .host),
                         ToolField(key: "clientID", title: "Client ID", placeholder: "0oa1b2c3d4e5f6g7h8i9", kind: .identifier)]

    /// The org authorization server, which alone issues tokens for Okta's own API. Its host stands for the org's domain,
    /// which each account's sign-in puts in its place; .invalid, so it can never be reached as it is. Every sign-in asks
    /// for the admin's password again, so a browser already signed in to Okta as someone else never answers for them.
    static func oauth(scopes: [String]) -> MCPOAuthConfiguration {
        MCPOAuthConfiguration(issuer: URL(string: "https://okta.invalid")!,
                              authorizationEndpoint: URL(string: "https://okta.invalid/oauth2/v1/authorize")!,
                              tokenEndpoint: URL(string: "https://okta.invalid/oauth2/v1/token")!, clients: [],
                              scopes: scopes + ["offline_access"], authorizationParameters: ["prompt": "login"],
                              usesResourceIndicator: false, revocationEndpoint: URL(string: "https://okta.invalid/oauth2/v1/revoke")!)
    }

    /// Only reading scopes, one for each kind of thing Okta Detection reads: users, with their factors and grants, and the
    /// signed-in admin; groups; apps; the System Log; admin roles and assignments; API tokens; policies with their rules;
    /// authenticators; and the network zones rules name.
    static let auditScopes = ["okta.users.read", "okta.users.read.self", "okta.groups.read", "okta.apps.read", "okta.logs.read",
                              "okta.roles.read", "okta.apiTokens.read", "okta.policies.read", "okta.authenticators.read", "okta.networkZones.read"]

    /// Where Okta sends each sign-in back to: Pion's bundle ID as a URL scheme.
    static let redirects = "`com.pdparchitect.pion:/oauth2callback` (`com.pdparchitect.pion.local:/oauth2callback` for Pion Dev)"

    static func appSteps(_ name: String, scopes: [String]) -> [String] {
        [
            "In the Okta Admin Console, open **Applications › Applications**, choose **Create App Integration**, then **OIDC - OpenID Connect** and **Native Application**, and name it \(name), kept for this tool alone.",
            "Keep the grant type **Authorization Code** and tick **Refresh Token**. Give \(redirects) as the **Sign-in redirect URI**. Under **Assignments**, allow only the admin who will sign in, and save. Keep client authentication as PKCE, a native app's default: Pion keeps no client secret.",
            "On the app's **Okta API Scopes** tab, grant exactly \(scopes.map { "`\($0)`" }.joined(separator: ", ")); only a super administrator can grant them. Pion asks for these and `offline_access`, and refuses a sign-in that lacks any.",
        ]
    }

    static let setup = appSteps("Pion Detection", scopes: auditScopes) + [
        "Okta allows a request only when both the app's scopes and the signed-in admin's role allow it. Keep an admin for Pion Detection alone, such as pion-detection@example.com, with the **Read-Only Administrator** role under **Security › Administrators**. It also views the org's policies, authenticators and network zones, which sign-on-policies, mfa-policies and password-policies read.",
        "To audit admins and API tokens too, under **Security › Administrators › Roles** create a role such as **Pion Detection** with only **View roles, resources, and admin assignments** (`okta.iam.read`) and **View API tokens** (`okta.users.apitokens.read`), and assign it to the same admin for all users and all Identity and Access Management resources. The Read-Only Administrator cannot see them.",
        "Give your org's domain, such as `acme.okta.com`, not its `-admin` address, and the app's **Client ID**. Choose **Add & Connect** and sign in as that admin. Then ask an agent to run check-access.",
    ]

    /// Every operation of both tools, each naming the jobs it serves; each tool offers those of its own job.
    static let operations: [any ServiceOperation] = [
        FindUser(), UserGroups(), UserApps(), UserFactors(), SignInEvents(), UserGrants(), AdminRoles(), APITokens(), SecurityEvents(), CheckAccess(),
        SignOnPolicies(), MFAPolicies(), PasswordPolicies(),
        ContainmentUser(), Suspend(), Unsuspend(), Deactivate(), ClearSessions(), ResetFactors(), DeleteFactor(), ExpirePassword(), RemoveFromGroup(),
        RevokeAdminRole(), RevokeAppGrants(), RevokeAPIToken(), ContainmentCheckAccess(),
    ]

    public static let adapter = OperationAdapter(operations: operations, job: .detection, trigger: NewSecurityEvents(),
                                                 // Paced, as admin-roles asks for each admin's roles in turn.
                                                 simultaneousRequests: 8)

    // MARK: Limits

    /// The most pages one listing reads.
    static let maximumPages = 10
    /// The most admins admin-roles reads the roles of, one request each, and the most token owners api-tokens names.
    static let adminLookups = 100, ownerLookups = 50
    /// How many days the System Log keeps.
    static let logDays = 90.0

    // MARK: Inputs

    /// A user named by its ID or login, as Okta's paths take it, for reads. Okta also takes an unambiguous short name,
    /// which is harmless to read but never acted on: containment checks what it resolved to.
    static func user(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ServiceError.input("Give the user's Okta ID or login.")
        }
        return value
    }

    /// An Okta ID: `prefix` and then letters and digits, `length` in all, such as 00u and 17 more for a user.
    static func id(_ value: String, prefix: String = "", length: ClosedRange<Int> = 20...20, _ name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard length.contains(value.count), value.hasPrefix(prefix),
              value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").contains) else {
            throw ServiceError.input("Give \(name) as Okta's ID\(prefix.isEmpty ? "" : ", starting \(prefix)"), letters and digits only.")
        }
        return value
    }

    static func userID(_ value: String) throws -> String { try id(value, prefix: "00u", "the user") }
    static func groupID(_ value: String) throws -> String { try id(value, prefix: "00g", "the group") }
    static func tokenID(_ value: String) throws -> String { try id(value, prefix: "00T", "the API token") }

    /// A value that goes inside double quotes in Okta's filter or search expressions: refused when it holds a quote,
    /// backslash or line break that could end it early.
    static func quoted(_ value: String, _ name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200, !value.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ServiceError.input("Give \(name) without quotes, backslashes or line breaks.")
        }
        return "\"\(value)\""
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// A window within the System Log's 90 days, since before until; `days` back from now when since is left out.
    static func window(_ since: String?, _ until: String?, days: Double) throws -> (since: Date, until: Date) {
        let now = Date()
        let from: Date? = try since.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantPast } ?? now.addingTimeInterval(-days * 86_400)
        let to: Date? = try until.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantFuture } ?? now
        guard let from, let to, from <= to, from >= now.addingTimeInterval(-logDays * 86_400 - 60), to <= now.addingTimeInterval(60) else {
            throw ServiceError.input("Give a time range within the last 90 days, the System Log's, with since before until.")
        }
        return (from, to)
    }

    // MARK: Requests

    /// What Okta said when it refused: its error code and summary, and the causes it gave.
    static func reason(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ServiceClient.reason(data) }
        let summary = object["errorSummary"] as? String
        let causes = ((object["errorCauses"] as? [[String: Any]]) ?? []).compactMap { $0["errorSummary"] as? String }.filter { $0 != summary }
        let words = ([summary].compactMap { $0 } + causes).joined(separator: "; ")
        guard !words.isEmpty else { return ServiceClient.reason(data) }
        let line = (object["errorCode"] as? String).map { "\($0): \(words)" } ?? words
        return String(line.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(300))
    }

    /// One request to the org. Okta's refusals are said in its own words; when it rate limits, after the transport
    /// has waited and tried again, the answer says when Okta's limit resets, from X-Rate-Limit-Reset.
    static func exchange(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], method: String = "GET",
                         body: Data? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        let answer = try await service.exchange(path, query: query, method: method, body: body, returning: Set(300...599))
        let status = answer.response.statusCode
        let said = reason(answer.data)
        switch status {
        case 200..<300: return answer
        case 429:
            let reset = answer.response.value(forHTTPHeaderField: "X-Rate-Limit-Reset").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .map { Date(timeIntervalSince1970: $0) }
            let when = reset.map { "Okta's limit for this endpoint resets at \(iso($0)), in \(max(0, Int($0.timeIntervalSinceNow.rounded(.up)))) seconds" }
            throw ServiceError.rateLimited([when, said].compactMap { $0 }.joined(separator: "; "))
        case 401: throw ServiceError.rejected(said)
        case 403:
            // A scope the sign-in lacks is told apart from a permission the admin lacks, as each is changed in its own place.
            if let scope = lackedScope(answer.response) { throw ServiceError.forbidden(lacking + scope + (said.map { "; " + $0 } ?? "")) }
            throw ServiceError.forbidden(said)
        case 404: throw ServiceError.notFound
        case 400, 405, 409, 412, 422: throw said.map(ServiceError.refused) ?? ServiceError.status(status)
        default: throw ServiceError.status(status, said)
        }
    }

    static func get<Answer: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:],
                                       as: Answer.Type = Answer.self) async throws -> Answer {
        do { return try JSONDecoder().decode(Answer.self, from: try await exchange(service, path, query: query).data) }
        catch is DecodingError { throw ServiceError.unreadable }
    }

    // MARK: Listings

    struct Listing<Item> {
        var value: [Item] = []
        /// Whether more remained when it stopped.
        var more = false
        var pages = 0
        /// Why it stopped before the end, when not for its page limit, such as a page Okta failed to give.
        var stopped: String? = nil
        /// The page it stopped at, for a listing stopped by a failure.
        var stoppedAt: Int? = nil
        /// Okta's cursor for the next page, when it stopped at its page limit with more to read.
        var cursor: String? = nil
        var complete: Bool { !more && stopped == nil }
    }

    /// Where the next page starts: Okta's `after` cursor, taken alone from its next link, which must be on the
    /// connection's own host and at the path just read; nil at the end. A link anywhere else is never followed.
    enum Next: Equatable { case end, after(String), unfollowable }

    static func next(_ response: HTTPURLResponse, body: Data?, service: ServiceClient, path: [String]) -> Next {
        var link: String?
        if let header = response.value(forHTTPHeaderField: "Link") {
            let pattern = #"<([^>]*)>\s*;\s*rel\s*=\s*"?next"?"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
               let range = Range(match.range(at: 1), in: header) { link = String(header[range]) }
        }
        // The admin assignment listings put it in their body's _links instead.
        if link == nil, let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let links = object["_links"] as? [String: Any], let next = links["next"] as? [String: Any] {
            link = next["href"] as? String
        }
        guard let link, !link.isEmpty else { return .end }
        let expected = path.reduce(service.base) { $0.appendingPathComponent($1) }
        guard let url = URLComponents(string: link), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.host?.lowercased() == service.base.host?.lowercased(), url.port == service.base.port,
              url.path == expected.path,
              let after = url.queryItems?.first(where: { $0.name == "after" })?.value, !after.isEmpty else { return .unfollowable }
        return .after(after)
    }

    /// One page's items: a JSON array, or for `envelope` an object whose value field is one. Anything else, such as an
    /// envelope without its value, is unreadable rather than an empty page, so it is never taken for "nothing found".
    static func items<Item: Decodable>(_ data: Data, envelope: Bool, as: Item.Type) throws -> [Item] {
        do {
            return envelope ? try JSONDecoder().decode(Envelope<Item>.self, from: data).value : try JSONDecoder().decode([Item].self, from: data)
        } catch {
            throw ServiceError.unreadable
        }
    }

    /// A listing, page after page, up to `pages` or until `limit` items are kept. Each next page is asked of the same
    /// path with the same query and Okta's cursor; `dropping` names parameters Okta takes only on the first page, as
    /// the System Log takes since. `after` starts from a cursor a listing stopped at before. `envelope` is for
    /// listings whose items are in a value field.
    ///
    /// When a page after the first fails, what earlier pages held is kept and the listing says where and why it
    /// stopped, unless `partial` is false, for a reader that must have all or nothing, which gets the failure.
    static func list<Item: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?], as: Item.Type,
                                      pages: Int = maximumPages, limit: Int? = nil, envelope: Bool = false, dropping: [String] = [],
                                      after: String? = nil, partial: Bool = true,
                                      matching: (Item) -> Bool = { _ in true }) async throws -> Listing<Item> {
        var query = query
        if let after {
            for name in dropping { query[name] = nil }
            query["after"] = after
        }
        var found = Listing<Item>()
        while found.pages < pages {
            let items: [Item], answer: (data: Data, response: HTTPURLResponse)
            do {
                answer = try await exchange(service, path, query: query)
                items = try Okta.items(answer.data, envelope: envelope, as: Item.self)
            } catch {
                guard partial, found.pages > 0 else { throw error }
                found.more = true
                found.stoppedAt = found.pages + 1
                found.stopped = error.localizedDescription
                return found
            }
            found.pages += 1
            found.value += items.filter(matching)
            switch next(answer.response, body: envelope ? answer.data : nil, service: service, path: path) {
            case .end:
                found.more = false
                found.cursor = nil
                return found
            case .unfollowable:
                found.more = true
                found.cursor = nil
                found.stoppedAt = found.pages + 1
                found.stopped = "Okta gave a next page on another address, which Pion does not follow"
                return found
            case .after(let cursor):
                found.more = true
                // A bounded page with nothing in it ends the listing whatever its link says.
                if items.isEmpty { found.more = false; found.cursor = nil; return found }
                found.cursor = cursor
                if let limit, found.value.count >= limit { return found }
                for name in dropping { query[name] = nil }
                query["after"] = cursor
            }
        }
        return found
    }

    struct Envelope<Item: Decodable>: Decodable { let value: [Item] }

    static func stopped<Item>(_ listing: Listing<Item>, _ name: String) -> String {
        if let reason = listing.stopped {
            return "\nIncomplete: stopped at page \(listing.stoppedAt ?? listing.pages + 1) reading \(name) because \(reason); what the \(listing.pages) page\(listing.pages == 1 ? "" : "s") before held is kept."
        }
        return listing.more ? "\nIncomplete: stopped after \(listing.pages) page\(listing.pages == 1 ? "" : "s") reading \(name), the most read at once; more remain." : ""
    }

    // MARK: Refusals

    /// What one thing the tool reads needs, to say what to change when Okta refuses it: the sign-in's scope and the
    /// admin's permission.
    struct Need: Sendable {
        let title: String, scope: String, permission: String
        static let users = Need(title: "Users", scope: "okta.users.read", permission: "the Read-Only Administrator role (okta.users.read)")
        static let groups = Need(title: "Groups", scope: "okta.groups.read", permission: "the Read-Only Administrator role (okta.groups.read)")
        static let apps = Need(title: "Apps", scope: "okta.apps.read", permission: "the Read-Only Administrator role (okta.apps.read)")
        static let logs = Need(title: "System Log", scope: "okta.logs.read", permission: "the Read-Only Administrator role, which reads the System Log")
        static let admins = Need(title: "Admin assignments", scope: "okta.roles.read", permission: "a custom role with View roles, resources, and admin assignments (okta.iam.read)")
        static let tokens = Need(title: "API tokens", scope: "okta.apiTokens.read", permission: "a custom role with View API tokens (okta.users.apitokens.read)")
        static let signedIn = Need(title: "The signed-in admin", scope: "okta.users.read.self", permission: "an admin role")
        static let policies = Need(title: "Policies", scope: "okta.policies.read", permission: "the Read-Only Administrator role, which views the org's policies")
        static let authenticators = Need(title: "Authenticators", scope: "okta.authenticators.read", permission: "the Read-Only Administrator role, which views the org's authenticators")
        static let zones = Need(title: "Network zones", scope: "okta.networkZones.read", permission: "the Read-Only Administrator role, which views the org's network zones")
    }

    /// How a refusal for a scope the sign-in lacks begins, before the scope Okta named.
    static let lacking = "insufficient_scope: "

    /// The scope Okta's 403 says the sign-in lacks, from its WWW-Authenticate header, such as
    /// `Bearer …, scope="okta.users.read", error="insufficient_scope"`; nil for any other refusal.
    static func lackedScope(_ response: HTTPURLResponse) -> String? {
        guard let header = response.value(forHTTPHeaderField: "WWW-Authenticate"),
              let regex = try? NSRegularExpression(pattern: #"([A-Za-z_]+)\s*=\s*"([^"]*)""#) else { return nil }
        var values: [String: String] = [:]
        for match in regex.matches(in: header, range: NSRange(header.startIndex..., in: header)) {
            guard let name = Range(match.range(at: 1), in: header), let value = Range(match.range(at: 2), in: header) else { continue }
            values[header[name].lowercased()] = String(header[value])
        }
        guard values["error"] == "insufficient_scope" else { return nil }
        // Only scope names, so nothing else Okta put there reaches the result.
        let scope = (values["scope"] ?? "").split(separator: " ").map(String.init).filter {
            (1...60).contains($0.count) && $0.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._").contains)
        }.joined(separator: " ")
        return scope
    }

    /// What to change when Okta refused, from what it said; nil for any other failure.
    static func fix(for error: Error, _ need: Need) -> String? {
        switch error {
        case ServiceError.rejected:
            return "Okta did not accept the sign-in: it expired or was revoked, the app or its refresh token was turned off, or the admin was deactivated. Connect the tool again in Settings › Tools."
        case ServiceError.forbidden(let reason?) where reason.hasPrefix(lacking):
            let named = reason.dropFirst(lacking.count).prefix { $0 != ";" }
            let scope = named.isEmpty ? need.scope : String(named)
            return "the sign-in lacks the scope \(scope): if the tool's Setup Steps list it, grant it on the Okta app's Okta API Scopes tab, then connect the tool again in Settings › Tools; if they do not, Okta wants a scope Pion does not ask for, so report it."
        case ServiceError.forbidden:
            return "the signed-in admin may not read this: give them \(need.permission), or, if they have it, check the admin's resource set."
        default: return nil
        }
    }

    /// A request, with Okta's refusal said as what to change.
    static func read<Value>(_ need: Need, _ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch {
            guard let fix = fix(for: error, need) else { throw error }
            let said: String? = switch error {
            case ServiceError.forbidden(let reason), ServiceError.rejected(let reason): reason
            default: nil
            }
            throw ServiceError.input("Okta refused \(need.title.lowercased())\(said.map { " (it said: \($0))" } ?? ""): \(fix) Running check-access shows everything this tool can and cannot do.")
        }
    }

    // MARK: Users

    struct Profile: Codable, Sendable { let login: String?; let email: String?; let firstName: String?; let lastName: String? }
    struct User: Codable, Sendable { let id: String; let status: String?; let created: String?; let lastLogin: String?; let passwordChanged: String?; let profile: Profile? }

    struct UserSummary: Encodable {
        let id: String, login: String?, email: String?, name: String?, status: String?
        let created: String?, lastLogin: String?, passwordChanged: String?

        init(_ user: User) {
            id = user.id; login = user.profile?.login; email = user.profile?.email
            let name = [user.profile?.firstName, user.profile?.lastName].compactMap { $0 }.joined(separator: " ")
            self.name = name.isEmpty ? nil : name
            status = user.status; created = user.created; lastLogin = user.lastLogin; passwordChanged = user.passwordChanged
        }

        var sentence: String {
            var parts = ["\(name ?? login ?? id) (\(login ?? id))"]
            if let status { parts.append(status) }
            parts.append(lastLogin.map { "last signed in \($0)" } ?? "never signed in")
            if let passwordChanged { parts.append("password changed \(passwordChanged)") }
            return parts.joined(separator: ", ")
        }
    }

    /// The user an ID or login names, as Okta resolves it.
    static func resolve(_ value: String, on service: ServiceClient) async throws -> User {
        let user = try await read(.users) { try await get(service, ["users", try Okta.user(value)], as: User.self) }
        _ = try id(user.id, length: 1...64, "the user")
        return user
    }

    /// A user's login by their ID, for naming admins and token owners; nil when it could not be read.
    static func login(_ id: String, on service: ServiceClient) async -> String? {
        try? await get(service, ["users", id], as: User.self).profile?.login
    }
}

extension Okta {
    struct FindUser: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String; let limit: Int? }
        static let name = "find-user"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Find users whose first name, last name or email starts with the query, with their status and last sign-in, saying when more match than it kept. It does not search logins; give a full login to the other tools."
        static let input = JSONSchema.object(["query": .string("The start of a first name, last name or email address."),
                                              "limit": .integer("How many users, at most. 10 when left out.", minimum: 1, maximum: 50)], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let query = try Okta.user(input.query)
            let limit = input.limit ?? 10
            guard (1...50).contains(limit) else { throw ServiceError.input("Ask for between 1 and 50 users.") }
            let listing = try await Okta.read(.users) {
                try await Okta.list(service, ["users"], query: ["q": query, "limit": String(limit)], as: User.self, pages: 1)
            }
            let users = listing.value.prefix(limit).map(UserSummary.init)
            struct Found: Encodable { let users: [UserSummary]; let complete: Bool }
            var text = users.isEmpty ? "No user's first name, last name or email starts with \"\(query)\"."
                : "Found \(users.count) user\(users.count == 1 ? "" : "s"): " + users.map(\.sentence).joined(separator: "; ") + "."
            if listing.more { text += "\nMore users match than the \(users.count) kept: give more of the name or email, or a higher limit." }
            return try ServiceResult(text: text, structured: Found(users: Array(users), complete: !listing.more))
        }
    }

    struct UserGroups: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-groups"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The groups a user belongs to, with each group's type, read page after page."
        static let input = JSONSchema.object(["user": .string("The user's Okta ID or login.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try Okta.user(input.user)
            struct Group: Decodable { struct Profile: Decodable { let name: String?; let description: String? }; let id: String; let type: String?; let profile: Profile? }
            struct Kept: Encodable { let id: String; let name: String?; let description: String?; let type: String? }
            struct Groups: Encodable { let groups: [Kept]; let complete: Bool }
            let listing = try await Okta.read(.groups) {
                try await Okta.list(service, ["users", user, "groups"], query: ["limit": "200"], as: Group.self)
            }
            let groups = listing.value.map { Kept(id: $0.id, name: $0.profile?.name, description: $0.profile?.description, type: $0.type) }
            let text = groups.isEmpty ? "\(user) is in no groups\(listing.complete ? "" : " in what was read")."
                : "\(user) is in \(groups.count) group\(groups.count == 1 ? "" : "s")\(listing.complete ? "" : " read so far"): "
                    + groups.map { ($0.name ?? $0.id) + ($0.type == "APP_GROUP" ? " (from an app)" : "") }.joined(separator: ", ") + "."
            return try ServiceResult(text: text + Okta.stopped(listing, "groups"), structured: Groups(groups: groups, complete: listing.complete))
        }
    }

    struct UserApps: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-apps"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Every app assigned to a user, directly or through a group, hidden ones included, read page after page."
        static let input = JSONSchema.object(["user": .string("The user's Okta ID or login.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try await Okta.resolve(input.user, on: service)
            struct App: Codable { let id: String; let label: String?; let name: String?; let status: String?; let signOnMode: String? }
            struct Apps: Encodable { let user: String; let apps: [App]; let complete: Bool }
            let listing = try await Okta.read(.apps) {
                try await Okta.list(service, ["apps"], query: ["filter": "user.id eq " + (try Okta.quoted(user.id, "the user's ID")), "limit": "200"], as: App.self)
            }
            let login = user.profile?.login ?? user.id
            let text = listing.value.isEmpty ? "\(login) has no apps assigned\(listing.complete ? "" : " in what was read")."
                : "\(login) has \(listing.value.count) app\(listing.value.count == 1 ? "" : "s")\(listing.complete ? "" : " read so far"): "
                    + listing.value.map { "\($0.label ?? $0.name ?? $0.id)\($0.status == "INACTIVE" ? " (inactive)" : "")" }.joined(separator: ", ") + "."
            return try ServiceResult(text: text + Okta.stopped(listing, "apps"), structured: Apps(user: user.id, apps: listing.value, complete: listing.complete))
        }
    }

    struct UserFactors: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-factors"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The sign-in factors a user has enrolled, such as push, SMS or a security key, with their status and when each was enrolled."
        static let input = JSONSchema.object(["user": .string("The user's Okta ID or login.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try Okta.user(input.user)
            struct Factor: Codable { let id: String; let factorType: String?; let provider: String?; let status: String?; let created: String?; let lastUpdated: String? }
            struct Factors: Encodable { let factors: [Factor] }
            let factors = try await Okta.read(.users) { try await Okta.get(service, ["users", user, "factors"], as: [Factor].self) }
            let text = factors.isEmpty ? "\(user) has no sign-in factors enrolled."
                : "\(user) has \(factors.count) factor\(factors.count == 1 ? "" : "s"): "
                    + factors.map { "\($0.factorType ?? "unknown") (\([$0.provider, $0.status, $0.created.map { "enrolled \($0)" }].compactMap { $0 }.joined(separator: ", ")))" }
                        .joined(separator: ", ") + "."
            return try ServiceResult(text: text, structured: Factors(factors: factors))
        }
    }

    /// A System Log event as the tools read it.
    struct LogEvent: Decodable, Sendable {
        struct Outcome: Decodable, Sendable { let result: String?; let reason: String? }
        struct Party: Decodable, Sendable { let id: String?; let type: String?; let alternateId: String?; let displayName: String? }
        struct Client: Decodable, Sendable {
            struct Place: Decodable, Sendable { let city: String?; let country: String? }
            struct Agent: Decodable, Sendable { let rawUserAgent: String? }
            let ipAddress: String?; let geographicalContext: Place?; let userAgent: Agent?
        }
        let uuid: String?, published: String?, eventType: String?, displayMessage: String?, severity: String?
        let outcome: Outcome?, actor: Party?, client: Client?, target: [Party]?
    }

    struct SignInEvents: ServiceOperation {
        struct Input: Decodable, Sendable {
            let user: String?, target: String?, ip: String?, eventType: String?, failuresOnly: Bool?, since: String?, until: String?, limit: Int?
        }
        static let name = "sign-in-events"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "System Log events of any kind, newest first, by the user who acted, the user or thing acted on, IP address, event type, failures only and time, saying when more matched than it kept. Okta keeps 90 days."
        static let input = JSONSchema.object([
            "user": .string("The login of the user who acted, such as name@example.com."),
            "target": .string("The ID or login of the user, group or app acted on, such as a user whose factors an admin reset."),
            "ip": .string("The IP address the events came from."),
            "eventType": .string("An event type, such as user.session.start or user.authentication.auth_via_mfa."),
            "failuresOnly": .boolean("Only events whose outcome was a failure."),
            "since": .string("The earliest time, in ISO 8601, such as 2026-11-13T00:00:00Z. The last 7 days when left out, at most 90 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many events, at most. 50 when left out.", minimum: 1, maximum: 100),
        ])

        struct Kept: Encodable {
            let id: String?, time: String?, type: String?, message: String?, outcome: String?, reason: String?
            let user: String?, ip: String?, city: String?, country: String?, userAgent: String?, targets: [String]
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter: [String] = []
            if let user = input.user { filter.append("actor.alternateId eq " + (try Okta.quoted(user, "the user's login"))) }
            if let target = input.target {
                let value = try Okta.quoted(target, "the target")
                filter.append("(target.id eq \(value) or target.alternateId eq \(value))")
            }
            if let ip = input.ip { filter.append("client.ipAddress eq \"\(try ServiceInput.ip(ip))\"") }
            if let type = input.eventType {
                guard !type.isEmpty, type.count <= 100, type.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._").contains) else {
                    throw ServiceError.input("Give an event type such as user.session.start.")
                }
                filter.append("eventType eq \"\(type)\"")
            }
            if input.failuresOnly == true { filter.append("outcome.result eq \"FAILURE\"") }
            let limit = input.limit ?? 50
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 events.") }
            let (since, until) = try Okta.window(input.since, input.until, days: 7)
            // Bounded, with until always given, so Okta's pages end; newest first, one page of the limit, its next link
            // saying more matched.
            let listing = try await Okta.read(.logs) {
                try await Okta.list(service, ["logs"], query: ["filter": filter.isEmpty ? nil : filter.joined(separator: " and "),
                                                              "since": Okta.iso(since), "until": Okta.iso(until), "limit": String(limit),
                                                              "sortOrder": "DESCENDING"], as: LogEvent.self, pages: 1)
            }
            let events = listing.value.prefix(limit).map {
                Kept(id: $0.uuid, time: $0.published, type: $0.eventType, message: $0.displayMessage, outcome: $0.outcome?.result,
                     reason: $0.outcome?.reason, user: $0.actor?.alternateId, ip: $0.client?.ipAddress,
                     city: $0.client?.geographicalContext?.city, country: $0.client?.geographicalContext?.country,
                     userAgent: $0.client?.userAgent?.rawUserAgent, targets: ($0.target ?? []).compactMap { $0.alternateId ?? $0.id })
            }
            let lines = events.prefix(20).map { event in
                var line = "\(event.time ?? "?") \(event.type ?? "event") \(event.outcome ?? "")".trimmingCharacters(in: .whitespaces)
                if let user = event.user { line += " by \(user)" }
                if !event.targets.isEmpty { line += " on \(event.targets.prefix(3).joined(separator: ", "))" }
                if let ip = event.ip { line += " from \(ip)" }
                let place = [event.city, event.country].compactMap { $0 }
                if !place.isEmpty { line += " (\(place.joined(separator: ", ")))" }
                return line
            }
            let window = "from \(Okta.iso(since)) to \(Okta.iso(until))"
            var text = events.isEmpty ? "No System Log events match \(window)."
                : "\(events.count) event\(events.count == 1 ? "" : "s") \(window), newest first:\n" + lines.joined(separator: "\n")
                    + (events.count > lines.count ? "\n… and \(events.count - lines.count) more in the structured result." : "")
            if listing.more { text += "\nMore events match than the \(events.count) kept, the newest: narrow the window or the filters, or raise the limit, to see older ones." }
            struct Events: Encodable { let events: [Kept]; let since: String; let until: String; let complete: Bool }
            return try ServiceResult(text: text, structured: Events(events: Array(events), since: Okta.iso(since), until: Okta.iso(until), complete: !listing.more))
        }
    }
}

// MARK: - Breach scope

extension Okta {
    /// The apps a user let act for them through OAuth, and what each may do. A grant outlives a password change.
    struct UserGrants: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-grants"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The apps a user let act for them through OAuth, with the scopes each holds and whether the user or an admin granted it, read page after page."
        static let input = JSONSchema.object(["user": .string("The user's Okta ID or login.")], required: ["user"])

        struct Scope: Codable { let name: String? }
        struct Embedded: Codable { let scope: Scope? }
        struct Grant: Codable {
            let id: String, clientId: String?, scopeId: String?, status: String?, source: String?, created: String?, issuer: String?
            let _embedded: Embedded?
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try Okta.user(input.user)
            let listing = try await Okta.read(.users) {
                try await Okta.list(service, ["users", user, "grants"], query: ["expand": "scope", "limit": "200"], as: Grant.self)
            }
            let grants = listing.value
            let text = grants.isEmpty ? "\(user) has granted no apps access\(listing.complete ? "" : " in what was read")." : Dictionary(grouping: grants) { $0.clientId ?? "?" }
                .sorted { $0.key < $1.key }.map { client, held in
                    let scopes = held.map { $0._embedded?.scope?.name ?? $0.scopeId ?? "?" }.joined(separator: ", ")
                    let by = held.contains { $0.source == "ADMIN" } ? "granted by an admin" : "granted by the user"
                    return "\(client): \(scopes) (\(by), since \(held.compactMap(\.created).min() ?? "?"))"
                }.joined(separator: "\n")
            struct Kept: Encodable { let grants: [Grant]; let complete: Bool }
            return try ServiceResult(text: text + Okta.stopped(listing, "grants"), structured: Kept(grants: grants, complete: listing.complete))
        }
    }

    struct Role: Codable, Sendable {
        let id: String?, type: String?, label: String?, status: String?, assignmentType: String?
        /// For a custom role: its ID, and the resource set it applies to.
        let role: String?, resourceSet: String?
        enum CodingKeys: String, CodingKey { case id, type, label, status, assignmentType, role, resourceSet = "resource-set" }
    }

    /// Who holds which admin role, directly or through a group: the accounts that can change the org.
    struct AdminRoles: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "admin-roles"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Everyone Okta lists as holding an admin role, with which roles and whether through a group, super administrators first, saying when it read only some."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Assignee: Decodable { let id: String }
            let listing = try await Okta.read(.admins) {
                try await Okta.list(service, ["iam", "assignees", "users"], query: ["limit": "100"], as: Assignee.self, envelope: true)
            }
            let ids = Array(listing.value.map(\.id).prefix(Okta.adminLookups))
            let admins = try await withThrowingTaskGroup(of: (String, String?, [Role]).self) { group in
                for id in ids {
                    group.addTask {
                        let roles = try await Okta.read(.admins) { try await Okta.get(service, ["users", id, "roles"], as: [Role].self) }
                        return (id, await Okta.login(id, on: service), roles)
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }.sorted { first, second in
                let superAdmin = (first.2.contains { $0.type == "SUPER_ADMIN" }, second.2.contains { $0.type == "SUPER_ADMIN" })
                return superAdmin.0 != superAdmin.1 ? superAdmin.0 : (first.1 ?? first.0) < (second.1 ?? second.0)
            }
            struct Admin: Encodable { let id: String; let login: String?; let roles: [Role] }
            var text = admins.isEmpty ? "Nobody holds an admin role\(listing.complete ? "" : " in what was read")." : admins.map { id, login, roles in
                "\(login ?? id): " + roles.map { ($0.label ?? $0.type ?? "?") + ($0.assignmentType == "GROUP" ? " (through a group)" : "") }.joined(separator: ", ")
            }.joined(separator: "\n")
            let unnamed = admins.filter { $0.1 == nil }.count
            if unnamed > 0 { text += "\n\(unnamed) admin\(unnamed == 1 ? "'s" : "s'") login could not be read, so they show their ID." }
            if listing.value.count > ids.count { text += "\nOnly the roles of \(ids.count) of the \(listing.value.count) admins read were looked up." }
            struct Kept: Encodable { let admins: [Admin]; let complete: Bool }
            return try ServiceResult(text: text + Okta.stopped(listing, "admins"),
                                     structured: Kept(admins: admins.map { Admin(id: $0.0, login: $0.1, roles: $0.2) },
                                                      complete: listing.complete && listing.value.count == ids.count))
        }
    }

    /// Every API token: each acts as the admin who made it, from anywhere unless its network is limited.
    struct APITokens: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "api-tokens"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Every API token, with who made it, when it expires and where it may be used from, read page after page."
        static let input = JSONSchema.object([:])

        struct Network: Codable { let connection: String? }
        struct Token: Codable {
            let id: String, name: String?, userId: String?, clientName: String?, created: String?, expiresAt: String?, lastUpdated: String?
            let network: Network?
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let listing = try await Okta.read(.tokens) { try await Okta.list(service, ["api-tokens"], query: ["limit": "200"], as: Token.self) }
            let tokens = listing.value
            let owners = Set(tokens.compactMap(\.userId)).sorted()
            var named: [String: String] = [:]
            for id in owners.prefix(Okta.ownerLookups) { named[id] = await Okta.login(id, on: service) }
            var text = tokens.isEmpty ? "The org has no API tokens\(listing.complete ? "" : " in what was read")." : tokens.map { token in
                let from = switch token.network?.connection {
                case "ANYWHERE", nil: "from anywhere"
                case let other?: "from \(other.lowercased().replacingOccurrences(of: "_", with: " ")) networks only"
                }
                return "\(token.name ?? token.id) [\(token.id)], made by \(token.userId.map { named[$0] ?? $0 } ?? "?") on \(token.created ?? "?"), \(from), expires \(token.expiresAt ?? "?")"
            }.joined(separator: "\n")
            if owners.count > Okta.ownerLookups { text += "\nOnly \(Okta.ownerLookups) of \(owners.count) owners were named; the rest show their ID." }
            struct Kept: Encodable { let tokens: [Token]; let complete: Bool }
            return try ServiceResult(text: text + Okta.stopped(listing, "API tokens"), structured: Kept(tokens: tokens, complete: listing.complete))
        }
    }

    /// The admin signed in to this connection, and their roles.
    static func signedIn(_ service: ServiceClient) async throws -> (user: User, roles: [Role]) {
        let me = try await get(service, ["users", "me"], as: User.self)
        let roles = try await get(service, ["users", try id(me.id, length: 1...64, "the signed-in user"), "roles"], as: [Role].self)
        return (me, roles)
    }

    /// The permissions of a custom admin role, by Okta's names, such as okta.users.read.
    static func permissions(_ role: String, _ service: ServiceClient) async throws -> [String] {
        struct Permission: Decodable { let label: String? }
        struct Answer: Decodable { let permissions: [Permission]? }
        return try await get(service, ["iam", "roles", try id(role, length: 1...64, "the role"), "permissions"], as: Answer.self)
            .permissions?.compactMap(\.label) ?? []
    }

    /// Tries each thing Okta Detection reads once, says what works and what to change for what does not, which scopes the
    /// sign-in holds, and which roles the signed-in admin holds.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Tries each thing this tool reads once and says what works and, for what does not, exactly what to change, in the Okta app's scopes or the admin's role; which scopes the sign-in holds; and which admin roles the signed-in admin holds, saying when they could change the org. It changes nothing."
        static let input = JSONSchema.object([:])

        /// Standard admin roles that only read.
        static let reading: Set<String> = ["READ_ONLY_ADMIN", "REPORT_ADMIN"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            func check(_ need: Need, _ probe: () async throws -> Void) async -> String {
                do { try await probe(); return "✓ \(need.title)" }
                catch { return "✗ \(need.title): " + (Okta.fix(for: error, need) ?? error.localizedDescription) }
            }
            var lines: [String] = []
            lines.append(await check(.users) { _ = try await Okta.exchange(service, ["users"], query: ["limit": "1"]) })
            lines.append(await check(.groups) { _ = try await Okta.exchange(service, ["groups"], query: ["limit": "1"]) })
            lines.append(await check(.apps) { _ = try await Okta.exchange(service, ["apps"], query: ["limit": "1"]) })
            let now = Date()
            lines.append(await check(.logs) {
                _ = try await Okta.exchange(service, ["logs"], query: ["since": Okta.iso(now.addingTimeInterval(-3_600)), "until": Okta.iso(now), "limit": "1"])
            })
            lines.append(await check(.admins) { _ = try await Okta.exchange(service, ["iam", "assignees", "users"], query: ["limit": "1"]) })
            lines.append(await check(.tokens) { _ = try await Okta.exchange(service, ["api-tokens"], query: ["limit": "1"]) })
            lines.append(await check(.policies) { _ = try await Okta.exchange(service, ["policies"], query: ["type": "OKTA_SIGN_ON", "limit": "1"]) })
            lines.append(await check(.authenticators) { _ = try await Okta.exchange(service, ["authenticators"]) })
            lines.append(await check(.zones) { _ = try await Okta.exchange(service, ["zones"], query: ["limit": "1"]) })
            do {
                let (me, roles) = try await Okta.signedIn(service)
                let named = roles.map { $0.label ?? $0.type ?? "?" }
                var writes: [String] = []
                for role in roles where !Self.reading.contains(role.type ?? "") {
                    if role.type == "CUSTOM", let custom = role.role {
                        if let held = try? await Okta.permissions(custom, service) {
                            writes += held.filter { !$0.hasSuffix(".read") }
                        } else {
                            writes.append("\(role.label ?? custom) (its permissions could not be read)")
                        }
                    } else {
                        writes.append(role.label ?? role.type ?? "?")
                    }
                }
                lines.append("· Signed in as \(me.profile?.login ?? me.id), who holds \(named.isEmpty ? "no admin role" : named.joined(separator: ", ")).")
                lines.append(writes.isEmpty
                    ? "✓ The signed-in admin cannot change the org: they hold only reading roles."
                    : "⚠ The signed-in admin's roles also allow changes: \(Array(Set(writes)).sorted().prefix(6).joined(separator: ", ")). This sign-in's scopes only read, so Okta Detection cannot make them, but an admin kept for it needs only the Read-Only Administrator and a custom role that views roles and API tokens.")
            } catch {
                lines.append("· Which roles the signed-in admin holds: not read: \(error.localizedDescription)")
            }
            lines.append(Okta.scopesLine(Okta.auditScopes, service))
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }

    /// The scopes a sign-in holds, as a line of check-access: those its tool asks for, as Pion refuses a sign-in Okta
    /// grants fewer, and the app they are granted to.
    static func scopesLine(_ scopes: [String], _ service: ServiceClient) -> String {
        let app = service.settings["clientID"].map { " to the Okta app \($0)" } ?? ""
        return "· The sign-in holds the scopes \((scopes + ["offline_access"]).joined(separator: ", ")), granted\(app); Pion refuses a sign-in that lacks any. Okta allows a request only when the admin's role allows it too."
    }
}
