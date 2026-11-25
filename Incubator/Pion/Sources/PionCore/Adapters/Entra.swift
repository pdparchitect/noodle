import Foundation
import NoodleCore
import NoodleToolConnections

/// A Microsoft tenant's users, their groups, roles and sign-in methods, its sign-in and audit logs, Identity
/// Protection's risk, who holds which role and which apps hold which permissions and credentials, read through
/// Microsoft Graph as the admin who signs in. Each account is one tenant. Microsoft Entra ID Detection only reads; Microsoft
/// Entra ID Containment, a tool of its own with a sign-in of its own, acts.
///
/// Both sign in through OAuth at the tenant's own address on Microsoft's sign-in service, with an authorization code
/// and PKCE, through a public client app registration the organisation made for each tool, which keeps no client
/// secret. Microsoft allows a delegated request only when both the app's consented permissions and the admin's role
/// allow it, so Detection's permissions only read, whatever the admin may do, and each tool's setup gives its admin only
/// the roles the tool needs, which check-access reports.
///
/// Both tools' guide is Incubator/Pion/docs/tools/entra.md. Change it with the setup steps, permissions or operations here.
public enum Entra {
    public static let preset = ToolDefinition(
        id: "7b419894-4d22-4624-a699-5df62b3ab680", name: "Microsoft Entra ID Detection",
        summary: "Users, groups, roles, sign-in methods, sign-in and audit logs, risky users and apps' permissions and credentials of a Microsoft tenant, read-only.",
        defaultInstructions: """
        Use Microsoft Entra ID Detection to learn who an identity is and what happened to it: find-user, then user-groups \
        (groups and roles, nested ones marked), user-sign-in-methods, sign-ins (the sign-in log with location, IP \
        address, conditional access and risk) and risky-users. To audit who holds what, role-holders lists each directory \
        role's active and eligible holders, Global Administrator first; app-permissions which apps hold which Microsoft \
        Graph permissions; app-credentials the secrets and certificates apps sign in with, newest first, with each one's \
        keyId, as one added lately may be an attacker's way back in; directory-audit who changed what, and from where. \
        The alert watch checks every five minutes and wakes you with a note naming security-events, which reads what it \
        reads for the note's window: privileged roles granted, made eligible or activated, secrets or certificates added \
        to apps, consent to apps (admin consent, or high-privilege permissions), federation and domains changed, \
        Conditional Access policies and named locations changed or deleted, sign-in methods changed by an admin, and \
        users and sign-ins Identity Protection rates at high risk. A note may name a feed the watch could not read, such \
        as Identity Protection without Microsoft Entra ID P2: security-events says why, so tell the champion and treat \
        that feed's silence as unknown. When a tool is refused or something you need seems missing, run check-access and \
        tell the champion exactly what it says to change. Silence is not proof: every result says when it stopped \
        before reading everything or matched more than it kept; report those gaps with what you found. Sign-in logs \
        need Entra ID P1 and keep 30 days; Identity Protection and eligible roles need P2. An event's actor is the \
        account used, not who held it. Record what you find as evidence, citing the tenant, user and time window. These \
        tools only read: recommend disabling an account, revoking sessions or removing sign-in methods to the champion, \
        or use Microsoft Entra ID Containment, with the user, why, and how to undo it.
        """,
        iconName: "entra",
        configuration: .connection(.init(endpointTemplate: "https://graph.microsoft.com/v1.0", fields: fields,
                                         oauth: oauth(scopes: auditScopes), oauthClientField: "clientID", oauthPathField: "tenant", oauthPathExcludes: generic,
                                         adapter: "entra")),
        setup: setup)

    static let fields = [ToolField(key: "tenant", title: "Directory (tenant) ID", placeholder: "4f1c2e3d-0000-4000-8000-000000000001", kind: .identifier),
                         ToolField(key: "clientID", title: "Application (client) ID", placeholder: "0b1c2d3e-0000-4000-8000-000000000002", kind: .identifier)]

    /// Microsoft's sign-in service at the tenant each account names in its path. Every sign-in asks for the admin's
    /// password again, so a browser already signed in to Microsoft as someone else never answers for them. Microsoft
    /// never lists offline_access among the scopes it granted, so it is asked for without being required back.
    static func oauth(scopes: [String]) -> MCPOAuthConfiguration {
        let tenant = "https://login.microsoftonline.com/{tenant}"
        return MCPOAuthConfiguration(issuer: URL(string: tenant + "/v2.0")!, authorizationEndpoint: URL(string: tenant + "/oauth2/v2.0/authorize")!,
                                     tokenEndpoint: URL(string: tenant + "/oauth2/v2.0/token")!, clients: [], scopes: scopes,
                                     authorizationParameters: ["prompt": "login"], usesResourceIndicator: false, unlistedScopes: ["offline_access"])
    }

    /// Only reading permissions, one for each kind of thing Detection reads: the directory, its users, groups, apps and
    /// grants (sign-in logs need it too); the audit and sign-in logs; users' sign-in methods; risky users; risk
    /// detections; and role assignments with eligibility in Privileged Identity Management.
    static let auditScopes = ["Directory.Read.All", "AuditLog.Read.All", "UserAuthenticationMethod.Read.All", "IdentityRiskyUser.Read.All",
                              "IdentityRiskEvent.Read.All", "RoleManagement.Read.Directory"]

    /// Where Microsoft sends each sign-in back to: Pion's bundle ID as a URL scheme.
    static let redirects = "`com.pdparchitect.pion:/oauth2callback` (`com.pdparchitect.pion.local:/oauth2callback` for Pion Dev)"

    static func appSteps(_ name: String, scopes: [String]) -> [String] {
        [
            "In the [Microsoft Entra admin center](https://entra.microsoft.com), open **App registrations** and choose **New registration**. Name it \(name), kept for this tool alone, and keep **Single tenant**. Under **Redirect URI**, choose **Public client/native (mobile & desktop)** and give \(redirects). Add no client secret or certificate: Pion keeps none and signs in with PKCE.",
            "Under **API permissions**, choose **Add a permission › Microsoft Graph › Delegated permissions** and add exactly \(scopes.map { "`\($0)`" }.joined(separator: ", ")); remove `User.Read`, which a new app is given. Choose **Grant admin consent**. Pion asks for these and `offline_access`, and refuses a sign-in that lacks any.",
            "Under **Enterprise applications**, open the app: in **Properties**, set **Assignment required?** to **Yes**, and under **Users and groups** assign only the admin who will sign in.",
        ]
    }

    static let setup = appSteps("Pion Detection", scopes: auditScopes) + [
        "Microsoft allows a request only when both the app's permissions and the signed-in admin's role allow it. Keep an admin for Pion Detection alone, such as pion-detection@contoso.com, with only the **Global Reader** role, which reads everything this tool reads and changes nothing.",
        "Sign-in logs need Microsoft Entra ID P1; Identity Protection's risky users and risk detections, and roles eligible in Privileged Identity Management, need P2. Without them, what needs them says so.",
        "Give the **Directory (tenant) ID** and the app's **Application (client) ID** from its **Overview**. Choose **Add & Connect** and sign in as that admin. Then ask an agent to run check-access.",
    ]

    /// Every operation of both tools, each naming the jobs it serves; each tool offers those of its own job.
    static let operations: [any ServiceOperation] = [
        FindUser(), UserGroups(), SignInMethods(), SignIns(), RiskyUsers(), RoleHolders(), AppPermissions(), DirectoryAudit(), AppCredentials(),
        SecurityEvents(), CheckAccess(),
        ContainmentUser(), DisableSignIn(), EnableSignIn(), RevokeSessions(), DeleteSignInMethods(), RemoveDirectoryRole(), RemoveAppCredential(),
        ConfirmCompromised(), DismissUserRisk(), ContainmentCheckAccess(),
    ]

    public static let adapter = OperationAdapter(operations: operations, job: .detection, trigger: NewSecurityEvents(),
                                                 // Graph throttles each app in each tenant, and role-holders and app-permissions look up names.
                                                 simultaneousRequests: 4)

    // MARK: Limits

    /// The most pages one listing reads.
    static let maximumPages = 10
    /// The most apps app-permissions names by asking for each, one request each.
    static let nameLookups = 50
    /// How many days the audit and sign-in logs keep, with Entra ID P1 or P2.
    static let logDays = 30.0
    /// Microsoft Graph's own app, the same in every tenant.
    static let graphApp = "00000003-0000-0000-c000-000000000000"

    // MARK: Inputs

    /// The sign-in addresses that are no one tenant, which sign in to whichever tenant the admin belongs to: refused
    /// when the account is set up and before any sign-in, and again here before any request.
    static let generic: Set<String> = ["common", "organizations", "consumers"]

    /// The tenant the connection names, never one of Microsoft's addresses that stand for any tenant.
    static func tenant(_ service: ServiceClient) throws -> String {
        let tenant = try service.setting("tenant")
        guard !generic.contains(tenant.lowercased()) else {
            throw ServiceError.input("This connection names \(tenant), which is no one tenant: give the Directory (tenant) ID or a verified domain of one tenant in Settings › Tools, and connect again.")
        }
        return tenant
    }

    static func isGUID(_ value: String) -> Bool { value.count == 36 && UUID(uuidString: value) != nil }

    /// A directory object's ID, as Graph gives it: a GUID.
    static func guid(_ value: String, _ name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGUID(value) else { throw ServiceError.input("Give \(name) as its object ID, a GUID such as 4f1c2e3d-0000-4000-8000-000000000001.") }
        return value.lowercased()
    }

    /// A user named by its object ID or user principal name, as Graph's paths take it. A guest's name holds #EXT#,
    /// which no path can take, so a guest is given by object ID.
    static func user(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isGUID(value) { return value.lowercased() }
        guard value.count <= 113, value.split(separator: "@", omittingEmptySubsequences: false).count == 2, !value.hasPrefix("@"), !value.hasSuffix("@"),
              !value.contains(where: { $0.isWhitespace || "/?#\\%\"'".contains($0) }),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ServiceError.input("Give the user's object ID (a GUID) or full user principal name, such as name@contoso.com; give a guest, whose name holds #EXT#, by object ID.")
        }
        return value
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// A window within the logs' 30 days, since before until; `days` back from now when since is left out.
    static func window(_ since: String?, _ until: String?, days: Double) throws -> (since: Date, until: Date) {
        let now = Date()
        let from: Date? = try since.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantPast } ?? now.addingTimeInterval(-days * 86_400)
        let to: Date? = try until.map { ServiceAlert.time(try ServiceInput.time($0)) ?? .distantFuture } ?? now
        guard let from, let to, from <= to, from >= now.addingTimeInterval(-logDays * 86_400 - 60), to <= now.addingTimeInterval(60) else {
            throw ServiceError.input("Give a time range within the last 30 days, which the logs keep, with since before until.")
        }
        return (from, to)
    }

    // MARK: Requests

    /// What Graph said when it refused: its error's code and message.
    static func reason(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] as? [String: Any] else {
            return ServiceClient.reason(data)
        }
        let words = [error["code"] as? String, error["message"] as? String].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ": ")
        guard !words.isEmpty else { return ServiceClient.reason(data) }
        return String(words.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(300))
    }

    /// One request to Graph, for the tenant the connection names. Graph's refusals are said in its own words; when it
    /// throttles, after the transport has waited as Retry-After asked and tried again, the answer says how long Graph
    /// asked to wait.
    static func exchange(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:], method: String = "GET",
                         body: Data? = nil, headers: [String: String] = [:]) async throws -> (data: Data, response: HTTPURLResponse) {
        _ = try tenant(service)
        let answer = try await service.exchange(path, query: query, method: method, body: body, headers: headers, returning: Set(300...599))
        let status = answer.response.statusCode, said = reason(answer.data)
        switch status {
        case 200..<300: return answer
        case 429:
            let wait = answer.response.value(forHTTPHeaderField: "Retry-After").map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { Int($0) }.map { "Microsoft Graph asked to wait \($0) seconds before trying again" }
            throw ServiceError.rateLimited([wait, said].compactMap { $0 }.joined(separator: "; "))
        case 401: throw ServiceError.rejected(said)
        case 403: throw ServiceError.forbidden(said)
        case 404: throw ServiceError.notFound
        case 400, 405, 409, 412, 422: throw said.map(ServiceError.refused) ?? ServiceError.status(status)
        default: throw ServiceError.status(status, said)
        }
    }

    static func get<Answer: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?] = [:],
                                       as: Answer.Type = Answer.self) async throws -> Answer {
        let data = try await exchange(service, path, query: query).data
        do { return try JSONDecoder().decode(Answer.self, from: data) } catch { throw ServiceError.unreadable }
    }

    /// A change sent as JSON; what Graph answers is returned unread.
    static func send(_ service: ServiceClient, _ path: [String], method: String, _ body: [String: Any]?) async throws -> (data: Data, response: HTTPURLResponse) {
        try await exchange(service, path, method: method, body: try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) })
    }

    // MARK: Listings

    struct Listing<Item> {
        var value: [Item] = []
        /// Whether more remained when it stopped.
        var more = false
        var pages = 0
        /// Why it stopped before the end, when not for its page limit, such as a page Graph failed to give.
        var stopped: String? = nil
        /// The page it stopped at, for a listing stopped by a failure.
        var stoppedAt: Int? = nil
        /// Graph's $skiptoken for the next page, when it stopped at its page limit, or at `limit`, with more to read.
        var token: String? = nil
        var complete: Bool { !more && stopped == nil }
    }

    /// One page: a value list, with the address of the next when there is one. A page without its value is unreadable,
    /// never an empty one.
    struct Page<Item: Decodable>: Decodable {
        let value: [Item]
        let nextLink: String?
        enum CodingKeys: String, CodingKey { case value, nextLink = "@odata.nextLink" }
    }

    /// Where the next page starts: Graph's $skiptoken, taken alone from its next link, which must be on
    /// graph.microsoft.com over https and at the path just read; nil at the end. A link anywhere else is never followed.
    enum Next: Equatable { case end, token(String), unfollowable }

    static func next(_ link: String?, service: ServiceClient, path: [String]) -> Next {
        guard let link, !link.isEmpty else { return .end }
        let expected = path.reduce(service.base) { $0.appendingPathComponent($1) }
        guard let url = URLComponents(string: link), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
              url.host?.lowercased() == "graph.microsoft.com", url.host?.lowercased() == service.base.host?.lowercased(),
              url.path.lowercased() == expected.path.lowercased(),
              let token = url.queryItems?.first(where: { $0.name.lowercased() == "$skiptoken" })?.value, !token.isEmpty else { return .unfollowable }
        return .token(token)
    }

    /// A listing, page after page, up to `pages` or until `limit` items are kept. Each next page is asked of the same
    /// path with the same query and Graph's $skiptoken; `token` starts from one a listing stopped at before, with the
    /// query it came from. Graph may give an empty page with a next link, so only the link ends a listing.
    ///
    /// When a page after the first fails, what earlier pages held is kept and the listing says where and why it
    /// stopped, unless `partial` is false, for a reader that must have all or nothing, which gets the failure.
    static func list<Item: Decodable>(_ service: ServiceClient, _ path: [String], query: [String: String?], as: Item.Type,
                                      pages: Int = maximumPages, limit: Int? = nil, token: String? = nil, partial: Bool = true,
                                      matching: (Item) -> Bool = { _ in true }) async throws -> Listing<Item> {
        var query = query
        if let token { query["$skiptoken"] = token }
        var found = Listing<Item>()
        while found.pages < pages {
            let page: Page<Item>
            do { page = try await get(service, path, query: query, as: Page<Item>.self) } catch {
                guard partial, found.pages > 0 else { throw error }
                found.more = true
                found.token = nil
                found.stoppedAt = found.pages + 1
                found.stopped = error.localizedDescription
                return found
            }
            found.pages += 1
            found.value += page.value.filter(matching)
            switch next(page.nextLink, service: service, path: path) {
            case .end:
                found.more = false
                found.token = nil
                return found
            case .unfollowable:
                found.more = true
                found.token = nil
                found.stoppedAt = found.pages + 1
                found.stopped = "Microsoft Graph gave a next page on another address, or without a $skiptoken, which Pion does not follow"
                return found
            case .token(let next):
                found.more = true
                found.token = next
                if let limit, found.value.count >= limit { return found }
                query["$skiptoken"] = next
            }
        }
        return found
    }

    static func stopped<Item>(_ listing: Listing<Item>, _ name: String) -> String {
        if let reason = listing.stopped {
            return "\nIncomplete: stopped at page \(listing.stoppedAt ?? listing.pages + 1) reading \(name) because \(reason); what the \(listing.pages) page\(listing.pages == 1 ? "" : "s") before held is kept."
        }
        return listing.more ? "\nIncomplete: stopped after \(listing.pages) page\(listing.pages == 1 ? "" : "s") reading \(name), the most read at once; more remain." : ""
    }

    // MARK: Refusals

    /// What one thing a tool reads or does needs, to say what to change when Graph refuses it: the app's permission,
    /// the admin's role, and a licence when it takes one.
    struct Need: Sendable {
        let title: String, scope: String, role: String
        var licence: String? = nil

        static let users = Need(title: "Users and groups", scope: "Directory.Read.All", role: "Global Reader")
        static let apps = Need(title: "Apps, their permissions and credentials", scope: "Directory.Read.All", role: "Global Reader")
        static let audit = Need(title: "Directory audit log", scope: "AuditLog.Read.All", role: "Global Reader or Reports Reader")
        static let signIns = Need(title: "Sign-in log", scope: "AuditLog.Read.All and Directory.Read.All", role: "Global Reader or Reports Reader",
                                  licence: "Microsoft Entra ID P1")
        static let methods = Need(title: "Sign-in methods", scope: "UserAuthenticationMethod.Read.All", role: "Global Reader")
        static let risky = Need(title: "Risky users", scope: "IdentityRiskyUser.Read.All", role: "Global Reader or Security Reader",
                                licence: "Microsoft Entra ID P2")
        static let detections = Need(title: "Risk detections", scope: "IdentityRiskEvent.Read.All", role: "Global Reader or Security Reader",
                                     licence: "Microsoft Entra ID P2")
        static let roles = Need(title: "Role assignments", scope: "RoleManagement.Read.Directory", role: "Global Reader")
        static let eligible = Need(title: "Roles eligible in Privileged Identity Management", scope: "RoleManagement.Read.Directory",
                                   role: "Global Reader", licence: "Microsoft Entra ID P2")
        static let signedIn = Need(title: "The signed-in admin", scope: "Directory.Read.All", role: "any role")
    }

    /// Whether Graph refused for want of a licence, such as Entra ID P1 for sign-in logs or P2 for Identity Protection,
    /// rather than a permission.
    static func unlicensed(_ error: Error) -> Bool {
        guard case ServiceError.forbidden(let reason?) = error else { return false }
        let lower = reason.lowercased()
        return lower.contains("premium") || lower.contains("licen")
    }

    /// What to change when Graph refused, from what it said; nil for any other failure.
    static func fix(for error: Error, _ need: Need) -> String? {
        switch error {
        case ServiceError.rejected:
            return "Microsoft did not accept the sign-in: it expired or was revoked, the admin's account was disabled or their password changed, or a Conditional Access policy now blocks it. Connect the tool again in Settings › Tools."
        case ServiceError.forbidden where unlicensed(error):
            return "this needs \(need.licence ?? "a Microsoft Entra ID licence") in the tenant, which it lacks, so it cannot be read."
        case ServiceError.forbidden:
            return "either the app lacks the delegated permission \(need.scope), which its Setup Steps list (add it, grant admin consent, then connect the tool again in Settings › Tools), or the signed-in admin lacks a role that allows it, such as \(need.role)."
        case ServiceError.input(let said) where said.contains("no one tenant"):
            return said
        default: return nil
        }
    }

    /// A request, with Graph's refusal said as what to change.
    static func read<Value>(_ need: Need, _ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch {
            guard let fix = fix(for: error, need) else { throw error }
            let said: String? = switch error {
            case ServiceError.forbidden(let reason), ServiceError.rejected(let reason): reason
            default: nil
            }
            throw ServiceError.input("Microsoft Graph refused \(need.title.lowercased())\(said.map { " (it said: \($0))" } ?? ""): \(fix) Running check-access shows everything this tool can and cannot do.")
        }
    }

    // MARK: Directory objects

    /// A role holder, a member or an app, as Graph lists directory objects.
    struct DirectoryObject: Codable, Sendable {
        enum CodingKeys: String, CodingKey { case type = "@odata.type", id, displayName, userPrincipalName, appId }
        let type: String?, id: String, displayName: String?, userPrincipalName: String?, appId: String?
        /// As a person reads it: a user by sign-in name, an app or a group by name.
        var shown: String {
            switch Graph.kind(type) {
            case "user": "user " + (userPrincipalName ?? displayName ?? id)
            case "servicePrincipal": "app " + (displayName ?? id)
            case "group": "group " + (displayName ?? id)
            case let kind?: kind + " " + (displayName ?? id)
            case nil: displayName ?? id
            }
        }
    }

    struct RoleDefinition: Decodable, Sendable { let id: String; let displayName: String?; let templateId: String? }

    /// Every directory role's name, by its definition's ID and its template's, from RoleManagement.Read.Directory.
    static func roleNames(_ service: ServiceClient) async throws -> (names: [String: String], complete: Bool) {
        let listing = try await list(service, ["roleManagement", "directory", "roleDefinitions"], query: ["$select": "id,displayName,templateId"],
                                     as: RoleDefinition.self)
        var names: [String: String] = [:]
        for role in listing.value {
            names[role.id.lowercased()] = role.displayName ?? role.id
            if let template = role.templateId { names[template.lowercased()] = role.displayName ?? template }
        }
        return (names, listing.complete)
    }

    /// Roles that hand over the tenant or its defences, by their template IDs, which are the same in every tenant.
    static let globalAdministrator = "62e90394-69f5-4237-9190-012177145e10"
    static let privilegedRoles: [String: String] = [
        globalAdministrator: "Global Administrator", "e8611ab8-c189-46e8-94e1-60213ab1f814": "Privileged Role Administrator",
        "7be44c8a-adaf-4e2a-84d6-ab2649e08a13": "Privileged Authentication Administrator", "194ae4cb-b126-40b2-bd5b-6091b380977d": "Security Administrator",
        "29232cdf-9323-42fd-ade2-1d097af3e4de": "Exchange Administrator", "f28a1f50-f6e7-4571-818b-6a12f2af6b6c": "SharePoint Administrator",
        "9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3": "Application Administrator", "158c047a-c907-4556-b7ef-446551a6b5f7": "Cloud Application Administrator",
        "fe930be7-5e62-47db-91af-98c3a49a38b1": "User Administrator", "b1be1c3e-b65d-4f19-8427-f6fa0d97feb9": "Conditional Access Administrator",
        "8ac3fc64-6eca-42ea-9e69-59f4c7b60eb2": "Hybrid Identity Administrator", "c4e39bd9-1100-46d3-8c65-fb160da0071f": "Authentication Administrator",
    ]

    /// Whether a role, by its template ID or name, is one of `privilegedRoles`.
    static func isPrivileged(id: String?, name: String?) -> Bool {
        if let id, privilegedRoles[id.lowercased()] != nil { return true }
        guard let name = name?.lowercased() else { return false }
        return privilegedRoles.values.contains { $0.lowercased() == name }
    }

    /// The admin signed in to this connection, as Graph reads them from the sign-in.
    struct Me: Decodable, Sendable { let id: String; let userPrincipalName: String?; let displayName: String? }

    static func me(_ service: ServiceClient) async throws -> Me {
        let me = try await get(service, ["me"], query: ["$select": "id,userPrincipalName,displayName"], as: Me.self)
        _ = try guid(me.id, "the signed-in admin")
        return me
    }

    struct Assignment: Decodable, Sendable {
        let id: String, principalId: String?, roleDefinitionId: String?, directoryScopeId: String?
        let principal: DirectoryObject?
    }

    /// The roles a principal holds actively, assigned to it directly, by name, and whether every one was read.
    static func heldRoles(_ principal: String, _ service: ServiceClient) async throws -> (roles: [(assignment: Assignment, name: String)], complete: Bool) {
        let id = try guid(principal, "the principal")
        let (names, named) = try await roleNames(service)
        let listing = try await list(service, ["roleManagement", "directory", "roleAssignments"], query: ["$filter": "principalId eq '\(id)'"],
                                     as: Assignment.self)
        return (listing.value.map { ($0, $0.roleDefinitionId.flatMap { names[$0.lowercased()] } ?? $0.roleDefinitionId ?? "?") }, named && listing.complete)
    }
}

extension Entra {
    struct FindUser: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String; let limit: Int? }
        static let name = "find-user"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Find users whose display name, user principal name or email starts with the query, with whether they can sign in and when they were made, saying when more match than it kept."
        static let input = JSONSchema.object(["query": .string("The start of a name, user principal name or email address."),
                                              "limit": .integer("How many users, at most. 10 when left out.", minimum: 1, maximum: 50)], required: ["query"])

        struct User: Codable { let id: String, displayName: String?, userPrincipalName: String?, mail: String?, accountEnabled: Bool?, createdDateTime: String?, jobTitle: String?, department: String? }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let value = try Graph.literal(input.query, "the start of a name or address")
            let limit = input.limit ?? 10
            guard (1...50).contains(limit) else { throw ServiceError.input("Ask for between 1 and 50 users.") }
            let listing = try await Entra.read(.users) {
                try await Entra.list(service, ["users"], query: [
                    "$filter": ["displayName", "userPrincipalName", "mail"].map { "startswith(\($0),\(value))" }.joined(separator: " or "),
                    "$select": "id,displayName,userPrincipalName,mail,accountEnabled,createdDateTime,jobTitle,department", "$top": String(limit),
                ], as: User.self, pages: 1)
            }
            let users = Array(listing.value.prefix(limit))
            var text = users.isEmpty ? "No user's name, user principal name or email starts with \(value)."
                : "Found \(users.count) user\(users.count == 1 ? "" : "s"): " + users.map { user in
                    let state = user.accountEnabled == false ? "sign-in disabled" : user.accountEnabled == true ? "sign-in enabled" : "sign-in state unknown"
                    return "\(user.displayName ?? user.id) (\(user.userPrincipalName ?? user.id), \(state)\(user.jobTitle.map { ", \($0)" } ?? ""), id \(user.id))"
                }.joined(separator: "; ") + "."
            if listing.more { text += "\nMore users match than the \(users.count) kept: give more of the name, or a higher limit." }
            struct Found: Encodable { let users: [User]; let complete: Bool }
            return try ServiceResult(text: text, structured: Found(users: users, complete: !listing.more))
        }
    }

    struct UserGroups: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-groups"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The groups and directory roles a user is a member of, directly or through nested groups, read page after page."
        static let input = JSONSchema.object(["user": .string("The user's object ID or user principal name.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try Entra.user(input.user)
            struct Kept: Encodable { let id: String, name: String?, kind: String?, nested: Bool? }
            // A group inside a group gives its members what it is given, so both are listed, the nested ones marked.
            let (direct, all) = try await Entra.read(.users) {
                (try await Entra.list(service, ["users", user, "memberOf"], query: ["$select": "id"], as: DirectoryObject.self),
                 try await Entra.list(service, ["users", user, "transitiveMemberOf"], query: ["$select": "id,displayName"], as: DirectoryObject.self))
            }
            let ids = Set(direct.value.map(\.id))
            // Whether one is nested is known only when every direct membership was read.
            let kept = all.value.map { Kept(id: $0.id, name: $0.displayName, kind: Graph.kind($0.type), nested: ids.contains($0.id) ? false : direct.complete ? true : nil) }
            var text = kept.isEmpty ? "\(user) is in no groups or roles\(all.complete ? "" : " in what was read")."
                : "\(user) is a member of\(all.complete ? "" : ", in what was read"): " + kept.map { item in
                    (item.name ?? item.id) + (item.kind == "directoryRole" ? " (role)" : "")
                        + (item.nested == true ? " (through a nested group)" : item.nested == nil ? " (direct or nested, not known)" : "")
                }.joined(separator: ", ") + "."
            text += Entra.stopped(all, "memberships") + Entra.stopped(direct, "direct memberships")
            struct Memberships: Encodable { let memberships: [Kept]; let complete: Bool }
            return try ServiceResult(text: text, structured: Memberships(memberships: kept, complete: all.complete && direct.complete))
        }
    }

    /// A registered sign-in method, as Graph lists it, with its kind's name.
    struct Method: Decodable, Sendable {
        enum Keys: String, CodingKey { case type = "@odata.type", id, displayName, phoneNumber, phoneType, model, emailAddress, createdDateTime }
        let type: String?, id: String, detail: String?, created: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type); id = try container.decode(String.self, forKey: .id)
            detail = [Keys.displayName, .model, .phoneNumber, .emailAddress].lazy
                .compactMap { try? container.decodeIfPresent(String.self, forKey: $0) }.first
            created = try? container.decodeIfPresent(String.self, forKey: .createdDateTime)
        }
        var kind: String { Graph.kind(type) ?? "unknown" }
        var named: String { Entra.methodNames[kind] ?? kind }
    }

    static let methodNames = ["passwordAuthenticationMethod": "password", "microsoftAuthenticatorAuthenticationMethod": "Microsoft Authenticator",
                              "phoneAuthenticationMethod": "phone", "fido2AuthenticationMethod": "security key",
                              "windowsHelloForBusinessAuthenticationMethod": "Windows Hello for Business", "emailAuthenticationMethod": "email",
                              "softwareOathAuthenticationMethod": "authenticator app code", "temporaryAccessPassAuthenticationMethod": "temporary access pass",
                              "platformCredentialAuthenticationMethod": "platform credential"]

    struct SignInMethods: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-sign-in-methods"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The sign-in methods a user has registered, such as Microsoft Authenticator, a phone or a security key, with each one's ID and when it was added."
        static let input = JSONSchema.object(["user": .string("The user's object ID or user principal name.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try Entra.user(input.user)
            struct Kept: Encodable { let id: String, method: String, detail: String?, created: String? }
            let listing = try await Entra.read(.methods) { try await Entra.list(service, ["users", user, "authentication", "methods"], query: [:], as: Method.self) }
            let methods = listing.value.map { Kept(id: $0.id, method: $0.named, detail: $0.detail, created: $0.created) }
            let text = (methods.isEmpty ? "\(user) has no sign-in methods registered\(listing.complete ? "" : " in what was read")."
                : "\(user) has \(methods.count) sign-in method\(methods.count == 1 ? "" : "s")\(listing.complete ? "" : " read so far"): "
                    + methods.map { "\($0.method)\($0.detail.map { " (\($0))" } ?? "")\($0.created.map { ", added \($0)" } ?? "") [\($0.id)]" }.joined(separator: ", ") + ".")
                + Entra.stopped(listing, "sign-in methods")
            struct Methods: Encodable { let methods: [Kept]; let complete: Bool }
            return try ServiceResult(text: text, structured: Methods(methods: methods, complete: listing.complete))
        }
    }

    struct SignIns: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String?, ip: String?, failuresOnly: Bool?, since: String?, until: String?, limit: Int? }
        static let name = "sign-ins"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Interactive sign-ins, newest first, by user principal name, IP address, failures only and time, with app, location, conditional access and risk, saying when more matched than it kept. Needs Entra ID P1; the log keeps 30 days."
        static let input = JSONSchema.object([
            "user": .string("The user principal name, such as name@contoso.com."),
            "ip": .string("The IP address the sign-ins came from."),
            "failuresOnly": .boolean("Only sign-ins that failed."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out, at most 30 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many sign-ins, at most. 50 when left out.", minimum: 1, maximum: 200),
        ])

        struct SignIn: Decodable {
            struct Status: Decodable { let errorCode: Int?; let failureReason: String? }
            struct Location: Decodable { let city: String?; let countryOrRegion: String? }
            struct Device: Decodable { let operatingSystem: String?; let browser: String? }
            let id: String, createdDateTime: String?, userPrincipalName: String?, appDisplayName: String?, ipAddress: String?
            let clientAppUsed: String?, conditionalAccessStatus: String?, riskLevelDuringSignIn: String?
            let status: Status?, location: Location?, deviceDetail: Device?
        }
        struct Kept: Encodable {
            let id: String, time: String?, user: String?, app: String?, ip: String?, city: String?, country: String?
            /// Nil when Graph gave no status, so whether it succeeded is not known.
            let succeeded: Bool?, failure: String?, conditionalAccess: String?, risk: String?, client: String?, device: String?
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter: [String] = []
            if let user = input.user { filter.append("userPrincipalName eq " + (try Graph.literal(user, "the user principal name"))) }
            if let ip = input.ip { filter.append("ipAddress eq '\(try ServiceInput.ip(ip))'") }
            if input.failuresOnly == true { filter.append("status/errorCode ne 0") }
            let (since, until) = try Entra.window(input.since, input.until, days: 7)
            filter.append("createdDateTime ge \(Entra.iso(since))")
            filter.append("createdDateTime le \(Entra.iso(until))")
            let limit = input.limit ?? 50
            guard (1...200).contains(limit) else { throw ServiceError.input("Ask for between 1 and 200 sign-ins.") }
            let listing = try await Entra.read(.signIns) {
                try await Entra.list(service, ["auditLogs", "signIns"], query: ["$filter": filter.joined(separator: " and "), "$top": String(limit)],
                                     as: SignIn.self, pages: 3, limit: limit)
            }
            let signIns = listing.value.prefix(limit).map { item in
                Kept(id: item.id, time: item.createdDateTime, user: item.userPrincipalName, app: item.appDisplayName, ip: item.ipAddress,
                     city: item.location?.city, country: item.location?.countryOrRegion, succeeded: item.status?.errorCode.map { $0 == 0 },
                     failure: item.status?.failureReason, conditionalAccess: item.conditionalAccessStatus, risk: item.riskLevelDuringSignIn,
                     client: item.clientAppUsed,
                     device: [item.deviceDetail?.operatingSystem, item.deviceDetail?.browser].compactMap { $0 }.joined(separator: ", "))
            }.sorted { (ServiceAlert.time($0.time) ?? .distantPast) > (ServiceAlert.time($1.time) ?? .distantPast) }
            let lines = signIns.prefix(20).map { item in
                var line = "\(item.time ?? "?") " + (item.succeeded == true ? "succeeded" : item.succeeded == false ? "failed\(item.failure.map { " (\($0))" } ?? "")" : "outcome not given")
                if let user = item.user { line += " for \(user)" }
                if let app = item.app { line += " to \(app)" }
                if let ip = item.ip { line += " from \(ip)" }
                let place = [item.city, item.country].compactMap { $0 }.filter { !$0.isEmpty }
                if !place.isEmpty { line += " (\(place.joined(separator: ", ")))" }
                if let risk = item.risk, risk != "none" { line += ", risk \(risk)" }
                return line
            }
            let window = "from \(Entra.iso(since)) to \(Entra.iso(until))"
            var text = signIns.isEmpty ? "No sign-ins match \(window)\(listing.complete ? "" : " in what was read")."
                : "\(signIns.count) sign-in\(signIns.count == 1 ? "" : "s") \(window), newest first:\n" + lines.joined(separator: "\n")
                    + (signIns.count > lines.count ? "\n… and \(signIns.count - lines.count) more in the structured result." : "")
            if listing.stopped != nil { text += Entra.stopped(listing, "sign-ins") }
            else if listing.more { text += "\nMore sign-ins match than the \(signIns.count) kept: narrow the window or the filters, or raise the limit, to see the rest." }
            struct Kept2: Encodable { let signIns: [Kept]; let since: String; let until: String; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept2(signIns: Array(signIns), since: Entra.iso(since), until: Entra.iso(until), complete: listing.complete))
        }
    }

    struct RiskyUsers: ServiceOperation {
        struct Input: Decodable, Sendable { let limit: Int? }
        static let name = "risky-users"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "The users Identity Protection currently rates at risk, with how high, why and since when, highest first, saying when more are at risk than it kept. Needs Entra ID P2."
        static let input = JSONSchema.object(["limit": .integer("How many users, at most. 100 when left out.", minimum: 1, maximum: 500)])

        struct Risky: Codable { let id: String, userPrincipalName: String?, riskLevel: String?, riskState: String?, riskDetail: String?, riskLastUpdatedDateTime: String? }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 100
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 users.") }
            let listing = try await Entra.read(.risky) {
                try await Entra.list(service, ["identityProtection", "riskyUsers"], query: ["$filter": "riskState eq 'atRisk'", "$top": String(min(limit, 500))],
                                     as: Risky.self, limit: limit)
            }
            let order = ["high": 0, "medium": 1, "low": 2]
            let users = listing.value.prefix(limit).sorted { (order[$0.riskLevel ?? ""] ?? 3, $0.userPrincipalName ?? $0.id) < (order[$1.riskLevel ?? ""] ?? 3, $1.userPrincipalName ?? $1.id) }
            var text = users.isEmpty ? "No users are currently at risk\(listing.complete ? "" : " in what was read")."
                : "\(users.count) user\(users.count == 1 ? " is" : "s are") at risk\(listing.complete ? "" : " in what was read"): "
                    + users.map { "\($0.userPrincipalName ?? $0.id) (\($0.riskLevel ?? "level unknown")\($0.riskDetail.map { ", \($0)" } ?? "")\($0.riskLastUpdatedDateTime.map { ", since \($0)" } ?? ""), id \($0.id))" }
                        .joined(separator: "; ") + "."
            if listing.stopped != nil { text += Entra.stopped(listing, "risky users") }
            else if listing.more { text += "\nMore users are at risk than the \(users.count) kept: raise the limit to see the rest." }
            struct Users: Encodable { let users: [Risky]; let complete: Bool }
            return try ServiceResult(text: text, structured: Users(users: Array(users), complete: listing.complete))
        }
    }
}

// MARK: - Who holds what

extension Entra {
    struct Eligibility: Decodable, Sendable {
        struct Schedule: Decodable, Sendable { struct End: Decodable, Sendable { let endDateTime: String?; let type: String? }; let expiration: End? }
        let id: String, principalId: String?, roleDefinitionId: String?, directoryScopeId: String?, status: String?
        let scheduleInfo: Schedule?, principal: DirectoryObject?
    }

    /// Each directory role and who holds it, actively and, in Privileged Identity Management, eligibly: users, groups
    /// and apps, Global Administrator first, then the privileged roles.
    struct RoleHolders: ServiceOperation {
        struct Input: Decodable, Sendable { let role: String? }
        static let name = "role-holders"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Each directory role and who holds it, actively or eligible to activate it in Privileged Identity Management: users, groups and apps, Global Administrator and the other privileged roles first, saying what it could not read."
        static let input = JSONSchema.object(["role": .string("Only roles whose name contains this, such as Global or Exchange.")])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let filter = input.role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let (names, named) = try await Entra.read(.roles) { try await Entra.roleNames(service) }
            let active = try await Entra.read(.roles) {
                try await Entra.list(service, ["roleManagement", "directory", "roleAssignments"], query: ["$expand": "principal"], as: Assignment.self)
            }
            var gaps: [String] = []
            var eligible: Listing<Eligibility>?
            do {
                eligible = try await Entra.read(.eligible) {
                    try await Entra.list(service, ["roleManagement", "directory", "roleEligibilitySchedules"], query: ["$expand": "principal"], as: Eligibility.self)
                }
            } catch {
                gaps.append("Roles eligible in Privileged Identity Management were not read: \(error.localizedDescription)")
            }
            struct Holder: Encodable { let id: String, kind: String?, name: String, eligible: Bool, scope: String? }
            struct Held: Encodable { let role: String, privileged: Bool, holders: [Holder] }
            var byRole: [String: [Holder]] = [:]
            for item in active.value {
                let role = item.roleDefinitionId?.lowercased() ?? "?"
                byRole[role, default: []].append(Holder(id: item.principalId ?? item.principal?.id ?? "?", kind: Graph.kind(item.principal?.type),
                                                        name: item.principal?.shown ?? item.principalId ?? "?", eligible: false,
                                                        scope: item.directoryScopeId == "/" ? nil : item.directoryScopeId))
            }
            for item in eligible?.value ?? [] {
                let role = item.roleDefinitionId?.lowercased() ?? "?"
                byRole[role, default: []].append(Holder(id: item.principalId ?? item.principal?.id ?? "?", kind: Graph.kind(item.principal?.type),
                                                        name: item.principal?.shown ?? item.principalId ?? "?", eligible: true,
                                                        scope: item.directoryScopeId == "/" ? nil : item.directoryScopeId))
            }
            var held = byRole.map { id, holders in
                Held(role: names[id] ?? id, privileged: Entra.isPrivileged(id: id, name: names[id]), holders: holders.sorted { ($0.eligible ? 1 : 0, $0.name) < ($1.eligible ? 1 : 0, $1.name) })
            }.filter { role in filter.map { role.role.lowercased().contains($0) } ?? true }
            held.sort { first, second in
                let rank = { (role: Held) in role.role == "Global Administrator" ? 0 : role.privileged ? 1 : 2 }
                return (rank(first), first.role) < (rank(second), second.role)
            }
            var lines = held.map { role in
                "\(role.role) (\(role.holders.count)): " + role.holders.map { "\($0.name)\($0.eligible ? " (eligible)" : "")\($0.kind == "group" ? " (its members hold it)" : "")\($0.scope.map { " on \($0)" } ?? "")" }.joined(separator: ", ")
            }
            if lines.isEmpty { lines = ["No role is held\(filter == nil ? "" : " by that name")\(active.complete ? "" : " in what was read")."] }
            lines += gaps
            if !named { lines.append("Not every role's name was read, so some show their ID.") }
            var text = lines.joined(separator: "\n") + Entra.stopped(active, "role assignments")
            if let eligible { text += Entra.stopped(eligible, "eligible roles") }
            struct Kept: Encodable { let roles: [Held]; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(roles: held, complete: active.complete && (eligible?.complete ?? false) && named))
        }
    }

    /// Which apps hold which Microsoft Graph permissions: granted to the app itself, and consented for everyone or for
    /// single people. A permission that writes or sends can change the tenant; one that manages roles, app role grants
    /// or apps' credentials can make an app or a person an administrator.
    struct AppPermissions: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "app-permissions"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Which apps hold which Microsoft Graph permissions, granted to the app itself or consented for people, with those that can change the tenant or make administrators flagged, saying what it could not read."
        static let input = JSONSchema.object([:])
        /// Permissions with which an app can grant itself, or anyone, more.
        static let makesAdministrators: Set<String> = [
            "RoleManagement.ReadWrite.Directory", "AppRoleAssignment.ReadWrite.All", "Application.ReadWrite.All",
            "Directory.ReadWrite.All", "Application.ReadWrite.OwnedBy",
        ]

        static func flag(_ permission: String) -> String {
            if makesAdministrators.contains(permission) { return "\(permission) [can make administrators]" }
            if ["Write", "Send", "FullControl", "Manage"].contains(where: permission.contains) { return "\(permission) [can change]" }
            return permission
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct AppRole: Decodable { let id: String; let value: String? }
            struct Graphs: Decodable { let id: String; let appRoles: [AppRole]? }
            let found = try await Entra.read(.apps) {
                try await Entra.get(service, ["servicePrincipals"], query: ["$filter": "appId eq '\(Entra.graphApp)'", "$select": "id,appRoles"], as: Page<Graphs>.self)
            }
            guard let graph = found.value.first else { throw ServiceError.refused("Microsoft Graph's own app was not found in this tenant") }
            let names = Dictionary((graph.appRoles ?? []).compactMap { role in role.value.map { (role.id, $0) } }, uniquingKeysWith: { first, _ in first })
            struct Assignment: Decodable { let principalId: String; let principalDisplayName: String?; let appRoleId: String }
            let assigned = try await Entra.read(.apps) {
                try await Entra.list(service, ["servicePrincipals", graph.id, "appRoleAssignedTo"], query: ["$top": "999"], as: Assignment.self)
            }
            struct Grant: Decodable { let clientId: String; let consentType: String?; let resourceId: String?; let scope: String? }
            let grants = try await Entra.read(.apps) {
                try await Entra.list(service, ["oauth2PermissionGrants"], query: ["$top": "999"], as: Grant.self) { $0.resourceId == graph.id }
            }
            // An app known only from a consent is named by asking for it.
            var appNames = Dictionary(assigned.value.map { ($0.principalId, $0.principalDisplayName ?? $0.principalId) }, uniquingKeysWith: { first, _ in first })
            let unnamed = Set(grants.value.map(\.clientId)).subtracting(appNames.keys).sorted()
            var missed = 0
            for id in unnamed.prefix(Entra.nameLookups) {
                struct App: Decodable { let displayName: String? }
                if let name = try? await Entra.get(service, ["servicePrincipals", try Entra.guid(id, "the app")], query: ["$select": "displayName"], as: App.self).displayName {
                    appNames[id] = name
                } else { missed += 1 }
            }
            struct Held: Encodable { let app: String, id: String, kind: String, permissions: [String], people: Int? }
            var held = Dictionary(grouping: assigned.value, by: \.principalId).map { id, roles in
                Held(app: appNames[id] ?? id, id: id, kind: "application", permissions: roles.map { names[$0.appRoleId] ?? $0.appRoleId }.sorted(), people: nil)
            }
            for (id, consents) in Dictionary(grouping: grants.value, by: \.clientId) {
                let scopes = { (grants: [Grant]) in Set(grants.flatMap { ($0.scope ?? "").split(separator: " ").map(String.init) }).sorted() }
                let everyone = consents.filter { $0.consentType == "AllPrincipals" }, people = consents.filter { $0.consentType != "AllPrincipals" }
                if !everyone.isEmpty { held.append(Held(app: appNames[id] ?? id, id: id, kind: "delegated for everyone", permissions: scopes(everyone), people: nil)) }
                if !people.isEmpty { held.append(Held(app: appNames[id] ?? id, id: id, kind: "delegated", permissions: scopes(people), people: people.count)) }
            }
            // What can make administrators first, then what can change the tenant.
            func rank(_ item: Held) -> Int {
                item.permissions.contains(where: Self.makesAdministrators.contains) ? 0 : item.permissions.contains { Self.flag($0) != $0 } ? 1 : 2
            }
            held.sort { (rank($0), $0.app, $0.kind) < (rank($1), $1.app, $1.kind) }
            var text = held.isEmpty ? "No app holds Microsoft Graph permissions\(assigned.complete && grants.complete ? "" : " in what was read")." : held.map { item in
                let whom = item.people.map { " consented by \($0) \($0 == 1 ? "person" : "people")" } ?? (item.kind == "application" ? " as itself" : "")
                return "\(item.app) (\(item.kind == "delegated for everyone" ? "for everyone" : item.kind == "application" ? "application" : "delegated")\(whom)): "
                    + item.permissions.map(Self.flag).joined(separator: ", ")
            }.joined(separator: "\n")
            if unnamed.count > Entra.nameLookups { text += "\nOnly \(Entra.nameLookups) of the \(unnamed.count) apps known only from a consent were named; the rest show their ID." }
            if missed > 0 { text += "\n\(missed) app\(missed == 1 ? "'s" : "s'") name could not be read, so they show their ID." }
            text += Entra.stopped(assigned, "application permissions") + Entra.stopped(grants, "consents")
            struct Kept: Encodable { let apps: [Held]; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(apps: held, complete: assigned.complete && grants.complete))
        }
    }
}

// MARK: - Breach scope

extension Entra {
    /// A directory audit log entry.
    struct Audit: Codable, Sendable {
        struct Who: Codable, Sendable { let id: String?; let userPrincipalName: String?; let displayName: String?; let ipAddress: String?; let appId: String? }
        struct Initiator: Codable, Sendable { let user: Who?; let app: Who? }
        struct Property: Codable, Sendable { let displayName: String?; let oldValue: String?; let newValue: String? }
        struct Target: Codable, Sendable { let id: String?; let displayName: String?; let userPrincipalName: String?; let type: String?; let modifiedProperties: [Property]? }
        let id: String?, activityDateTime: String?, activityDisplayName: String?, category: String?, result: String?, loggedByService: String?
        let initiatedBy: Initiator?, targetResources: [Target]?

        var actor: String { initiatedBy?.user?.userPrincipalName ?? initiatedBy?.app?.displayName ?? initiatedBy?.user?.id ?? "someone" }
        var ip: String? { initiatedBy?.user?.ipAddress.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// Who changed what in the directory, from AuditLog.Read.All: roles granted, apps given secrets, users changed.
    struct DirectoryAudit: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String?, activity: String?, category: String?, since: String?, until: String?, limit: Int? }
        static let name = "directory-audit"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Changes to the directory, newest first, by who made them, the activity, category and time, with what they changed and from which IP address, saying when more matched than it kept. The log keeps 30 days."
        static let input = JSONSchema.object([
            "user": .string("Only changes this user principal name made."),
            "activity": .string("Only activities starting with this, such as Add member to role or Update application."),
            "category": .string("Only this category, such as RoleManagement, ApplicationManagement, UserManagement, Policy or DirectoryManagement."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out, at most 30 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many changes, at most. 100 when left out.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let (since, until) = try Entra.window(input.since, input.until, days: 7)
            var filters = ["activityDateTime ge \(Entra.iso(since))", "activityDateTime le \(Entra.iso(until))"]
            if let user = input.user { filters.append("initiatedBy/user/userPrincipalName eq " + (try Graph.literal(user, "the user principal name"))) }
            if let activity = input.activity { filters.append("startswith(activityDisplayName," + (try Graph.literal(activity, "the activity")) + ")") }
            if let category = input.category { filters.append("category eq " + (try Graph.literal(category, "the category"))) }
            let limit = input.limit ?? 100
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 changes.") }
            let listing = try await Entra.read(.audit) {
                try await Entra.list(service, ["auditLogs", "directoryAudits"], query: ["$filter": filters.joined(separator: " and "), "$top": String(limit)],
                                     as: Audit.self, pages: 5, limit: limit)
            }
            let changes = listing.value.prefix(limit).sorted { (ServiceAlert.time($0.activityDateTime) ?? .distantPast) > (ServiceAlert.time($1.activityDateTime) ?? .distantPast) }
            let window = "from \(Entra.iso(since)) to \(Entra.iso(until))"
            var text = changes.isEmpty ? "No directory changes match \(window)\(listing.complete ? "" : " in what was read")." : "\(changes.count) change\(changes.count == 1 ? "" : "s") \(window), newest first:\n" + changes.prefix(50).map { change in
                let targets = (change.targetResources ?? []).map { [$0.type, $0.userPrincipalName ?? $0.displayName].compactMap { $0 }.joined(separator: " ") }
                return "\(change.activityDateTime ?? "?") \(change.activityDisplayName ?? "?") by \(change.actor)\(change.ip.map { " from \($0)" } ?? "")"
                    + (targets.isEmpty ? "" : " on " + targets.joined(separator: ", ")) + (change.result == "success" || change.result == nil ? "" : " (\(change.result!))")
            }.joined(separator: "\n") + (changes.count > 50 ? "\n… and \(changes.count - 50) more in the structured result." : "")
            if listing.stopped != nil { text += Entra.stopped(listing, "directory changes") }
            else if listing.more { text += "\nMore changes match than the \(changes.count) kept: narrow the window or the filters, or raise the limit, to see the rest." }
            struct Kept: Encodable { let changes: [Audit]; let since: String; let until: String; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(changes: Array(changes), since: Entra.iso(since), until: Entra.iso(until), complete: listing.complete))
        }
    }

    /// The secrets and certificates app registrations and enterprise apps sign in with, from Directory.Read.All. One
    /// added lately may be an attacker's way back in; one valid for years lasts as long as nobody finds it.
    struct AppCredentials: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "app-credentials"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The secrets and certificates apps sign in with, newest first, with each app's object ID and each credential's keyId, flagging those added in the last 30 days, valid for more than two years, or expired, saying when it read only some apps."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Credential: Codable { let keyId: String?; let displayName: String?; let startDateTime: String?; let endDateTime: String? }
            struct App: Decodable { let id: String; let displayName: String?; let passwordCredentials: [Credential]?; let keyCredentials: [Credential]? }
            let query: [String: String?] = ["$select": "id,appId,displayName,passwordCredentials,keyCredentials", "$top": "999"]
            let (registrations, enterprise) = try await Entra.read(.apps) {
                (try await Entra.list(service, ["applications"], query: query, as: App.self),
                 try await Entra.list(service, ["servicePrincipals"], query: query, as: App.self))
            }
            struct Held: Encodable { let app: String, objectId: String, kind: String, credential: String, keyId: String?, name: String?, added: String?, expires: String?, flags: [String] }
            func held(_ apps: [App], _ kind: String) -> [Held] {
                apps.flatMap { app in
                    ((app.passwordCredentials ?? []).map { ("secret", $0) } + (app.keyCredentials ?? []).map { ("certificate", $0) }).map { type, credential in
                        let start = ServiceAlert.time(credential.startDateTime), end = ServiceAlert.time(credential.endDateTime), now = Date()
                        var flags: [String] = []
                        if let start, now.timeIntervalSince(start) < 30 * 86_400 { flags.append("added in the last 30 days") }
                        if let start, let end, end.timeIntervalSince(start) > 2 * 365 * 86_400 { flags.append("valid for more than two years") }
                        if let end, end < now { flags.append("expired") }
                        return Held(app: app.displayName ?? app.id, objectId: app.id, kind: kind, credential: type, keyId: credential.keyId, name: credential.displayName,
                                    added: credential.startDateTime, expires: credential.endDateTime, flags: flags)
                    }
                }
            }
            let all = (held(registrations.value, "application") + held(enterprise.value, "servicePrincipal"))
                .sorted { (ServiceAlert.time($0.added) ?? .distantPast) > (ServiceAlert.time($1.added) ?? .distantPast) }
            let complete = registrations.complete && enterprise.complete
            var text = all.isEmpty ? "No app signs in with a secret or certificate\(complete ? "" : " in what was read")." : all.prefix(100).map { item in
                "\(item.app) (\(item.kind == "application" ? "app registration" : "enterprise app") \(item.objectId)): \(item.credential)\(item.name.map { " \"\($0)\"" } ?? "") keyId \(item.keyId ?? "?"), added \(item.added ?? "?"), expires \(item.expires ?? "never")"
                    + (item.flags.isEmpty ? "" : " [" + item.flags.joined(separator: ", ") + "]")
            }.joined(separator: "\n") + (all.count > 100 ? "\n\(all.count - 100) more in the structured result." : "")
            text += Entra.stopped(registrations, "app registrations") + Entra.stopped(enterprise, "enterprise apps")
            struct Kept: Encodable { let credentials: [Held]; let complete: Bool }
            return try ServiceResult(text: text, structured: Kept(credentials: all, complete: complete))
        }
    }
}

// MARK: - Access

extension Entra {
    struct Organization: Decodable, Sendable {
        struct Domain: Decodable, Sendable { let name: String? }
        let id: String; let displayName: String?; let verifiedDomains: [Domain]?
    }

    /// The tenant the sign-in reads, said as a line of check-access, and whether it is the one the connection names.
    static func tenantLine(_ service: ServiceClient) async -> String {
        do {
            let named = try tenant(service)
            guard let organisation = try await get(service, ["organization"], query: ["$select": "id,displayName,verifiedDomains"], as: Page<Organization>.self).value.first else {
                return "· Which tenant the sign-in reads: Graph listed none."
            }
            let domains = (organisation.verifiedDomains ?? []).compactMap { $0.name?.lowercased() }
            let same = organisation.id.lowercased() == named.lowercased() || domains.contains(named.lowercased())
            return same ? "✓ Signed in to the tenant \(organisation.displayName ?? organisation.id) (\(organisation.id)), the one this connection names."
                : "✗ Signed in to the tenant \(organisation.displayName ?? organisation.id) (\(organisation.id)), not \(named), which this connection names: check the Directory (tenant) ID in Settings › Tools."
        } catch {
            return "· Which tenant the sign-in reads: not read: \(error.localizedDescription)"
        }
    }

    /// The delegated Microsoft Graph permissions consented to the connection's app, said as lines of check-access:
    /// those its tool asks for, and those besides, which are warned of. nil when they could not be read.
    static func consentLines(_ wanted: [String], reading: Bool, _ service: ServiceClient) async -> [String] {
        guard let client = service.settings["clientID"], isGUID(client) else { return ["· The app's consented permissions: no client ID to look them up by."] }
        do {
            struct Principal: Decodable { let id: String; let appDisplayName: String? }
            guard let app = try await get(service, ["servicePrincipals"], query: ["$filter": "appId eq '\(client.lowercased())'", "$select": "id,appDisplayName"],
                                          as: Page<Principal>.self).value.first,
                  let graph = try await get(service, ["servicePrincipals"], query: ["$filter": "appId eq '\(graphApp)'", "$select": "id"], as: Page<Principal>.self).value.first else {
                return ["· The app's consented permissions: the app \(client) was not found as an enterprise app in this tenant."]
            }
            struct Grant: Decodable { let consentType: String?; let resourceId: String?; let scope: String? }
            let grants = try await list(service, ["oauth2PermissionGrants"], query: ["$filter": "clientId eq '\(try guid(app.id, "the app"))'"], as: Grant.self)
            let held = Set(grants.value.filter { $0.resourceId == graph.id }.flatMap { ($0.scope ?? "").split(separator: " ").map(String.init) })
            let others = Set(grants.value.filter { $0.resourceId != graph.id }.compactMap(\.resourceId))
            var lines = ["· Delegated Microsoft Graph permissions consented to the app \(app.appDisplayName ?? client): \(held.sorted().joined(separator: ", "))\(grants.complete ? "" : ", in what was read")."]
            let missing = Set(wanted).subtracting(held), extra = held.subtracting(wanted).subtracting(["offline_access", "openid", "profile", "email"])
            if !missing.isEmpty { lines.append("✗ Not consented: \(missing.sorted().joined(separator: ", ")). Add them under the app's API permissions, grant admin consent, and connect again.") }
            if !extra.isEmpty {
                let writes = extra.filter { $0.contains("Write") || $0.contains("Manage") || $0.contains("Send") || $0.contains("FullControl") }
                lines.append("⚠ Consented besides what this tool asks for: \(extra.sorted().joined(separator: ", ")). Remove them from the app's API permissions\(reading && !writes.isEmpty ? "; some can change the tenant, which a detection app never needs" : "").")
            }
            if !others.isEmpty { lines.append("⚠ The app is also consented permissions to \(others.count) other API\(others.count == 1 ? "" : "s"), which Pion never uses; remove them.") }
            struct Role: Decodable { let appRoleId: String? }
            if let roles = try? await list(service, ["servicePrincipals", try guid(app.id, "the app"), "appRoleAssignments"], query: [:], as: Role.self), !roles.value.isEmpty {
                lines.append("⚠ The app also holds \(roles.value.count) application permission\(roles.value.count == 1 ? "" : "s"), which act without anyone signed in and which Pion never uses: remove them.")
            }
            return lines
        } catch {
            return ["· The app's consented permissions could not be read (\(error.localizedDescription)); Pion refuses a sign-in that lacks any it asks for: \((wanted + ["offline_access"]).joined(separator: ", "))."]
        }
    }

    /// Tries each thing Detection reads once, says what works and what to change for what does not, which permissions the
    /// app is consented, and which roles the signed-in admin holds.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Tries each thing this tool reads once and says what works and, for what does not, exactly what to change: the app's permissions, the admin's role or a licence the tenant lacks; which tenant it reads; which permissions the app is consented, warning of more than it needs; and which roles the signed-in admin holds, saying when they could change the tenant. It changes nothing."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            func check(_ need: Need, _ probe: () async throws -> Void) async -> String {
                do { try await probe(); return "✓ \(need.title)" }
                catch { return "✗ \(need.title): " + (Entra.fix(for: error, need) ?? error.localizedDescription) }
            }
            func one(_ path: [String], _ query: [String: String?] = [:]) async throws {
                _ = try await Entra.get(service, path, query: query.merging(["$top": "1"]) { first, _ in first }, as: Page<IgnoredItem>.self)
            }
            var lines = [await Entra.tenantLine(service)]
            lines.append(await check(.users) { try await one(["users"], ["$select": "id"]) })
            lines.append(await check(.apps) { try await one(["applications"], ["$select": "id"]) })
            lines.append(await check(.audit) { try await one(["auditLogs", "directoryAudits"]) })
            lines.append(await check(.signIns) { try await one(["auditLogs", "signIns"]) })
            lines.append(await check(.risky) { try await one(["identityProtection", "riskyUsers"]) })
            lines.append(await check(.detections) { try await one(["identityProtection", "riskDetections"]) })
            lines.append(await check(.roles) { try await one(["roleManagement", "directory", "roleAssignments"]) })
            lines.append(await check(.eligible) { try await one(["roleManagement", "directory", "roleEligibilitySchedules"]) })
            do {
                let me = try await Entra.me(service)
                lines.append(await check(.methods) { _ = try await Entra.get(service, ["users", me.id, "authentication", "methods"], as: Page<IgnoredItem>.self) })
                let (roles, complete) = try await Entra.heldRoles(me.id, service)
                let names = roles.map(\.name)
                lines.append("· Signed in as \(me.userPrincipalName ?? me.id), who holds \(names.isEmpty ? "no directory role assigned directly" : names.sorted().joined(separator: ", "))\(complete ? "" : ", in what was read"); roles held through a group or only eligible are not listed.")
                let writes = names.filter { !$0.hasSuffix("Reader") && !$0.hasSuffix("Readers") }
                lines.append(writes.isEmpty
                    ? "✓ The signed-in admin's roles only read."
                    : "⚠ The signed-in admin's roles also allow changes: \(writes.sorted().joined(separator: ", ")). This tool's permissions only read, so it cannot make them, but an admin kept for it needs only Global Reader.")
            } catch {
                lines.append("· Who is signed in, and their roles: not read: \(error.localizedDescription)")
            }
            lines += await Entra.consentLines(Entra.auditScopes, reading: true, service)
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }

    /// Any listed item, when only whether a listing can be read matters.
    struct IgnoredItem: Decodable {}
}
