import Foundation
import NoodleCore
import NoodleToolConnections

/// Elasticsearch: queries in ES|QL over the indices an API key can read. Each account is one deployment. check-access
/// reads whose key it is, the indices it can see and whether it may read them, and whether ES|QL runs.
///
/// The tool's guide is Incubator/Pion/docs/tools/elastic.md. Change it with the setup steps or operations here.
public enum Elastic {
    public static let preset = ToolDefinition(
        id: "4909bc20-0c1d-4302-8c33-0fa24c127abf", name: "Elastic", summary: "Query logs and security events in Elasticsearch with ES|QL.",
        defaultInstructions: """
        Use Elastic to query logs and security events with ES|QL, such as FROM logs-* | WHERE source.ip == "203.0.113.77" \
        | SORT @timestamp DESC | LIMIT 50. Filter by time and end with LIMIT to keep results small. Record each query and \
        what it returned as evidence, with the query itself as the method. ES|QL only reads. When a query is refused, run \
        check-access and tell the champion exactly what it says to change.
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
        "For the address, give the Elasticsearch endpoint's host, not Kibana's; on Elastic Cloud it is on the deployment's page. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [ESQL(), CheckAccess()])
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

extension Elastic {
    static let fixes = AccessCheck.Fixes(
        rejected: "Elasticsearch did not accept the API key: it is wrong, has expired or was invalidated, or it was made on another deployment. Make a new one under Stack Management › API keys and enter its Encoded value again in Settings › Tools.",
        forbidden: "the API key may not do this: give its role descriptor read and view_index_metadata on the indices agents should search.",
        unreachable: "Pion could not reach Elasticsearch: check the address in Settings › Tools, which is the Elasticsearch endpoint's host, not Kibana's.",
        notFound: "Elasticsearch does not offer this here: check that the address is the Elasticsearch endpoint, not Kibana's.")

    /// Reads whose key it is, the indices and data streams it can see, whether it may read them, and whether ES|QL runs,
    /// with a query that reads no index.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Tries the API key once and says whose it is, which indices and data streams it can see and may read, and whether ES|QL runs, and what to change for what does not work. It sends only reads, and its ES|QL query reads no index."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var check = AccessCheck(Elastic.fixes)
            check.note("Elasticsearch at \(service.base.host ?? "?").")
            struct Key: Decodable { let id: String?; let name: String? }
            struct Identity: Decodable { let username: String?; let authentication_type: String?; let api_key: Key? }
            guard await check.probe("API key", { () async throws -> String in
                let identity = try await service.get(["_security", "_authenticate"], as: Identity.self)
                let key = identity.api_key.map { key in "the API key \(key.name.map { "\"\($0)\"" } ?? key.id ?? "?")" } ?? "a sign-in of type \(identity.authentication_type ?? "?")"
                return key + " of \(identity.username ?? "?")"
            }) else { return try check.result() }

            struct Named: Decodable { let name: String }
            struct Resolved: Decodable { let indices: [Named]?; let aliases: [Named]?; let data_streams: [Named]? }
            var names: [String] = []
            await check.probe("Indices it can see", forbidden: "the API key may not see index metadata: add view_index_metadata to its indices privileges.") {
                let resolved = try await service.get(["_resolve", "index", "*"], as: Resolved.self)
                names = ((resolved.data_streams ?? []) + (resolved.indices ?? []) + (resolved.aliases ?? [])).map(\.name)
                guard !names.isEmpty else {
                    throw ServiceError.input("the API key sees no index or data stream: give its role descriptor read and view_index_metadata on the indices agents should search, such as logs-*.")
                }
                return "\(AccessCheck.count(names.count, "index or data stream", "indices and data streams"))"
            }
            if !names.isEmpty {
                let asked = Array(names.prefix(50))
                struct Ask: Encodable { struct Index: Encodable { let names: [String]; let privileges: [String] }; let index: [Index] }
                struct Held: Decodable { let index: [String: [String: Bool]]? }
                await check.probe("Reading them") {
                    let held = try await service.post(["_security", "user", "_has_privileges"], body: Ask(index: [.init(names: asked, privileges: ["read"])]), as: Held.self)
                    let readable = asked.filter { held.index?[$0]?["read"] == true }, unreadable = asked.filter { held.index?[$0]?["read"] != true }
                    guard !readable.isEmpty else {
                        throw ServiceError.input("the API key sees indices but may read none of them: add read to its indices privileges.")
                    }
                    return "it may read \(readable.prefix(20).joined(separator: ", "))\(readable.count > 20 ? ", …" : "")"
                        + (unreadable.isEmpty ? "" : "; not \(unreadable.prefix(10).joined(separator: ", "))\(unreadable.count > 10 ? ", …" : "")")
                        + (names.count > asked.count ? " (the first \(asked.count) tried)" : "")
                }
            }
            struct Body: Encodable { let query: String }
            struct Answer: Decodable { let values: [[CellValue]]? }
            await check.probe("ES|QL", forbidden: "ES|QL is refused: the deployment may be older than 8.11, which first offers it, or its license or the key's privileges exclude it.") {
                _ = try await service.post(["_query"], body: Body(query: "ROW ok = 1"), as: Answer.self)
                return "runs"
            }
            return try check.result()
        }
    }
}
