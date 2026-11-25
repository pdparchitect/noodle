import Foundation
import NoodleCore
import NoodleToolConnections

/// Splunk: searches in SPL, run once and returned, with an authentication token. Each account is one deployment.
/// check-access reads whose token it is and runs one search of index metadata.
///
/// The tool's guide is Incubator/Pion/docs/tools/splunk.md. Change it with the setup steps or operations here.
public enum Splunk {
    public static let preset = ToolDefinition(
        id: "dd7f89a9-d5ac-4f3c-9895-86725cd21c1b", name: "Splunk", summary: "Search logs and events with SPL.",
        defaultInstructions: """
        Use Splunk to search the logs and events it holds with SPL. Name the index, keep a time range and end with a \
        head, stats or table to keep results small. Record each search and what it returned as evidence, with the search \
        itself as the method. Searches only read: commands that write or send, such as delete, outputlookup, collect or \
        sendemail, are refused. When a search is refused, run check-access and tell the champion exactly what it says to \
        change.
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
        "Copy the token and paste it here. For the address, give the host only, such as `acme.splunkcloud.com`. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [Search(), CheckAccess()])

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

extension Splunk {
    static let fixes = AccessCheck.Fixes(
        rejected: "Splunk did not accept the token: it is wrong, has expired or was deleted, or token authentication is turned off. Make a new token under Settings › Tokens and enter it again in Settings › Tools.",
        forbidden: "the token's user may not do this: give its role the search capability under Settings › Roles.",
        rateLimited: "Splunk is turning searches away: the user's role has reached its limit of searches at once. Wait, or raise the role's search limits.",
        unreachable: "Pion could not reach the REST API on port 8089. On Splunk Cloud, add this Mac's public IP address to the search-api allow list with the Admin Config Service, or ask Splunk Support; free trials have no REST access. Otherwise check the address in Settings › Tools.")

    /// Capabilities that change Splunk or its users, which a role made for searching never needs.
    static let changing: Set = ["admin_all_objects", "delete_by_keyword", "edit_user", "edit_roles", "edit_tokens_all", "edit_tokens_settings",
                                "change_authentication", "edit_indexes"]

    /// Reads whose token it is, with its roles and capabilities, then lists the indexes it may search with one search of
    /// index metadata, which reads no events.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Tries the token once and says whose it is, with its roles, whether they may search, and which indexes they may search, and what to change for what does not work. It sends only reads: one search of index metadata, which reads no events."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var check = AccessCheck(Splunk.fixes)
            check.note("Splunk at \(service.base.host ?? "?"), port \(service.base.port.map(String.init) ?? "8089").")
            struct Content: Decodable { let username: String?; let roles: [String]?; let capabilities: [String]? }
            struct Entry: Decodable { let content: Content? }
            struct Context: Decodable { let entry: [Entry]? }
            var capabilities: Set<String>?
            await check.probe("Token") {
                let content = try await service.get(["authentication", "current-context"], query: ["output_mode": "json"], as: Context.self).entry?.first?.content
                capabilities = Set(content?.capabilities ?? [])
                return "user \(content?.username ?? "?"), with the role\((content?.roles ?? []).count == 1 ? "" : "s") \((content?.roles ?? []).joined(separator: ", "))"
            }
            guard let capabilities else { return try check.result() }
            if !capabilities.isEmpty, !capabilities.contains("search") {
                check.fail("Searches", "the user's roles lack the search capability: give the role search under Settings › Roles.")
            } else {
                struct Answer: Decodable { let results: [[String: CellValue]]? }
                await check.probe("Searches") {
                    let answer = try await service.postForm(["search", "jobs"], form: [
                        "search": "| eventcount summarize=false index=* | dedup index | fields index", "exec_mode": "oneshot",
                        "output_mode": "json", "count": "200",
                    ], as: Answer.self)
                    let indexes = (answer.results ?? []).compactMap { row -> String? in
                        if case .text(let name) = row["index"] ?? .none { return name }
                        return nil
                    }.sorted()
                    guard !indexes.isEmpty else {
                        throw ServiceError.input("searches run, but the role may search no index: add the indexes agents should read to the role's indexes under Settings › Roles.")
                    }
                    return "the role may search \(AccessCheck.count(indexes.count, "index", "indexes")): \(indexes.prefix(30).joined(separator: ", "))\(indexes.count > 30 ? ", …" : "")"
                }
            }
            let extra = capabilities.intersection(Splunk.changing).sorted()
            if !extra.isEmpty {
                check.note("The role also holds capabilities that change Splunk, which searching never needs: \(extra.joined(separator: ", ")). Searches here only read, but a role with only search is safer.")
            }
            return try check.result()
        }
    }
}
