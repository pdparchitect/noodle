import Foundation
import NoodleCore
import NoodleMCP

/// What Entra and Defender share: Microsoft Graph, reached as an app registered in the person's tenant, with
/// its client ID and secret exchanged for tokens at Microsoft's sign-in service. Each account is one tenant.
enum Graph {
    static func preset(id: String, name: String, summary: String, instructions: String) -> ToolDefinition {
        ToolDefinition(id: id, name: name, summary: summary, defaultInstructions: instructions, iconName: id,
            configuration: .mcp(.init(endpointTemplate: "https://graph.microsoft.com/v1.0",
                fields: [ToolField(key: "tenant", title: "Directory (tenant) ID", placeholder: "contoso.onmicrosoft.com", kind: .identifier)],
                clientCredentials: ClientCredentialsPreset(tokenEndpointTemplate: "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
                                                           scope: "https://graph.microsoft.com/.default"),
                adapter: id)))
    }

    /// Graph wraps every list.
    struct List<Item: Decodable>: Decodable { let value: [Item] }

    /// A value as an OData string literal: quoted, with its quotes doubled.
    static func literal(_ value: String, _ name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ServiceError.input("Give \(name).")
        }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// How many items, between 1 and `maximum`.
    static func limit(_ value: Int?, default fallback: Int, maximum: Int) throws -> String {
        let limit = value ?? fallback
        guard (1...maximum).contains(limit) else { throw ServiceError.input("Ask for between 1 and \(maximum).") }
        return String(limit)
    }

    /// A user named by its object ID or user principal name, as Graph's paths take it.
    static func user(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { throw ServiceError.input("Give the user's object ID or user principal name.") }
        return value
    }

    /// "#microsoft.graph.directoryRole" → "directoryRole".
    static func kind(_ type: String?) -> String? { type?.split(separator: ".").last.map(String.init) }
}

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
        """)

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

/// Microsoft Defender XDR: its alerts and incidents, and advanced hunting across devices, email, identities and apps.
public enum Defender {
    public static let preset = Graph.preset(id: "defender", name: "Microsoft Defender XDR",
        summary: "Alerts, incidents and advanced hunting across devices, email, identities and apps.",
        instructions: """
        Use Microsoft Defender XDR to see what Microsoft's detections found: list alerts and incidents by severity, status \
        and time, and hunt with KQL across the advanced hunting tables, such as DeviceProcessEvents, DeviceNetworkEvents, \
        EmailEvents and IdentityLogonEvents. Keep hunting queries narrow, with a time filter and a row limit. Record each \
        query and what it returned as evidence, with the query itself as the method. These tools only read: recommend \
        isolating a device or other responses to the champion.
        """)

    public static let adapter = OperationAdapter(operations: [Alerts(), Incidents(), Hunt()])
}

extension Defender {
    struct Alerts: ServiceOperation {
        struct Input: Decodable, Sendable { let severity: String?, status: String?, since: String?, limit: Int? }
        static let name = "alerts"
        static let summary = "Security alerts, newest first, by severity, status and time, with the entities each involves."
        static let input = JSONSchema.object([
            "severity": .string("The severity.", oneOf: ["informational", "low", "medium", "high"]),
            "status": .string("The status.", oneOf: ["new", "inProgress", "resolved"]),
            "since": .string("The earliest creation time, in ISO 8601. The last 7 days when left out."),
            "limit": .integer("How many alerts, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter: [String] = []
            if let severity = input.severity { filter.append("severity eq '\(try ServiceInput.oneOf(severity, ["informational", "low", "medium", "high"], "severity"))'") }
            if let status = input.status { filter.append("status eq '\(try ServiceInput.oneOf(status, ["new", "inProgress", "resolved"], "status"))'") }
            filter.append("createdDateTime ge " + (try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7)))
            let top = try Graph.limit(input.limit, default: 25, maximum: 100)
            struct Evidence: Decodable {
                enum Keys: String, CodingKey { case type = "@odata.type", hostName, userAccount, fileDetails, ipAddress, url }
                struct Account: Decodable { let userPrincipalName: String?; let accountName: String? }
                struct File: Decodable { let fileName: String? }
                let type: String?, name: String?
                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: Keys.self)
                    type = try container.decodeIfPresent(String.self, forKey: .type)
                    func text(_ key: Keys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
                    let account = (try? container.decodeIfPresent(Account.self, forKey: .userAccount)) ?? nil
                    let file = (try? container.decodeIfPresent(File.self, forKey: .fileDetails)) ?? nil
                    // The entity's most telling name: its host, account, file, address or URL.
                    let candidates: [String?] = [text(.hostName), account?.userPrincipalName, account?.accountName, file?.fileName,
                                                 text(.ipAddress), text(.url)]
                    name = candidates.lazy.compactMap { $0 }.first
                }
            }
            struct Alert: Decodable {
                let id: String, title: String?, severity: String?, status: String?, category: String?, serviceSource: String?
                let createdDateTime: String?, incidentId: String?, alertWebUrl: String?, mitreTechniques: [String]?, evidence: [Evidence]?
            }
            struct Kept: Encodable {
                let id: String, title: String?, severity: String?, status: String?, category: String?, source: String?, created: String?
                let incident: String?, link: String?, techniques: [String], entities: [String]
            }
            struct Alerts: Encodable { let alerts: [Kept] }
            let alerts = try await service.get(["security", "alerts_v2"], query: ["$filter": filter.joined(separator: " and "), "$top": top],
                                               as: Graph.List<Alert>.self).value.map { alert in
                Kept(id: alert.id, title: alert.title, severity: alert.severity, status: alert.status, category: alert.category,
                     source: alert.serviceSource, created: alert.createdDateTime, incident: alert.incidentId, link: alert.alertWebUrl,
                     techniques: alert.mitreTechniques ?? [], entities: (alert.evidence ?? []).compactMap { evidence in
                         evidence.name.map { "\($0) (\(Graph.kind(evidence.type)?.replacingOccurrences(of: "Evidence", with: "") ?? "entity"))" }
                     })
            }
            let text = alerts.isEmpty ? "No alerts match." : "\(alerts.count) alert\(alerts.count == 1 ? "" : "s"), newest first:\n" + alerts.prefix(20).map { alert in
                var line = "\(alert.created ?? "?") \(alert.severity ?? "?") \(alert.status ?? "?"): \(alert.title ?? alert.id)"
                if let incident = alert.incident { line += " (incident \(incident))" }
                if !alert.entities.isEmpty { line += " — " + alert.entities.prefix(5).joined(separator: ", ") }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Alerts(alerts: alerts))
        }
    }

    struct Incidents: ServiceOperation {
        struct Input: Decodable, Sendable { let severity: String?, status: String?, since: String?, limit: Int? }
        static let name = "incidents"
        static let summary = "Incidents, newest first, by severity, status and time."
        static let input = JSONSchema.object([
            "severity": .string("The severity.", oneOf: ["informational", "low", "medium", "high"]),
            "status": .string("The status.", oneOf: ["active", "inProgress", "resolved", "redirected"]),
            "since": .string("The earliest creation time, in ISO 8601. The last 30 days when left out."),
            "limit": .integer("How many incidents, at most.", minimum: 1, maximum: 50),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var filter: [String] = []
            if let severity = input.severity { filter.append("severity eq '\(try ServiceInput.oneOf(severity, ["informational", "low", "medium", "high"], "severity"))'") }
            if let status = input.status { filter.append("status eq '\(try ServiceInput.oneOf(status, ["active", "inProgress", "resolved", "redirected"], "status"))'") }
            filter.append("createdDateTime ge " + (try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(30)))
            let top = try Graph.limit(input.limit, default: 20, maximum: 50)
            struct Incident: Codable {
                let id: String, displayName: String?, severity: String?, status: String?, createdDateTime: String?, lastUpdateDateTime: String?
                let assignedTo: String?, classification: String?, determination: String?, incidentWebUrl: String?
            }
            struct Incidents: Encodable { let incidents: [Incident] }
            let incidents = try await service.get(["security", "incidents"], query: ["$filter": filter.joined(separator: " and "), "$top": top],
                                                  as: Graph.List<Incident>.self).value
            let text = incidents.isEmpty ? "No incidents match." : "\(incidents.count) incident\(incidents.count == 1 ? "" : "s"), newest first:\n"
                + incidents.map { "\($0.createdDateTime ?? "?") \($0.severity ?? "?") \($0.status ?? "?"): \($0.displayName ?? $0.id) (\($0.id))" }
                    .joined(separator: "\n")
            return try ServiceResult(text: text, structured: Incidents(incidents: incidents))
        }
    }

    struct Hunt: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String, timespan: String? }
        static let name = "hunt"
        static let summary = "Run a KQL query over Defender's advanced hunting tables, such as DeviceProcessEvents or EmailEvents. Read-only."
        static let input = JSONSchema.object([
            "query": .string("The KQL query. Filter by time and end with take or limit to keep results small."),
            "timespan": .string("How far back, in ISO 8601, such as P7D or 2026-11-13T00:00:00Z/P1D. 30 days when left out."),
        ], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let query = try ServiceInput.query(input.query)
            struct Body: Encodable { let Query: String; let Timespan: String? }
            struct Column: Decodable { let name: String }
            struct Answer: Decodable { let schema: [Column]?; let results: [[String: CellValue]]? }
            let answer = try await service.post(["security", "runHuntingQuery"],
                                                body: Body(Query: query, Timespan: input.timespan?.trimmingCharacters(in: .whitespaces)), as: Answer.self)
            let columns = answer.schema?.map(\.name) ?? []
            return try ServiceTable(columns: columns, rows: (answer.results ?? []).map { row in columns.map { row[$0] ?? .none } }).result()
        }
    }
}
