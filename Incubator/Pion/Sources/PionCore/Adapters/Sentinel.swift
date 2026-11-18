import Foundation
import NoodleCore
import NoodleMCP

/// Microsoft Sentinel: KQL over its Log Analytics workspace, reached as an app registered in the tenant.
/// Each account is one workspace.
public enum Sentinel {
    public static let preset = ToolDefinition(
        id: "812bf7c3-d2a3-4121-9026-a2e503ad1182", formerID: "sentinel", name: "Microsoft Sentinel", summary: "Query a Sentinel workspace's logs with KQL.",
        defaultInstructions: """
        Use Microsoft Sentinel to query the logs in its Log Analytics workspace with KQL, such as SigninLogs, \
        SecurityEvent, AzureActivity, CommonSecurityLog or SecurityAlert. Filter by time and end with take or summarize \
        to keep results small. Record each query and what it returned as evidence, with the query itself as the method. \
        KQL only reads.
        """,
        iconName: "sentinel",
        configuration: .connection(.init(endpointTemplate: "https://api.loganalytics.azure.com/v1/workspaces/{workspace}",
            fields: [ToolField(key: "tenant", title: "Directory (tenant) ID", placeholder: "contoso.onmicrosoft.com", kind: .identifier),
                     ToolField(key: "workspace", title: "Workspace ID", placeholder: "8a7f3c2e-0000-4000-8000-000000000002", kind: .identifier)],
            clientCredentials: ClientCredentialsPreset(tokenEndpointTemplate: "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
                                                       scope: "https://api.loganalytics.io/.default"),
            adapter: "sentinel")),
        setup: setup)

    static let setup = [
        "In the [Microsoft Entra admin center](https://entra.microsoft.com), open **App registrations** and choose **New registration**. Name it, such as Pion, keep **Single tenant** and leave the redirect URI empty. It needs no API permissions.",
        "Under **Certificates & secrets**, add a client secret and copy its **Value**, not its Secret ID; it is shown only once.",
        "In the [Azure portal](https://portal.azure.com), open the Log Analytics workspace behind Microsoft Sentinel, choose **Access control (IAM) › Add role assignment**, and give the app the **Log Analytics Reader** role.",
        "Copy the **Workspace ID** from the workspace's **Overview**, and the **Directory (tenant) ID** and **Application (client) ID** from the app's **Overview**.",
    ]

    public static let adapter = OperationAdapter(operations: [Query()])
}

extension Sentinel {
    struct Query: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String, timespan: String? }
        static let name = "query"
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
            struct Body: Encodable { let query: String; let timespan: String }
            struct Column: Decodable { let name: String }
            struct Table: Decodable { let columns: [Column]?; let rows: [[CellValue]]? }
            struct Answer: Decodable { let tables: [Table]? }
            let answer = try await service.post(["query"], body: Body(query: try ServiceInput.query(input.query), timespan: timespan), as: Answer.self)
            let table = answer.tables?.first
            return try ServiceTable(columns: table?.columns?.map(\.name) ?? [], rows: table?.rows ?? []).result()
        }
    }
}
