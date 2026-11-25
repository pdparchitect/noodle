import Foundation
import NoodleCore
import NoodleToolConnections

/// Sumo Logic: log searches run as search jobs, read with an access ID and key. Each account is one deployment.
/// check-access starts one search job over the last minute and removes it at once.
///
/// The tool's guide is Incubator/Pion/docs/tools/sumo-logic.md. Change it with the setup steps or operations here.
public enum SumoLogic {
    static let deployments = [("api.sumologic.com", "US1"), ("api.us2.sumologic.com", "US2"), ("api.eu.sumologic.com", "EU"),
                              ("api.de.sumologic.com", "DE"), ("api.au.sumologic.com", "AU"), ("api.jp.sumologic.com", "JP"),
                              ("api.ca.sumologic.com", "CA"), ("api.in.sumologic.com", "IN"), ("api.fed.sumologic.com", "FED")]

    public static let preset = ToolDefinition(
        id: "14cc897d-ee46-4b5e-9664-955fdc5cf702", name: "Sumo Logic", summary: "Search logs with Sumo Logic queries.",
        defaultInstructions: """
        Use Sumo Logic to search logs, such as _sourceCategory=auth | where src_ip="203.0.113.77" | count by user. Keep a \
        time range and end aggregate queries with a count or limit. Record each search and what it returned as evidence, \
        with the query itself as the method. Searches only read. When a search is refused, run check-access and tell the \
        champion exactly what it says to change.
        """,
        iconName: "sumologic",
        configuration: .connection(.init(endpointTemplate: "https://{deployment}/api/v1",
            fields: [ToolField(key: "deployment", title: "Deployment", placeholder: "api.sumologic.com",
                               kind: .choice(deployments.map { .init(value: $0.0, title: $0.1) }))],
            tokenHeader: "Authorization", tokenScheme: "Basic",
            composedToken: ComposedToken(first: "Access ID", second: "Access Key", format: .basic), adapter: "sumologic")),
        setup: setup)

    static let setup = [
        "Use a Sumo Logic user for Pion whose role has the **Manage Access Keys** capability, and make the access key as that user; where Sumo Logic offers key scopes, give the key only **Run Log Search**. Searching through the API needs an Enterprise account.",
        "Signed in as that user, open **Preferences › My Access Keys** and choose **Add Access Key**. Copy its **Access ID** and **Access Key** here; the key is shown only once.",
        "For the deployment, choose the one your Sumo Logic address names: `service.eu.sumologic.com` is EU, and `service.sumologic.com` is US1. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [Search(), CheckAccess()])

    /// The cookie that names the node a search job lives on, which every later request of the job must carry.
    static func jobHeaders(_ response: HTTPURLResponse, on service: ServiceClient) -> [String: String] {
        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { fields, pair in
            if let name = pair.key as? String, let value = pair.value as? String { fields[name] = value }
        }
        let cookie = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: response.url ?? service.base)
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return cookie.isEmpty ? [:] : ["Cookie": cookie]
    }
}

extension SumoLogic {
    struct Search: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String, since: String?, until: String? }
        static let name = "search"
        static let jobs: Set<ToolJob> = [.detection]
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
            let headers = SumoLogic.jobHeaders(started.response, on: service)
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

extension SumoLogic {
    static let fixes = AccessCheck.Fixes(
        rejected: "Sumo Logic did not accept the access ID and key: they are wrong, the key was deleted or turned off, or it belongs to another deployment. Check the deployment, or make a new access key and enter both again in Settings › Tools.",
        forbidden: "Sumo Logic refused searching through the API: check that the account's plan includes the Search Job API, which needs an Enterprise account, that the user's role may search, and that an access key with scopes includes Run Log Search.",
        rateLimited: "Sumo Logic is limiting this key, to 4 requests a second and 10 at once, or the organisation to 200 searches running at once: wait before trying again.")

    /// Starts one search job over the last minute, the only part the tool uses, and removes it at once without reading it.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Tries the access key once by starting a search over the last minute, removed at once without reading it (on credit-based plans it may spend a little scan credit), and says whether searching works and, if not, what to change. It changes nothing in Sumo Logic."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var check = AccessCheck(SumoLogic.fixes)
            let deployment = SumoLogic.deployments.first { $0.0 == service.base.host }?.1 ?? service.base.host ?? "?"
            check.note("Sumo Logic deployment \(deployment).")
            await check.probe("Search jobs") {
                struct Start: Encodable { let query: String, from: String, to: String, timeZone: String }
                struct Started: Decodable { let id: String }
                let now = Date(), format = ISO8601DateFormatter()
                let body = Start(query: "* | limit 1", from: format.string(from: now.addingTimeInterval(-60)), to: format.string(from: now), timeZone: "UTC")
                let started: (data: Data, response: HTTPURLResponse)
                do { started = try await service.exchange(["search", "jobs"], method: "POST", body: try JSONEncoder().encode(body)) }
                catch ServiceError.status(let code, _) where (300..<400).contains(code) {
                    throw ServiceError.input("Sumo Logic sent the request to another deployment: choose the one your Sumo Logic address names in Settings › Tools.")
                }
                guard let job = try? JSONDecoder().decode(Started.self, from: started.data).id else { throw ServiceError.unreadable }
                _ = try? await service.data(["search", "jobs", job], method: "DELETE", headers: SumoLogic.jobHeaders(started.response, on: service))
                return "the key may search; which logs it finds depends on the role's search filter"
            }
            return try check.result()
        }
    }
}
