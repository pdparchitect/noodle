import Foundation
import NoodleCore
import NoodleMCP

/// VirusTotal's reputation lookups for files, domains, IP addresses and URLs, with the person's API key.
public enum VirusTotal {
    public static let preset = ToolDefinition(
        id: "virustotal", name: "VirusTotal", summary: "Reputation of files, domains, IP addresses and URLs.",
        defaultInstructions: """
        Use VirusTotal to check the reputation of a file hash, domain, IP address or URL you met in the evidence. \
        A verdict is how many security engines flag something, not proof: say how many, and weigh it with what else you found. \
        Record each lookup as evidence, citing the tool and the value looked up. Lookups never submit anything for scanning. \
        Public keys allow only a few lookups a minute; look up what matters, and wait when told the service is rate limiting.
        """,
        iconName: "virustotal",
        configuration: .mcp(.init(endpoint: URL(string: "https://www.virustotal.com/api/v3")!, tokenHeader: "x-apikey",
                                  adapter: "virustotal")))

    public static let adapter = OperationAdapter(operations: [FileReport(), DomainReport(), AddressReport(), URLReport()])

    /// What VirusTotal reports for any object: how the engines judged it, the community's score and its tags.
    struct Common: Decodable {
        struct Stats: Decodable {
            let harmless, malicious, suspicious, undetected, timeout: Int?
        }
        let last_analysis_stats: Stats?
        let reputation: Int?
        let last_analysis_date: Int?
        let tags: [String]?
    }

    /// How VirusTotal wraps every object it returns.
    struct Envelope<Body: Decodable>: Decodable {
        struct Object: Decodable { let id: String; let attributes: Body }
        let data: Object
    }

    /// One object's id, its common report and the attributes only its kind has.
    static func lookup<Attributes: Decodable>(_ path: [String], on service: ServiceClient,
                                              _ attributes: Attributes.Type) async throws -> (id: String, common: Common, own: Attributes) {
        let data = try await service.data(path)
        do {
            let common = try JSONDecoder().decode(Envelope<Common>.self, from: data)
            let own = try JSONDecoder().decode(Envelope<Attributes>.self, from: data)
            return (common.data.id, common.data.attributes, own.data.attributes)
        } catch { throw ServiceError.unreadable }
    }

    /// The fields a report keeps, whatever its kind; those a kind lacks are left out.
    struct Report: Encodable {
        var id: String
        var link: String
        var malicious: Int, suspicious: Int, harmless: Int, undetected: Int, engines: Int
        var reputation: Int?
        var lastAnalysis: String?
        var tags: [String]?
        var name: String? = nil, type: String? = nil, size: Int? = nil, firstSeen: String? = nil
        var registrar: String? = nil, created: String? = nil
        var owner: String? = nil, asn: Int? = nil, country: String? = nil, network: String? = nil
        var url: String? = nil, finalURL: String? = nil, title: String? = nil

        init(id: String, page: String, common: Common) {
            let stats = common.last_analysis_stats
            self.id = id
            link = "https://www.virustotal.com/gui/\(page)/\(id)"
            malicious = stats?.malicious ?? 0; suspicious = stats?.suspicious ?? 0
            harmless = stats?.harmless ?? 0; undetected = stats?.undetected ?? 0
            engines = malicious + suspicious + harmless + undetected + (stats?.timeout ?? 0)
            reputation = common.reputation
            lastAnalysis = common.last_analysis_date.map(VirusTotal.date)
            tags = common.tags?.isEmpty == false ? common.tags : nil
        }

        /// "invoice.exe: 3 of 70 engines flag it as malicious, 1 as suspicious. Community reputation -12. Last analysed 2023-11-14."
        func sentence(_ subject: String) -> String {
            var text = engines == 0 ? "\(subject): VirusTotal has no engine verdicts yet."
                : "\(subject): \(malicious) of \(engines) engines flag it as malicious, \(suspicious) as suspicious."
            if let reputation { text += " Community reputation \(reputation)." }
            if let lastAnalysis { text += " Last analysed \(lastAnalysis.prefix(10))." }
            if let tags { text += " Tags: \(tags.joined(separator: ", "))." }
            return text
        }

        func result(_ subject: String) throws -> ServiceResult { try ServiceResult(text: sentence(subject), structured: self) }
    }

    static func date(_ seconds: Int) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// The value, or why VirusTotal cannot be asked about it.
    static func checked(_ value: String, _ valid: (String) -> String?, _ problem: String) throws -> String {
        guard let checked = valid(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ServiceError.input(problem) }
        return checked
    }
}

extension VirusTotal {
    struct FileReport: ServiceOperation {
        struct Input: Decodable, Sendable { let hash: String }
        static let name = "file-report"
        static let summary = "A file's reputation by its MD5, SHA-1 or SHA-256 hash, with its name, type and size."
        static let input = JSONSchema.object(["hash": .string("The file's MD5, SHA-1 or SHA-256 hash.")], required: ["hash"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let hash = try checked(input.hash, { value in
                let hex = value.lowercased()
                return [32, 40, 64].contains(hex.count) && hex.allSatisfy(\.isHexDigit) ? hex : nil
            }, "Give the file's MD5, SHA-1 or SHA-256 hash in hexadecimal.")
            struct Own: Decodable { let meaningful_name: String?; let type_description: String?; let size: Int?; let first_submission_date: Int? }
            let (id, common, own) = try await lookup(["files", hash], on: service, Own.self)
            var report = Report(id: id, page: "file", common: common)
            report.name = own.meaningful_name; report.type = own.type_description; report.size = own.size
            report.firstSeen = own.first_submission_date.map(date)
            return try report.result(own.meaningful_name.map { "\($0) (\(hash))" } ?? hash)
        }
    }

    struct DomainReport: ServiceOperation {
        struct Input: Decodable, Sendable { let domain: String }
        static let name = "domain-report"
        static let summary = "A domain's reputation, with its registrar and when it was registered."
        static let input = JSONSchema.object(["domain": .string("The domain name alone, such as example.com.")], required: ["domain"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let domain = try ServiceInput.domain(input.domain)
            struct Own: Decodable { let registrar: String?; let creation_date: Int? }
            let (id, common, own) = try await lookup(["domains", domain], on: service, Own.self)
            var report = Report(id: id, page: "domain", common: common)
            report.registrar = own.registrar; report.created = own.creation_date.map(date)
            var text = report.sentence(domain)
            if let created = report.created { text += " Registered \(created.prefix(10))\(own.registrar.map { " with \($0)" } ?? "")." }
            return try ServiceResult(text: text, structured: report)
        }
    }

    struct AddressReport: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String }
        static let name = "ip-report"
        static let summary = "An IP address's reputation, with its network, owner and country."
        static let input = JSONSchema.object(["ip": .string("An IPv4 or IPv6 address.")], required: ["ip"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let ip = try ServiceInput.ip(input.ip)
            struct Own: Decodable { let as_owner: String?; let asn: Int?; let country: String?; let network: String? }
            let (id, common, own) = try await lookup(["ip_addresses", ip], on: service, Own.self)
            var report = Report(id: id, page: "ip-address", common: common)
            report.owner = own.as_owner; report.asn = own.asn; report.country = own.country; report.network = own.network
            var text = report.sentence(ip)
            let place = [own.network, own.as_owner.map { "owned by \($0)" }, own.country.map { "in \($0)" }].compactMap { $0 }
            if !place.isEmpty { text += " Network: \(place.joined(separator: ", "))." }
            return try ServiceResult(text: text, structured: report)
        }
    }

    struct URLReport: ServiceOperation {
        struct Input: Decodable, Sendable { let url: String }
        static let name = "url-report"
        static let summary = "A web address's reputation, with where it ends up and its page title. Never submits it for scanning."
        static let input = JSONSchema.object(["url": .string("The full http or https address.")], required: ["url"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let url = try checked(input.url, { value in
                guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
                return value
            }, "Give the full http or https address.")
            // VirusTotal names a URL by its base64url form, without padding.
            let id = Data(url.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            struct Own: Decodable { let url: String?; let final_url: String?; let title: String? }
            let (objectID, common, own) = try await lookup(["urls", id], on: service, Own.self)
            var report = Report(id: objectID, page: "url", common: common)
            report.url = own.url ?? url; report.finalURL = own.final_url; report.title = own.title
            var text = report.sentence(url)
            if let final = own.final_url, final != url { text += " It ends up at \(final)." }
            if let title = own.title { text += " Page title: \(title)." }
            return try ServiceResult(text: text, structured: report)
        }
    }
}
