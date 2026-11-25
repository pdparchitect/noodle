import Foundation
import NoodleCore
import NoodleToolConnections

/// Splunk: searches in SPL, run once and returned, with an authentication token. Each account is one deployment.
public enum Splunk {
    public static let preset = ToolDefinition(
        id: "dd7f89a9-d5ac-4f3c-9895-86725cd21c1b", name: "Splunk", summary: "Search logs and events with SPL.",
        defaultInstructions: """
        Use Splunk to search the logs and events it holds with SPL. Name the index, keep a time range and end with a \
        head, stats or table to keep results small. Record each search and what it returned as evidence, with the search \
        itself as the method. Searches only read: commands that write or send, such as delete, outputlookup, collect or \
        sendemail, are refused.
        """,
        iconName: "splunk",
        configuration: .connection(.init(endpointTemplate: "https://{host}:8089/services",
            fields: [ToolField(key: "host", title: "Splunk address", placeholder: "acme.splunkcloud.com", kind: .host)],
            tokenHeader: "Authorization", adapter: "splunk")),
        setup: setup)

    static let setup = [
        "On Splunk Cloud, let this Mac reach the REST API on port 8089: add its public IP address to the `search-api` allow list with the Admin Config Service, or ask Splunk Support. Free trials have no REST access.",
        "Under **Settings › Roles**, make a role that can search only the indexes agents should read, and a user for Pion with that role.",
        "Under **Settings › Tokens**, turn on token authentication if it is off, then choose **New Token** for that user, with an expiry date.",
        "Copy the token and paste it here. For the address, give the host only, such as `acme.splunkcloud.com`.",
    ]

    public static let adapter = OperationAdapter(operations: [Search()])

    /// SPL commands that change data or reach out, which a read-only search never needs.
    static let writing: Set = ["delete", "outputlookup", "outputcsv", "outputtext", "collect", "mcollect", "meventcollect", "tscollect",
                               "sendemail", "sendalert", "script", "run", "dump"]
}

extension Splunk {
    struct Search: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String, earliest: String?, latest: String?, limit: Int? }
        static let name = "search"
        static let jobs: Set<ToolJob> = [.detection]
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
