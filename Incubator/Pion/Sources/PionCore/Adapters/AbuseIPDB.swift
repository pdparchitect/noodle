import Foundation
import NoodleCore
import NoodleMCP

/// AbuseIPDB: how often an IP address has been reported for abuse, with the person's API key.
public enum AbuseIPDB {
    public static let preset = ToolDefinition(
        id: "abuseipdb", name: "AbuseIPDB", summary: "How often an IP address has been reported for abuse, and by how many.",
        defaultInstructions: """
        Use AbuseIPDB to see whether an IP address has been reported for abuse: its confidence score, how many reports \
        and reporters, when last reported, and its ISP, usage type and whether it is a Tor exit. A score reflects other \
        people's reports, not proof: weigh it with what else you found. Record each lookup as evidence. Lookups never \
        report anything.
        """,
        iconName: "abuseipdb",
        configuration: .mcp(.init(endpoint: URL(string: "https://api.abuseipdb.com/api/v2")!, tokenHeader: "Key", adapter: "abuseipdb")))

    public static let adapter = OperationAdapter(operations: [Check()])
}

extension AbuseIPDB {
    struct Check: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String, days: Int? }
        static let name = "check-ip"
        static let summary = "An IP address's abuse confidence score, reports and reporters, ISP, usage type and Tor status."
        static let input = JSONSchema.object([
            "ip": .string("An IPv4 or IPv6 address."),
            "days": .integer("How many days of reports to count. 90 when left out.", minimum: 1, maximum: 365),
        ], required: ["ip"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let ip = try ServiceInput.ip(input.ip)
            let days = input.days ?? 90
            guard (1...365).contains(days) else { throw ServiceError.input("Count between 1 and 365 days of reports.") }
            struct Report: Codable {
                let ipAddress: String?, abuseConfidenceScore: Int?, countryCode: String?, usageType: String?, isp: String?
                let domain: String?, hostnames: [String]?, isTor: Bool?, totalReports: Int?, numDistinctUsers: Int?, lastReportedAt: String?
            }
            struct Envelope: Decodable { let data: Report }
            let report = try await service.get(["check"], query: ["ipAddress": ip, "maxAgeInDays": String(days)], as: Envelope.self).data
            var text = "\(ip): abuse confidence \(report.abuseConfidenceScore ?? 0)%, \(report.totalReports ?? 0) reports from \(report.numDistinctUsers ?? 0) users in \(days) days"
            if let last = report.lastReportedAt { text += ", last \(last.prefix(10))" }
            text += "."
            let about = [report.isp, report.usageType, report.countryCode, report.isTor == true ? "Tor exit" : nil].compactMap { $0 }
            if !about.isEmpty { text += " " + about.joined(separator: ", ") + "." }
            return try ServiceResult(text: text, structured: report)
        }
    }
}
