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
        To investigate an account, start with user-timeline, everything it and admins did to it in one list; to follow an \
        address, ip-activity; for a deleted account, users with deleted true gives the profile ID to read its history by. \
        activity filters on an event's details, such as doc_id== for who opened a file or client_id== for an app. oauth-apps \
        lists every app people granted access in a window, by client ID and scopes, and app-activity what an app pulled; \
        Google Workspace Containment's tokens and apps list the access apps hold now. group-members shows who reads a \
        group, flagging outsiders. Drive sharing \
        changes are drive events change_document_visibility, change_document_access_scope and change_user_access. When a \
        tool is refused or something you need seems missing, run check-access and tell the champion exactly what it says \
        to change. Silence is not proof: Google lists events minutes to hours late, keeps most for 180 days, and Gmail \
        events only in windows of 30 days; results say what was cut short or could not be read. This tool cannot see \
        current mail forwarding addresses, filters or delegates, laptops and desktops, or Google's Alert Center: use \
        Proofpoint or Microsoft Defender for mail and CrowdStrike or Defender for endpoints, and say what you could not check. \
        Record each finding as evidence, citing the application, user \
        and time window. These tools only read: recommend suspending a user, signing them out, revoking a token or \
        changing sharing to the champion.
        """,
        iconName: "google-workspace",
        configuration: .connection(.init(endpointTemplate: "https://admin.googleapis.com",
            fields: [ToolField(key: "clientID", title: "Client ID", placeholder: "1234-abc.apps.googleusercontent.com", kind: .identifier)],
            // Read-only, as the tool only reads: audit reports, users, their admin roles, groups and mobile devices. Laptops and
            // desktops are in Cloud Identity's device API, which takes only a service account with domain-wide delegation.
            oauth: .google(scopes: ["https://www.googleapis.com/auth/admin.reports.audit.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.user.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.group.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.device.mobile.readonly"], clients: []),
            oauthClientField: "clientID", adapter: "google-workspace")),
        setup: setup)

    static let setup = [
        "In the [Google Cloud console](https://console.cloud.google.com), pick or create a project in your organisation, and enable the [Admin SDK API](https://console.cloud.google.com/apis/library/admin.googleapis.com) in it.",
        "Set up [Google Auth Platform](https://console.cloud.google.com/auth/overview) with the audience **Internal**, and under [Data Access](https://console.cloud.google.com/auth/scopes) add the scopes `https://www.googleapis.com/auth/admin.reports.audit.readonly`, `https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly`, `https://www.googleapis.com/auth/admin.directory.user.readonly`, `https://www.googleapis.com/auth/admin.directory.group.readonly` and `https://www.googleapis.com/auth/admin.directory.device.mobile.readonly`. Data Access takes a scope only once its API is enabled.",
        "Under [Clients](https://console.cloud.google.com/auth/clients), choose **Create client** of the type **iOS** with the bundle ID `com.pdparchitect.pion` (`com.pdparchitect.pion.local` for Pion Dev), and copy its **Client ID** here.",
        "In the Admin console's [Admin roles](https://admin.google.com/ac/roles), create a role such as **Pion Audit** with only **Reports**, **Users › Read**, **Groups › Read**, read access to admin roles and to devices, and assign it to an admin account kept for Pion, never a super admin.",
        "Choose **Add & Connect** and sign in as that admin.",
    ]

    /// The Reports API turns away part of a burst of about 19 requests at once, well inside its per-minute quota.
    public static let adapter = OperationAdapter(operations: [Activity(), SecurityEvents(), AdminRoles(), Users(), UserGroups(), UserDevices(),
                                                              GroupMembers(), OAuthApps(), AppActivity(), UserTimeline(), IPActivity(), CheckAccess()], trigger: NewSecurityEvents(),
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
        with its scopes and holders; check-access says what to change when something is refused. User Security Management \
        never covers admins, so tokens, app passwords, sign-out, revoke-token and delete-app-password are refused for an \
        admin: contain one with suspend, or ask the champion to act in the Admin console. sign-out, revoke-token, delete-app-password, suspend and unsuspend are held \
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
        "In the Admin console's [Admin roles](https://admin.google.com/ac/roles), create a role such as **Pion Containment** with only **Users › Read**, **Users › Update › Suspend users** and **Security › User Security Management**.",
        "Assign it to an admin account kept for Pion, never a super admin. Its role, not the sign-in, limits what Pion can do.",
        "In the Google Cloud project of your Google Workspace Audit client, check the [Admin SDK API](https://console.cloud.google.com/apis/library/admin.googleapis.com) is enabled and add the scopes `https://www.googleapis.com/auth/admin.directory.user` and `https://www.googleapis.com/auth/admin.directory.user.security` under [Data Access](https://console.cloud.google.com/auth/scopes).",
        "Paste that same iOS client's **Client ID** here, or create one under [Clients](https://console.cloud.google.com/auth/clients) of the type **iOS** with the bundle ID `com.pdparchitect.pion` (`com.pdparchitect.pion.local` for Pion Dev).",
        "If your organisation limits API access, mark the client **Trusted** in the Admin console's [API controls](https://admin.google.com/ac/owl).",
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

    /// One audit event. Its ID is the report, the record's time and qualifier, which Google gives to tell records at the
    /// same time apart, the event's name and its place in the record, so no two events are taken for one.
    struct Event: Encodable {
        let id: String, time: String?, application: String, user: String?, ip: String?, event: String, parameters: [String: String]
        /// Where the address is, as Google places it: its autonomous system and region.
        var asn: String? = nil, region: String? = nil
        /// The app that acted for the user, when one did.
        var via: String? = nil

        /// The details that matter for each kind of event, shown before the rest.
        static let keyDetails = [
            "doc_title", "target_user", "visibility", "old_visibility", "new_value", "old_value", "target_domain", "owner", "doc_id",
            "app_name", "client_id", "scope", "client_type", "api_name", "method_name", "num_response_bytes",
            "login_type", "login_challenge_method", "login_challenge_status", "is_suspicious", "is_second_factor", "sensitive_action_name",
            "USER_EMAIL", "SETTING_NAME", "NEW_VALUE", "OLD_VALUE", "EMAIL_MONITOR_DEST_EMAIL", "email_forwarding_destination_address",
            "affected_email_address", "event_info.mail_event_type",
        ]

        var line: String {
            var line = "\(time ?? "?") \(event)"
            if let user { line += " by \(user)" }
            if let via { line += " via \(via)" }
            if let ip { line += " from \(ip)" + ([asn.map { "AS\($0)" }, region].compactMap { $0 }.isEmpty ? "" : " (\([asn.map { "AS\($0)" }, region].compactMap { $0 }.joined(separator: ", ")))") }
            let rank = Dictionary(Self.keyDetails.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let details = parameters.sorted { (rank[$0.key] ?? Int.max, $0.key) < (rank[$1.key] ?? Int.max, $1.key) }.prefix(8)
                .map { "\($0.key)=\($0.value.count > 160 ? String($0.value.prefix(160)) + "…" : $0.value)" }
            if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
            return line
        }
    }

    /// Events read from one report, and whether the report had more than were read.
    struct EventPage { var events: [Event]; var more: Bool }

    /// An event's details as Google sends them: values, lists, and details nested inside details, as Gmail's are.
    fileprivate struct Parameter: Decodable {
        struct Message: Decodable { let parameter: [Parameter]? }
        let name: String?, value: String?, boolValue: Bool?, intValue: String?, multiValue: [String]?, multiIntValue: [String]?
        let messageValue: Message?, multiMessageValue: [Message]?

        /// Each value by its name, nested ones as parent.child.
        func flattened(under prefix: String = "") -> [(String, String)] {
            let key = prefix + (name ?? "?")
            if let shown = value ?? boolValue.map(String.init) ?? intValue ?? multiValue?.joined(separator: ", ")
                ?? multiIntValue?.joined(separator: ", ") {
                return [(key, key == "event_info.mail_event_type" ? GoogleWorkspace.mailEvent(shown) : shown)]
            }
            let nested = (messageValue.map { [$0] } ?? []) + (multiMessageValue ?? [])
            return nested.flatMap { message in (message.parameter ?? []).flatMap { $0.flattened(under: key + ".") } }
        }
    }

    /// What a Gmail event type means, for the ones Google's Gmail event page names; the number alone for the rest.
    static func mailEvent(_ code: String) -> String {
        let said = ["1": "sent", "2": "received", "4": "flagged as spam after delivery", "10": "forwarded for the first time",
                    "11": "autoforwarded by a forwarding setting", "33": "read by an app for the user", "34": "receive rate limited",
                    "35": "send started by the user or an app"][code]
        return said.map { "\(code) (\($0))" } ?? code
    }

    /// A report's events, newest first, only those named `event` when it is given, reading page after page up to
    /// `limit`. A Gmail report takes only a window of 30 days at most, with an end.
    static func events(_ service: ServiceClient, application: String, user: String = "all", event: String? = nil,
                       query: [String: String?], limit: Int = 1000) async throws -> EventPage {
        struct ID: Decodable { let time: String?; let uniqueQualifier: String? }
        struct Info: Decodable { let applicationName: String? }
        struct Actor: Decodable { let email: String?; let applicationInfo: Info? }
        struct Network: Decodable {
            let regionCode: String?, subdivisionCode: String?, asn: [String]
            enum Keys: String, CodingKey { case ipAsn, regionCode, subdivisionCode }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                regionCode = try? container.decodeIfPresent(String.self, forKey: .regionCode)
                subdivisionCode = try? container.decodeIfPresent(String.self, forKey: .subdivisionCode)
                asn = (try? container.decodeIfPresent([Int].self, forKey: .ipAsn))?.map(String.init)
                    ?? (try? container.decodeIfPresent([String].self, forKey: .ipAsn)) ?? []
            }
        }
        struct Named: Decodable { let name: String?; let parameters: [Parameter]? }
        struct Item: Decodable { let id: ID?; let actor: Actor?; let ipAddress: String?; let networkInfo: Network?; let events: [Named]? }
        struct Answer: Decodable { let items: [Item]?; let nextPageToken: String? }
        var query = query
        if let event { query["eventName"] = event }
        if application == "gmail" { query = try gmailWindow(query) }
        var items: [Item] = [], token: String?, more = false
        for _ in 0..<50 {
            query["maxResults"] = String(min(1000, limit - items.count))
            query["pageToken"] = token
            let page = try await read(.reports) { try await service.at(host: "admin.googleapis.com").get(
                ["admin", "reports", "v1", "activity", "users", user, "applications", application], query: query, as: Answer.self) }
            items += page.items ?? []
            guard let next = page.nextPageToken, !next.isEmpty else { break }
            if items.count >= limit { more = true; break }
            token = next
        }
        let events = items.flatMap { item in
            (item.events ?? []).enumerated().compactMap { index, named -> Event? in
                guard let name = named.name, event == nil || name == event else { return nil }
                var found = Event(id: "\(application)/\(item.id?.time ?? "?")/\(item.id?.uniqueQualifier ?? "?")/\(name)/\(index)", time: item.id?.time,
                                  application: application, user: item.actor?.email, ip: item.ipAddress, event: name,
                                  parameters: Dictionary((named.parameters ?? []).flatMap { $0.flattened() }, uniquingKeysWith: { first, _ in first }))
                found.asn = item.networkInfo?.asn.first
                found.region = item.networkInfo?.subdivisionCode ?? item.networkInfo?.regionCode
                found.via = item.actor?.applicationInfo?.applicationName
                return found
            }
        }
        return EventPage(events: events, more: more)
    }

    /// Google takes Gmail events only with both ends, at most 30 days apart: the end is now when left out.
    static func gmailWindow(_ query: [String: String?]) throws -> [String: String?] {
        var query = query
        let end = (query["endTime"] ?? nil) ?? ISO8601DateFormatter().string(from: Date())
        query["endTime"] = end
        let parse: (String?) -> Date? = { value in value.flatMap { ServiceAlert.time($0) } }
        if let start = parse(query["startTime"] ?? nil), let finish = parse(end), finish.timeIntervalSince(start) > 30 * 86_400 {
            throw ServiceError.input("Google takes Gmail events for a window of 30 days at most; ask for a shorter one.")
        }
        return query
    }

    /// Several reports read at once, keeping what each found when another is refused, and saying what was searched,
    /// what was cut short and what could not be read, so a gap is never taken for nothing having happened.
    struct Gathered {
        var events: [Event] = [], searched: [String] = [], cut: [String] = [], failed: [(String, String)] = []

        var coverage: String {
            var lines = ["Searched: \(searched.joined(separator: ", "))."]
            if !cut.isEmpty { lines.append("Cut short, with more not read: \(cut.joined(separator: ", ")); narrow the window.") }
            if !failed.isEmpty { lines.append("Could not read: " + failed.map { "\($0.0) (\($0.1))" }.joined(separator: "; ")) }
            return lines.joined(separator: "\n")
        }
    }

    static func gather(_ service: ServiceClient, _ reads: [(label: String, application: String, user: String, event: String?, query: [String: String?])],
                       limit: Int, keep: @escaping @Sendable (String, Event) -> Bool = { _, _ in true }) async -> Gathered {
        let results = await withTaskGroup(of: (String, Result<EventPage, Error>).self) { group in
            for read in reads {
                group.addTask {
                    do { return (read.label, .success(try await events(service, application: read.application, user: read.user, event: read.event,
                                                                         query: read.query, limit: limit))) }
                    catch { return (read.label, .failure(error)) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        var gathered = Gathered(), seen = Set<String>()
        for (label, result) in results.sorted(by: { $0.0 < $1.0 }) {
            switch result {
            case .success(let page):
                if !gathered.searched.contains(label) { gathered.searched.append(label) }
                if page.more { gathered.cut.append(label) }
                for event in page.events where keep(label, event) && seen.insert(event.id).inserted { gathered.events.append(event) }
            case .failure(let error):
                gathered.failed.append((label, error.localizedDescription))
            }
        }
        gathered.events.sort { ($0.time ?? "") > ($1.time ?? "") }
        return gathered
    }

    /// The watched events from `since` to `until`, newest first, up to `limit` of each.
    static func securityEvents(_ service: ServiceClient, since: String, until: String?, limit: Int) async -> Gathered {
        let unless = Dictionary(watched.map { ("\($0.application)/\($0.event)", $0.unless) }, uniquingKeysWith: { first, _ in first })
        return await gather(service, watched.map { (label: "\($0.application)/\($0.event)", application: $0.application, user: "all", event: $0.event,
                                                    query: ["startTime": since, "endTime": until]) }, limit: limit) { label, event in
            (unless[label] ?? nil).map { event.parameters[$0.parameter] != $0.value } ?? true
        }
    }

    /// One page of a Directory list, whichever list it is.
    struct DirectoryPage<Item: Decodable>: Decodable {
        let users: [Item]?, groups: [Item]?, members: [Item]?, items: [Item]?, mobiledevices: [Item]?, nextPageToken: String?
        var listed: [Item] { users ?? groups ?? members ?? items ?? mobiledevices ?? [] }
    }

    /// A Directory list read page after page up to `limit`, and whether there was more, so a large org's admins,
    /// members or users are not left out unsaid.
    static func listAll<Item: Decodable>(_ client: ServiceClient, _ path: [String], query: [String: String?], pageSize: Int = 500,
                                         limit: Int = 5000) async throws -> (items: [Item], more: Bool) {
        var query = query, items: [Item] = []
        for _ in 0..<100 {
            query["maxResults"] = String(min(pageSize, limit - items.count))
            let page = try await client.get(path, query: query, as: DirectoryPage<Item>.self)
            items += page.listed
            guard let next = page.nextPageToken, !next.isEmpty else { return (items, false) }
            if items.count >= limit { return (items, true) }
            query["pageToken"] = next
        }
        return (items, true)
    }

    /// A user for an audit report: their email, or the numeric profile ID that a deleted account is still found by.
    static func reportUser(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value.count <= 30, value.allSatisfy(\.isNumber) { return value }
        return try ServiceInput.email(value)
    }
}

extension GoogleWorkspace {
    struct Activity: ServiceOperation {
        struct Input: Decodable, Sendable {
            let application: String, user: String?, eventName: String?, ip: String?, filters: String?, since: String?, until: String?, limit: Int?
        }
        static let name = "activity"
        static let summary = "Audit events of one report, newest first, by user, event name, IP address, an event's details and time, with each event's details and where its address is."
        static let input = JSONSchema.object([
            "application": .string("Which report.", oneOf: GoogleWorkspace.applications),
            "user": .string("The user's email, or the profile ID of a deleted account from users. Everyone when left out."),
            "eventName": .string("An event, such as login_failure, suspicious_login, authorize or download."),
            "ip": .string("Only events from this IP address."),
            "filters": .string("Only events whose details match, as Google takes them: name==value, comma-separated, such as doc_id==1AbC, client_id==123 or target_user==someone@example.com. Each must belong to the event named in eventName or every event of the report."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601. For Gmail, at most 30 days after since."),
            "limit": .integer("How many events, at most.", minimum: 1, maximum: 5000),
        ], required: ["application"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let application = try ServiceInput.oneOf(input.application, GoogleWorkspace.applications, "application")
            let user = try input.user.map(GoogleWorkspace.reportUser) ?? "all"
            let limit = input.limit ?? 500
            guard (1...5000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 5000 events.") }
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7)]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            if let event = input.eventName { query["eventName"] = try ServiceInput.quoted(event, "the event name") }
            if let ip = input.ip { query["actorIpAddress"] = try ServiceInput.ip(ip) }
            if let filters = input.filters?.trimmingCharacters(in: .whitespacesAndNewlines), !filters.isEmpty {
                guard filters.count <= 500, !filters.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw ServiceError.input("Give filters as name==value pairs separated by commas, briefly.")
                }
                query["filters"] = filters
            }
            let page = try await GoogleWorkspace.events(service, application: application, user: user, query: query, limit: limit)
            var text = page.events.isEmpty ? "No \(application) events match." : page.events.prefix(50).map(\.line).joined(separator: "\n")
            if page.events.count > 50 { text += "\n\(page.events.count - 50) more in the structured result." }
            if page.more { text += "\nThere are more events than the \(limit) read; narrow the window or raise limit." }
            struct Events: Encodable { let events: [Event]; let more: Bool }
            return try ServiceResult(text: text, structured: Events(events: page.events, more: page.more))
        }
    }

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "security-events"
        static let summary = "The audit events that mean an attack or a takeover, newest first: suspicious and blocked sign-ins, accounts Google disabled, government-backed attack warnings, admin privileges, SSO and 2-step verification changes, recovery changes, mail forwarded out or monitored, compromised devices and rules that fired above low."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out."),
            "until": .string("The latest time, in ISO 8601."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let since = try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(1)
            let gathered = await GoogleWorkspace.securityEvents(service, since: since, until: try input.until.map(ServiceInput.time), limit: 500)
            if gathered.searched.isEmpty, let first = gathered.failed.first { throw ServiceError.input(first.1) }
            var text = gathered.events.isEmpty ? "No security events in this window." : gathered.events.prefix(80).map { "\($0.application) \($0.line)" }.joined(separator: "\n")
            if gathered.events.count > 80 { text += "\n\(gathered.events.count - 80) more in the structured result." }
            if !gathered.cut.isEmpty || !gathered.failed.isEmpty { text += "\n" + gathered.coverage }
            struct Kept: Encodable { let events: [Event]; let cutShort: [String]; let couldNotRead: [String] }
            return try ServiceResult(text: text, structured: Kept(events: gathered.events, cutShort: gathered.cut, couldNotRead: gathered.failed.map(\.0)))
        }
    }

    /// Each watched event from `since` on. Google lists some audit events minutes to hours after their time. What one
    /// report found is kept when another is refused; only when none can be read is the check a failure.
    struct NewSecurityEvents: ServiceTrigger {
        var tool: String { SecurityEvents.name }
        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            let gathered = await GoogleWorkspace.securityEvents(service, since: ISO8601DateFormatter().string(from: since), until: nil, limit: ServiceAlert.most)
            if gathered.searched.isEmpty, let first = gathered.failed.first { throw ServiceError.input(first.1) }
            return gathered.events.prefix(ServiceAlert.most).compactMap { event in ServiceAlert.time(event.time).map { ServiceAlert(id: event.id, time: $0) } }
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
            let superAdmins: [User] = try await GoogleWorkspace.read(.users) {
                try await GoogleWorkspace.listAll(directory, base + ["users"], query: ["customer": "my_customer", "query": "isAdmin=true"]).items
            }
            let (roles, assignments) = try await GoogleWorkspace.read(.adminRoles) { () async throws -> ([Role], [Assignment]) in
                (try await GoogleWorkspace.listAll(directory, base + ["customer", "my_customer", "roles"], query: [:], pageSize: 100).items,
                 try await GoogleWorkspace.listAll(directory, base + ["customer", "my_customer", "roleassignments"], query: [:], pageSize: 200).items)
            }
            var names = Dictionary(superAdmins.map { ($0.id, $0.primaryEmail ?? $0.id) }, uniquingKeysWith: { first, _ in first })
            for id in Set(assignments.filter { $0.assigneeType != "group" }.map(\.assignedTo)).subtracting(names.keys).sorted().prefix(500) {
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
        struct Input: Decodable, Sendable { let query: String?, deleted: Bool?, limit: Int? }
        static let name = "users"
        static let summary = "Accounts in the domain, optionally by search such as isEnrolledIn2Sv=false, isSuspended=true or orgUnitPath=/Finance, with admin, 2-step verification and its enforcement, recovery email and phone, aliases and last sign-in."
        static let input = JSONSchema.object([
            "query": .string("A Directory search, such as isEnrolledIn2Sv=false, isAdmin=true, isSuspended=false or email:m.okafor*. Everyone when left out."),
            "deleted": .boolean("List accounts deleted in the last 20 days instead, with the profile ID their audit history is read by."),
            "limit": .integer("How many accounts, at most.", minimum: 1, maximum: 10000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 2000
            guard (1...10000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 10000 accounts.") }
            struct User: Codable {
                let id: String?, primaryEmail: String?, isAdmin: Bool?, isDelegatedAdmin: Bool?, isEnrolledIn2Sv: Bool?, isEnforcedIn2Sv: Bool?, suspended: Bool?
                let lastLoginTime: String?, creationTime: String?, orgUnitPath: String?
                let recoveryEmail: String?, recoveryPhone: String?, aliases: [String]?, isGuestUser: Bool?, archived: Bool?
            }
            struct Listed: Codable { let users: [User]? }
            var query: [String: String?] = ["customer": "my_customer", "viewType": "admin_view"]
            if let search = input.query?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
                guard search.count <= 500 else { throw ServiceError.input("Keep the search short.") }
                query["query"] = search
            }
            if input.deleted == true { query["showDeleted"] = "true" }
            let (users, more): ([User], Bool) = try await GoogleWorkspace.read(.users) {
                try await GoogleWorkspace.listAll(service.at(host: "admin.googleapis.com"), ["admin", "directory", "v1", "users"], query: query, limit: limit)
            }
            var text = users.isEmpty ? (input.deleted == true ? "No accounts were deleted in the last 20 days." : "No accounts match.") : users.map { user in
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
                if input.deleted == true, let id = user.id { parts.append("deleted; read its history with user \(id)") }
                return "\(user.primaryEmail ?? "?"): " + parts.filter { !$0.isEmpty }.joined(separator: ", ")
            }.joined(separator: "\n")
            if more { text += "\nThere are more accounts than the \(limit) read; narrow the search or raise limit." }
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
            let groups: [Group] = try await GoogleWorkspace.read(.groups) {
                try await GoogleWorkspace.listAll(service.at(host: "admin.googleapis.com"), ["admin", "directory", "v1", "groups"],
                                                  query: ["userKey": user], pageSize: 200).items
            }
            let text = groups.isEmpty ? "\(user) is in no groups." : "\(user) is in: " + groups.map {
                "\($0.name ?? $0.email ?? "?") <\($0.email ?? "?")>" + ($0.directMembersCount.map { " (\($0) members)" } ?? "")
            }.joined(separator: ", ")
            return try ServiceResult(text: text, structured: Listed(groups: groups))
        }
    }

    /// The phones and tablets that sync a user's mail and files, which keep their data after a password change. Laptops,
    /// desktops and company-owned devices are in Cloud Identity, which takes only a service account, and are not listed.
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
            let devices: [Device] = try await GoogleWorkspace.read(.mobileDevices) {
                try await GoogleWorkspace.listAll(service.at(host: "admin.googleapis.com"), ["admin", "directory", "v1", "customer", "my_customer", "devices", "mobile"],
                                                  query: ["query": "email:\(user)"], pageSize: 100).items
            }.filter { ($0.email ?? []).contains { $0.lowercased() == user } }
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
        static func report(_ title: String) -> Need {
            Need(title: title, api: reports.api, apiID: reports.apiID, scope: reports.scope, privilege: reports.privilege)
        }
        static let users = Need(title: "Users", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                scope: "https://www.googleapis.com/auth/admin.directory.user.readonly", privilege: "Users › Read")
        static let adminRoles = Need(title: "Admin roles", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                     scope: "https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly", privilege: "read access to admin roles")
        static let groups = Need(title: "Groups", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                 scope: "https://www.googleapis.com/auth/admin.directory.group.readonly", privilege: "Groups › Read")
        static let mobileDevices = Need(title: "Mobile devices", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                        scope: "https://www.googleapis.com/auth/admin.directory.device.mobile.readonly", privilege: "read access to devices")
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
            let admin = try service.at(host: "admin.googleapis.com")
            let directory = ["admin", "directory", "v1"]
            let lines = await GoogleWorkspace.check([
                (.reports, { _ = try await admin.data(["admin", "reports", "v1", "activity", "users", "all", "applications", "login"],
                                                      query: ["startTime": ServiceInput.daysAgo(1), "maxResults": "1"]) }),
                (.users, { _ = try await admin.data(directory + ["users"], query: ["customer": "my_customer", "maxResults": "1"]) }),
                (.adminRoles, { _ = try await admin.data(directory + ["customer", "my_customer", "roles"], query: ["maxResults": "1"]) }),
                (.groups, { _ = try await admin.data(directory + ["groups"], query: ["customer": "my_customer", "maxResults": "1"]) }),
                (.mobileDevices, { _ = try await admin.data(directory + ["customer", "my_customer", "devices", "mobile"], query: ["maxResults": "1"]) }),
                // A working sign-in report does not prove the others: Gmail's needs a window, and some editions lack it.
                (Need.report("Takeout report"), { _ = try await admin.data(["admin", "reports", "v1", "activity", "users", "all", "applications", "takeout"],
                                                                       query: ["startTime": ServiceInput.daysAgo(1), "maxResults": "1"]) }),
                (Need.report("Gmail report"), { _ = try await admin.data(["admin", "reports", "v1", "activity", "users", "all", "applications", "gmail"],
                                                                     query: ["startTime": ServiceInput.daysAgo(1), "endTime": ServiceInput.daysAgo(0),
                                                                             "maxResults": "1"]) }),
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
            // Members of groups inside the group read what it receives too.
            let members: [Member] = try await GoogleWorkspace.read(.groups) {
                try await GoogleWorkspace.listAll(service.at(host: "admin.googleapis.com"), ["admin", "directory", "v1", "groups", group, "members"],
                                                  query: ["includeDerivedMembership": "true"], pageSize: 200).items
            }
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
            async let granted = GoogleWorkspace.events(service, application: "token", event: "authorize", query: query, limit: 20000)
            async let revoked = GoogleWorkspace.events(service, application: "token", event: "revoke", query: query, limit: 20000)
            let (grantPage, revokePage) = try await (granted, revoked)
            let grants = grantPage.events, revokes = revokePage.events
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
            var text = apps.isEmpty ? "No app was granted access in this window." : apps.map { app in
                "\(app.name) (client \(app.clientId)\(app.type.map { ", \($0)" } ?? ""))" + (app.risk.map { ": \($0)" } ?? "")
                    + "; granted by \(app.grantedBy.joined(separator: ", ")), last \(app.lastGranted ?? "?")"
                    + (app.revokedBy.isEmpty ? "" : "; revoked by \(app.revokedBy.joined(separator: ", "))")
                    + "; scopes \(app.scopes.joined(separator: " "))"
            }.joined(separator: "\n")
            if grantPage.more || revokePage.more { text += "\nThere are more grants or revocations than were read; narrow the window." }
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
            let user = try input.user.map(GoogleWorkspace.reportUser) ?? "all"
            let page = try await GoogleWorkspace.events(service, application: "token", user: user, event: "activity", query: query, limit: 20000)
            let calls = page.events
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
            }.joined(separator: "\n") + (page.more ? "\nThere are more calls than the \(calls.count) read; narrow the window or name the app." : "")
            struct Kept: Encodable { let usage: [Usage] }
            return try ServiceResult(text: text, structured: Kept(usage: usage))
        }
    }

    /// One account's activity across the reports, and what admins did to it, merged newest first: where an
    /// investigation of an account starts. It says which reports it searched, which it could not read and which held
    /// more than it read, so a gap is never taken for nothing having happened.
    struct UserTimeline: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String, since: String?, until: String? }
        static let name = "user-timeline"
        static let summary = "One account's activity across every report it appears in, and what admins did to it, newest first: sign-ins, account and recovery changes, app grants, Drive, Gmail, Calendar, Chat, Meet, Takeout exports, groups and admin actions. It says which reports it searched and which it could not read."
        static let input = JSONSchema.object([
            "user": .string("The user's email, or the profile ID of a deleted account from users."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out. Gmail is read only for windows of 30 days at most."),
            "until": .string("The latest time, in ISO 8601."),
        ], required: ["user"])
        static let applications = ["login", "user_accounts", "token", "drive", "admin", "saml", "mobile", "groups", "gmail", "calendar", "chat", "meet",
                                   "takeout", "vault", "context_aware_access"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try GoogleWorkspace.reportUser(input.user)
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7)]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            // What admins did to the account, as they are the actors there.
            let reads = Self.applications.map { (label: $0, application: $0, user: user, event: String?.none, query: query) }
                + (user.contains("@") ? [(label: "admin, about them", application: "admin", user: "all", event: String?.none,
                                          query: query.merging(["filters": "USER_EMAIL==\(user)"]) { $1 })] : [])
            let gathered = await GoogleWorkspace.gather(service, reads, limit: 1000)
            if gathered.searched.isEmpty, let first = gathered.failed.first { throw ServiceError.input(first.1) }
            var text = gathered.events.isEmpty ? "Nothing for \(user) in this window." : gathered.events.prefix(150).map { "\($0.application) \($0.line)" }.joined(separator: "\n")
            if gathered.events.count > 150 { text += "\n\(gathered.events.count - 150) more in the structured result." }
            text += "\n" + gathered.coverage
            struct Kept: Encodable { let events: [Event]; let searched: [String]; let cutShort: [String]; let couldNotRead: [String] }
            return try ServiceResult(text: text, structured: Kept(events: gathered.events, searched: gathered.searched, cutShort: gathered.cut,
                                                                  couldNotRead: gathered.failed.map(\.0)))
        }
    }

    /// Everything one address did, in every report: how an attacker's IP is followed across accounts.
    struct IPActivity: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String, since: String?, until: String? }
        static let name = "ip-activity"
        static let summary = "Everything one IP address did across every report and account, newest first: sign-ins, app grants, Drive, admin actions, exports and more. It says which reports it searched and which it could not read."
        static let input = JSONSchema.object([
            "ip": .string("The IPv4 or IPv6 address."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601."),
        ], required: ["ip"])
        static let applications = ["login", "user_accounts", "token", "drive", "admin", "saml", "mobile", "groups", "calendar", "chat", "meet",
                                   "takeout", "vault", "context_aware_access", "gcp"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7),
                                            "actorIpAddress": try ServiceInput.ip(input.ip)]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            let gathered = await GoogleWorkspace.gather(service, Self.applications.map {
                (label: $0, application: $0, user: "all", event: String?.none, query: query)
            }, limit: 1000)
            if gathered.searched.isEmpty, let first = gathered.failed.first { throw ServiceError.input(first.1) }
            var text = gathered.events.isEmpty ? "Nothing from \(input.ip) in this window." : gathered.events.prefix(150).map { "\($0.application) \($0.line)" }.joined(separator: "\n")
            if gathered.events.count > 150 { text += "\n\(gathered.events.count - 150) more in the structured result." }
            text += "\n" + gathered.coverage
            struct Kept: Encodable { let events: [Event]; let searched: [String]; let cutShort: [String]; let couldNotRead: [String] }
            return try ServiceResult(text: text, structured: Kept(events: gathered.events, searched: gathered.searched, cutShort: gathered.cut,
                                                                  couldNotRead: gathered.failed.map(\.0)))
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
            let (users, more): ([User], Bool) = try await read(.containmentUsers) {
                try await GoogleWorkspace.listAll(service, ["admin", "directory", "v1", "users"], query: ["customer": "my_customer"], limit: 10000)
            }
            let emails = users.compactMap(\.primaryEmail)
            // One account refused, as an admin is under User Security Management, leaves the rest.
            let results = await withTaskGroup(of: (String, Result<[Token], Error>).self) { group in
                for email in emails {
                    group.addTask {
                        do { return (email, .success(try await directory(email, ["tokens"]) { try await service.get($0, as: Tokens.self) }.items ?? [])) }
                        catch { return (email, .failure(error)) }
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            let held = results.compactMap { email, result in (try? result.get()).map { (email, $0) } }
            let failed = results.compactMap { email, result -> String? in if case .failure = result { email } else { nil } }.sorted()
            struct App: Encodable { let clientId: String, name: String, scopes: [String], holders: [String], risk: String? }
            let apps = Dictionary(grouping: held.flatMap { email, tokens in tokens.map { (email, $0) } }) { $0.1.clientId ?? "?" }.map { client, pairs in
                let scopes = Array(Set(pairs.flatMap { $0.1.scopes ?? [] })).sorted()
                return App(clientId: client, name: pairs.compactMap { $0.1.displayText }.first ?? client, scopes: scopes,
                           holders: Array(Set(pairs.map(\.0))).sorted(), risk: GoogleWorkspace.risk(scopes)?.said)
            }.sorted { first, second in
                let ranks = (GoogleWorkspace.risk(first.scopes)?.rank ?? 9, GoogleWorkspace.risk(second.scopes)?.rank ?? 9)
                return ranks.0 != ranks.1 ? ranks.0 < ranks.1 : (first.holders.count, second.name) > (second.holders.count, first.name)
            }
            let checked = emails.count - failed.count
            var text = apps.isEmpty ? "No app holds access to any of the \(checked) account\(checked == 1 ? "" : "s") checked." : apps.map { app in
                "\(app.name) (\(app.clientId))" + (app.risk.map { ": \($0)" } ?? "")
                    + "; held by \(app.holders.count) user\(app.holders.count == 1 ? "" : "s"): \(app.holders.joined(separator: ", ")); scopes \(app.scopes.joined(separator: " "))"
            }.joined(separator: "\n")
            text += "\nChecked \(emails.count) account\(emails.count == 1 ? "" : "s")"
                + (failed.isEmpty ? "." : "; could not read \(failed.joined(separator: ", ")), as User Security Management never covers admins or the role lacks it.")
            if more { text += "\nThere are more accounts than were read." }
            struct Kept: Encodable { let apps: [App]; let accountsChecked: Int; let couldNotRead: [String] }
            return try ServiceResult(text: text, structured: Kept(apps: apps, accountsChecked: emails.count, couldNotRead: failed))
        }
    }
}

