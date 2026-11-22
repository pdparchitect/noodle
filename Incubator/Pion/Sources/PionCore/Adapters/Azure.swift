import Foundation
import NoodleCore
import NoodleToolConnections

/// Microsoft Azure: activity, security alerts, resources and access, reached as an app registered in the tenant.
/// Each account is one subscription.
public enum Azure {
    public static let preset = ToolDefinition(
        id: "bb70fbdc-96ea-4c56-91cf-b1b29fe91328", name: "Microsoft Azure", summary: "Activity, security alerts, resources and access in an Azure subscription.",
        defaultInstructions: """
        Use Microsoft Azure to read a subscription's activity log, Microsoft Defender for Cloud alerts, resources and role \
        assignments. Keep queries narrow, with a time filter and a row limit. Record each query and what it returned as \
        evidence, with the query itself as the method. These tools only read: recommend changes to the champion.
        Defender for Cloud alerts may also appear in Microsoft Defender XDR (alerts_v2 serviceSource microsoftDefenderForCloud) under a different ID, so match them up.
        """,
        iconName: "azure",
        configuration: .connection(.init(endpointTemplate: "https://management.azure.com",
            fields: [ToolField(key: "tenant", title: "Directory (tenant) ID", placeholder: "contoso.onmicrosoft.com", kind: .identifier),
                     ToolField(key: "subscription", title: "Subscription ID", placeholder: "8a7f3c2e-0000-4000-8000-000000000002", kind: .identifier)],
            clientCredentials: ClientCredentialsPreset(tokenEndpointTemplate: "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
                                                       scope: "https://management.azure.com/.default"),
            adapter: "azure")),
        setup: setup)

    static let setup = [
        "In the [Microsoft Entra admin center](https://entra.microsoft.com), open **App registrations** and choose **New registration**. Name it, such as Pion, keep **Single tenant** and leave the redirect URI empty. It needs no API permissions.",
        "Under **Certificates & secrets**, add a client secret and copy its **Value**, not its Secret ID; it is shown only once.",
        "In the [Azure portal](https://portal.azure.com), open the subscription, choose **Access control (IAM) › Add role assignment**, and give the app the **Reader** role.",
        "Copy the **Subscription ID** from the subscription's **Overview**, and the **Directory (tenant) ID** and **Application (client) ID** from the app's **Overview**.",
    ]

    public static let adapter = OperationAdapter(operations: [ActivityLog(), DefenderAlerts(), ResourceGraph(), RoleAssignments()], trigger: SevereAlerts())

    static func guid(_ value: String) throws -> String {
        guard value.count == 36, UUID(uuidString: value) != nil else { throw ServiceError.input("Give the ID as a GUID.") }
        return value
    }

    static func path(_ service: ServiceClient, _ provider: String, _ resource: String) throws -> [String] {
        ["subscriptions", try guid(service.setting("subscription")), "providers", provider, resource]
    }

    static let maximumPages = 20
    struct List<Item: Decodable>: Decodable { let value: [Item]; let nextLink: String? }
    struct Listing<Item> { var value: [Item] = []; var more = false }

    static func list<Item: Decodable>(_ service: ServiceClient, path: [String], query: [String: String?],
                                      as: Item.Type, limit: Int? = nil, matching: (Item) -> Bool = { _ in true }) async throws -> Listing<Item> {
        var query = query
        var found = Listing<Item>()
        for _ in 0..<maximumPages {
            let page = try await service.get(path, query: query, as: List<Item>.self)
            found.value += page.value.filter(matching)
            found.more = page.nextLink?.isEmpty == false
            if !found.more || limit.map({ found.value.count >= $0 }) == true { break }
            guard let link = page.nextLink,
                  let token = URLComponents(string: link)?.queryItems?.first(where: { $0.name.lowercased() == "$skiptoken" })?.value,
                  !token.isEmpty else { throw ServiceError.unreadable }
            query["$skipToken"] = token
        }
        return found
    }

    static func stopped(_ more: Bool, _ listing: String) -> String {
        more ? "\nStopped early reading \(listing); more pages remain, so results may be incomplete." : ""
    }

    struct Alert: Codable {
        struct Properties: Codable {
            struct Resource: Codable { let azureResourceId: String?, type: String? }
            struct Entity: Codable { let name: String?, type: String? }
            let alertDisplayName: String?, severity: String?, status: String?, timeGeneratedUtc: String?
            let description: String?, entities: [Entity]?
            let compromisedEntity: String?, resourceIdentifiers: [Resource]?, techniques: [String]?, intent: String?, alertUri: String?
        }
        let id: String, name: String?, properties: Properties?
    }

    static func alerts(_ service: ServiceClient) async throws -> Listing<Alert> {
        try await list(service, path: path(service, "Microsoft.Security", "alerts"), query: ["api-version": "2022-01-01"], as: Alert.self)
    }

    struct SevereAlerts: ServiceTrigger {
        var tool: String { DefenderAlerts.name }
        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            Array(try await Azure.alerts(service).value.compactMap { alert -> ServiceAlert? in
                guard alert.properties?.severity == "High", let time = ServiceAlert.time(alert.properties?.timeGeneratedUtc), time >= since else { return nil }
                return ServiceAlert(id: alert.id, time: time)
            }.sorted { $0.time > $1.time }.prefix(ServiceAlert.most))
        }
    }
}

extension Azure {
    struct ActivityLog: ServiceOperation {
        struct Input: Decodable, Sendable { let caller: String?, resourceGroup: String?, resource: String?, failuresOnly: Bool?, since: String?, until: String?, limit: Int? }
        static let name = "activity-log"
        static let summary = "Subscription activity by time, caller and resource, optionally only failures."
        static let input = JSONSchema.object([
            "caller": .string("Only this caller."), "resourceGroup": .string("Only this resource group."),
            "resource": .string("Only this resource's full ID."), "failuresOnly": .boolean("Only failed activity."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out, at most 90 days."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
            "limit": .integer("How many events, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard input.resource == nil || input.resourceGroup == nil else { throw ServiceError.input("Give a resource or resourceGroup, not both.") }
            let since = try input.since.map { try ServiceInput.time(ServiceInput.quoted($0, "the time")) } ?? ServiceInput.daysAgo(7)
            let until = try input.until.map { try ServiceInput.time(ServiceInput.quoted($0, "the time")) } ?? ISO8601DateFormatter().string(from: Date())
            guard let from = ServiceAlert.time(since), let to = ServiceAlert.time(until), from <= to,
                  from >= Date().addingTimeInterval(-90 * 86_400 - 60), to <= Date().addingTimeInterval(60) else {
                throw ServiceError.input("Give a time range within the last 90 days, with since before until.")
            }
            let limit = Int(try Graph.limit(input.limit, default: 25, maximum: 100))!
            var filter = ["eventTimestamp ge '\(since)'", "eventTimestamp le '\(until)'"]
            for (key, value) in [("caller", input.caller), ("resourceGroupName", input.resourceGroup), ("resourceUri", input.resource)] {
                if let value { filter.append("\(key) eq '\(try ServiceInput.quoted(value, key))'") }
            }
            struct Named: Codable { let value: String?, localizedValue: String? }
            struct Event: Codable {
                let eventDataId: String?, eventTimestamp: String?, caller: String?, resourceId: String?, resourceGroupName: String?
                let status: Named?, operationName: Named?
            }
            let listing = try await Azure.list(service, path: Azure.path(service, "Microsoft.Insights", "eventtypes") + ["management", "values"],
                query: ["api-version": "2015-04-01", "$filter": filter.joined(separator: " and "),
                        "$select": "eventDataId,eventTimestamp,caller,resourceId,resourceGroupName,status,operationName"], as: Event.self, limit: limit,
                matching: { input.failuresOnly != true || $0.status?.value?.lowercased() == "failed" })
            let events = Array(listing.value
                .sorted { (ServiceAlert.time($0.eventTimestamp) ?? .distantPast) > (ServiceAlert.time($1.eventTimestamp) ?? .distantPast) }.prefix(limit))
            let text = events.isEmpty ? "No activity matches." : events.map {
                "\($0.eventTimestamp ?? "?") \($0.status?.value ?? "?"): \($0.operationName?.localizedValue ?? $0.operationName?.value ?? "?") — \($0.caller ?? "?")"
            }.joined(separator: "\n")
            struct Kept: Encodable { let events: [Event] }
            return try ServiceResult(text: text + Azure.stopped(listing.more, "activity"), structured: Kept(events: events))
        }
    }

    struct DefenderAlerts: ServiceOperation {
        struct Input: Decodable, Sendable { let severity: String?, status: String?, since: String?, limit: Int? }
        static let name = "defender-alerts"
        static let summary = "Microsoft Defender for Cloud alerts, newest first, by severity, status and time."
        static let input = JSONSchema.object([
            "severity": .string("The severity.", oneOf: ["Informational", "Low", "Medium", "High"]),
            "status": .string("The status.", oneOf: ["Active", "InProgress", "Resolved", "Dismissed"]),
            "since": .string("The earliest creation time, in ISO 8601. The last 7 days when left out."),
            "limit": .integer("How many alerts, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let severity = try input.severity.map { try ServiceInput.oneOf($0, ["Informational", "Low", "Medium", "High"], "severity") }
            let status = try input.status.map { try ServiceInput.oneOf($0, ["Active", "InProgress", "Resolved", "Dismissed"], "status") }
            let since = ServiceAlert.time(try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7))!
            let limit = Int(try Graph.limit(input.limit, default: 25, maximum: 100))!
            let listing = try await Azure.alerts(service)
            let alerts = Array(listing.value.filter { alert in
                guard let time = ServiceAlert.time(alert.properties?.timeGeneratedUtc), time >= since else { return false }
                return (severity == nil || alert.properties?.severity == severity) && (status == nil || alert.properties?.status == status)
            }.sorted { (ServiceAlert.time($0.properties?.timeGeneratedUtc) ?? .distantPast) > (ServiceAlert.time($1.properties?.timeGeneratedUtc) ?? .distantPast) }.prefix(limit))
            let text = alerts.isEmpty ? "No alerts match." : alerts.map {
                "\($0.properties?.timeGeneratedUtc ?? "?") \($0.properties?.severity ?? "?") \($0.properties?.status ?? "?"): \($0.properties?.alertDisplayName ?? $0.id) — \($0.properties?.compromisedEntity ?? "?")"
            }.joined(separator: "\n")
            struct Kept: Encodable { let alerts: [Alert] }
            return try ServiceResult(text: text + Azure.stopped(listing.more, "alerts"), structured: Kept(alerts: alerts))
        }
    }

    struct ResourceGraph: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String }
        static let name = "resource-graph"
        static let summary = "Run a KQL query over the subscription's resources and return its columns and rows. Read-only."
        static let input = JSONSchema.object(["query": .string("The KQL query. End with take or summarize to keep results small.")], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Options: Encodable { let resultFormat = "table" }
            struct Body: Encodable { let subscriptions: [String]; let query: String; let options = Options() }
            struct Column: Decodable { let name: String }
            struct Table: Decodable { let columns: [Column]; let rows: [[CellValue]] }
            struct Answer: Decodable { let data: Table }
            let subscription = try Azure.guid(service.setting("subscription"))
            let answer = try await service.post(["providers", "Microsoft.ResourceGraph", "resources"],
                body: Body(subscriptions: [subscription], query: try ServiceInput.query(input.query)),
                query: ["api-version": "2022-10-01"], as: Answer.self)
            return try ServiceTable(columns: answer.data.columns.map(\.name), rows: answer.data.rows).result()
        }
    }

    struct RoleAssignments: ServiceOperation {
        struct Input: Decodable, Sendable { let principalId: String?, atScope: Bool? }
        static let name = "role-assignments"
        static let summary = "Who has access to the subscription, with each assignment's role name and scope."
        static let input = JSONSchema.object([
            "principalId": .string("Only this principal's object ID."),
            "atScope": .boolean("Only assignments at the subscription's scope or above."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard input.principalId == nil || input.atScope != true else { throw ServiceError.input("Give a principalId or atScope, not both.") }
            var query: [String: String?] = ["api-version": "2022-04-01"]
            if let principal = input.principalId { query["$filter"] = "principalId eq '\(try Azure.guid(principal))'" }
            if input.atScope == true { query["$filter"] = "atScope()" }
            struct Properties: Codable { let principalId: String?, principalType: String?, roleDefinitionId: String?, scope: String? }
            struct Assignment: Codable { let id: String; let properties: Properties }
            struct Definition: Decodable {
                struct Properties: Decodable { let roleName: String? }
                let id: String; let properties: Properties
            }
            let assignments = try await Azure.list(service, path: Azure.path(service, "Microsoft.Authorization", "roleAssignments"), query: query, as: Assignment.self)
            let definitions = try await Azure.list(service, path: Azure.path(service, "Microsoft.Authorization", "roleDefinitions"),
                query: ["api-version": "2022-04-01"], as: Definition.self)
            func roleKey(_ id: String) -> String { String(id.split(separator: "/").last ?? "").lowercased() }
            let names = Dictionary(definitions.value.map { (roleKey($0.id), $0.properties.roleName ?? $0.id) }, uniquingKeysWith: { first, _ in first })
            struct Kept: Encodable { let id: String; let properties: Properties; let roleName: String? }
            struct Answer: Encodable { let assignments: [Kept] }
            let kept = assignments.value.map { Kept(id: $0.id, properties: $0.properties, roleName: $0.properties.roleDefinitionId.flatMap { names[roleKey($0)] }) }
            let text = kept.isEmpty ? "No access matches." : kept.prefix(30).map {
                "\($0.properties.principalId ?? "?"): \($0.roleName ?? $0.properties.roleDefinitionId ?? "?") on \($0.properties.scope ?? "?")"
            }.joined(separator: "\n")
            let count = kept.count > 30 ? "\nShowing 30 of \(kept.count)\(assignments.more ? " read so far" : " total") assignments." : ""
            return try ServiceResult(text: text + count + Azure.stopped(assignments.more, "role assignments") + Azure.stopped(definitions.more, "role definitions"), structured: Answer(assignments: kept))
        }
    }
}
