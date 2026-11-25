import Foundation
import NoodleCore
import NoodleToolConnections

/// Shodan's view of what an internet address exposes, and DNS both ways, with the person's API key, which
/// Shodan takes only in the address. check-access reads the key's plan and credits.
///
/// The tool's guide is Incubator/Pion/docs/tools/threat-intel.md. Change it with the setup steps or operations here.
public enum Shodan {
    public static let preset = ToolDefinition(
        id: "6ca1686e-ba46-4e5c-90ad-e78c5ad4e171", name: "Shodan", summary: "What an internet-facing address exposes: open ports, services and known vulnerabilities.",
        defaultInstructions: """
        Use Shodan to see what an IP address exposes to the internet: its open ports, the software on them, known \
        vulnerabilities, its hostnames and owner; and to resolve hostnames and addresses both ways. Shodan reports what its \
        scanners last saw, which may be days old: say when. Record each lookup as evidence. These lookups never scan anything. \
        When a lookup is refused, run check-access and tell the champion exactly what it says to change.
        """,
        iconName: "shodan",
        configuration: .connection(.init(endpoint: URL(string: "https://api.shodan.io")!, tokenParameter: "key", adapter: "shodan")),
        setup: setup)

    static let setup = [
        "Sign in at [account.shodan.io](https://account.shodan.io), or create an account.",
        "Copy the **API Key** shown on the account page and paste it here. Then ask an agent to run check-access.",
    ]

    public static let adapter = OperationAdapter(operations: [HostReport(), Resolve(), Reverse(), CheckAccess()])
}

extension Shodan {
    struct HostReport: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String }
        static let name = "host-report"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "An IP address's open ports and services, known vulnerabilities, hostnames, owner and location, as Shodan last saw them."
        static let input = JSONSchema.object(["ip": .string("An IPv4 or IPv6 address.")], required: ["ip"])

        /// Shodan lists vulnerabilities as names, or as an object keyed by them.
        struct Names: Decodable {
            let names: [String]
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let list = try? container.decode([String].self) { names = list }
                else { names = (try? container.decode([String: Ignored].self).keys.sorted()) ?? [] }
            }
            struct Ignored: Decodable { init(from decoder: Decoder) throws {} }
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let ip = try ServiceInput.ip(input.ip)
            struct Banner: Decodable { let port: Int?; let transport: String?; let product: String?; let version: String? }
            struct Host: Decodable {
                let ip_str: String?, ports: [Int]?, hostnames: [String]?, org: String?, isp: String?, asn: String?
                let country_name: String?, city: String?, os: String?, last_update: String?, vulns: Names?, data: [Banner]?
            }
            struct Service: Encodable { let port: Int?, transport: String?, product: String?, version: String? }
            struct Report: Encodable {
                let ip: String, ports: [Int], hostnames: [String], organisation: String?, isp: String?, asn: String?
                let country: String?, city: String?, os: String?, lastSeen: String?, vulnerabilities: [String], services: [Service]
            }
            let host = try await service.get(["shodan", "host", ip], as: Host.self)
            let services = (host.data ?? []).map { Service(port: $0.port, transport: $0.transport, product: $0.product, version: $0.version) }
            let report = Report(ip: host.ip_str ?? ip, ports: (host.ports ?? []).sorted(), hostnames: host.hostnames ?? [],
                                organisation: host.org, isp: host.isp, asn: host.asn, country: host.country_name, city: host.city,
                                os: host.os, lastSeen: host.last_update, vulnerabilities: host.vulns?.names ?? [], services: services)
            var text = "\(report.ip)"
            let owner = [report.organisation, [report.city, report.country].compactMap { $0 }.joined(separator: ", ")].compactMap { $0 }
                .filter { !$0.isEmpty }
            if !owner.isEmpty { text += " (\(owner.joined(separator: "; ")))" }
            text += report.ports.isEmpty ? ": no open ports seen." : ": \(report.ports.count) open port\(report.ports.count == 1 ? "" : "s")."
            let lines = services.map { service in
                ["\(service.port.map(String.init) ?? "?")/\(service.transport ?? "tcp")", service.product, service.version].compactMap { $0 }.joined(separator: " ")
            }
            if !lines.isEmpty { text += " Services: " + lines.joined(separator: "; ") + "." }
            if !report.vulnerabilities.isEmpty { text += " Known vulnerabilities: " + report.vulnerabilities.joined(separator: ", ") + "." }
            if !report.hostnames.isEmpty { text += " Hostnames: " + report.hostnames.joined(separator: ", ") + "." }
            if let seen = report.lastSeen { text += " Last seen \(seen.prefix(10))." }
            return try ServiceResult(text: text, structured: report)
        }
    }

    struct Resolve: ServiceOperation {
        struct Input: Decodable, Sendable { let hostnames: [String] }
        static let name = "dns-resolve"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "The IP address each hostname resolves to."
        static let input = JSONSchema.object(["hostnames": .array(.string("A hostname."), "Up to 20 hostnames.")], required: ["hostnames"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let names = try ServiceInput.list(input.hostnames, limit: 20, ServiceInput.domain)
            let answers = try await service.get(["dns", "resolve"], query: ["hostnames": names.joined(separator: ",")], as: [String: String?].self)
            struct Answers: Encodable { let addresses: [String: String?] }
            let lines = names.map { "\($0) → \(answers[$0].flatMap { $0 } ?? "no address")" }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Answers(addresses: answers))
        }
    }

    struct Reverse: ServiceOperation {
        struct Input: Decodable, Sendable { let ips: [String] }
        static let name = "dns-reverse"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "The hostnames each IP address points back to."
        static let input = JSONSchema.object(["ips": .array(.string("An IPv4 or IPv6 address."), "Up to 20 addresses.")], required: ["ips"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let ips = try ServiceInput.list(input.ips, limit: 20, ServiceInput.ip)
            let answers = try await service.get(["dns", "reverse"], query: ["ips": ips.joined(separator: ",")], as: [String: [String]?].self)
            struct Answers: Encodable { let hostnames: [String: [String]?] }
            let lines = ips.map { ip in "\(ip) → \(answers[ip].flatMap { $0 }.map { $0.joined(separator: ", ") } ?? "no hostname")" }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Answers(hostnames: answers))
        }
    }
}

extension Shodan {
    static let fixes = AccessCheck.Fixes(
        rejected: "Shodan did not accept the key: it is wrong, or was reset. Copy the API Key again from account.shodan.io and enter it in Settings › Tools.",
        forbidden: "Shodan refused the key for this: the account's plan may not include API access to it. A free account reaches little of the API; a membership or paid plan reaches more.",
        rateLimited: "Shodan is rate limiting this key, about one request a second: wait before trying again.")

    /// Reads the key's plan and the credits left this month, which spends none.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Tries the key once with a read of its plan and credits, which looks nothing up, and says the plan and the query credits left this month, or what to change."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var check = AccessCheck(Shodan.fixes)
            await check.probe("API key") {
                let info = try await Shodan.info(service)
                var found = "it works, on the \(info.plan ?? "?") plan"
                if let left = info.query_credits {
                    found += "; \(left)\(info.usage_limits?.query_credits.map { " of \($0)" } ?? "") query credits are left this month"
                }
                return found
            }
            check.note("Whether the plan includes host reports and DNS lookups shows when they are first tried: one it does not include is refused with HTTP 403.")
            return try check.result()
        }
    }

    /// The key's plan and credits, as Shodan reports them.
    struct Info: Decodable {
        struct Limits: Decodable { let query_credits: Int? }
        let plan: String?, query_credits: Int?, usage_limits: Limits?
    }

    /// Reads them, which spends no credit.
    static func info(_ service: ServiceClient) async throws -> Info { try await service.get(["api-info"], as: Info.self) }
}
