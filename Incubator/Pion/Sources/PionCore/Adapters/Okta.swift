import Foundation
import NoodleCore
import NoodleMCP

/// An Okta org's users, their groups, apps and sign-in factors, and its System Log, read with an API token.
/// Each account is its own org, named by its domain. Nothing here changes the org.
public enum Okta {
    public static let preset = ToolDefinition(
        id: "bdc65def-9c77-4503-9d57-eac000822cce", formerID: "okta", name: "Okta", summary: "Users, groups, sign-in factors and the System Log of an Okta org.",
        defaultInstructions: """
        Use Okta to learn who an identity is and what happened to it: find the user, then their groups, assigned apps and \
        enrolled sign-in factors, and the System Log's sign-in events by user, IP address, event type or time. \
        Record what you find as evidence, citing the org, the user and the time window you searched. \
        These tools only read. Never ask for a user to be suspended, their sessions cleared or their factors reset through \
        this connection; recommend it to the champion with the user's login, why, and how to undo it.
        """,
        iconName: "okta",
        configuration: .connection(.init(endpointTemplate: "https://{domain}/api/v1",
                                  fields: [ToolField(key: "domain", title: "Okta domain", placeholder: "acme.okta.com", kind: .host)],
                                  tokenHeader: "Authorization", tokenScheme: "SSWS",
                                  // Okta revokes the token a request is made with.
                                  tokenRevocation: TokenRevocation(method: "DELETE", path: "api-tokens/current", authorized: true),
                                  adapter: "okta")),
        setup: setup)

    static let setup = [
        "In the Okta Admin Console, create a user for Pion, such as pion@example.com, so the token does not belong to a person.",
        "Under **Security › Administrators**, give that user the **Read-Only Administrator** role.",
        "Sign in to the Admin Console as that user, open **Security › API › Tokens** and choose **Create Token**. A token has its creator's access, so this one can only read.",
        "Copy the token and paste it here. Okta revokes tokens left unused for 30 days.",
        "For the domain, give your org's address, such as `acme.okta.com`, not its `-admin` address.",
    ]

    public static let adapter = OperationAdapter(operations: [FindUser(), UserGroups(), UserApps(), UserFactors(), SignInEvents()])

    /// A user named by its ID or login, as Okta's paths take it.
    static func user(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ServiceError.input("Give the user's Okta ID or login.")
        }
        return value
    }

    struct Profile: Decodable { let login: String?; let email: String?; let firstName: String?; let lastName: String? }
    struct User: Decodable { let id: String; let status: String?; let created: String?; let lastLogin: String?; let passwordChanged: String?; let profile: Profile? }

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
}

extension Okta {
    struct FindUser: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String }
        static let name = "find-user"
        static let summary = "Find users whose first name, last name or email starts with the query, with their status and last sign-in."
        static let input = JSONSchema.object(["query": .string("The start of a first name, last name or email address.")], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let query = try Okta.user(input.query)
            let users = try await service.get(["users"], query: ["q": query, "limit": "10"], as: [User].self).map(UserSummary.init)
            struct Found: Encodable { let users: [UserSummary] }
            let text = users.isEmpty ? "No user matches \"\(query)\"."
                : "Found \(users.count) user\(users.count == 1 ? "" : "s"): " + users.map(\.sentence).joined(separator: "; ") + "."
            return try ServiceResult(text: text, structured: Found(users: users))
        }
    }

    struct UserGroups: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-groups"
        static let summary = "The groups a user belongs to."
        static let input = JSONSchema.object(["user": .string("The user's Okta ID or login.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try Okta.user(input.user)
            struct Group: Decodable { struct Profile: Decodable { let name: String?; let description: String? }; let id: String; let profile: Profile? }
            struct Kept: Encodable { let id: String; let name: String?; let description: String? }
            struct Groups: Encodable { let groups: [Kept] }
            let groups = try await service.get(["users", user, "groups"], as: [Group].self)
                .map { Kept(id: $0.id, name: $0.profile?.name, description: $0.profile?.description) }
            let text = groups.isEmpty ? "\(user) is in no groups."
                : "\(user) is in \(groups.count) group\(groups.count == 1 ? "" : "s"): " + groups.map { $0.name ?? $0.id }.joined(separator: ", ") + "."
            return try ServiceResult(text: text, structured: Groups(groups: groups))
        }
    }

    struct UserApps: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-apps"
        static let summary = "The apps assigned to a user."
        static let input = JSONSchema.object(["user": .string("The user's Okta ID or login.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try Okta.user(input.user)
            struct App: Codable { let label: String?; let appName: String?; let appInstanceId: String? }
            struct Apps: Encodable { let apps: [App] }
            let apps = try await service.get(["users", user, "appLinks"], as: [App].self)
            let text = apps.isEmpty ? "\(user) has no apps assigned."
                : "\(user) has \(apps.count) app\(apps.count == 1 ? "" : "s"): " + apps.map { $0.label ?? $0.appName ?? "unnamed" }.joined(separator: ", ") + "."
            return try ServiceResult(text: text, structured: Apps(apps: apps))
        }
    }

    struct UserFactors: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-factors"
        static let summary = "The sign-in factors a user has enrolled, such as push, SMS or a security key, with their status."
        static let input = JSONSchema.object(["user": .string("The user's Okta ID or login.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try Okta.user(input.user)
            struct Factor: Codable { let id: String; let factorType: String?; let provider: String?; let status: String?; let created: String?; let lastUpdated: String? }
            struct Factors: Encodable { let factors: [Factor] }
            let factors = try await service.get(["users", user, "factors"], as: [Factor].self)
            let text = factors.isEmpty ? "\(user) has no sign-in factors enrolled."
                : "\(user) has \(factors.count) factor\(factors.count == 1 ? "" : "s"): "
                    + factors.map { "\($0.factorType ?? "unknown") (\([$0.provider, $0.status].compactMap { $0 }.joined(separator: ", ")))" }
                        .joined(separator: ", ") + "."
            return try ServiceResult(text: text, structured: Factors(factors: factors))
        }
    }

    struct SignInEvents: ServiceOperation {
        struct Input: Decodable, Sendable {
            let user: String?, ip: String?, eventType: String?, failuresOnly: Bool?, since: String?, until: String?, limit: Int?
        }
        static let name = "sign-in-events"
        static let summary = "System Log events, newest first, by the user who acted, their IP address, the event type, failures only, and time. Okta keeps 90 days."
        static let input = JSONSchema.object([
            "user": .string("The login of the user who acted, such as name@example.com."),
            "ip": .string("The IP address the events came from."),
            "eventType": .string("An event type, such as user.session.start or user.authentication.auth_via_mfa."),
            "failuresOnly": .boolean("Only events whose outcome was a failure."),
            "since": .string("The earliest time, in ISO 8601, such as 2026-11-13T00:00:00Z. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601."),
            "limit": .integer("How many events, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            func quoted(_ value: String, _ problem: String) throws -> String {
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, value.count <= 200,
                      !value.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }) else { throw ServiceError.input(problem) }
                return "\"\(value)\""
            }
            var filter: [String] = []
            if let user = input.user { filter.append("actor.alternateId eq " + (try quoted(user, "Give the user's login."))) }
            if let ip = input.ip {
                let ip = try ServiceInput.ip(ip)
                filter.append("client.ipAddress eq \"\(ip)\"")
            }
            if let type = input.eventType {
                guard !type.isEmpty, type.count <= 100, type.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._").contains) else {
                    throw ServiceError.input("Give an event type such as user.session.start.")
                }
                filter.append("eventType eq \"\(type)\"")
            }
            if input.failuresOnly == true { filter.append("outcome.result eq \"FAILURE\"") }
            let limit = input.limit ?? 50
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 events.") }
            let since = try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7)
            let until = try input.until.map(ServiceInput.time)

            struct Event: Decodable {
                struct Outcome: Decodable { let result: String?; let reason: String? }
                struct Actor: Decodable { let alternateId: String?; let displayName: String? }
                struct Client: Decodable {
                    struct Place: Decodable { let city: String?; let country: String? }
                    struct Agent: Decodable { let rawUserAgent: String? }
                    let ipAddress: String?; let geographicalContext: Place?; let userAgent: Agent?
                }
                let uuid: String?, published: String?, eventType: String?, displayMessage: String?
                let outcome: Outcome?, actor: Actor?, client: Client?
            }
            struct Kept: Encodable {
                let id: String?, time: String?, type: String?, message: String?, outcome: String?, reason: String?
                let user: String?, ip: String?, city: String?, country: String?, userAgent: String?
            }
            struct Events: Encodable { let events: [Kept] }
            let events = try await service.get(["logs"], query: ["filter": filter.isEmpty ? nil : filter.joined(separator: " and "),
                                                                 "since": since, "until": until, "limit": String(limit), "sortOrder": "DESCENDING"],
                                               as: [Event].self).map {
                Kept(id: $0.uuid, time: $0.published, type: $0.eventType, message: $0.displayMessage, outcome: $0.outcome?.result,
                     reason: $0.outcome?.reason, user: $0.actor?.alternateId, ip: $0.client?.ipAddress,
                     city: $0.client?.geographicalContext?.city, country: $0.client?.geographicalContext?.country,
                     userAgent: $0.client?.userAgent?.rawUserAgent)
            }
            let lines = events.prefix(20).map { event in
                var line = "\(event.time ?? "?") \(event.type ?? "event") \(event.outcome ?? "")".trimmingCharacters(in: .whitespaces)
                if let user = event.user { line += " by \(user)" }
                if let ip = event.ip { line += " from \(ip)" }
                let place = [event.city, event.country].compactMap { $0 }
                if !place.isEmpty { line += " (\(place.joined(separator: ", ")))" }
                return line
            }
            let text = events.isEmpty ? "No System Log events match since \(since)."
                : "\(events.count) event\(events.count == 1 ? "" : "s") since \(since), newest first:\n" + lines.joined(separator: "\n")
                    + (events.count > lines.count ? "\n… and \(events.count - lines.count) more in the structured result." : "")
            return try ServiceResult(text: text, structured: Events(events: events))
        }
    }
}
