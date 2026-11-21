import Foundation
import NoodleCore
import NoodleToolConnections

/// The National Vulnerability Database: CVEs by product, keyword and date, with their CVSS scores and, from CISA's
/// catalogue NVD carries, whether they are being exploited. It answers without a key, five requests in 30 seconds.
public enum NVD {
    public static let preset = ToolDefinition(
        id: "d6a1f3c8-2b74-4e9a-9c51-7e08b4f2a613", name: "NVD",
        summary: "New CVEs for the products you use, with their scores and whether they are being exploited.",
        defaultInstructions: """
        Use NVD to watch for vulnerabilities in the products the organisation runs. Find a product's name as NVD knows it \
        with products, such as grafana:grafana, then list its new CVEs with recent, newest first, with their CVSS scores \
        and whether CISA has seen them exploited. Newly published CVEs often await NVD's analysis and carry no products \
        yet, so search them by keyword too. Read one in full with cve, and see what CISA has lately found exploited with \
        exploited. Weigh a CVE by whether the organisation runs an affected version and whether it is exploited; record \
        what matters as evidence, and open an Investigation for one that needs acting on.
        """,
        iconName: "nvd",
        configuration: .connection(.init(endpoint: URL(string: "https://services.nvd.nist.gov/rest/json")!, adapter: "nvd")))

    public static let adapter = OperationAdapter(operations: [Products(), Recent(), CVE(), Exploited()])

    static let severities = ["LOW", "MEDIUM", "HIGH", "CRITICAL"]

    /// A day as NVD takes it, from a date or a time no more than 119 days back: its range may not pass 120 days.
    static func day(_ value: String?, defaultDays: Double) throws -> String {
        let utc = TimeZone(identifier: "UTC")!
        let date: Date
        if let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            let plain = DateFormatter()
            plain.locale = Locale(identifier: "en_US_POSIX"); plain.timeZone = utc; plain.dateFormat = "yyyy-MM-dd"
            guard let parsed = plain.date(from: String(value.prefix(10))) else { throw ServiceError.input("Give the date as 2026-11-01.") }
            date = parsed
        } else {
            date = Date().addingTimeInterval(-defaultDays * 86_400)
        }
        guard Date().timeIntervalSince(date) <= 119 * 86_400 else {
            throw ServiceError.input("NVD searches at most 119 days back; give a later date.")
        }
        return stamp(date)
    }

    static func stamp(_ date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return format.string(from: date)
    }

    /// A product as products names it, vendor:product, made into the match NVD takes for any of its versions.
    static func match(_ product: String) throws -> String {
        let parts = product.lowercased().split(separator: ":", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-.!~+")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 100 && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw ServiceError.input("Give the product as vendor:product, such as grafana:grafana, from products.")
        }
        return "cpe:2.3:*:\(parts[0]):\(parts[1])"
    }

    /// NVD limits requests without a key with a refusal, which says nothing of a key here.
    static func asked<Answer>(_ request: () async throws -> Answer) async throws -> Answer {
        do { return try await request() }
        catch ServiceError.forbidden, ServiceError.rateLimited, ServiceError.rejected {
            throw ServiceError.input("NVD is limiting requests: without a key it takes five requests in 30 seconds. Wait half a minute and try again.")
        }
    }

    struct Text: Codable { let lang: String?; let value: String? }
    struct Score: Codable { let baseScore: Double?; let baseSeverity: String?; let vectorString: String? }
    struct Metric: Codable { let type: String?; let cvssData: Score?; let baseSeverity: String? }
    struct Metrics: Codable { let cvssMetricV40: [Metric]?, cvssMetricV31: [Metric]?, cvssMetricV30: [Metric]?, cvssMetricV2: [Metric]? }
    struct Weakness: Codable { let description: [Text]? }
    struct Match: Codable {
        let vulnerable: Bool?, criteria: String?
        let versionStartIncluding: String?, versionStartExcluding: String?, versionEndIncluding: String?, versionEndExcluding: String?
    }
    struct Node: Codable { let cpeMatch: [Match]? }
    struct Configuration: Codable { let nodes: [Node]? }
    struct Reference: Codable { let url: String? }
    struct Item: Codable {
        let id: String, published: String?, lastModified: String?, vulnStatus: String?
        let descriptions: [Text]?, metrics: Metrics?, weaknesses: [Weakness]?, configurations: [Configuration]?, references: [Reference]?
        let cisaExploitAdd: String?, cisaActionDue: String?, cisaRequiredAction: String?, cisaVulnerabilityName: String?

        var summary: String { descriptions?.first { $0.lang == "en" }?.value ?? descriptions?.first?.value ?? "" }
        /// The most recent CVSS version scored, the primary source's where both scored it.
        var score: (score: Double, severity: String)? {
            for metrics in [metrics?.cvssMetricV40, metrics?.cvssMetricV31, metrics?.cvssMetricV30, metrics?.cvssMetricV2] {
                guard let metrics, !metrics.isEmpty else { continue }
                let metric = metrics.first { $0.type == "Primary" } ?? metrics[0]
                if let score = metric.cvssData?.baseScore { return (score, metric.cvssData?.baseSeverity ?? metric.baseSeverity ?? "?") }
            }
            return nil
        }
        var exploited: String? {
            cisaExploitAdd.map { "exploited: CISA added it \($0)" + (cisaActionDue.map { ", fix by \($0)" } ?? "") }
        }
        /// One line, for a list.
        var line: String {
            var facts = ["published \(published?.prefix(10) ?? "?")"]
            if let score { facts.append("\(score.severity) \(score.score)") }
            if let exploited { facts.append(exploited) }
            var line = "\(id) (\(facts.joined(separator: ", ")))"
            if vulnStatus == "Awaiting Analysis" || vulnStatus == "Received" || vulnStatus == "Undergoing Analysis" {
                line += ", awaiting NVD's analysis"
            }
            let text = summary.split(whereSeparator: \.isNewline).joined(separator: " ")
            return line + ": " + (text.count > 220 ? text.prefix(220) + "…" : text)
        }
    }
    struct Entry: Codable { let cve: Item }
    struct Answer: Codable { let totalResults: Int?; let vulnerabilities: [Entry]? }

    /// CVEs matching `query`, the newest `limit` of them: NVD lists oldest first, so the newest are on its last page.
    static func newest(_ service: ServiceClient, _ query: [String: String?], limit: Int, by date: (Item) -> String?) async throws -> [Item] {
        var query = query
        query["resultsPerPage"] = String(limit)
        query["noRejected"] = ""
        var answer = try await asked { try await service.get(["cves", "2.0"], query: query, as: Answer.self) }
        if let total = answer.totalResults, total > limit {
            query["startIndex"] = String(total - limit)
            answer = try await asked { try await service.get(["cves", "2.0"], query: query, as: Answer.self) }
        }
        return (answer.vulnerabilities ?? []).map(\.cve).sorted { (date($0) ?? "") > (date($1) ?? "") }
    }
}

extension NVD {
    struct Products: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String }
        static let name = "products"
        static let summary = "Find a product's name as NVD knows it, vendor:product, to search its CVEs with recent."
        static let input = JSONSchema.object(["query": .string("Words in the product's name, such as grafana or google chrome.")], required: ["query"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Title: Codable { let title: String?; let lang: String? }
            struct Name: Codable { let cpeName: String; let titles: [Title]? }
            struct Product: Codable { let cpe: Name }
            struct Answer: Codable { let products: [Product]? }
            let products = try await NVD.asked {
                try await service.get(["cpes", "2.0"], query: ["keywordSearch": try ServiceInput.query(input.query, limit: 200), "resultsPerPage": "200"],
                                      as: Answer.self).products ?? []
            }
            let kinds = ["a": "application", "o": "operating system", "h": "hardware"]
            var seen: [String] = [], found: [(name: String, kind: String, example: String)] = []
            for product in products {
                let parts = product.cpe.cpeName.split(separator: ":")
                guard parts.count > 4 else { continue }
                let name = "\(parts[3]):\(parts[4])"
                guard !seen.contains(name) else { continue }
                seen.append(name)
                let title = product.cpe.titles?.first { $0.lang == "en" }?.title ?? product.cpe.titles?.first?.title ?? ""
                found.append((name, kinds[String(parts[2])] ?? "product", title))
            }
            let text = found.isEmpty ? "NVD knows no product by those words." : found.prefix(30).map {
                "\($0.name) (\($0.kind))" + ($0.example.isEmpty ? "" : ", such as \($0.example)")
            }.joined(separator: "\n")
            struct Kept: Encodable { let products: [String] }
            return try ServiceResult(text: text, structured: Kept(products: found.map(\.name)))
        }
    }

    struct Recent: ServiceOperation {
        struct Input: Decodable, Sendable { let product: String?, keyword: String?, since: String?, severity: String?, exploited: Bool?, limit: Int? }
        static let name = "recent"
        static let summary = "CVEs published since a date for a product or by keyword, newest first, with CVSS scores and whether CISA has seen them exploited."
        static let input = JSONSchema.object([
            "product": .string("The product as products names it, vendor:product, such as grafana:grafana."),
            "keyword": .string("Words in the CVE's description instead or as well, for CVEs NVD has not analysed yet."),
            "since": .string("The earliest publication date, such as 2026-11-01, at most 119 days back. The last week when left out."),
            "severity": .string("Only this CVSS v3 severity.", oneOf: NVD.severities),
            "exploited": .boolean("Only CVEs CISA has seen exploited."),
            "limit": .integer("How many CVEs, at most.", minimum: 1, maximum: 50),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            guard input.product != nil || input.keyword != nil else { throw ServiceError.input("Give a product, a keyword or both.") }
            let limit = input.limit ?? 20
            guard (1...50).contains(limit) else { throw ServiceError.input("Ask for between 1 and 50 CVEs.") }
            var query: [String: String?] = ["pubStartDate": try NVD.day(input.since, defaultDays: 7), "pubEndDate": NVD.stamp(Date())]
            if let product = input.product { query["virtualMatchString"] = try NVD.match(product) }
            if let keyword = input.keyword { query["keywordSearch"] = try ServiceInput.query(keyword, limit: 200) }
            if let severity = input.severity { query["cvssV3Severity"] = try ServiceInput.oneOf(severity.uppercased(), NVD.severities, "severity") }
            if input.exploited == true { query["hasKev"] = "" }
            let items = try await NVD.newest(service, query, limit: limit) { $0.published }
            let text = items.isEmpty ? "No CVE matches." : items.map(\.line).joined(separator: "\n")
            struct Kept: Encodable { let cves: [Item] }
            return try ServiceResult(text: text, structured: Kept(cves: items))
        }
    }

    struct CVE: ServiceOperation {
        struct Input: Decodable, Sendable { let id: String }
        static let name = "cve"
        static let summary = "One CVE in full: its description, CVSS score, weakness, affected products and versions, whether it is exploited, and references."
        static let input = JSONSchema.object(["id": .string("The CVE's ID, such as CVE-2026-14199.")], required: ["id"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let id = input.id.trimmingCharacters(in: .whitespaces).uppercased()
            guard id.range(of: #"^CVE-\d{4}-\d{4,}$"#, options: .regularExpression) != nil else {
                throw ServiceError.input("Give the CVE's ID, such as CVE-2026-14199.")
            }
            let answer = try await NVD.asked { try await service.get(["cves", "2.0"], query: ["cveId": id], as: Answer.self) }
            guard let item = answer.vulnerabilities?.first?.cve else {
                return try ServiceResult(text: "NVD has no \(id).", structured: ["id": id, "found": "false"])
            }
            var lines = ["\(item.id): \(item.vulnStatus ?? "?"), published \(item.published?.prefix(10) ?? "?"), changed \(item.lastModified?.prefix(10) ?? "?")"]
            if let score = item.score { lines.append("CVSS: \(score.severity) \(score.score)") }
            let weaknesses = (item.weaknesses ?? []).flatMap { $0.description ?? [] }.compactMap(\.value).filter { $0.hasPrefix("CWE-") }
            if !weaknesses.isEmpty { lines.append("Weakness: " + Array(Set(weaknesses)).sorted().joined(separator: ", ")) }
            if let exploited = item.exploited {
                lines.append("Exploited: " + exploited.dropFirst("exploited: ".count) + (item.cisaRequiredAction.map { ". \($0)" } ?? ""))
            }
            lines.append(String(item.summary.prefix(2_000)))
            let affected = (item.configurations ?? []).flatMap { $0.nodes ?? [] }.flatMap { $0.cpeMatch ?? [] }.filter { $0.vulnerable != false }
            if !affected.isEmpty {
                lines.append("Affected:")
                lines += affected.prefix(10).map { match in
                    var range: [String] = []
                    if let from = match.versionStartIncluding { range.append("from \(from)") }
                    if let from = match.versionStartExcluding { range.append("after \(from)") }
                    if let to = match.versionEndIncluding { range.append("up to \(to)") }
                    if let to = match.versionEndExcluding { range.append("before \(to)") }
                    return "- \(match.criteria ?? "?")" + (range.isEmpty ? "" : " " + range.joined(separator: " "))
                }
            }
            let references = (item.references ?? []).compactMap(\.url)
            if !references.isEmpty { lines.append("References:"); lines += references.prefix(8).map { "- \($0)" } }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: item)
        }
    }

    struct Exploited: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, product: String?, keyword: String?, limit: Int? }
        static let name = "exploited"
        static let summary = "CVEs CISA has added to its catalogue of those exploited in the wild since a date, newest first, with the date to fix them by."
        static let input = JSONSchema.object([
            "since": .string("The earliest date CISA added them, such as 2026-11-01, at most 119 days back. The last 30 days when left out."),
            "product": .string("Only this product, as products names it, vendor:product."),
            "keyword": .string("Only CVEs whose description has these words."),
            "limit": .integer("How many CVEs, at most.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 25
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 CVEs.") }
            var query: [String: String?] = ["hasKev": "", "kevStartDate": try NVD.day(input.since, defaultDays: 30), "kevEndDate": NVD.stamp(Date())]
            if let product = input.product { query["virtualMatchString"] = try NVD.match(product) }
            if let keyword = input.keyword { query["keywordSearch"] = try ServiceInput.query(keyword, limit: 200) }
            // NVD lists CISA's additions by publication, not by when CISA added them, so up to 500 in the range are
            // read, a few months' worth, and the newest additions kept.
            let items = Array(try await NVD.newest(service, query, limit: 500) { $0.cisaExploitAdd }.prefix(limit))
            let text = items.isEmpty ? "CISA has added none since then." : items.map { item in
                "\(item.id) (\(item.exploited?.dropFirst("exploited: ".count) ?? "")): \(item.cisaVulnerabilityName ?? item.summary.prefix(160) + "")"
                    + (item.cisaRequiredAction.map { ". \($0)" } ?? "")
            }.joined(separator: "\n")
            struct Kept: Encodable { let cves: [Item] }
            return try ServiceResult(text: text, structured: Kept(cves: items))
        }
    }
}
