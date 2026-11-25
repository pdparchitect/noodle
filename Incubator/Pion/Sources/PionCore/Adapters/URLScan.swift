import Foundation
import NoodleCore
import NoodleToolConnections

/// urlscan.io: earlier scans of pages, searched by domain, IP address, URL or hash, with the person's API key.
/// Nothing is submitted for scanning. check-access reads the key's quotas.
///
/// The tool's guide is Incubator/Pion/docs/tools/threat-intel.md. Change it with the setup steps or operations here.
public enum URLScan {
    public static let preset = ToolDefinition(
        id: "1c56a13d-c7fe-4905-ab05-732e0351c0a5", name: "urlscan.io", summary: "Search earlier scans of web pages: what a URL showed, where it was hosted, and its verdict.",
        defaultInstructions: """
        Use urlscan.io to search scans other people already made of web pages, by domain, IP address, URL or hash, such \
        as domain:example.com or page.ip:203.0.113.77: what each page showed, where it was hosted, and urlscan's verdict. \
        Record each search as evidence. Searches never submit anything for scanning, so they never reveal what you are \
        looking at. When a search is refused, run check-access and tell the champion exactly what it says to change.
        """,
        iconName: "urlscan",
        configuration: .connection(.init(endpoint: URL(string: "https://urlscan.io/api/v1")!, tokenHeader: "API-Key", adapter: "urlscan")),
        setup: setup)

    static let setup = [
        "Sign in at [urlscan.io](https://urlscan.io), or create a free account.",
        "Open **Settings & API › API Keys**, choose **New API key**, and paste the key here. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [Search(), CheckAccess()])
}

extension URLScan {
    struct Search: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String, limit: Int? }
        static let name = "search"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Search earlier scans, newest first, with each page's URL, domain, IP address, country, title and verdict."
        static let input = JSONSchema.object([
            "query": .string("A urlscan search, such as domain:example.com, page.ip:203.0.113.77 or hash:<sha256>."),
            "limit": .integer("How many scans, at most.", minimum: 1, maximum: 100),
        ], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let query = try ServiceInput.query(input.query, limit: 500)
            let limit = input.limit ?? 20
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 scans.") }
            struct Task: Codable { let url: String?; let time: String? }
            struct Page: Codable { let domain: String?, ip: String?, country: String?, title: String?, status: String? }
            struct Overall: Codable { let malicious: Bool?; let score: Int? }
            struct Verdicts: Codable { let overall: Overall? }
            struct Scan: Codable { let _id: String?, task: Task?, page: Page?, verdicts: Verdicts?, result: String?, screenshot: String? }
            struct Answer: Decodable { let total: Int?; let results: [Scan]? }
            struct Scans: Encodable { let total: Int?; let scans: [Scan] }
            let answer = try await service.get(["search"], query: ["q": query, "size": String(limit)], trailingSlash: true, as: Answer.self)
            let scans = answer.results ?? []
            let text = scans.isEmpty ? "No scans match." : "\(answer.total ?? scans.count) scan\(scans.count == 1 ? "" : "s") match, newest first:\n" + scans.prefix(20).map { scan in
                var line = "\(scan.task?.time ?? "?") \(scan.task?.url ?? "?")"
                if let overall = scan.verdicts?.overall, overall.malicious == true { line += " — malicious (score \(overall.score ?? 0))" }
                let page = [scan.page?.ip, scan.page?.country, scan.page?.title.map { "\"\($0)\"" }].compactMap { $0 }
                if !page.isEmpty { line += " — " + page.joined(separator: ", ") }
                return line
            }.joined(separator: "\n")
            return try ServiceResult(text: text, structured: Scans(total: answer.total, scans: scans))
        }
    }
}

extension URLScan {
    static let fixes = AccessCheck.Fixes(
        rejected: "urlscan.io did not accept the key: it is wrong or was deleted. Make a new one under Settings & API › API Keys and enter it again in Settings › Tools.",
        forbidden: "urlscan.io refused the key for this: the account's plan may not include it.",
        rateLimited: "the key's searches for this minute, hour or day are used up: wait for the window to pass, or use a paid plan.")

    /// Reads the key's quotas, which searches nothing, and says how many searches are left in each window.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Tries the key once with a read of its quotas, which searches nothing, and says how many searches are left this minute, hour and day, or what to change."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var check = AccessCheck(URLScan.fixes)
            struct Window: Decodable { let limit: Double?; let used: Double?; let remaining: Double? }
            struct Quotas: Decodable { let limits: [String: [String: Window]]? }
            await check.probe("API key") {
                let quotas = try await service.get(["quotas"], as: Quotas.self)
                guard let search = quotas.limits?["search"], !search.isEmpty else { return "it works" }
                let windows = ["minute", "hour", "day"].compactMap { period -> String? in
                    guard let window = search[period], let limit = AccessCheck.whole(window.limit) else { return nil }
                    let left = AccessCheck.whole(window.remaining ?? window.limit.map { $0 - (window.used ?? 0) }) ?? "?"
                    return "\(left) of \(limit) this \(period)"
                }
                return "it works; searches left: " + (windows.isEmpty ? "not reported" : windows.joined(separator: ", "))
            }
            return try check.result()
        }
    }
}
