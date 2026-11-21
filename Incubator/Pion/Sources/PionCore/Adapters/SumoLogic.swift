import Foundation
import NoodleCore
import NoodleToolConnections

/// Sumo Logic: log searches run as search jobs, read with an access ID and key. Each account is one deployment.
public enum SumoLogic {
    static let deployments = [("api.sumologic.com", "US1"), ("api.us2.sumologic.com", "US2"), ("api.eu.sumologic.com", "EU"),
                              ("api.de.sumologic.com", "DE"), ("api.au.sumologic.com", "AU"), ("api.jp.sumologic.com", "JP"),
                              ("api.ca.sumologic.com", "CA"), ("api.in.sumologic.com", "IN"), ("api.fed.sumologic.com", "FED")]

    public static let preset = ToolDefinition(
        id: "14cc897d-ee46-4b5e-9664-955fdc5cf702", name: "Sumo Logic", summary: "Search logs with Sumo Logic queries.",
        defaultInstructions: """
        Use Sumo Logic to search logs, such as _sourceCategory=auth | where src_ip="203.0.113.77" | count by user. Keep a \
        time range and end aggregate queries with a count or limit. Record each search and what it returned as evidence, \
        with the query itself as the method. Searches only read.
        """,
        iconName: "sumologic",
        configuration: .connection(.init(endpointTemplate: "https://{deployment}/api/v1",
            fields: [ToolField(key: "deployment", title: "Deployment", placeholder: "api.sumologic.com",
                               kind: .choice(deployments.map { .init(value: $0.0, title: $0.1) }))],
            tokenHeader: "Authorization", tokenScheme: "Basic",
            composedToken: ComposedToken(first: "Access ID", second: "Access Key", format: .basic), adapter: "sumologic")),
        setup: setup)

    static let setup = [
        "Use a Sumo Logic user for Pion whose role has the **Download Search Results** and **View Collectors** capabilities. Searching through the API needs an Enterprise account.",
        "Signed in as that user, open **Preferences › My Access Keys** and choose **Add Access Key**. Copy its **Access ID** and **Access Key** here; the key is shown only once.",
        "For the deployment, choose the one your Sumo Logic address names: `service.eu.sumologic.com` is EU, and `service.sumologic.com` is US1.",
    ]

    public static let adapter = OperationAdapter(operations: [Search()])
}

extension SumoLogic {
    struct Search: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String, since: String?, until: String? }
        static let name = "search"
        static let summary = "Run a Sumo Logic search over a time range and return its messages, or for an aggregate query its records. Read-only."
        static let input = JSONSchema.object([
            "query": .string("The Sumo Logic query."),
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out."),
            "until": .string("The latest time, in ISO 8601. Now when left out."),
        ], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Start: Encodable { let query: String, from: String, to: String, timeZone: String }
            struct Started: Decodable { let id: String }
            let body = Start(query: try ServiceInput.query(input.query), from: try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(1),
                             to: try input.until.map(ServiceInput.time) ?? ISO8601DateFormatter().string(from: Date()), timeZone: "UTC")
            let started = try await service.exchange(["search", "jobs"], method: "POST", body: try JSONEncoder().encode(body))
            guard let job = try? JSONDecoder().decode(Started.self, from: started.data).id else { throw ServiceError.unreadable }
            // A job lives on one of Sumo's nodes; every later request of it carries the cookie that names that node.
            let headerFields = started.response.allHeaderFields.reduce(into: [String: String]()) { fields, pair in
                if let name = pair.key as? String, let value = pair.value as? String { fields[name] = value }
            }
            let cookie = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: started.response.url ?? service.base)
                .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            let headers = cookie.isEmpty ? [:] : ["Cookie": cookie]
            // The job is removed once read, whether or not reading worked.
            do {
                let result = try await read(job, headers: headers, on: service)
                _ = try? await service.data(["search", "jobs", job], method: "DELETE", headers: headers)
                return result
            } catch {
                _ = try? await service.data(["search", "jobs", job], method: "DELETE", headers: headers)
                throw error
            }
        }

        /// Waits for the job to finish gathering, then reads its first page.
        private func read(_ job: String, headers: [String: String], on service: ServiceClient) async throws -> ServiceResult {
            struct Status: Decodable { let state: String?; let messageCount: Int?; let recordCount: Int? }
            var status: Status?
            for _ in 0..<30 {
                let current = try JSONDecoder().decode(Status.self, from: try await service.data(["search", "jobs", job], headers: headers))
                if current.state == "DONE GATHERING RESULTS" { status = current; break }
                if current.state == "CANCELLED" || current.state == "FORCE PAUSED" { throw ServiceError.refused("the search was \(current.state!.lowercased())") }
                try await Task.sleep(for: .seconds(1))
            }
            guard let status else { throw ServiceError.refused("the search is still running; narrow its time range") }
            struct Field: Decodable { let name: String }
            struct Row: Decodable { let map: [String: CellValue] }
            struct Page: Decodable { let fields: [Field]?; let messages: [Row]?; let records: [Row]? }
            let aggregate = (status.recordCount ?? 0) > 0
            let page = try JSONDecoder().decode(Page.self, from: try await service.data(["search", "jobs", job, aggregate ? "records" : "messages"],
                                                                                       query: ["offset": "0", "limit": "100"], headers: headers))
            let rows = (aggregate ? page.records : page.messages) ?? []
            let columns = page.fields?.map(\.name).filter { !$0.hasPrefix("_") || $0 == "_messagetime" } ?? []
            return try ServiceTable(columns: columns, rows: rows.map { row in columns.map { row.map[$0] ?? .none } }).result()
        }
    }
}
