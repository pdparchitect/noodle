import Foundation
import NoodleCore
import NoodleToolConnections

/// An Okta org's users, their groups, apps and sign-in factors, and its System Log, read with an API token.
/// Each account is its own org, named by its domain. Nothing here changes the org.
public enum Okta {
    public static let preset = ToolDefinition(
        id: "bdc65def-9c77-4503-9d57-eac000822cce", name: "Okta", summary: "Users, groups, sign-in factors and the System Log of an Okta org.",
        defaultInstructions: """
        Use Okta to learn who an identity is and what happened to it: find the user, then their groups, assigned apps and \
        enrolled sign-in factors, and the System Log's sign-in events by user, IP address, event type or time. For a \
        breach's scope, user-grants shows the apps a user let act for them, which keep working after a password change; \
        admin-roles who holds which admin role; and api-tokens every API token, who made it and where it works from. \
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
        "To audit admins and API tokens too, under **Security › Administrators › Roles** create a role such as **Pion Audit** with only **View roles, resources, and admin assignments** and **View API tokens**, and assign it to the same user, for all users and all Identity and Access Management resources. The Read-Only Administrator cannot see them.",
        "For the domain, give your org's address, such as `acme.okta.com`, not its `-admin` address.",
    ]

    public static let adapter = OperationAdapter(operations: [FindUser(), UserGroups(), UserApps(), UserFactors(), SignInEvents(),
                                                              UserGrants(), AdminRoles(), APITokens()],
                                                 // Paced, as admin-roles asks for each admin's roles in turn.
                                                 simultaneousRequests: 8)

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

// MARK: - Breach scope

extension Okta {
    /// A read the Read-Only Administrator cannot make, with Okta's refusal explained by the custom role it needs.
    static func auditRead<Value>(_ read: () async throws -> Value) async throws -> Value {
        do { return try await read() } catch ServiceError.forbidden {
            throw ServiceError.input("""
                Okta refused: the admin this token belongs to may not see admins or API tokens. Give them a custom role with \
                View roles, resources, and admin assignments and View API tokens, as Okta's Setup Steps say, besides the \
                Read-Only Administrator.
                """)
        }
    }

    /// A user's login by their ID, for naming admins and token owners; the ID when Okta does not say.
    static func login(_ id: String, on service: ServiceClient) async -> String {
        (try? await service.get(["users", id], as: User.self).profile?.login) ?? id
    }

    /// The apps a user let act for them through OAuth, and what each may do. A grant outlives a password change.
    struct UserGrants: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-grants"
        static let summary = "The apps a user let act for them through OAuth, with the scopes each holds and whether the user or an admin granted it."
        static let input = JSONSchema.object(["user": .string("The user's Okta ID or login.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try Okta.user(input.user)
            struct Scope: Codable { let name: String? }
            struct Embedded: Codable { let scope: Scope? }
            struct Grant: Codable {
                let id: String, clientId: String?, scopeId: String?, status: String?, source: String?, created: String?, issuer: String?
                let _embedded: Embedded?
            }
            let grants = try await service.get(["users", user, "grants"], query: ["expand": "scope", "limit": "200"], as: [Grant].self)
            let text = grants.isEmpty ? "\(user) has granted no apps access." : Dictionary(grouping: grants) { $0.clientId ?? "?" }
                .sorted { $0.key < $1.key }.map { client, held in
                    let scopes = held.map { $0._embedded?.scope?.name ?? $0.scopeId ?? "?" }.joined(separator: ", ")
                    let by = held.contains { $0.source == "ADMIN" } ? "granted by an admin" : "granted by the user"
                    return "\(client): \(scopes) (\(by), since \(held.compactMap(\.created).min() ?? "?"))"
                }.joined(separator: "\n")
            struct Kept: Encodable { let grants: [Grant] }
            return try ServiceResult(text: text, structured: Kept(grants: grants))
        }
    }

    /// Who holds which admin role, directly or through a group: the accounts that can change the org.
    struct AdminRoles: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "admin-roles"
        static let summary = "Everyone who holds an admin role, with which roles and whether through a group, super administrators first."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Assignee: Decodable { let id: String }
            struct Assignees: Decodable { let value: [Assignee]? }
            struct Role: Codable { let type: String?; let label: String?; let status: String?; let assignmentType: String? }
            let ids = try await Okta.auditRead {
                try await service.get(["iam", "assignees", "users"], query: ["limit": "200"], as: Assignees.self).value ?? []
            }.map(\.id)
            let admins = try await withThrowingTaskGroup(of: (String, String, [Role]).self) { group in
                for id in ids {
                    group.addTask {
                        let roles = try await Okta.auditRead { try await service.get(["users", id, "roles"], as: [Role].self) }
                        return (id, await Okta.login(id, on: service), roles)
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }.sorted { first, second in
                let superAdmin = (first.2.contains { $0.type == "SUPER_ADMIN" }, second.2.contains { $0.type == "SUPER_ADMIN" })
                return superAdmin.0 != superAdmin.1 ? superAdmin.0 : first.1 < second.1
            }
            struct Admin: Encodable { let id: String; let login: String; let roles: [Role] }
            let text = admins.isEmpty ? "Nobody holds an admin role." : admins.map { id, login, roles in
                "\(login): " + roles.map { ($0.label ?? $0.type ?? "?") + ($0.assignmentType == "GROUP" ? " (through a group)" : "") }.joined(separator: ", ")
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: ["admins": admins.map { Admin(id: $0.0, login: $0.1, roles: $0.2) }])
        }
    }

    /// Every API token: each acts as the admin who made it, from anywhere unless its network is limited.
    struct APITokens: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "api-tokens"
        static let summary = "Every API token, with who made it, when it expires and where it may be used from."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Network: Codable { let connection: String? }
            struct Token: Codable {
                let id: String, name: String?, userId: String?, clientName: String?, created: String?, expiresAt: String?, lastUpdated: String?
                let network: Network?
            }
            let tokens = try await Okta.auditRead { try await service.get(["api-tokens"], as: [Token].self) }
            var owners: [String: String] = [:]
            for id in Set(tokens.compactMap(\.userId)).sorted().prefix(50) { owners[id] = await Okta.login(id, on: service) }
            let text = tokens.isEmpty ? "The org has no API tokens." : tokens.map { token in
                let from = switch token.network?.connection {
                case "ANYWHERE", nil: "from anywhere"
                case let other?: "from \(other.lowercased().replacingOccurrences(of: "_", with: " ")) networks only"
                }
                return "\(token.name ?? token.id), made by \(token.userId.map { owners[$0] ?? $0 } ?? "?") on \(token.created ?? "?"), \(from), expires \(token.expiresAt ?? "?")"
            }.joined(separator: "\n")
            struct Kept: Encodable { let tokens: [Token] }
            return try ServiceResult(text: text, structured: Kept(tokens: tokens))
        }
    }
}

