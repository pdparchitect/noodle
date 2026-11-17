import Foundation
import NoodleCore
import NoodleMCP

/// Microsoft Entra ID: who an identity is, what it belongs to, how it signs in, its sign-in log and risk.
public enum Entra {
    public static let preset = Graph.preset(id: "entra", name: "Microsoft Entra ID",
        summary: "Users, groups and roles, sign-in methods, sign-in logs and risky users of a Microsoft tenant.",
        instructions: """
        Use Microsoft Entra ID to learn who an identity is and what happened to it: find the user, then their groups and \
        roles, their registered sign-in methods, their sign-in log with location, IP address and conditional access, and \
        whether Identity Protection rates them at risk. Sign-in logs need Entra ID P1 and risky users P2; say so when the \
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

    public static let adapter = OperationAdapter(operations: [FindUser(), UserGroups(), SignInMethods(), SignIns(), RiskyUsers()])
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
        static let summary = "The groups and directory roles a user is a direct member of."
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
            struct Kept: Encodable { let id: String, name: String?, kind: String?, description: String? }
            struct Memberships: Encodable { let memberships: [Kept] }
            let memberships = try await service.get(["users", user, "memberOf"], query: ["$select": "id,displayName,description"],
                                                    as: Graph.List<Membership>.self).value
                .map { Kept(id: $0.id, name: $0.displayName, kind: Graph.kind($0.type), description: $0.description) }
            let text = memberships.isEmpty ? "\(user) is in no groups or roles."
                : "\(user) is a member of: " + memberships.map { item in
                    (item.name ?? item.id) + (item.kind == "directoryRole" ? " (role)" : "")
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
