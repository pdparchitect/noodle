import Foundation
import NoodleCore
import NoodleToolConnections

/// Microsoft Sentinel: KQL over its Log Analytics workspace, read through the Log Analytics query API as the admin who
/// signs in. Each account is one workspace.
///
/// It signs in as Microsoft Entra ID's tools do: OAuth at the tenant's own address, an authorization code and PKCE,
/// through a public client app registration made for it, with no client secret. One sign-in gets tokens for one API, and
/// every request goes to the query API alone, so it asks only for Log Analytics' Data.Read; what the admin may query is
/// what their roles on the workspace allow, which the setup keeps to reading.
///
/// Its guide is Incubator/Pion/docs/tools/sentinel.md. Change it with the setup steps, roles or operations here.
public enum Sentinel {
    public static let preset = ToolDefinition(
        id: "812bf7c3-d2a3-4121-9026-a2e503ad1182", name: "Microsoft Sentinel", summary: "Query a Sentinel workspace's logs with KQL.",
        defaultInstructions: """
        Use Microsoft Sentinel to query the logs in its Log Analytics workspace with KQL, such as SigninLogs, \
        SecurityEvent, AzureActivity, CommonSecurityLog or SecurityAlert. For what an account touched, OfficeActivity holds \
        its Microsoft 365 activity, such as Operation "FileDownloaded", "FileAccessed" or "MailItemsAccessed"; AuditLogs holds \
        directory changes, such as roles granted or app secrets added; SigninLogs and AADNonInteractiveUserSignInLogs its \
        sign-ins. Each table is there only if its connector is on. Filter by time and end with take or summarize \
        to keep results small. Record each query and what it returned as evidence, with the query itself as the method. \
        KQL only reads. When a query is refused or a table you expect seems missing, run check-access and tell the \
        champion exactly what it says to change.
        """,
        iconName: "sentinel",
        configuration: .connection(.init(endpointTemplate: "https://api.loganalytics.azure.com/v1/workspaces/{workspace}",
                                         fields: Entra.fields + [ToolField(key: "workspace", title: "Workspace ID", placeholder: "8a7f3c2e-0000-4000-8000-000000000003", kind: .identifier)],
                                         oauth: Entra.oauth(scopes: scopes), oauthClientField: "clientID", oauthPathField: "tenant",
                                         oauthPathExcludes: Entra.generic, adapter: "sentinel")),
        setup: setup)

    /// The Log Analytics API's resource, which its tokens must name, whichever of its hosts the requests go to.
    static let resource = "https://api.loganalytics.io"
    /// Its one delegated permission, which reads what the admin's roles on a workspace let them read.
    static let permission = "Data.Read"
    static let scopes = [resource + "/" + permission]

    static let setup = Azure.appSteps("Pion Sentinel", api: "**APIs my organization uses**, search for **Log Analytics API**", permission: permission,
                                      resource: resource) + [
        "Each query runs as the signed-in admin, with their own roles on the workspace: `Data.Read` adds no rights of its own. Keep an admin for Pion Sentinel alone, such as pion-sentinel@contoso.com. In the [Azure portal](https://portal.azure.com), open the Log Analytics workspace behind Microsoft Sentinel, choose **Access control (IAM) › Add role assignment**, and give that admin only **Log Analytics Reader**, or **Microsoft Sentinel Reader**, which reads the same logs. Neither can change anything.",
        "Give the **Directory (tenant) ID** and the app's **Application (client) ID** from its **Overview**, and the **Workspace ID** from the workspace's **Overview**. Choose **Add & Connect** and sign in as that admin. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [Query(), CheckAccess()], trigger: HighIncidents())

    /// What to change when the query API refused, from what it said; nil for any other failure.
    static func fix(for error: Error) -> String? {
        switch error {
        case ServiceError.rejected:
            return "Microsoft did not accept the sign-in: it expired or was revoked, the admin's account was disabled or their password changed, or a Conditional Access policy now blocks it. Connect the tool again in Settings › Tools."
        case ServiceError.forbidden:
            return "the signed-in admin may not query this workspace: give them Log Analytics Reader or Microsoft Sentinel Reader on it in the Azure portal's Access control (IAM), allow a few minutes for it to apply, and check the Workspace ID in Settings › Tools."
        default: return nil
        }
    }

    /// A request, with the query API's refusal said as what to change.
    static func read<Value>(_ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch {
            guard let fix = fix(for: error) else { throw error }
            let said: String? = switch error {
            case ServiceError.forbidden(let reason), ServiceError.rejected(let reason): reason
            default: nil
            }
            throw ServiceError.input("Log Analytics refused the query\(said.map { " (it said: \($0))" } ?? ""): \(fix) Running check-access shows what this tool can and cannot do.")
        }
    }

    struct Column: Decodable { let name: String }
    struct Table: Decodable { let columns: [Column]?; let rows: [[CellValue]]? }
    struct Answer: Decodable { let tables: [Table]? }
    struct Body: Encodable { let query: String; let timespan: String }

    /// One KQL query over the workspace, for `timespan`.
    static func query(_ service: ServiceClient, _ query: String, timespan: String) async throws -> Table? {
        try await read { try await service.post(["query"], body: Body(query: query, timespan: timespan), as: Answer.self) }.tables?.first
    }

    /// New high-severity incidents, by their latest record, so one raised to high after it was made counts too.
    struct HighIncidents: ServiceTrigger {
        var tool: String { Query.name }
        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            let from = ISO8601DateFormatter().string(from: since)
            let query = """
            SecurityIncident
            | summarize arg_max(TimeGenerated, Severity, CreatedTime) by IncidentNumber
            | where CreatedTime >= datetime(\(from)) and Severity == "High"
            | order by CreatedTime desc
            | take \(ServiceAlert.most)
            """
            let table = try await Sentinel.query(service, query, timespan: from + "/" + ISO8601DateFormatter().string(from: Date()))
            let names = table?.columns?.map(\.name) ?? []
            guard let number = names.firstIndex(of: "IncidentNumber"), let created = names.firstIndex(of: "CreatedTime") else { return [] }
            return (table?.rows ?? []).compactMap { row -> ServiceAlert? in
                guard row.indices.contains(number), row.indices.contains(created) else { return nil }
                let id: String? = switch row[number] {
                case .number(let value): String(Int(value))
                case .text(let value): value
                default: nil
                }
                guard let id, case .text(let time) = row[created], let date = ServiceAlert.time(time) else { return nil }
                return ServiceAlert(id: id, time: date)
            }.sorted { $0.time > $1.time }
        }
    }
}

extension Sentinel {
    struct Query: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String, timespan: String? }
        static let name = "query"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Run a KQL query over the workspace and return its columns and rows. Read-only."
        static let input = JSONSchema.object([
            "query": .string("The KQL query. Filter by time and end with take or summarize."),
            "timespan": .string("How far back, in ISO 8601, such as PT12H, P7D or 2026-11-13/2026-11-14. The last 7 days when left out."),
        ], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let timespan = input.timespan?.trimmingCharacters(in: .whitespaces) ?? "P7D"
            guard !timespan.isEmpty, timespan.count <= 60, !timespan.contains(where: { $0.isWhitespace || $0 == "\"" }) else {
                throw ServiceError.input("Give the timespan in ISO 8601, such as P7D.")
            }
            let table = try await Sentinel.query(service, try ServiceInput.query(input.query), timespan: timespan)
            return try ServiceTable(columns: table?.columns?.map(\.name) ?? [], rows: table?.rows ?? []).result()
        }
    }
}

extension Sentinel {
    /// Tries a query over the workspace, and the incidents table the watch reads, and says what works and what to change.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Tries a query over the workspace, and Microsoft Sentinel's incidents, which the alert watch reads, and says what works and, for what does not, exactly what to change: the signed-in admin's role on the workspace, the Workspace ID or signing in again; and the app and permission it signed in with. It changes nothing."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            func check(_ title: String, _ query: String) async -> String {
                do { _ = try await Sentinel.query(service, query, timespan: "P1D"); return "✓ \(title)" }
                catch ServiceError.input(let said) { return "✗ \(title): \(said)" }
                catch { return "✗ \(title): \(error.localizedDescription)" }
            }
            var lines = [await check("Querying the workspace", "print ok = 1")]
            let incidents = await check("Microsoft Sentinel's incidents, which the alert watch reads", "SecurityIncident | take 1")
            lines.append(incidents.hasPrefix("✗") && !incidents.contains("Log Analytics refused")
                ? incidents + " If the workspace has no SecurityIncident table, Microsoft Sentinel is not turned on for it, so the watch has nothing to wake for."
                : incidents)
            lines.append(Azure.signInLine(service, scopes: Sentinel.scopes))
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
