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
        To investigate an account, start with user-timeline, everything it and admins did to it in one list. oauth-apps \
        lists every app people granted access in a window, by client ID and scopes, and app-activity what an app pulled; \
        Google Workspace Containment's tokens and apps list the access apps hold now. group-members shows who reads a \
        group, flagging outsiders, and devices every laptop, desktop and phone with its users and risks. Drive sharing \
        changes are drive events change_document_visibility, change_document_access_scope and change_user_access. When a \
        tool is refused or something you need seems missing, run check-access and tell the champion exactly what it says \
        to change. \
        Record each finding as evidence, citing the application, user \
        and time window. These tools only read: recommend suspending a user, signing them out, revoking a token or \
        changing sharing to the champion.
        """,
        iconName: "google-workspace",
        configuration: .connection(.init(endpointTemplate: "https://admin.googleapis.com",
            fields: [ToolField(key: "clientID", title: "Client ID", placeholder: "1234-abc.apps.googleusercontent.com", kind: .identifier)],
            // Read-only, as the tool only reads: audit reports, users, their admin roles, groups and devices.
            oauth: .google(scopes: ["https://www.googleapis.com/auth/admin.reports.audit.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.user.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.group.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.device.mobile.readonly",
                                    "https://www.googleapis.com/auth/cloud-identity.devices.readonly"], clients: []),
            oauthClientField: "clientID", adapter: "google-workspace")),
        setup: setup)

    static let setup = [
        "In the [Google Cloud console](https://console.cloud.google.com), pick or create a project in your organisation, and under **APIs & Services › Library** enable the **Admin SDK API** and the [Cloud Identity API](https://console.cloud.google.com/apis/library/cloudidentity.googleapis.com).",
        "Open **Google Auth Platform**, set it up with the audience **Internal**, and under **Data Access** add the scopes `https://www.googleapis.com/auth/admin.reports.audit.readonly`, `https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly`, `https://www.googleapis.com/auth/admin.directory.user.readonly`, `https://www.googleapis.com/auth/admin.directory.group.readonly`, `https://www.googleapis.com/auth/admin.directory.device.mobile.readonly` and `https://www.googleapis.com/auth/cloud-identity.devices.readonly`.",
        "Under **Clients**, choose **Create client** of the type **iOS** with the bundle ID `com.pdparchitect.pion` (`com.pdparchitect.pion.local` for Pion Dev), and copy its **Client ID** here.",
        "In the [Admin console](https://admin.google.com), under **Account › Admin roles**, create a role such as **Pion Audit** with only **Reports**, **Users › Read**, **Groups › Read**, read access to admin roles and to devices, and assign it to an admin account kept for Pion, never a super admin.",
        "Choose **Add & Connect** and sign in as that admin.",
    ]

    /// The Reports API turns away part of a burst of about 19 requests at once, well inside its per-minute quota.
    public static let adapter = OperationAdapter(operations: [Activity(), SecurityEvents(), AdminRoles(), Users(), UserGroups(), UserDevices(),
                                                              GroupMembers(), OAuthApps(), AppActivity(), UserTimeline(), Devices(), CheckAccess()], trigger: NewSecurityEvents(),
                                                 simultaneousRequests: 8)

    /// Suspending takes the broad user scope, as Google has none narrower; what the token can really do is set by the
    /// signing-in admin's role, which the setup keeps to suspending and User Security Management.
    public static let containment = ToolDefinition(
        id: "b04472f4-fbd5-496e-b286-fa76c23dd08f", name: "Google Workspace Containment",
        summary: "Sign a user out everywhere, revoke an app's access or an app password, and suspend or restore a user.",
        defaultInstructions: """
        Use Google Workspace Containment to see an account's state and contain it: user shows whether it is suspended, \
        an admin or enrolled in 2-step verification; tokens lists the apps it has granted access, with their scopes; \
        app-passwords lists its app passwords; apps lists every app holding access to any account now, by client ID, \
        with its scopes and holders; check-access says what to change when something is refused. sign-out, revoke-token, delete-app-password, suspend and unsuspend are held \
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

    /// Paced, as apps asks for each user's tokens in turn.
    public static let containmentAdapter = OperationAdapter(operations: [
        UserState(), Tokens(), Apps(), AppPasswords(), ContainmentCheckAccess(), SignOut(), RevokeToken(), DeleteAppPassword(), Suspend(), Unsuspend(),
    ], simultaneousRequests: 8)

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
        // An account taken over: its second factor or recovery changed, its mail sent elsewhere or copied, codes or a
        // mailbox dump made for someone else.
        ("user_accounts", "2sv_disable", nil), ("user_accounts", "recovery_email_edit", nil), ("user_accounts", "recovery_phone_edit", nil),
        ("user_accounts", "email_forwarding_out_of_domain", nil), ("user_accounts", "titanium_unenroll", nil),
        ("admin", "CREATE_EMAIL_MONITOR", nil), ("admin", "MAIL_ROUTING_DESTINATION_ADDED", nil), ("admin", "GENERATE_2SV_SCRATCH_CODES", nil),
        ("admin", "REQUEST_MAILBOX_DUMP", nil), ("admin", "CHANGE_RECOVERY_EMAIL", nil), ("admin", "ADD_RECOVERY_EMAIL", nil),
        ("login", "account_disabled_generic", nil),
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
        let items = try await read(.reports) { try await service.at(host: "admin.googleapis.com").get(
            ["admin", "reports", "v1", "activity", "users", user, "applications", application], query: query, as: Answer.self).items ?? [] }
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

    /// A Directory API request about one user, with Google's refusal said as what to change. User Security Management
    /// never covers admins, so it is refused for them whatever the role holds.
    static func directory<Answer>(_ user: String, _ path: [String] = [], need: Need = .security,
                                  _ request: ([String]) async throws -> Answer) async throws -> Answer {
        let path = ["admin", "directory", "v1", "users", try ServiceInput.email(user)] + path
        return try await read(need) { try await request(path) }
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
            let user = try await directory(input.user, need: .containmentUsers) { try await service.get($0, as: User.self) }
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
        _ = try await directory(user, need: .suspending) {
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
            let superAdmins = try await GoogleWorkspace.read(.users) {
                try await directory.get(base + ["users"], query: ["customer": "my_customer", "query": "isAdmin=true", "maxResults": "500"],
                                        as: Users.self).users ?? []
            }
            let (roles, assignments) = try await GoogleWorkspace.read(.adminRoles) { () async throws -> ([Role], [Assignment]) in
                (try await directory.get(base + ["customer", "my_customer", "roles"], query: ["maxResults": "100"], as: Roles.self).items ?? [],
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
        static let summary = "Accounts in the domain, optionally by search such as isEnrolledIn2Sv=false, isSuspended=true or orgUnitPath=/Finance, with admin, 2-step verification and its enforcement, recovery email and phone, aliases and last sign-in."
        static let input = JSONSchema.object([
            "query": .string("A Directory search, such as isEnrolledIn2Sv=false, isAdmin=true, isSuspended=false or email:m.okafor*. Everyone when left out."),
            "limit": .integer("How many accounts, at most.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 200
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 accounts.") }
            struct User: Codable {
                let primaryEmail: String?, isAdmin: Bool?, isDelegatedAdmin: Bool?, isEnrolledIn2Sv: Bool?, isEnforcedIn2Sv: Bool?, suspended: Bool?
                let lastLoginTime: String?, creationTime: String?, orgUnitPath: String?
                let recoveryEmail: String?, recoveryPhone: String?, aliases: [String]?, isGuestUser: Bool?, archived: Bool?
            }
            struct Listed: Codable { let users: [User]? }
            var query: [String: String?] = ["customer": "my_customer", "maxResults": String(limit), "viewType": "admin_view"]
            if let search = input.query?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
                guard search.count <= 500 else { throw ServiceError.input("Keep the search short.") }
                query["query"] = search
            }
            let users = try await GoogleWorkspace.read(.users) { try await service.at(host: "admin.googleapis.com")
                .get(["admin", "directory", "v1", "users"], query: query, as: Listed.self).users ?? [] }
            let text = users.isEmpty ? "No accounts match." : users.map { user in
                let twoStep = user.isEnrolledIn2Sv != true ? "2-step verification off" : user.isEnforcedIn2Sv == false ? "2-step verification not enforced" : nil
                var parts = [user.isAdmin == true ? "super admin" : user.isDelegatedAdmin == true ? "delegated admin" : nil, twoStep,
                             user.suspended == true ? "suspended" : nil, user.isGuestUser == true ? "guest" : nil, user.archived == true ? "archived" : nil]
                    .compactMap { $0 }
                if let unit = user.orgUnitPath { parts.append("in \(unit)") }
                // An attacker who takes an account over often points its recovery somewhere they control.
                let domains = Set(([user.primaryEmail] + (user.aliases ?? []).map { $0 }).compactMap { $0?.split(separator: "@").last?.lowercased() })
                if let recovery = user.recoveryEmail, !recovery.isEmpty {
                    let domain = recovery.split(separator: "@").last?.lowercased() ?? ""
                    if !domains.contains(domain) { parts.append("recovery email outside the domain: \(recovery)") }
                }
                if let phone = user.recoveryPhone, !phone.isEmpty { parts.append("recovery phone set") }
                if let aliases = user.aliases, !aliases.isEmpty { parts.append("aliases " + aliases.joined(separator: ", ")) }
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
            let groups = try await GoogleWorkspace.read(.groups) { try await service.at(host: "admin.googleapis.com")
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
            let devices = try await GoogleWorkspace.read(.mobileDevices) { try await service.at(host: "admin.googleapis.com")
                .get(["admin", "directory", "v1", "customer", "my_customer", "devices", "mobile"], query: ["query": "email:\(user)", "maxResults": "100"],
                     as: Listed.self).mobiledevices ?? [] }.filter { ($0.email ?? []).contains { $0.lowercased() == user } }
            let text = devices.isEmpty ? "\(user) syncs no mobile devices." : devices.map { device in
                "\(device.model ?? "A device") (\([device.os, device.type, device.status].compactMap { $0 }.joined(separator: ", "))), last synced \(device.lastSync ?? "?")"
                    + (device.deviceCompromisedStatus.map { $0 == "No compromise detected" || $0.isEmpty ? "" : ", \($0)" } ?? "")
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Listed(mobiledevices: devices))
        }
    }

    /// What one thing the tools read needs from the setup, to say exactly what to change when Google refuses it.
    struct Need: Sendable {
        let title: String, api: String, apiID: String, scope: String, privilege: String

        static let reports = Need(title: "Audit reports", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                  scope: "https://www.googleapis.com/auth/admin.reports.audit.readonly", privilege: "Reports")
        static let users = Need(title: "Users", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                scope: "https://www.googleapis.com/auth/admin.directory.user.readonly", privilege: "Users › Read")
        static let adminRoles = Need(title: "Admin roles", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                     scope: "https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly", privilege: "read access to admin roles")
        static let groups = Need(title: "Groups", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                 scope: "https://www.googleapis.com/auth/admin.directory.group.readonly", privilege: "Groups › Read")
        static let mobileDevices = Need(title: "Mobile devices", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                        scope: "https://www.googleapis.com/auth/admin.directory.device.mobile.readonly", privilege: "read access to devices")
        static let devices = Need(title: "Devices", api: "Cloud Identity API", apiID: "cloudidentity.googleapis.com",
                                  scope: "https://www.googleapis.com/auth/cloud-identity.devices.readonly", privilege: "read access to devices")
        static let containmentUsers = Need(title: "Users", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                           scope: "https://www.googleapis.com/auth/admin.directory.user", privilege: "Users › Read")
        static let security = Need(title: "Sessions, apps and app passwords", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                   scope: "https://www.googleapis.com/auth/admin.directory.user.security",
                                   privilege: "Security › User Security Management, which never covers admins,")
        static let suspending = Need(title: "Suspending", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                     scope: "https://www.googleapis.com/auth/admin.directory.user", privilege: "Users › Update › Suspend users")
    }

    /// What to change when Google refused something, from what it said: a scope the sign-in lacks, an API turned off in
    /// the project, a privilege the admin's role lacks, or a sign-in that expired; nil for any other failure.
    static func fix(for error: Error, _ need: Need) -> String? {
        let said: String
        switch error {
        case ServiceError.rejected: return "the sign-in expired or was revoked: sign the tool in again in Settings › Tools."
        case ServiceError.forbidden(let reason): said = reason ?? ""
        case ServiceError.refused(let reason): said = reason
        case ServiceError.status(_, let reason): said = reason ?? ""
        default: return nil
        }
        let lower = said.lowercased()
        if lower.contains("insufficient authentication scopes") || lower.contains("access_token_scope_insufficient") {
            return "the sign-in lacks the scope \(need.scope): add it under Google Auth Platform › Data Access if it is missing, then sign the tool in again in Settings › Tools."
        }
        if lower.contains("has not been used in project") || lower.contains("service_disabled") || lower.contains("it is disabled") {
            // Google names the page that turns it on, with the project.
            let link = said.range(of: #"https://\S+"#, options: .regularExpression).map { String(said[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)")) }
            return "the \(need.api) is turned off in the tool's Google Cloud project: enable it at \(link ?? "https://console.cloud.google.com/apis/library/" + need.apiID), then try again."
        }
        if case ServiceError.forbidden = error {
            return "the admin this tool signs in as may not do this: add \(need.privilege) to its role in the Admin console, or check the role is assigned to them."
        }
        return nil
    }

    /// A request, with Google's refusal said as what to change, so an agent can tell the champion.
    static func read<Value>(_ need: Need, _ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch {
            guard let fix = fix(for: error, need) else { throw error }
            throw ServiceError.input("Google refused \(need.title.lowercased()): \(fix) Running check-access shows everything this tool can and cannot do.")
        }
    }

    /// Each thing a tool reads, tried once with the smallest request it takes, as a checklist of what works and what to
    /// change for what does not.
    static func check(_ probes: [(Need, () async throws -> Void)]) async -> [String] {
        var lines: [String] = []
        for (need, probe) in probes {
            do { try await probe(); lines.append("✓ \(need.title)") }
            catch { lines.append("✗ \(need.title): " + (fix(for: error, need) ?? error.localizedDescription)) }
        }
        return lines
    }

    /// Tries each thing Google Workspace Audit reads and says how to fix what it cannot.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let summary = "Tries each thing this tool reads once and says what works and, for what does not, exactly what to change: a scope, an API or the admin's role. Run it when a tool is refused."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let admin = try service.at(host: "admin.googleapis.com"), identity = try service.at(host: "cloudidentity.googleapis.com")
            let directory = ["admin", "directory", "v1"]
            let lines = await GoogleWorkspace.check([
                (.reports, { _ = try await admin.data(["admin", "reports", "v1", "activity", "users", "all", "applications", "login"],
                                                      query: ["startTime": ServiceInput.daysAgo(1), "maxResults": "1"]) }),
                (.users, { _ = try await admin.data(directory + ["users"], query: ["customer": "my_customer", "maxResults": "1"]) }),
                (.adminRoles, { _ = try await admin.data(directory + ["customer", "my_customer", "roles"], query: ["maxResults": "1"]) }),
                (.groups, { _ = try await admin.data(directory + ["groups"], query: ["customer": "my_customer", "maxResults": "1"]) }),
                (.mobileDevices, { _ = try await admin.data(directory + ["customer", "my_customer", "devices", "mobile"], query: ["maxResults": "1"]) }),
                (.devices, { _ = try await identity.data(["v1", "devices"], query: ["customer": "customers/my_customer", "pageSize": "1"]) }),
            ])
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }

    /// Tries what Google Workspace Containment can safely: reading users and one user's tokens. Suspending changes an
    /// account, so it is only described.
    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let summary = "Tries reading users and one user's tokens and says what works and what to change for what does not; suspending is described, not tried. Run it when a tool is refused."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct User: Decodable { let primaryEmail: String? }
            struct Users: Decodable { let users: [User]? }
            let found = FoundUser()
            var lines = await GoogleWorkspace.check([
                (.containmentUsers, {
                    found.email = try await service.get(["admin", "directory", "v1", "users"], query: ["customer": "my_customer", "maxResults": "1"],
                                                        as: Users.self).users?.first?.primaryEmail
                }),
            ])
            if let email = found.email {
                lines += await GoogleWorkspace.check([(.security, { _ = try await service.data(["admin", "directory", "v1", "users", email, "tokens"]) })])
            } else {
                lines.append("· \(Need.security.title): not tried, as no user could be read.")
            }
            lines.append("· Suspending: can only be confirmed by suspending someone; the admin's role needs \(Need.suspending.privilege).")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }

        private final class FoundUser: @unchecked Sendable { var email: String? }
    }
}

// MARK: - Investigation

extension GoogleWorkspace {
    /// What a set of OAuth scopes lets an app do, the most dangerous first, or nil for nothing that reads data or administers.
    static func risk(_ scopes: [String]) -> (rank: Int, said: String)? {
        let held = Set(scopes.flatMap { $0.split(separator: " ").map(String.init) })
        let kinds: [(Int, String, (String) -> Bool)] = [
            (0, "administers the domain", { $0.contains("/auth/admin.") && !$0.hasSuffix(".readonly") }),
            (1, "reads and sends mail", { $0 == "https://mail.google.com/" || $0.hasSuffix("/gmail.modify") || $0.hasSuffix("/gmail.compose") }),
            (1, "reads mail", { $0.hasSuffix("/gmail.readonly") || $0.hasSuffix("/gmail.metadata") }),
            (2, "reads and changes every file", { $0.hasSuffix("/auth/drive") }),
            (2, "reads every file", { $0.hasSuffix("/auth/drive.readonly") }),
            (3, "full Google Cloud access", { $0.hasSuffix("/auth/cloud-platform") }),
            (4, "reads directory data", { $0.contains("/auth/admin.") }),
            (5, "reads and changes calendars", { $0.hasSuffix("/auth/calendar") }),
            (5, "reads contacts", { $0.contains("/auth/contacts") }),
        ]
        let found = kinds.filter { kind in held.contains(where: kind.2) }
        guard let rank = found.map(\.0).min() else { return nil }
        return (rank, found.map(\.1).joined(separator: ", "))
    }

    /// Who is in a group, and so reads what it receives, with members outside the domain flagged.
    struct GroupMembers: ServiceOperation {
        struct Input: Decodable, Sendable { let group: String }
        static let name = "group-members"
        static let summary = "Who is in a group, with their role, flagging members outside the domain."
        static let input = JSONSchema.object(["group": .string("The group's email address.")], required: ["group"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Member: Codable { let email: String?; let id: String?; let role: String?; let type: String?; let status: String? }
            struct Listed: Codable { let members: [Member]? }
            let group = try ServiceInput.email(input.group)
            let domain = group.split(separator: "@").last.map(String.init) ?? ""
            let members = try await GoogleWorkspace.read(.groups) { try await service.at(host: "admin.googleapis.com")
                .get(["admin", "directory", "v1", "groups", group, "members"], query: ["maxResults": "200"], as: Listed.self).members ?? [] }
            let text = members.isEmpty ? "\(group) has no members." : "\(group) (\(members.count)): " + members.map { member in
                if member.type == "CUSTOMER" { return "everyone in the domain" }
                let email = member.email ?? member.id ?? "?"
                var notes: [String] = []
                if member.type == "GROUP" { notes.append("group") }
                if let role = member.role, role != "MEMBER" { notes.append(role.lowercased()) }
                let theirs = email.split(separator: "@").last.map { $0.lowercased() == domain || $0.lowercased().hasSuffix("." + domain) } ?? true
                if !theirs { notes.append("outside the domain") }
                return email + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")
            }.joined(separator: ", ")
            return try ServiceResult(text: text, structured: Listed(members: members))
        }
    }

    /// Every app people granted access to their accounts in a window, from the token audit log, which keeps six months:
    /// its client ID, name, type and scopes, who granted it and who revoked it. The access apps hold now is
    /// Containment's apps.
    struct OAuthApps: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "oauth-apps"
        static let summary = "Every app people granted access to their accounts in a window, by client ID, with its scopes and who granted or revoked it, those that read mail or files or administer first."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 180 days when left out, as far back as Google keeps."),
            "until": .string("The latest time, in ISO 8601."),
        ])

        struct App: Encodable {
            let clientId: String, name: String, type: String?, scopes: [String], grantedBy: [String], revokedBy: [String], lastGranted: String?
            let risk: String?
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(180), "maxResults": "1000"]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            async let granted = GoogleWorkspace.events(service, application: "token", event: "authorize", query: query)
            async let revoked = GoogleWorkspace.events(service, application: "token", event: "revoke", query: query)
            let (grants, revokes) = try await (granted, revoked)
            let apps = Dictionary(grouping: grants) { $0.parameters["client_id"] ?? "?" }.map { client, events in
                let scopes = Array(Set(events.flatMap { ($0.parameters["scope"] ?? "").components(separatedBy: ", ") }.filter { !$0.isEmpty })).sorted()
                return App(clientId: client, name: events.compactMap { $0.parameters["app_name"] }.first ?? client,
                           type: events.compactMap { $0.parameters["client_type"] }.first, scopes: scopes,
                           grantedBy: Array(NSOrderedSet(array: events.compactMap(\.user))) as? [String] ?? [],
                           revokedBy: Array(NSOrderedSet(array: revokes.filter { $0.parameters["client_id"] == client }.compactMap(\.user))) as? [String] ?? [],
                           lastGranted: events.compactMap(\.time).max(), risk: GoogleWorkspace.risk(scopes)?.said)
            }.sorted { first, second in
                let ranks = (GoogleWorkspace.risk(first.scopes)?.rank ?? 9, GoogleWorkspace.risk(second.scopes)?.rank ?? 9)
                return ranks.0 != ranks.1 ? ranks.0 < ranks.1 : (first.grantedBy.count, second.name) > (second.grantedBy.count, first.name)
            }
            let text = apps.isEmpty ? "No app was granted access in this window." : apps.map { app in
                "\(app.name) (client \(app.clientId)\(app.type.map { ", \($0)" } ?? ""))" + (app.risk.map { ": \($0)" } ?? "")
                    + "; granted by \(app.grantedBy.joined(separator: ", ")), last \(app.lastGranted ?? "?")"
                    + (app.revokedBy.isEmpty ? "" : "; revoked by \(app.revokedBy.joined(separator: ", "))")
                    + "; scopes \(app.scopes.joined(separator: " "))"
            }.joined(separator: "\n")
            struct Kept: Encodable { let apps: [App] }
            return try ServiceResult(text: text, structured: Kept(apps: apps))
        }
    }

    /// What apps did with the access they were given: API calls and the data they pulled, by app, user and method.
    /// A large pull by one app on one account is how data leaves through an OAuth grant.
    struct AppActivity: ServiceOperation {
        struct Input: Decodable, Sendable { let clientId: String?, user: String?, since: String?, until: String? }
        static let name = "app-activity"
        static let summary = "API calls apps made on people's behalf and the data they pulled, by app, user and method, the largest first; by client ID, user or both."
        static let input = JSONSchema.object([
            "clientId": .string("Only this app, by its client ID from oauth-apps."),
            "user": .string("Only calls on behalf of this user's email."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7), "maxResults": "1000"]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            if let client = input.clientId { query["filters"] = "client_id==" + (try ServiceInput.quoted(client, "the client ID")) }
            let user = try input.user.map(ServiceInput.email) ?? "all"
            let calls = try await GoogleWorkspace.events(service, application: "token", user: user, event: "activity", query: query)
            struct Usage: Encodable { let app: String, clientId: String, user: String, method: String, calls: Int, bytes: Int }
            let usage = Dictionary(grouping: calls) { [$0.parameters["app_name"] ?? "?", $0.parameters["client_id"] ?? "?", $0.user ?? "?",
                                                      $0.parameters["method_name"] ?? "?"] }
                .map { key, events in
                    Usage(app: key[0], clientId: key[1], user: key[2], method: key[3], calls: events.count,
                          bytes: events.reduce(0) { $0 + (Int($1.parameters["num_response_bytes"] ?? "") ?? 0) })
                }.sorted { ($0.bytes, $0.calls) > ($1.bytes, $1.calls) }
            func size(_ bytes: Int) -> String {
                bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : bytes >= 1_000 ? String(format: "%.1f KB", Double(bytes) / 1_000) : "\(bytes) bytes"
            }
            let text = usage.isEmpty ? "No API calls by apps match." : usage.prefix(60).map {
                "\($0.app) (\($0.clientId)) as \($0.user): \($0.method) \($0.calls) call\($0.calls == 1 ? "" : "s"), \(size($0.bytes))"
            }.joined(separator: "\n") + (calls.count >= 1000 ? "\nOnly the first 1000 calls were read; narrow the window or name the app." : "")
            struct Kept: Encodable { let usage: [Usage] }
            return try ServiceResult(text: text, structured: Kept(usage: usage))
        }
    }

    /// One account's activity across the reports, and what admins did to it, merged newest first: where an
    /// investigation of an account starts.
    struct UserTimeline: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String, since: String?, until: String? }
        static let name = "user-timeline"
        static let summary = "Everything one account did, and admins did to it, newest first: sign-ins, account and recovery changes, app grants, Drive, SAML, devices, groups and admin actions."
        static let input = JSONSchema.object([
            "user": .string("The user's email."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601."),
        ], required: ["user"])
        static let applications = ["login", "user_accounts", "token", "drive", "admin", "saml", "mobile", "groups"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try ServiceInput.email(input.user)
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7), "maxResults": "200"]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            let asked = query, about = query.merging(["filters": "USER_EMAIL==\(user)"]) { $1 }
            let events = try await withThrowingTaskGroup(of: [Event].self) { group in
                for application in Self.applications {
                    group.addTask { try await GoogleWorkspace.events(service, application: application, user: user, query: asked) }
                }
                // What admins did to the account, as they are the actors there.
                group.addTask { try await GoogleWorkspace.events(service, application: "admin", query: about) }
                return try await group.reduce(into: [String: Event]()) { found, events in for event in events { found[event.id] = event } }
            }.values.sorted { ($0.time ?? "") > ($1.time ?? "") }
            let text = events.isEmpty ? "Nothing for \(user) in this window." : events.prefix(150).map { "\($0.application) \($0.line)" }.joined(separator: "\n")
                + (events.count > 150 ? "\n\(events.count - 150) more in the structured result." : "")
            struct Kept: Encodable { let events: [Event] }
            return try ServiceResult(text: text, structured: Kept(events: events))
        }
    }

    /// Every device the organisation knows, from Cloud Identity: laptops and desktops with Endpoint Verification,
    /// company-owned devices and phones, with who uses each, compromised, unencrypted or unmanaged ones first.
    struct Devices: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String? }
        static let name = "devices"
        static let summary = "Every laptop, desktop and phone the organisation knows, with who uses it and whether it is compromised, unencrypted or not approved; or only one user's."
        static let input = JSONSchema.object(["user": .string("Only this user's devices, by email.")])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Device: Codable {
                let name: String, deviceType: String?, model: String?, osVersion: String?, ownerType: String?, encryptionState: String?
                let managementState: String?, compromisedState: String?, lastSyncTime: String?, serialNumber: String?, hostname: String?
            }
            struct DevicePage: Decodable { let devices: [Device]?; let nextPageToken: String? }
            struct DeviceUser: Codable { let name: String; let userEmail: String?; let managementState: String?; let lastSyncTime: String? }
            struct UserPage: Decodable { let deviceUsers: [DeviceUser]?; let nextPageToken: String? }
            let identity = try service.at(host: "cloudidentity.googleapis.com")
            let user = try input.user.map(ServiceInput.email)
            var devices: [Device] = [], users: [DeviceUser] = [], token: String?
            try await GoogleWorkspace.read(.devices) {
                for _ in 0..<10 {
                    let page = try await identity.get(["v1", "devices"], query: ["customer": "customers/my_customer", "pageSize": "100", "pageToken": token],
                                                      as: DevicePage.self)
                    devices += page.devices ?? []
                    guard let next = page.nextPageToken, !next.isEmpty else { break }
                    token = next
                }
                token = nil
                // Twenty a page at most, so a large fleet is read in part.
                for _ in 0..<25 {
                    let page = try await identity.get(["v1", "devices", "-", "deviceUsers"],
                                                      query: ["customer": "customers/my_customer", "pageSize": "20", "pageToken": token], as: UserPage.self)
                    users += page.deviceUsers ?? []
                    guard let next = page.nextPageToken, !next.isEmpty else { break }
                    token = next
                }
            }
            let owners = Dictionary(grouping: users) { $0.name.components(separatedBy: "/deviceUsers/").first ?? "" }
            struct Kept: Encodable { let device: Device; let users: [String]; let risks: [String] }
            let kept = devices.map { device -> Kept in
                var risks: [String] = []
                if device.compromisedState == "COMPROMISED" { risks.append("compromised") }
                if device.encryptionState == "NOT_ENCRYPTED" { risks.append("not encrypted") }
                if let state = device.managementState, !["APPROVED"].contains(state) { risks.append(state.lowercased().replacingOccurrences(of: "_", with: " ")) }
                return Kept(device: device, users: (owners[device.name] ?? []).compactMap(\.userEmail), risks: risks)
            }.filter { item in user.map { email in item.users.contains { $0.lowercased() == email } } ?? true }
                .sorted { ($0.risks.contains("compromised") ? 0 : $0.risks.isEmpty ? 2 : 1, $0.device.model ?? "") < ($1.risks.contains("compromised") ? 0 : $1.risks.isEmpty ? 2 : 1, $1.device.model ?? "") }
            let text = kept.isEmpty ? (user.map { "\($0) uses no devices the organisation knows." } ?? "The organisation knows no devices.") : kept.map { item in
                let device = item.device
                let what = [device.deviceType, device.osVersion, device.ownerType.map { $0 == "COMPANY" ? "company-owned" : "personal" }].compactMap { $0 }.joined(separator: ", ")
                return "\(device.model ?? device.hostname ?? device.name) (\(what)), used by \(item.users.isEmpty ? "nobody listed" : item.users.joined(separator: ", "))"
                    + ", last synced \(device.lastSyncTime ?? "?")" + (item.risks.isEmpty ? "" : " [\(item.risks.joined(separator: ", "))]")
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: ["devices": kept])
        }
    }
}

extension GoogleWorkspace {
    /// The access apps hold now, across every account, from each user's tokens: what is still open after a breach,
    /// whatever the audit log has kept.
    struct Apps: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "apps"
        static let summary = "Every app holding access to accounts now, across all users, by client ID, with its scopes and holders, those that read mail or files or administer first."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct User: Decodable { let primaryEmail: String? }
            struct Users: Decodable { let users: [User]? }
            struct Token: Decodable { let clientId: String?; let displayText: String?; let scopes: [String]? }
            struct Tokens: Decodable { let items: [Token]? }
            let emails = try await read(.containmentUsers) {
                try await service.get(["admin", "directory", "v1", "users"], query: ["customer": "my_customer", "maxResults": "500"],
                                      as: Users.self).users?.compactMap(\.primaryEmail) ?? []
            }
            let held = try await withThrowingTaskGroup(of: (String, [Token]).self) { group in
                for email in emails {
                    group.addTask { (email, try await directory(email, ["tokens"]) { try await service.get($0, as: Tokens.self) }.items ?? []) }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }
            struct App: Encodable { let clientId: String, name: String, scopes: [String], holders: [String], risk: String? }
            let apps = Dictionary(grouping: held.flatMap { email, tokens in tokens.map { (email, $0) } }) { $0.1.clientId ?? "?" }.map { client, pairs in
                let scopes = Array(Set(pairs.flatMap { $0.1.scopes ?? [] })).sorted()
                return App(clientId: client, name: pairs.compactMap { $0.1.displayText }.first ?? client, scopes: scopes,
                           holders: Array(Set(pairs.map(\.0))).sorted(), risk: GoogleWorkspace.risk(scopes)?.said)
            }.sorted { first, second in
                let ranks = (GoogleWorkspace.risk(first.scopes)?.rank ?? 9, GoogleWorkspace.risk(second.scopes)?.rank ?? 9)
                return ranks.0 != ranks.1 ? ranks.0 < ranks.1 : (first.holders.count, second.name) > (second.holders.count, first.name)
            }
            let text = apps.isEmpty ? "No app holds access to any account." : apps.map { app in
                "\(app.name) (\(app.clientId))" + (app.risk.map { ": \($0)" } ?? "")
                    + "; held by \(app.holders.count) user\(app.holders.count == 1 ? "" : "s"): \(app.holders.joined(separator: ", ")); scopes \(app.scopes.joined(separator: " "))"
            }.joined(separator: "\n") + (emails.count >= 500 ? "\nOnly the first 500 accounts were read." : "")
            struct Kept: Encodable { let apps: [App] }
            return try ServiceResult(text: text, structured: Kept(apps: apps))
        }
    }
}

