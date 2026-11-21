import Foundation
import NoodleCore
import NoodleToolConnections

/// Google Workspace's audit reports: sign-ins, admin actions, OAuth grants to apps, Drive and more, read as the admin
/// who signs in with Google, the way Noodle signs in to Gmail, through an iOS OAuth client their organisation made for
/// Pion's bundle ID. Each account is one admin's Workspace. Its Alert Center is not read: only a service account
/// acting for an admin may, and an admin's own sign-in is refused its scope. The audit events behind most of its alerts
/// are watched instead.
///
/// Containment is a second tool with a sign-in of its own, so only the bots given it can even ask for an action, and
/// the audit sign-in never carries a scope that can change accounts.
///
/// Why each tool asks for what it does, the least access to set each up with, and their caveats:
/// Incubator/Pion/docs/tools/google-workspace.md. Change it with the scopes, setup steps or operations here.
public enum GoogleWorkspace {
    /// The reports agents read: sign-ins and accounts, admin actions and app grants, what was opened, shared or sent,
    /// and what left the domain through Takeout and Vault exports.
    static let applications = ["login", "admin", "token", "drive", "saml", "user_accounts", "groups", "mobile", "rules", "gmail", "chat",
                               "meet", "calendar", "takeout", "vault", "context_aware_access", "chrome", "access_transparency", "gcp",
                               "data_studio"]

    public static let preset = ToolDefinition(
        id: "8b1c8cc5-9be4-4be9-91fc-cb650f05d78c", name: "Google Workspace Audit", summary: "Audit reports: sign-ins, admin actions, OAuth app grants and Drive activity.",
        defaultInstructions: """
        Use Google Workspace Audit to see what happened in the domain: sign-ins, including suspicious ones and their IP \
        addresses; admin actions; OAuth tokens granted to apps; Drive sharing and downloads; SAML sign-ins; account changes. \
        Filter by user, event name, IP address and time; security-events lists those that mean an attack, such as \
        suspicious sign-ins, leaked passwords, admin privileges granted and compromised devices. To audit who holds what, \
        admin-roles lists the super admins and every admin role with what it allows and who holds it. For a breach's \
        scope, users finds accounts by search, such as isEnrolledIn2Sv=false; user-groups and user-devices show what a user \
        reaches through groups and which phones hold their data; and the takeout and vault reports show what was exported. \
        Record each finding as evidence, citing the application, user \
        and time window. These tools only read: recommend suspending a user, signing them out, revoking a token or \
        changing sharing to the champion.
        """,
        iconName: "google-workspace",
        configuration: .connection(.init(endpointTemplate: "https://admin.googleapis.com",
            fields: [ToolField(key: "clientID", title: "Client ID", placeholder: "1234-abc.apps.googleusercontent.com", kind: .identifier)],
            // Read-only, as the tool only reads: audit reports, users, their admin roles, groups and mobile devices.
            oauth: .google(scopes: ["https://www.googleapis.com/auth/admin.reports.audit.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.user.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.group.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.device.mobile.readonly"], clients: []),
            oauthClientField: "clientID", adapter: "google-workspace")),
        setup: setup)

    static let setup = [
        "In the [Google Cloud console](https://console.cloud.google.com), pick or create a project in your organisation, and under **APIs & Services › Library** enable the **Admin SDK API**.",
        "Open **Google Auth Platform**, set it up with the audience **Internal**, and under **Data Access** add the scopes `https://www.googleapis.com/auth/admin.reports.audit.readonly`, `https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly`, `https://www.googleapis.com/auth/admin.directory.user.readonly`, `https://www.googleapis.com/auth/admin.directory.group.readonly` and `https://www.googleapis.com/auth/admin.directory.device.mobile.readonly`.",
        "Under **Clients**, choose **Create client** of the type **iOS** with the bundle ID `com.pdparchitect.pion` (`com.pdparchitect.pion.local` for Pion Dev), and copy its **Client ID** here.",
        "In the [Admin console](https://admin.google.com), under **Account › Admin roles**, create a role such as **Pion Audit** with only **Reports**, **Users › Read**, **Groups › Read**, read access to admin roles and to mobile devices, and assign it to an admin account kept for Pion, never a super admin.",
        "Choose **Add & Connect** and sign in as that admin.",
    ]

    /// The Reports API turns away part of a burst of about 19 requests at once, well inside its per-minute quota.
    public static let adapter = OperationAdapter(operations: [Activity(), SecurityEvents(), AdminRoles(), Users(), UserGroups(), UserDevices()], trigger: NewSecurityEvents(),
                                                 simultaneousRequests: 8)

    /// Suspending takes the broad user scope, as Google has none narrower; what the token can really do is set by the
    /// signing-in admin's role, which the setup keeps to suspending and User Security Management.
    public static let containment = ToolDefinition(
        id: "b04472f4-fbd5-496e-b286-fa76c23dd08f", name: "Google Workspace Containment",
        summary: "Sign a user out everywhere, revoke an app's access or an app password, and suspend or restore a user.",
        defaultInstructions: """
        Use Google Workspace Containment to see an account's state and contain it: user shows whether it is suspended, \
        an admin or enrolled in 2-step verification; tokens lists the apps it has granted access, with their scopes; \
        app-passwords lists its app passwords. sign-out, revoke-token, delete-app-password, suspend and unsuspend are held \
        for the champion's approval: give the exact user, and in --approval-reason why, the expected effect and how to undo \
        it, with the Investigation as --approval-conversation. Signing out alone leaves app access and the password working.
        """,
        iconName: "google-workspace",
        configuration: .connection(.init(endpointTemplate: "https://admin.googleapis.com",
            fields: [ToolField(key: "clientID", title: "Client ID", placeholder: "1234-abc.apps.googleusercontent.com", kind: .identifier)],
            oauth: .google(scopes: ["https://www.googleapis.com/auth/admin.directory.user",
                                    "https://www.googleapis.com/auth/admin.directory.user.security"], clients: []),
            oauthClientField: "clientID", adapter: "google-workspace-containment")),
        setup: containmentSetup)

    static let containmentSetup = [
        "In the [Admin console](https://admin.google.com), under **Account › Admin roles**, create a role such as **Pion Containment** with only **Users › Read**, **Users › Update › Suspend users** and **Security › User Security Management**.",
        "Assign it to an admin account kept for Pion, never a super admin. Its role, not the sign-in, limits what Pion can do.",
        "In the Google Cloud project of your Google Workspace Audit client, enable the **Admin SDK API** and add the scopes `https://www.googleapis.com/auth/admin.directory.user` and `https://www.googleapis.com/auth/admin.directory.user.security` under **Google Auth Platform › Data Access**.",
        "Paste that same iOS client's **Client ID** here, or create one of the type **iOS** with the bundle ID `com.pdparchitect.pion` (`com.pdparchitect.pion.local` for Pion Dev).",
        "If your organisation limits API access, mark the client **Trusted** under **Security › Access and data control › API controls**.",
        "Choose **Add & Connect** and sign in as the admin with the Pion Containment role.",
    ]

    public static let containmentAdapter = OperationAdapter(operations: [
        UserState(), Tokens(), AppPasswords(), SignOut(), RevokeToken(), DeleteAppPassword(), Suspend(), Unsuspend(),
    ])

    /// The audit events that mean an account or the domain may be under attack, each asked for by name as the Reports
    /// API takes one at a time, with a parameter value that makes one not count: Google's suspicious and blocked
    /// sign-ins and the accounts it disabled; admin privileges, the primary admin, single sign-on and 2-step
    /// verification changed; devices found compromised or acting suspiciously; and rules that fired above low.
    static let watched: [(application: String, event: String, unless: (parameter: String, value: String)?)] = [
        ("login", "suspicious_login", nil), ("login", "suspicious_login_less_secure_app", nil), ("login", "suspicious_programmatic_login", nil),
        ("login", "user_signed_out_due_to_suspicious_session_cookie", nil), ("login", "risky_sensitive_action_blocked", nil),
        ("login", "account_disabled_password_leak", nil), ("login", "account_disabled_hijacked", nil), ("login", "account_disabled_spamming", nil),
        ("login", "account_disabled_spamming_through_relay", nil), ("login", "gov_attack_warning", nil),
        ("admin", "GRANT_ADMIN_PRIVILEGE", nil), ("admin", "GRANT_DELEGATED_ADMIN_PRIVILEGES", nil),
        ("admin", "UPDATE_DOMAIN_PRIMARY_ADMIN_EMAIL", nil), ("admin", "CHANGE_SSO_SETTINGS", nil), ("admin", "TOGGLE_SSO_ENABLED", nil),
        ("admin", "TURN_OFF_2_STEP_VERIFICATION", nil),
        ("mobile", "DEVICE_COMPROMISED_EVENT", ("DEVICE_COMPROMISED_STATE", "NOT_COMPROMISED")), ("mobile", "SUSPICIOUS_ACTIVITY_EVENT", nil),
        ("rules", "rule_trigger", ("severity", "LOW")),
    ]

    /// One audit event, with what tells it from the rest: its report's ID for the activity it was part of, and its name.
    struct Event: Encodable {
        let id: String, time: String?, application: String, user: String?, ip: String?, event: String, parameters: [String: String]

        var line: String {
            var line = "\(time ?? "?") \(event)"
            if let user { line += " by \(user)" }
            if let ip { line += " from \(ip)" }
            let details = parameters.sorted { $0.key < $1.key }.prefix(4).map { "\($0.key)=\($0.value)" }
            if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
            return line
        }
    }

    /// A report's events, newest first, only those named `event` when it is given, as an activity may hold several.
    static func events(_ service: ServiceClient, application: String, user: String = "all", event: String? = nil,
                       query: [String: String?]) async throws -> [Event] {
        struct Parameter: Decodable {
            let name: String; let value: String?; let boolValue: Bool?; let intValue: String?; let multiValue: [String]?
            var shown: String? {
                value ?? boolValue.map(String.init) ?? intValue ?? multiValue?.joined(separator: ", ")
            }
        }
        struct Named: Decodable { let name: String?; let parameters: [Parameter]? }
        struct ID: Decodable { let time: String?; let uniqueQualifier: String? }
        struct Actor: Decodable { let email: String? }
        struct Item: Decodable { let id: ID?; let actor: Actor?; let ipAddress: String?; let events: [Named]? }
        struct Answer: Decodable { let items: [Item]? }
        var query = query
        if let event { query["eventName"] = event }
        let items = try await service.at(host: "admin.googleapis.com").get(
            ["admin", "reports", "v1", "activity", "users", user, "applications", application], query: query, as: Answer.self).items ?? []
        return items.flatMap { item in
            (item.events ?? []).compactMap { named -> Event? in
                guard let name = named.name, event == nil || name == event else { return nil }
                return Event(id: "\(application)/\(item.id?.uniqueQualifier ?? "?")/\(name)", time: item.id?.time, application: application,
                             user: item.actor?.email, ip: item.ipAddress, event: name,
                             parameters: Dictionary((named.parameters ?? []).compactMap { parameter in parameter.shown.map { (parameter.name, $0) } },
                                                    uniquingKeysWith: { first, _ in first }))
            }
        }
    }

    /// The watched events from `since` to `until`, newest first, up to `limit` of each.
    static func securityEvents(_ service: ServiceClient, since: String, until: String?, limit: Int) async throws -> [Event] {
        try await withThrowingTaskGroup(of: [Event].self) { group in
            for watched in watched {
                group.addTask {
                    try await events(service, application: watched.application, event: watched.event,
                                     query: ["startTime": since, "endTime": until, "maxResults": String(limit)])
                        .filter { event in watched.unless.map { event.parameters[$0.parameter] != $0.value } ?? true }
                }
            }
            return try await group.reduce(into: []) { $0 += $1 }.sorted { ($0.time ?? "") > ($1.time ?? "") }
        }
    }
}

extension GoogleWorkspace {
    struct Activity: ServiceOperation {
        struct Input: Decodable, Sendable { let application: String, user: String?, eventName: String?, ip: String?, since: String?, until: String?, limit: Int? }
        static let name = "activity"
        static let summary = "Audit events of one application, newest first, by user, event name, IP address and time, with each event's parameters."
        static let input = JSONSchema.object([
            "application": .string("Which report.", oneOf: GoogleWorkspace.applications),
            "user": .string("The user's email. Everyone when left out."),
            "eventName": .string("An event, such as login_failure, suspicious_login, authorize or download."),
            "ip": .string("Only events from this IP address."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601."), "limit": .integer("How many events, at most.", minimum: 1, maximum: 500),
        ], required: ["application"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let application = try ServiceInput.oneOf(input.application, GoogleWorkspace.applications, "application")
            let user = try input.user.map(ServiceInput.email) ?? "all"
            let limit = input.limit ?? 100
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 events.") }
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7),
                                            "maxResults": String(limit)]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            if let event = input.eventName { query["eventName"] = try ServiceInput.quoted(event, "the event name") }
            if let ip = input.ip { query["actorIpAddress"] = try ServiceInput.ip(ip) }
            struct Events: Encodable { let events: [Event] }
            let events = try await GoogleWorkspace.events(service, application: application, user: user, query: query)
            let text = events.isEmpty ? "No \(application) events match." : events.prefix(30).map(\.line).joined(separator: "\n")
            return try ServiceResult(text: text, structured: Events(events: events))
        }
    }

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "security-events"
        static let summary = "The audit events that mean an attack, newest first: suspicious and blocked sign-ins, accounts Google disabled, government-backed attack warnings, admin privileges, primary admin, SSO and 2-step verification changes, compromised devices and rules that fired above low."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out."),
            "until": .string("The latest time, in ISO 8601."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let since = try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(1)
            let events = try await GoogleWorkspace.securityEvents(service, since: since, until: try input.until.map(ServiceInput.time), limit: 100)
            let text = events.isEmpty ? "No security events in this window." : events.prefix(50).map(\.line).joined(separator: "\n")
                + (events.count > 50 ? "\n\(events.count - 50) more; narrow the window." : "")
            struct Kept: Encodable { let events: [Event] }
            return try ServiceResult(text: text, structured: Kept(events: events))
        }
    }

    /// Each watched event from `since` on. Google lists some audit events minutes to hours after their time.
    struct NewSecurityEvents: ServiceTrigger {
        var tool: String { SecurityEvents.name }
        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            try await GoogleWorkspace.securityEvents(service, since: ISO8601DateFormatter().string(from: since), until: nil, limit: ServiceAlert.most)
                .prefix(ServiceAlert.most).compactMap { event in ServiceAlert.time(event.time).map { ServiceAlert(id: event.id, time: $0) } }
        }
    }
}

// MARK: - Containment

extension GoogleWorkspace {
    struct UserInput: Decodable, Sendable { let user: String }
    static let userSchema = JSONSchema.object(["user": .string("The user's primary email address.")], required: ["user"])

    /// A Directory API request about one user, with Google's refusals explained by the role they come from.
    static func directory<Answer>(_ user: String, _ path: [String] = [], _ request: ([String]) async throws -> Answer) async throws -> Answer {
        let path = ["admin", "directory", "v1", "users", try ServiceInput.email(user)] + path
        do { return try await request(path) }
        catch ServiceError.forbidden {
            throw ServiceError.input("""
                Google refused this for \(user): the admin this tool signs in as may not do it. Its role needs Users › Read and \
                Users › Update › Suspend users for a user's state and suspending, and Security › User Security Management for \
                sessions, apps and app passwords; User Security Management never covers admins. Ask the champion to check the role.
                """)
        }
    }

    struct UserState: ServiceOperation {
        typealias Input = UserInput
        static let name = "user"
        static let summary = "Whether a user is suspended, an admin or enrolled in 2-step verification, their organisational unit and last sign-in."
        static let input = userSchema

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            struct Name: Codable { let fullName: String? }
            struct User: Codable {
                let primaryEmail: String?, name: Name?, suspended: Bool?, suspensionReason: String?, isAdmin: Bool?, isDelegatedAdmin: Bool?
                let isEnrolledIn2Sv: Bool?, lastLoginTime: String?, orgUnitPath: String?
            }
            let user = try await directory(input.user) { try await service.get($0, as: User.self) }
            var parts = [user.suspended == true ? "suspended" + (user.suspensionReason.map { " (\($0))" } ?? "") : "active"]
            if user.isAdmin == true { parts.append("super admin") } else if user.isDelegatedAdmin == true { parts.append("delegated admin") }
            parts.append(user.isEnrolledIn2Sv == true ? "2-step verification on" : "2-step verification off")
            if let unit = user.orgUnitPath { parts.append("in \(unit)") }
            // Google gives the epoch for an account that never signed in.
            if let last = user.lastLoginTime, !last.hasPrefix("1970") { parts.append("last signed in \(last)") }
            let who = [user.name?.fullName, user.primaryEmail.map { "<\($0)>" }].compactMap { $0 }.joined(separator: " ")
            return try ServiceResult(text: "\(who.isEmpty ? input.user : who): \(parts.joined(separator: ", ")).", structured: user)
        }
    }

    struct Tokens: ServiceOperation {
        typealias Input = UserInput
        static let name = "tokens"
        static let summary = "The apps a user has granted access to their account, with each app's client ID and scopes."
        static let input = userSchema

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            struct Token: Codable { let clientId: String?, displayText: String?, scopes: [String]?, nativeApp: Bool? }
            struct Answer: Codable { let items: [Token]? }
            let tokens = try await directory(input.user, ["tokens"]) { try await service.get($0, as: Answer.self) }.items ?? []
            let text = tokens.isEmpty ? "\(input.user) has granted no apps access." : tokens.map { token in
                "\(token.displayText ?? "An app") (\(token.clientId ?? "?")): \((token.scopes ?? []).joined(separator: ", "))"
            }.joined(separator: "\n")
            struct Kept: Encodable { let tokens: [Token] }
            return try ServiceResult(text: text, structured: Kept(tokens: tokens))
        }
    }

    struct AppPasswords: ServiceOperation {
        typealias Input = UserInput
        static let name = "app-passwords"
        static let summary = "A user's app passwords, which sign in without 2-step verification, with when each was made and last used."
        static let input = userSchema

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            struct Password: Codable { let codeId: Int?, name: String?, creationTime: String?, lastTimeUsed: String? }
            struct Answer: Codable { let items: [Password]? }
            let passwords = try await directory(input.user, ["asps"]) { try await service.get($0, as: Answer.self) }.items ?? []
            func time(_ milliseconds: String?) -> String {
                guard let value = milliseconds.flatMap(Double.init), value > 0 else { return "never" }
                return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: value / 1000))
            }
            let text = passwords.isEmpty ? "\(input.user) has no app passwords." : passwords.map {
                "\($0.codeId.map(String.init) ?? "?"): \($0.name ?? "unnamed"), made \(time($0.creationTime)), last used \(time($0.lastTimeUsed))"
            }.joined(separator: "\n")
            struct Kept: Encodable { let appPasswords: [Password] }
            return try ServiceResult(text: text, structured: Kept(appPasswords: passwords))
        }
    }

    /// Ends every web and device session and resets sign-in cookies; app access and the password keep working.
    struct SignOut: ServiceOperation {
        typealias Input = UserInput
        static let name = "sign-out"
        static let summary = "Sign a user out of every web and device session."
        static let input = userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            _ = try await directory(input.user, ["signOut"]) { try await service.data($0, method: "POST") }
            return try ServiceResult(text: "Signed \(input.user) out of every session.", structured: ["user": input.user])
        }
    }

    struct RevokeToken: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String, clientId: String }
        static let name = "revoke-token"
        static let summary = "Revoke every token a user granted one app, by its client ID from tokens."
        static let input = JSONSchema.object(["user": .string("The user's primary email address."),
                                              "clientId": .string("The app's client ID, as tokens lists it.")], required: ["user", "clientId"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            _ = try await directory(input.user, ["tokens", input.clientId]) { try await service.data($0, method: "DELETE") }
            return try ServiceResult(text: "Revoked \(input.clientId)'s access to \(input.user).", structured: ["user": input.user, "clientId": input.clientId])
        }
    }

    struct DeleteAppPassword: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String, codeId: Int }
        static let name = "delete-app-password"
        static let summary = "Delete one of a user's app passwords, by its ID from app-passwords."
        static let input = JSONSchema.object(["user": .string("The user's primary email address."),
                                              "codeId": .integer("The app password's ID, as app-passwords lists it.", minimum: 0)],
                                             required: ["user", "codeId"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            _ = try await directory(input.user, ["asps", String(input.codeId)]) { try await service.data($0, method: "DELETE") }
            return try ServiceResult(text: "Deleted app password \(input.codeId) of \(input.user).", structured: ["user": input.user])
        }
    }

    /// Suspending blocks sign-in and ends access; unsuspend undoes it, and is as serious, as it could let an attacker back in.
    struct Suspend: ServiceOperation {
        typealias Input = UserInput
        static let name = "suspend"
        static let summary = "Suspend a user, so they cannot sign in until restored with unsuspend."
        static let input = userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            try await suspended(true, input.user, on: service)
            return try ServiceResult(text: "Suspended \(input.user). Restore them with unsuspend.", structured: ["user": input.user])
        }
    }

    struct Unsuspend: ServiceOperation {
        typealias Input = UserInput
        static let name = "unsuspend"
        static let summary = "Restore a suspended user."
        static let input = userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            try await suspended(false, input.user, on: service)
            return try ServiceResult(text: "Restored \(input.user).", structured: ["user": input.user])
        }
    }

    static func suspended(_ suspended: Bool, _ user: String, on service: ServiceClient) async throws {
        _ = try await directory(user) {
            try await service.data($0, method: "PATCH", body: try JSONEncoder().encode(["suspended": suspended]))
        }
    }
}

// MARK: - Who holds what

extension GoogleWorkspace {
    /// The super admins, then every admin role someone holds, with its privileges and its holders, from the Directory
    /// API's read-only scopes. A delegated admin is named by asking for them; a group holding a role is named by its ID.
    struct AdminRoles: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "admin-roles"
        static let summary = "The super admins, and every admin role with what it allows and who holds it."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let directory = try service.at(host: "admin.googleapis.com")
            let base = ["admin", "directory", "v1"]
            struct User: Codable { let id: String; let primaryEmail: String?; let isEnrolledIn2Sv: Bool?; let suspended: Bool? }
            struct Users: Decodable { let users: [User]? }
            struct Privilege: Codable { let privilegeName: String }
            struct Role: Codable { let roleId: String; let roleName: String?; let isSuperAdminRole: Bool?; let rolePrivileges: [Privilege]? }
            struct Roles: Decodable { let items: [Role]? }
            struct Assignment: Codable { let roleId: String; let assignedTo: String; let assigneeType: String?; let scopeType: String? }
            struct Assignments: Decodable { let items: [Assignment]? }
            let (superAdmins, roles, assignments) = try await GoogleWorkspace.directoryRead { () async throws -> ([User], [Role], [Assignment]) in
                (try await directory.get(base + ["users"], query: ["customer": "my_customer", "query": "isAdmin=true", "maxResults": "500"],
                                         as: Users.self).users ?? [],
                 try await directory.get(base + ["customer", "my_customer", "roles"], query: ["maxResults": "100"], as: Roles.self).items ?? [],
                 try await directory.get(base + ["customer", "my_customer", "roleassignments"], query: ["maxResults": "200"],
                                         as: Assignments.self).items ?? [])
            }
            var names = Dictionary(superAdmins.map { ($0.id, $0.primaryEmail ?? $0.id) }, uniquingKeysWith: { first, _ in first })
            for id in Set(assignments.filter { $0.assigneeType != "group" }.map(\.assignedTo)).subtracting(names.keys).sorted().prefix(100) {
                names[id] = (try? await directory.get(base + ["users", id], as: User.self).primaryEmail) ?? id
            }
            func holder(_ assignment: Assignment) -> String {
                let who = assignment.assigneeType == "group" ? "group \(assignment.assignedTo)" : names[assignment.assignedTo] ?? assignment.assignedTo
                return who + (assignment.scopeType == "ORG_UNIT" ? " (in one organisational unit)" : "")
            }
            struct Held: Encodable { let role: String; let superAdmin: Bool; let privileges: [String]; let holders: [String] }
            let held = roles.compactMap { role -> Held? in
                let holders = assignments.filter { $0.roleId == role.roleId }.map(holder)
                guard !holders.isEmpty, role.isSuperAdminRole != true else { return nil }
                return Held(role: role.roleName ?? role.roleId, superAdmin: false, privileges: (role.rolePrivileges ?? []).map(\.privilegeName), holders: holders)
            }
            let admins = superAdmins.map { user in
                (user.primaryEmail ?? user.id) + (user.isEnrolledIn2Sv == false ? " (2-step verification off)" : "") + (user.suspended == true ? " (suspended)" : "")
            }
            var lines = ["Super admins (\(admins.count)): " + (admins.isEmpty ? "none listed" : admins.joined(separator: ", "))]
            lines += held.map { role in
                let privileges = role.privileges.prefix(12).joined(separator: ", ") + (role.privileges.count > 12 ? " and \(role.privileges.count - 12) more" : "")
                return "\(role.role) (\(role.holders.count)): \(role.holders.joined(separator: ", ")); allows \(privileges.isEmpty ? "nothing listed" : privileges)"
            }
            struct Kept: Encodable { let superAdmins: [String]; let roles: [Held] }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(superAdmins: superAdmins.map { $0.primaryEmail ?? $0.id }, roles: held))
        }
    }
}

// MARK: - Breach scope

extension GoogleWorkspace {
    /// Accounts in the domain, by the Directory's own search, with what matters when one may be compromised.
    struct Users: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String?, limit: Int? }
        static let name = "users"
        static let summary = "Accounts in the domain, optionally by search such as isEnrolledIn2Sv=false, isSuspended=true or orgUnitPath=/Finance, with admin, 2-step verification and last sign-in."
        static let input = JSONSchema.object([
            "query": .string("A Directory search, such as isEnrolledIn2Sv=false, isAdmin=true, isSuspended=false or email:m.okafor*. Everyone when left out."),
            "limit": .integer("How many accounts, at most.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 200
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 accounts.") }
            struct User: Codable {
                let primaryEmail: String?, isAdmin: Bool?, isDelegatedAdmin: Bool?, isEnrolledIn2Sv: Bool?, suspended: Bool?
                let lastLoginTime: String?, creationTime: String?, orgUnitPath: String?
            }
            struct Listed: Codable { let users: [User]? }
            var query: [String: String?] = ["customer": "my_customer", "maxResults": String(limit), "viewType": "admin_view"]
            if let search = input.query?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
                guard search.count <= 500 else { throw ServiceError.input("Keep the search short.") }
                query["query"] = search
            }
            let users = try await GoogleWorkspace.directoryRead { try await service.at(host: "admin.googleapis.com")
                .get(["admin", "directory", "v1", "users"], query: query, as: Listed.self).users ?? [] }
            let text = users.isEmpty ? "No accounts match." : users.map { user in
                var parts = [user.isAdmin == true ? "super admin" : user.isDelegatedAdmin == true ? "delegated admin" : nil,
                             user.isEnrolledIn2Sv == true ? nil : "2-step verification off", user.suspended == true ? "suspended" : nil].compactMap { $0 }
                if let unit = user.orgUnitPath { parts.append("in \(unit)") }
                parts.append(user.lastLoginTime.map { $0.hasPrefix("1970") ? "never signed in" : "last signed in \($0)" } ?? "")
                return "\(user.primaryEmail ?? "?"): " + parts.filter { !$0.isEmpty }.joined(separator: ", ")
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Listed(users: users))
        }
    }

    /// The groups a user is in: what they reach through shared drives, mailing lists and access granted to groups.
    struct UserGroups: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-groups"
        static let summary = "The groups a user is a member of, and so the shared drives, lists and access granted to them."
        static let input = userSchema

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Group: Codable { let id: String?; let email: String?; let name: String?; let directMembersCount: String? }
            struct Listed: Codable { let groups: [Group]? }
            let user = try ServiceInput.email(input.user)
            let groups = try await GoogleWorkspace.directoryRead { try await service.at(host: "admin.googleapis.com")
                .get(["admin", "directory", "v1", "groups"], query: ["userKey": user, "maxResults": "200"], as: Listed.self).groups ?? [] }
            let text = groups.isEmpty ? "\(user) is in no groups." : "\(user) is in: " + groups.map {
                "\($0.name ?? $0.email ?? "?") <\($0.email ?? "?")>" + ($0.directMembersCount.map { " (\($0) members)" } ?? "")
            }.joined(separator: ", ")
            return try ServiceResult(text: text, structured: Listed(groups: groups))
        }
    }

    /// The phones and tablets that sync a user's mail and files, which keep their data after a password change.
    /// Company-owned devices are in Cloud Identity instead and are not listed.
    struct UserDevices: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-devices"
        static let summary = "The phones and tablets that sync a user's mail and files, with their model, OS, status, last sync and whether Google finds them compromised."
        static let input = userSchema

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Device: Codable {
                let resourceId: String?, email: [String]?, model: String?, os: String?, type: String?, status: String?
                let firstSync: String?, lastSync: String?, deviceCompromisedStatus: String?
            }
            struct Listed: Codable { let mobiledevices: [Device]? }
            let user = try ServiceInput.email(input.user)
            // The search matches addresses that start the same too, so only this user's are kept.
            let devices = try await GoogleWorkspace.directoryRead { try await service.at(host: "admin.googleapis.com")
                .get(["admin", "directory", "v1", "customer", "my_customer", "devices", "mobile"], query: ["query": "email:\(user)", "maxResults": "100"],
                     as: Listed.self).mobiledevices ?? [] }.filter { ($0.email ?? []).contains { $0.lowercased() == user } }
            let text = devices.isEmpty ? "\(user) syncs no mobile devices." : devices.map { device in
                "\(device.model ?? "A device") (\([device.os, device.type, device.status].compactMap { $0 }.joined(separator: ", "))), last synced \(device.lastSync ?? "?")"
                    + (device.deviceCompromisedStatus.map { $0 == "No compromise detected" || $0.isEmpty ? "" : ", \($0)" } ?? "")
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Listed(mobiledevices: devices))
        }
    }

    /// A read of the Directory, with Google's refusal explained by what the Audit admin's role lacks.
    static func directoryRead<Value>(_ read: () async throws -> Value) async throws -> Value {
        do { return try await read() } catch ServiceError.forbidden {
            throw ServiceError.input("""
                Google refused: the admin this tool signs in as may not read this. Its role needs Users › Read, Groups › Read and \
                read access to admin roles and mobile devices besides Reports. Ask the champion to add them, and to sign the tool \
                in again if it was connected before it asked for the Directory scopes.
                """)
        }
    }
}

