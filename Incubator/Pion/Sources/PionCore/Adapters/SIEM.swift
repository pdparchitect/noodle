import Foundation
import NoodleCore
import NoodleMCP

/// Splunk: searches in SPL, run once and returned, with an authentication token. Each account is one deployment.
public enum Splunk {
    public static let preset = ToolDefinition(
        id: "splunk", name: "Splunk", summary: "Search logs and events with SPL.",
        defaultInstructions: """
        Use Splunk to search the logs and events it holds with SPL. Name the index, keep a time range and end with a \
        head, stats or table to keep results small. Record each search and what it returned as evidence, with the search \
        itself as the method. Searches only read: commands that write or send, such as delete, outputlookup, collect or \
        sendemail, are refused.
        """,
        iconName: "splunk",
        configuration: .mcp(.init(endpointTemplate: "https://{host}:8089/services",
            fields: [ToolField(key: "host", title: "Splunk address", placeholder: "acme.splunkcloud.com", kind: .host)],
            tokenHeader: "Authorization", adapter: "splunk")))

    public static let adapter = OperationAdapter(operations: [Search()])

    /// SPL commands that change data or reach out, which a read-only search never needs.
    static let writing: Set = ["delete", "outputlookup", "outputcsv", "outputtext", "collect", "mcollect", "meventcollect", "tscollect",
                               "sendemail", "sendalert", "script", "run", "dump"]
}

extension Splunk {
    struct Search: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String, earliest: String?, latest: String?, limit: Int? }
        static let name = "search"
        static let summary = "Run an SPL search once and return its results. Read-only."
        static let input = JSONSchema.object([
            "query": .string("The SPL search, such as index=auth action=failure | stats count by src_ip."),
            "earliest": .string("The earliest time, in Splunk's form (-24h, -7d@d) or ISO 8601. The last 24 hours when left out."),
            "latest": .string("The latest time, in the same forms. Now when left out."),
            "limit": .integer("How many results, at most.", minimum: 1, maximum: 500),
        ], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query = try ServiceInput.query(input.query)
            // Every command after a pipe, and a search that starts with one, is checked against those that write.
            let commands = query.split(separator: "|").compactMap { $0.split(whereSeparator: \.isWhitespace).first?.lowercased() }
            if let command = commands.first(where: Splunk.writing.contains) {
                throw ServiceError.input("\(command) changes data or sends it; searches here only read.")
            }
            if !query.hasPrefix("|"), !query.lowercased().hasPrefix("search ") { query = "search " + query }
            func time(_ value: String?, _ fallback: String) throws -> String {
                guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return fallback }
                guard value.count <= 40, value.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "0123456789+-@:.TZtzsmhdwqyonmc").contains) else {
                    throw ServiceError.input("Give times as -24h, -7d@d, now or ISO 8601.")
                }
                return value
            }
            let limit = input.limit ?? 100
            guard (1...500).contains(limit) else { throw ServiceError.input("Ask for between 1 and 500 results.") }
            struct Field: Decodable { let name: String }
            struct Answer: Decodable { let fields: [Field]?; let results: [[String: CellValue]]? }
            let answer = try await service.postForm(["search", "jobs"], form: [
                "search": query, "exec_mode": "oneshot", "output_mode": "json", "count": String(limit),
                "earliest_time": try time(input.earliest, "-24h"), "latest_time": try time(input.latest, "now"),
            ], as: Answer.self)
            let results = answer.results ?? []
            let columns = answer.fields?.map(\.name) ?? Array(Set(results.flatMap(\.keys))).sorted()
            return try ServiceTable(columns: columns, rows: results.map { row in columns.map { row[$0] ?? .none } }).result()
        }
    }
}

/// Elasticsearch: queries in ES|QL over the indices an API key can read. Each account is one deployment.
public enum Elastic {
    public static let preset = ToolDefinition(
        id: "elastic", name: "Elastic", summary: "Query logs and security events in Elasticsearch with ES|QL.",
        defaultInstructions: """
        Use Elastic to query logs and security events with ES|QL, such as FROM logs-* | WHERE source.ip == "203.0.113.77" \
        | SORT @timestamp DESC | LIMIT 50. Filter by time and end with LIMIT to keep results small. Record each query and \
        what it returned as evidence, with the query itself as the method. ES|QL only reads.
        """,
        iconName: "elastic",
        configuration: .mcp(.init(endpointTemplate: "https://{host}",
            fields: [ToolField(key: "host", title: "Elasticsearch address", placeholder: "acme.es.eu-west-1.aws.elastic.cloud", kind: .host)],
            tokenHeader: "Authorization", tokenScheme: "ApiKey", adapter: "elastic")))

    public static let adapter = OperationAdapter(operations: [ESQL()])
}

extension Elastic {
    struct ESQL: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String }
        static let name = "esql"
        static let summary = "Run an ES|QL query and return its columns and rows. Read-only."
        static let input = JSONSchema.object(["query": .string("The ES|QL query. Filter by time and end with LIMIT.")], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Body: Encodable { let query: String }
            struct Column: Decodable { let name: String }
            struct Answer: Decodable { let columns: [Column]?; let values: [[CellValue]]? }
            let answer = try await service.post(["_query"], body: Body(query: try ServiceInput.query(input.query)), as: Answer.self)
            return try ServiceTable(columns: answer.columns?.map(\.name) ?? [], rows: answer.values ?? []).result()
        }
    }
}

/// Microsoft Sentinel: KQL over its Log Analytics workspace, reached as an app registered in the tenant.
/// Each account is one workspace.
public enum Sentinel {
    public static let preset = ToolDefinition(
        id: "sentinel", name: "Microsoft Sentinel", summary: "Query a Sentinel workspace's logs with KQL.",
        defaultInstructions: """
        Use Microsoft Sentinel to query the logs in its Log Analytics workspace with KQL, such as SigninLogs, \
        SecurityEvent, AzureActivity, CommonSecurityLog or SecurityAlert. Filter by time and end with take or summarize \
        to keep results small. Record each query and what it returned as evidence, with the query itself as the method. \
        KQL only reads.
        """,
        iconName: "sentinel",
        configuration: .mcp(.init(endpointTemplate: "https://api.loganalytics.azure.com/v1/workspaces/{workspace}",
            fields: [ToolField(key: "tenant", title: "Directory (tenant) ID", placeholder: "contoso.onmicrosoft.com", kind: .identifier),
                     ToolField(key: "workspace", title: "Workspace ID", placeholder: "8a7f3c2e-0000-4000-8000-000000000002", kind: .identifier)],
            clientCredentials: ClientCredentialsPreset(tokenEndpointTemplate: "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
                                                       scope: "https://api.loganalytics.io/.default"),
            adapter: "sentinel")))

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
