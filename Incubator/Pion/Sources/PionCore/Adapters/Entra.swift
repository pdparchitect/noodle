import Foundation
import NoodleCore
import NoodleToolConnections

/// Microsoft Entra ID: who an identity is, what it belongs to, how it signs in, its sign-in log and risk.
public enum Entra {
    public static let preset = Graph.preset(id: "7b419894-4d22-4624-a699-5df62b3ab680", key: "entra", name: "Microsoft Entra ID",
        summary: "Users, groups and roles, sign-in methods, sign-in logs and risky users of a Microsoft tenant.",
        instructions: """
        Use Microsoft Entra ID to learn who an identity is and what happened to it: find the user, then their groups and \
        roles, their registered sign-in methods, their sign-in log with location, IP address and conditional access, and \
        whether Identity Protection rates them at risk. To audit who holds what, role-holders lists each directory role's \
        holders and app-permissions which apps hold which Microsoft Graph permissions; app-credentials lists the secrets \
        and certificates apps sign in with, newest first, as one added lately may be an attacker's way back in; and \
        directory-audit shows who changed what in the directory, and from where. Sign-in logs need Entra ID P1 and risky users P2; say so when the \
        service refuses. Record what you find as evidence, citing the tenant, user and time window. These tools only read: \
        recommend disabling an account, revoking sessions or resetting methods to the champion, with how to undo it.
        """,
        setup: setup)

    static let setup = [
        "In the [Microsoft Entra admin center](https://entra.microsoft.com), open **App registrations** and choose **New registration**. Name it, such as Pion, keep **Single tenant** and leave the redirect URI empty.",
        "Under **API permissions**, choose **Add a permission › Microsoft Graph › Application permissions** and add `Directory.Read.All`, `AuditLog.Read.All`, `UserAuthenticationMethod.Read.All` and `IdentityRiskyUser.Read.All`.",
        "Choose **Grant admin consent** for your tenant.",
        "Under **Certificates & secrets**, add a client secret and copy its **Value**, not its Secret ID; it is shown only once.",
        "From the app's **Overview**, copy the **Directory (tenant) ID** and the **Application (client) ID** into the fields here.",
        "Sign-in logs need Entra ID P1, and risky users P2. One app can serve both Entra ID and Defender XDR when it has both sets of permissions.",
    ]

    public static let adapter = OperationAdapter(operations: [FindUser(), UserGroups(), SignInMethods(), SignIns(), RiskyUsers(),
                                                              RoleHolders(), AppPermissions(), DirectoryAudit(), AppCredentials()],
                                                 trigger: HighRiskUsers())

    /// Users Identity Protection newly rates at high risk, by when their risk last changed.
    struct HighRiskUsers: ServiceTrigger {
        var tool: String { RiskyUsers.name }
        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            struct Risky: Decodable { let id: String; let riskLastUpdatedDateTime: String? }
            let filter = "riskLevel eq 'high' and riskState eq 'atRisk' and riskLastUpdatedDateTime ge " + ISO8601DateFormatter().string(from: since)
            return try await service.get(["identityProtection", "riskyUsers"], query: ["$filter": filter, "$top": String(ServiceAlert.most)],
                                         as: Graph.List<Risky>.self).value
                .compactMap { user in ServiceAlert.time(user.riskLastUpdatedDateTime).map { ServiceAlert(id: user.id, time: $0) } }
                .sorted { $0.time > $1.time }
        }
    }
}

extension Entra {
    struct FindUser: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String }
        static let name = "find-user"
        static let summary = "Find users whose display name, user principal name or email starts with the query."
        static let input = JSONSchema.object(["query": .string("The start of a name, user principal name or email address.")], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let value = try Graph.literal(input.query, "the start of a name or address")
            struct User: Codable {
                let id: String, displayName: String?, userPrincipalName: String?, mail: String?, accountEnabled: Bool?
                let createdDateTime: String?, jobTitle: String?, department: String?
            }
            struct Found: Encodable { let users: [User] }
            let users = try await service.get(["users"], query: [
                "$filter": ["displayName", "userPrincipalName", "mail"].map { "startswith(\($0),\(value))" }.joined(separator: " or "),
                "$select": "id,displayName,userPrincipalName,mail,accountEnabled,createdDateTime,jobTitle,department", "$top": "10",
            ], as: Graph.List<User>.self).value
            let text = users.isEmpty ? "No user matches \(value)."
                : "Found \(users.count) user\(users.count == 1 ? "" : "s"): " + users.map { user in
                    let state = user.accountEnabled == false ? "disabled" : "enabled"
                    return "\(user.displayName ?? user.id) (\(user.userPrincipalName ?? user.id), \(state)\(user.jobTitle.map { ", \($0)" } ?? ""))"
                }.joined(separator: "; ") + "."
            return try ServiceResult(text: text, structured: Found(users: users))
        }
    }

    struct UserGroups: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-groups"
        static let summary = "The groups and directory roles a user is a member of, directly or through nested groups."
        static let input = JSONSchema.object(["user": .string("The user's object ID or user principal name.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try Graph.user(input.user)
            struct Membership: Decodable {
                enum Keys: String, CodingKey { case type = "@odata.type", id, displayName, description }
                let type: String?, id: String, displayName: String?, description: String?
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: Keys.self)
                    type = try container.decodeIfPresent(String.self, forKey: .type); id = try container.decode(String.self, forKey: .id)
                    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
                    description = try container.decodeIfPresent(String.self, forKey: .description)
                }
            }
            struct Kept: Encodable { let id: String, name: String?, kind: String?, description: String?, nested: Bool }
            struct Memberships: Encodable { let memberships: [Kept] }
            // A group inside a group gives its members what it is given, so both are listed, the nested ones marked.
            let direct = Set(try await service.get(["users", user, "memberOf"], query: ["$select": "id"], as: Graph.List<Membership>.self).value.map(\.id))
            let memberships = try await service.get(["users", user, "transitiveMemberOf"], query: ["$select": "id,displayName,description"],
                                                    as: Graph.List<Membership>.self).value
                .map { Kept(id: $0.id, name: $0.displayName, kind: Graph.kind($0.type), description: $0.description, nested: !direct.contains($0.id)) }
            let text = memberships.isEmpty ? "\(user) is in no groups or roles."
                : "\(user) is a member of: " + memberships.map { item in
                    (item.name ?? item.id) + (item.kind == "directoryRole" ? " (role)" : "") + (item.nested ? " (through a nested group)" : "")
                }.joined(separator: ", ") + "."
            return try ServiceResult(text: text, structured: Memberships(memberships: memberships))
        }
    }

    struct SignInMethods: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-sign-in-methods"
        static let summary = "The sign-in methods a user has registered, such as Microsoft Authenticator, a phone or a security key."
        static let input = JSONSchema.object(["user": .string("The user's object ID or user principal name.")], required: ["user"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try Graph.user(input.user)
            struct Method: Decodable {
                enum Keys: String, CodingKey { case type = "@odata.type", id, displayName, phoneNumber, phoneType, model, emailAddress, createdDateTime }
                let type: String?, id: String, detail: String?, created: String?
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: Keys.self)
                    type = try container.decodeIfPresent(String.self, forKey: .type); id = try container.decode(String.self, forKey: .id)
                    detail = [Keys.displayName, .model, .phoneNumber, .emailAddress].lazy
                        .compactMap { try? container.decodeIfPresent(String.self, forKey: $0) }.first
                    created = try container.decodeIfPresent(String.self, forKey: .createdDateTime)
                }
            }
            struct Kept: Encodable { let id: String, method: String, detail: String?, created: String? }
            struct Methods: Encodable { let methods: [Kept] }
            let names = ["passwordAuthenticationMethod": "password", "microsoftAuthenticatorAuthenticationMethod": "Microsoft Authenticator",
                         "phoneAuthenticationMethod": "phone", "fido2AuthenticationMethod": "security key",
                         "windowsHelloForBusinessAuthenticationMethod": "Windows Hello for Business", "emailAuthenticationMethod": "email",
                         "softwareOathAuthenticationMethod": "authenticator app code", "temporaryAccessPassAuthenticationMethod": "temporary access pass",
                         "platformCredentialAuthenticationMethod": "platform credential"]
            let methods = try await service.get(["users", user, "authentication", "methods"], as: Graph.List<Method>.self).value.map { method in
                let kind = Graph.kind(method.type) ?? "unknown"
                return Kept(id: method.id, method: names[kind] ?? kind, detail: method.detail, created: method.created)
            }
            let text = methods.isEmpty ? "\(user) has no sign-in methods registered."
                : "\(user) has \(methods.count) sign-in method\(methods.count == 1 ? "" : "s"): "
                    + methods.map { $0.method + ($0.detail.map { " (\($0))" } ?? "") }.joined(separator: ", ") + "."
            return try ServiceResult(text: text, structured: Methods(methods: methods))
        }
    }

    struct SignIns: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String?, ip: String?, failuresOnly: Bool?, since: String?, until: String?, limit: Int? }
        static let name = "sign-ins"
        static let summary = "Interactive sign-ins, newest first, by user principal name, IP address, failures only and time, with app, location, conditional access and risk."
        static let input = JSONSchema.object([
            "user": .string("The user principal name, such as name@contoso.com."),
            "ip": .string("The IP address the sign-ins came from."),
            "failuresOnly": .boolean("Only sign-ins that failed."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601."),
            "limit": .integer("How many sign-ins, at most.", minimum: 1, maximum: 200),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter: [String] = []
            if let user = input.user { filter.append("userPrincipalName eq " + (try Graph.literal(user, "the user principal name"))) }
            if let ip = input.ip { filter.append("ipAddress eq '\(try ServiceInput.ip(ip))'") }
            if input.failuresOnly == true { filter.append("status/errorCode ne 0") }
            filter.append("createdDateTime ge " + (try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7)))
            if let until = input.until { filter.append("createdDateTime le " + (try ServiceInput.time(until))) }
            let top = try Graph.limit(input.limit, default: 50, maximum: 200)
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
                let succeeded: Bool, failure: String?, conditionalAccess: String?, risk: String?, client: String?, device: String?
            }
            struct SignIns: Encodable { let signIns: [Kept] }
            let signIns = try await service.get(["auditLogs", "signIns"], query: ["$filter": filter.joined(separator: " and "), "$top": top],
                                                as: Graph.List<SignIn>.self).value.map { item in
                Kept(id: item.id, time: item.createdDateTime, user: item.userPrincipalName, app: item.appDisplayName, ip: item.ipAddress,
                     city: item.location?.city, country: item.location?.countryOrRegion, succeeded: (item.status?.errorCode ?? 0) == 0,
                     failure: item.status?.failureReason, conditionalAccess: item.conditionalAccessStatus, risk: item.riskLevelDuringSignIn,
                     client: item.clientAppUsed,
                     device: [item.deviceDetail?.operatingSystem, item.deviceDetail?.browser].compactMap { $0 }.joined(separator: ", "))
            }
            let lines = signIns.prefix(20).map { item in
                var line = "\(item.time ?? "?") \(item.succeeded ? "succeeded" : "failed\(item.failure.map { " (\($0))" } ?? "")")"
                if let user = item.user { line += " for \(user)" }
                if let app = item.app { line += " to \(app)" }
                if let ip = item.ip { line += " from \(ip)" }
                let place = [item.city, item.country].compactMap { $0 }
                if !place.isEmpty { line += " (\(place.joined(separator: ", ")))" }
                if let risk = item.risk, risk != "none" { line += ", risk \(risk)" }
                return line
            }
            let text = signIns.isEmpty ? "No sign-ins match." : "\(signIns.count) sign-in\(signIns.count == 1 ? "" : "s"), newest first:\n"
                + lines.joined(separator: "\n") + (signIns.count > lines.count ? "\n… and \(signIns.count - lines.count) more in the structured result." : "")
            return try ServiceResult(text: text, structured: SignIns(signIns: signIns))
        }
    }

    struct RiskyUsers: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "risky-users"
        static let summary = "The users Identity Protection currently rates at risk, with how high and since when."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Risky: Codable {
                let id: String, userPrincipalName: String?, riskLevel: String?, riskState: String?, riskDetail: String?, riskLastUpdatedDateTime: String?
            }
            struct Users: Encodable { let users: [Risky] }
            let users = try await service.get(["identityProtection", "riskyUsers"], query: ["$filter": "riskState eq 'atRisk'", "$top": "50"],
                                              as: Graph.List<Risky>.self).value
            let text = users.isEmpty ? "No users are currently at risk."
                : "\(users.count) user\(users.count == 1 ? " is" : "s are") at risk: "
                    + users.map { "\($0.userPrincipalName ?? $0.id) (\($0.riskLevel ?? "unknown")\($0.riskLastUpdatedDateTime.map { ", since \($0)" } ?? ""))" }
                        .joined(separator: "; ") + "."
            return try ServiceResult(text: text, structured: Users(users: users))
        }
    }
}

// MARK: - Who holds what

extension Entra {
    /// A role holder or a permission's app, as Graph lists directory objects.
    struct DirectoryObject: Decodable {
        enum Keys: String, CodingKey { case type = "@odata.type", id, displayName, userPrincipalName }
        let type: String?, id: String, displayName: String?, userPrincipalName: String?
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            type = try container.decodeIfPresent(String.self, forKey: .type); id = try container.decode(String.self, forKey: .id)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            userPrincipalName = try container.decodeIfPresent(String.self, forKey: .userPrincipalName)
        }
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

    /// Each active directory role and its holders, from Directory.Read.All. Roles held only through eligibility in
    /// Privileged Identity Management are not listed: they need a permission of their own.
    struct RoleHolders: ServiceOperation {
        struct Input: Decodable, Sendable { let role: String? }
        static let name = "role-holders"
        static let summary = "Each active directory role and who holds it: users, groups and apps, Global Administrator first. Eligible assignments are not listed."
        static let input = JSONSchema.object(["role": .string("Only roles whose name contains this, such as Global or Exchange.")])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Role: Decodable { let id: String; let displayName: String? }
            let filter = input.role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let roles = try await service.get(["directoryRoles"], query: ["$select": "id,displayName"], as: Graph.List<Role>.self).value
                .filter { role in filter.map { (role.displayName ?? "").lowercased().contains($0) } ?? true }
            let held = try await withThrowingTaskGroup(of: (Role, [DirectoryObject]).self) { group in
                for role in roles {
                    group.addTask {
                        (role, try await service.get(["directoryRoles", role.id, "members"],
                                                     query: ["$select": "id,displayName,userPrincipalName"], as: Graph.List<DirectoryObject>.self).value)
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }.filter { !$0.1.isEmpty }.sorted { first, second in
                let global = (first.0.displayName == "Global Administrator", second.0.displayName == "Global Administrator")
                return global.0 != global.1 ? global.0 : (first.0.displayName ?? "") < (second.0.displayName ?? "")
            }
            struct Holder: Encodable { let id: String, kind: String?, name: String }
            struct Held: Encodable { let role: String, holders: [Holder] }
            struct Kept: Encodable { let roles: [Held] }
            let kept = held.map { role, members in
                Held(role: role.displayName ?? role.id, holders: members.map { Holder(id: $0.id, kind: Graph.kind($0.type), name: $0.shown) })
            }
            let lines = kept.map { "\($0.role) (\($0.holders.count)): \($0.holders.map(\.name).joined(separator: ", "))" }
            let text = (lines.isEmpty ? ["No active role is held\(filter == nil ? "" : " by that name")."] : lines)
                + ["Active assignments only; roles someone is only eligible for in Privileged Identity Management are not listed."]
            return try ServiceResult(text: text.joined(separator: "\n"), structured: Kept(roles: kept))
        }
    }

    /// Which apps hold which Microsoft Graph permissions: granted to the app itself, and consented for everyone or for
    /// single people. A permission that writes or sends can change the tenant; one that manages roles, app role grants
    /// or apps' credentials can make an app or a person an administrator.
    struct AppPermissions: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "app-permissions"
        static let summary = "Which apps hold which Microsoft Graph permissions, granted to the app itself or consented for people, with those that can change the tenant or make administrators flagged."
        static let input = JSONSchema.object([:])
        static let graphApp = "00000003-0000-0000-c000-000000000000"
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
            guard let graph = try await service.get(["servicePrincipals"], query: ["$filter": "appId eq '\(Self.graphApp)'",
                                                                                    "$select": "id,appRoles"], as: Graph.List<Graphs>.self).value.first else {
                throw ServiceError.refused("Microsoft Graph's own app was not found in this tenant")
            }
            let names = Dictionary((graph.appRoles ?? []).compactMap { role in role.value.map { (role.id, $0) } }, uniquingKeysWith: { first, _ in first })
            struct Assignment: Decodable { let principalId: String; let principalDisplayName: String?; let appRoleId: String }
            let assigned = try await service.get(["servicePrincipals", graph.id, "appRoleAssignedTo"], query: ["$top": "999"],
                                                 as: Graph.List<Assignment>.self).value
            struct Grant: Decodable { let clientId: String; let consentType: String?; let resourceId: String?; let scope: String? }
            let grants = try await service.get(["oauth2PermissionGrants"], query: ["$top": "999"], as: Graph.List<Grant>.self).value
                .filter { $0.resourceId == graph.id }
            // An app known only from a consent is named by asking for it.
            var appNames = Dictionary(assigned.map { ($0.principalId, $0.principalDisplayName ?? $0.principalId) }, uniquingKeysWith: { first, _ in first })
            for id in Set(grants.map(\.clientId)).subtracting(appNames.keys).sorted().prefix(50) {
                struct App: Decodable { let displayName: String? }
                appNames[id] = (try? await service.get(["servicePrincipals", id], query: ["$select": "displayName"], as: App.self).displayName) ?? id
            }
            struct Held: Encodable { let app: String, id: String, kind: String, permissions: [String], people: Int? }
            var held = Dictionary(grouping: assigned, by: \.principalId).map { id, roles in
                Held(app: appNames[id] ?? id, id: id, kind: "application",
                     permissions: roles.map { names[$0.appRoleId] ?? $0.appRoleId }.sorted(), people: nil)
            }
            for (id, consents) in Dictionary(grouping: grants, by: \.clientId) {
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
            let text = held.isEmpty ? "No app holds Microsoft Graph permissions." : held.map { item in
                let whom = item.people.map { " consented by \($0) \($0 == 1 ? "person" : "people")" } ?? (item.kind == "application" ? " as itself" : "")
                return "\(item.app) (\(item.kind == "delegated for everyone" ? "for everyone" : item.kind == "application" ? "application" : "delegated")\(whom)): "
                    + item.permissions.map(Self.flag).joined(separator: ", ")
            }.joined(separator: "\n")
            struct Kept: Encodable { let apps: [Held] }
            return try ServiceResult(text: text, structured: Kept(apps: held))
        }
    }
}

// MARK: - Breach scope

extension Entra {
    /// Who changed what in the directory, from AuditLog.Read.All: roles granted, apps given secrets, users changed.
    struct DirectoryAudit: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String?, activity: String?, since: String?, until: String?, limit: Int? }
        static let name = "directory-audit"
        static let summary = "Changes to the directory, newest first, by who made them, the activity and time, with what they changed and from which IP address."
        static let input = JSONSchema.object([
            "user": .string("Only changes this user principal name made."),
            "activity": .string("Only activities starting with this, such as Add member to role or Update application."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601."),
            "limit": .integer("How many changes, at most.", minimum: 1, maximum: 500),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filters = ["activityDateTime ge " + (try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7))]
            if let until = input.until { filters.append("activityDateTime le " + (try ServiceInput.time(until))) }
            if let user = input.user { filters.append("initiatedBy/user/userPrincipalName eq " + (try Graph.literal(user, "the user principal name"))) }
            if let activity = input.activity { filters.append("startswith(activityDisplayName," + (try Graph.literal(activity, "the activity")) + ")") }
            struct Who: Codable { let userPrincipalName: String?; let ipAddress: String?; let displayName: String? }
            struct Initiator: Codable { let user: Who?; let app: Who? }
            struct Target: Codable { let displayName: String?; let userPrincipalName: String?; let type: String? }
            struct Change: Codable {
                let activityDateTime: String?, activityDisplayName: String?, category: String?, result: String?
                let initiatedBy: Initiator?, targetResources: [Target]?
            }
            let changes = try await service.get(["auditLogs", "directoryAudits"], query: [
                "$filter": filters.joined(separator: " and "), "$top": try Graph.limit(input.limit, default: 100, maximum: 500),
                "$orderby": "activityDateTime desc",
            ], as: Graph.List<Change>.self).value
            let text = changes.isEmpty ? "No directory changes match." : changes.prefix(50).map { change in
                let who = change.initiatedBy?.user?.userPrincipalName ?? change.initiatedBy?.app?.displayName ?? "someone"
                let from = change.initiatedBy?.user?.ipAddress.map { " from \($0)" } ?? ""
                let targets = (change.targetResources ?? []).map { [$0.type, $0.userPrincipalName ?? $0.displayName].compactMap { $0 }.joined(separator: " ") }
                return "\(change.activityDateTime ?? "?") \(change.activityDisplayName ?? "?") by \(who)\(from)"
                    + (targets.isEmpty ? "" : " on " + targets.joined(separator: ", ")) + (change.result == "success" || change.result == nil ? "" : " (\(change.result!))")
            }.joined(separator: "\n")
            struct Kept: Encodable { let changes: [Change] }
            return try ServiceResult(text: text, structured: Kept(changes: changes))
        }
    }

    /// The secrets and certificates app registrations and enterprise apps sign in with, from Directory.Read.All. One
    /// added lately may be an attacker's way back in; one valid for years lasts as long as nobody finds it.
    struct AppCredentials: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "app-credentials"
        static let summary = "The secrets and certificates apps sign in with, newest first, flagging those added in the last 30 days, valid for more than two years, or expired."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Credential: Codable { let keyId: String?; let displayName: String?; let startDateTime: String?; let endDateTime: String? }
            struct App: Decodable { let id: String; let displayName: String?; let passwordCredentials: [Credential]?; let keyCredentials: [Credential]? }
            let query: [String: String?] = ["$select": "id,appId,displayName,passwordCredentials,keyCredentials", "$top": "999"]
            async let registrations = service.get(["applications"], query: query, as: Graph.List<App>.self).value
            async let enterprise = service.get(["servicePrincipals"], query: query, as: Graph.List<App>.self).value
            struct Held: Encodable { let app: String, kind: String, credential: String, name: String?, added: String?, expires: String?, flags: [String] }
            func held(_ apps: [App], _ kind: String) -> [Held] {
                apps.flatMap { app in
                    ((app.passwordCredentials ?? []).map { ("secret", $0) } + (app.keyCredentials ?? []).map { ("certificate", $0) }).map { type, credential in
                        let start = ServiceAlert.time(credential.startDateTime), end = ServiceAlert.time(credential.endDateTime), now = Date()
                        var flags: [String] = []
                        if let start, now.timeIntervalSince(start) < 30 * 86_400 { flags.append("added in the last 30 days") }
                        if let start, let end, end.timeIntervalSince(start) > 2 * 365 * 86_400 { flags.append("valid for more than two years") }
                        if let end, end < now { flags.append("expired") }
                        return Held(app: app.displayName ?? app.id, kind: kind, credential: type, name: credential.displayName,
                                    added: credential.startDateTime, expires: credential.endDateTime, flags: flags)
                    }
                }
            }
            let all = (held(try await registrations, "app registration") + held(try await enterprise, "enterprise app"))
                .sorted { (ServiceAlert.time($0.added) ?? .distantPast) > (ServiceAlert.time($1.added) ?? .distantPast) }
            let text = all.isEmpty ? "No app signs in with a secret or certificate." : all.prefix(100).map { item in
                "\(item.app) (\(item.kind)): \(item.credential)\(item.name.map { " \"\($0)\"" } ?? ""), added \(item.added ?? "?"), expires \(item.expires ?? "never")"
                    + (item.flags.isEmpty ? "" : " [" + item.flags.joined(separator: ", ") + "]")
            }.joined(separator: "\n") + (all.count > 100 ? "\n\(all.count - 100) more in the structured result." : "")
            struct Kept: Encodable { let credentials: [Held] }
            return try ServiceResult(text: text, structured: Kept(credentials: all))
        }
    }
}

