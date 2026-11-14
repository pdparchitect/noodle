import Foundation
import NoodleCore
import NoodleMCP

/// Google Workspace's audit reports: sign-ins, admin actions, OAuth grants to apps, Drive and more, read as a
/// service account acting for an admin through domain-wide delegation. Each account is one Workspace.
public enum GoogleWorkspace {
    static let applications = ["login", "admin", "token", "drive", "saml", "user_accounts", "groups", "mobile", "rules"]

    public static let preset = ToolDefinition(
        id: "google-workspace", name: "Google Workspace", summary: "Audit reports: sign-ins, admin actions, OAuth app grants and Drive activity.",
        defaultInstructions: """
        Use Google Workspace to see what happened in the domain: sign-ins, including suspicious ones and their IP \
        addresses; admin actions; OAuth tokens granted to apps; Drive sharing and downloads; SAML sign-ins; account changes. \
        Filter by user, event name, IP address and time. Record each finding as evidence, citing the application, user \
        and time window. These tools only read: recommend suspending a user, revoking a token or changing sharing to the \
        champion.
        """,
        iconName: "google-workspace",
        configuration: .connection(.init(endpointTemplate: "https://googleapis.com",
            fields: [ToolField(key: "subject", title: "Admin to act as", placeholder: "admin@example.com", kind: .text)],
            googleScopes: ["https://www.googleapis.com/auth/admin.reports.audit.readonly"], adapter: "google-workspace")))

    public static let adapter = OperationAdapter(operations: [Activity()])
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
            struct Parameter: Decodable {
                let name: String; let value: String?; let boolValue: Bool?; let intValue: String?; let multiValue: [String]?
                var shown: String? {
                    value ?? boolValue.map(String.init) ?? intValue ?? multiValue?.joined(separator: ", ")
                }
            }
            struct Event: Decodable { let type: String?; let name: String?; let parameters: [Parameter]? }
            struct ID: Decodable { let time: String?; let applicationName: String? }
            struct Actor: Decodable { let email: String? }
            struct Item: Decodable { let id: ID?; let actor: Actor?; let ipAddress: String?; let events: [Event]? }
            struct Answer: Decodable { let items: [Item]? }
            struct Kept: Encodable { let time: String?, user: String?, ip: String?, event: String?, parameters: [String: String] }
            struct Events: Encodable { let events: [Kept] }
            let items = try await service.at(host: "admin.googleapis.com").get(
                ["admin", "reports", "v1", "activity", "users", user, "applications", application], query: query, as: Answer.self).items ?? []
            let events = items.flatMap { item in
                (item.events ?? []).map { event in
                    Kept(time: item.id?.time, user: item.actor?.email, ip: item.ipAddress, event: event.name,
                         parameters: Dictionary((event.parameters ?? []).compactMap { parameter in parameter.shown.map { (parameter.name, $0) } },
                                                uniquingKeysWith: { first, _ in first }))
                }
            }
            let text = events.isEmpty ? "No \(application) events match." : events.prefix(30).map { event in
                var line = "\(event.time ?? "?") \(event.event ?? "?")"
                if let user = event.user { line += " by \(user)" }
                if let ip = event.ip { line += " from \(ip)" }
                let details = event.parameters.sorted { $0.key < $1.key }.prefix(4).map { "\($0.key)=\($0.value)" }
                if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Events(events: events))
        }
    }
}
