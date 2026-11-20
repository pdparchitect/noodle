import Foundation
import NoodleCore
import NoodleMCP

/// Google Workspace's audit reports: sign-ins, admin actions, OAuth grants to apps, Drive and more, read as the admin
/// who signs in with Google, the way Noodle signs in to Gmail, through an iOS OAuth client their organisation made for
/// Pion's bundle ID. Each account is one admin's Workspace. Its Alert Center is not read: only a service account
/// acting for an admin may, and an admin's own sign-in is refused its scope. The audit events behind most of its alerts
/// are watched instead.
public enum GoogleWorkspace {
    static let applications = ["login", "admin", "token", "drive", "saml", "user_accounts", "groups", "mobile", "rules"]

    public static let preset = ToolDefinition(
        id: "8b1c8cc5-9be4-4be9-91fc-cb650f05d78c", name: "Google Workspace", summary: "Audit reports: sign-ins, admin actions, OAuth app grants and Drive activity.",
        defaultInstructions: """
        Use Google Workspace to see what happened in the domain: sign-ins, including suspicious ones and their IP \
        addresses; admin actions; OAuth tokens granted to apps; Drive sharing and downloads; SAML sign-ins; account changes. \
        Filter by user, event name, IP address and time; security-events lists those that mean an attack, such as \
        suspicious sign-ins, leaked passwords, admin privileges granted and compromised devices. Record each finding as evidence, citing the application, user \
        and time window. These tools only read: recommend suspending a user, revoking a token or changing sharing to the \
        champion.
        """,
        iconName: "google-workspace",
        configuration: .connection(.init(endpointTemplate: "https://admin.googleapis.com",
            fields: [ToolField(key: "clientID", title: "Client ID", placeholder: "1234-abc.apps.googleusercontent.com", kind: .identifier)],
            oauth: .google(scopes: ["https://www.googleapis.com/auth/admin.reports.audit.readonly"], clients: []),
            oauthClientField: "clientID", adapter: "google-workspace")),
        setup: setup)

    static let setup = [
        "In the [Google Cloud console](https://console.cloud.google.com), pick or create a project in your organisation, and under **APIs & Services › Library** enable the **Admin SDK API**.",
        "Open **Google Auth Platform**, set it up with the audience **Internal**, and under **Data Access** add the scope `https://www.googleapis.com/auth/admin.reports.audit.readonly`.",
        "Under **Clients**, choose **Create client** of the type **iOS** with the bundle ID `com.pdparchitect.pion` (`com.pdparchitect.pion.local` for Pion Dev), and copy its **Client ID** here.",
        "Choose **Add & Connect** and sign in as a super admin, or an admin whose role includes Reports.",
    ]

    public static let adapter = OperationAdapter(operations: [Activity(), SecurityEvents()], trigger: NewSecurityEvents())

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
