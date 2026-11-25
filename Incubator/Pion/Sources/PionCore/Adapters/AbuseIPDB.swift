import Foundation
import NoodleCore
import NoodleToolConnections

/// AbuseIPDB: how often an IP address has been reported for abuse, with the person's API key. AbuseIPDB has no read
/// of the key's own account, so check-access looks up a loopback address, spending one check of the day's quota.
///
/// The tool's guide is Incubator/Pion/docs/tools/threat-intel.md. Change it with the setup steps or operations here.
public enum AbuseIPDB {
    public static let preset = ToolDefinition(
        id: "a1d168df-eb3c-4c66-927b-e552f7bb62c0", name: "AbuseIPDB", summary: "How often an IP address has been reported for abuse, and by how many.",
        defaultInstructions: """
        Use AbuseIPDB to see whether an IP address has been reported for abuse: its confidence score, how many reports \
        and reporters, when last reported, and its ISP, usage type and whether it is a Tor exit. A score reflects other \
        people's reports, not proof: weigh it with what else you found. Record each lookup as evidence. Lookups never \
        report anything. When a lookup is refused, run check-access and tell the champion exactly what it says to change.
        """,
        iconName: "abuseipdb",
        configuration: .connection(.init(endpoint: URL(string: "https://api.abuseipdb.com/api/v2")!, tokenHeader: "Key", adapter: "abuseipdb")),
        setup: setup)

    static let setup = [
        "Sign in at [abuseipdb.com](https://www.abuseipdb.com), or create a free account.",
        "Open [Account › API](https://www.abuseipdb.com/account/api), choose **Create Key**, and paste the key here. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [Check(), CheckAccess()])
}

extension AbuseIPDB {
    struct Check: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String, days: Int? }
        static let name = "check-ip"
        static let jobs: Set<ToolJob> = [.detection]
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

extension AbuseIPDB {
    static let fixes = AccessCheck.Fixes(
        rejected: "AbuseIPDB did not accept the key: it is wrong or was deleted. Create a new key under Account › API and enter it again in Settings › Tools.",
        forbidden: "AbuseIPDB refused the key: the account may be suspended or unverified. Check it at abuseipdb.com.",
        rateLimited: "the account's checks for today are used up. They renew at midnight UTC; a paid plan raises the limit.")

    /// Looks up a loopback address once, the only way to try the key, and reports the day's quota from the answer's headers.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Tries the key with one lookup of 127.0.0.1 and says whether it works and how many of today's checks are left, or what to change. That lookup spends one check of the day's quota."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var check = AccessCheck(AbuseIPDB.fixes)
            await check.probe("API key") {
                // AbuseIPDB may refuse an address that is not public, which still shows the key was taken.
                let answer = try await service.exchange(["check"], query: ["ipAddress": "127.0.0.1", "maxAgeInDays": "1"], returning: [400, 422])
                let limit = answer.response.value(forHTTPHeaderField: "X-RateLimit-Limit"), left = answer.response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
                guard let limit, let left else { return "it works" }
                return "it works; \(left) of today's \(limit) checks are left, after the one this spent"
            }
            return try check.result()
        }
    }
}
