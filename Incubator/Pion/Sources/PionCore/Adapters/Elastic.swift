import Foundation
import NoodleCore
import NoodleToolConnections

/// Elasticsearch: queries in ES|QL over the indices an API key can read. Each account is one deployment.
public enum Elastic {
    public static let preset = ToolDefinition(
        id: "4909bc20-0c1d-4302-8c33-0fa24c127abf", name: "Elastic", summary: "Query logs and security events in Elasticsearch with ES|QL.",
        defaultInstructions: """
        Use Elastic to query logs and security events with ES|QL, such as FROM logs-* | WHERE source.ip == "203.0.113.77" \
        | SORT @timestamp DESC | LIMIT 50. Filter by time and end with LIMIT to keep results small. Record each query and \
        what it returned as evidence, with the query itself as the method. ES|QL only reads.
        """,
        iconName: "elastic",
        configuration: .connection(.init(endpointTemplate: "https://{host}",
            fields: [ToolField(key: "host", title: "Elasticsearch address", placeholder: "acme.es.eu-west-1.aws.elastic.cloud", kind: .host)],
            tokenHeader: "Authorization", tokenScheme: "ApiKey", adapter: "elastic")),
        setup: setup)

    static let setup = [
        "In Kibana, open **Stack Management › API keys** and choose **Create API key**.",
        "Turn on **Control security privileges** and let it only read the indices agents should search, such as `{\"pion\": {\"indices\": [{\"names\": [\"logs-*\"], \"privileges\": [\"read\", \"view_index_metadata\"]}]}}`.",
        "Copy the **Encoded** key and paste it here.",
        "For the address, give the Elasticsearch endpoint's host, not Kibana's; on Elastic Cloud it is on the deployment's page.",
    ]

    public static let adapter = OperationAdapter(operations: [ESQL()])
}

extension Elastic {
    struct ESQL: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String }
        static let name = "esql"
        static let jobs: Set<ToolJob> = [.detection]
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
