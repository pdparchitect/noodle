import Foundation
import NoodleCore
import NoodleMCP

/// urlscan.io: earlier scans of pages, searched by domain, IP address, URL or hash, with the person's API key.
/// Nothing is submitted for scanning.
public enum URLScan {
    public static let preset = ToolDefinition(
        id: "urlscan", name: "urlscan.io", summary: "Search earlier scans of web pages: what a URL showed, where it was hosted, and its verdict.",
        defaultInstructions: """
        Use urlscan.io to search scans other people already made of web pages, by domain, IP address, URL or hash, such \
        as domain:example.com or page.ip:203.0.113.77: what each page showed, where it was hosted, and urlscan's verdict. \
        Record each search as evidence. Searches never submit anything for scanning, so they never reveal what you are \
        looking at.
        """,
        iconName: "urlscan",
        configuration: .connection(.init(endpoint: URL(string: "https://urlscan.io/api/v1")!, tokenHeader: "API-Key", adapter: "urlscan")))

    public static let adapter = OperationAdapter(operations: [Search()])
}

extension URLScan {
    struct Search: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String, limit: Int? }
        static let name = "search"
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
