import Foundation
import NoodleCore
import NoodleMCP

/// Microsoft Defender XDR: its alerts and incidents, and advanced hunting across devices, email, identities and apps.
public enum Defender {
    public static let preset = Graph.preset(id: "eef1f5bd-b131-448f-9f37-0a3ba0beb217", formerID: "defender", key: "defender", name: "Microsoft Defender XDR",
        summary: "Alerts, incidents and advanced hunting across devices, email, identities and apps.",
        instructions: """
        Use Microsoft Defender XDR to see what Microsoft's detections found: list alerts and incidents by severity, status \
        and time, and hunt with KQL across the advanced hunting tables, such as DeviceProcessEvents, DeviceNetworkEvents, \
        EmailEvents and IdentityLogonEvents. Keep hunting queries narrow, with a time filter and a row limit. Record each \
        query and what it returned as evidence, with the query itself as the method. These tools only read: recommend \
        isolating a device or other responses to the champion.
        """,
        setup: setup)

    static let setup = [
        "In the [Microsoft Entra admin center](https://entra.microsoft.com), open **App registrations** and choose **New registration**. Name it, such as Pion, keep **Single tenant** and leave the redirect URI empty.",
        "Under **API permissions**, choose **Add a permission › Microsoft Graph › Application permissions** and add `SecurityAlert.Read.All`, `SecurityIncident.Read.All` and `ThreatHunting.Read.All`.",
        "Choose **Grant admin consent** for your tenant.",
        "Under **Certificates & secrets**, add a client secret and copy its **Value**, not its Secret ID; it is shown only once.",
        "From the app's **Overview**, copy the **Directory (tenant) ID** and the **Application (client) ID** into the fields here.",
        "One app can serve both Defender XDR and Entra ID when it has both sets of permissions.",
    ]

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
