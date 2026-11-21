import Foundation
import NoodleCore
import NoodleToolConnections

/// crt.sh, Sectigo's search over the public Certificate Transparency logs: every certificate issued for a domain's
/// names, which shows the hosts an organisation has, including ones it has forgotten. It answers without a key, slowly
/// and often not at all when busy, and asks to be used gently.
public enum CrtSh {
    public static let preset = ToolDefinition(
        id: "e98bdac6-1125-4ad4-a287-15d3c5d139f2", name: "crt.sh",
        summary: "The hosts a domain has, from every certificate issued for its names.",
        defaultInstructions: """
        Use crt.sh to discover what an organisation has on the internet: every certificate issued for a domain's names \
        is logged publicly, so its certificates list the domain's hosts, including forgotten, staging and test ones, and \
        the other domains they share certificates with. Ask for the organisation's domains one at a time, and narrow a \
        large domain to a subdomain. Hosts found here are leads, not proof they are live or the organisation's: check them \
        with the other tools before relying on them, and record what matters as evidence. crt.sh is a free public service, \
        often slow or busy; call it once per domain and wait rather than retrying at once.
        """,
        iconName: "crtsh",
        configuration: .connection(.init(endpoint: URL(string: "https://crt.sh")!, adapter: "crtsh")))

    public static let adapter = OperationAdapter(operations: [Certificates()])

    /// A domain as crt.sh takes it, without a wildcard: crt.sh's own wildcard is added for subdomains.
    static func domain(_ value: String) throws -> String {
        var domain = value.trimmingCharacters(in: .whitespaces).lowercased()
        if domain.hasPrefix("*.") { domain.removeFirst(2) }
        if domain.hasSuffix(".") { domain.removeLast() }
        let label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
        guard domain.count <= 253, domain.range(of: "^(\(label)\\.)+\(label)$", options: .regularExpression) != nil else {
            throw ServiceError.input("Give a domain, such as example.com or dev.example.com.")
        }
        return domain
    }

    /// An issuer as people name it, its organisation and name: Let's Encrypt R11.
    static func issuer(_ name: String?) -> String {
        guard let name else { return "?" }
        func field(_ key: String) -> String? {
            guard let range = name.range(of: "(^|, )\(key)=(\"[^\"]*\"|[^,]*)", options: .regularExpression) else { return nil }
            return String(name[range]).components(separatedBy: "\(key)=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        let parts = [field("O"), field("CN")].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? name : parts.joined(separator: " ")
    }

    struct Entry: Codable {
        let id: Int
        let issuer_name: String?, name_value: String?, common_name: String?, not_before: String?, not_after: String?, entry_timestamp: String?

        /// Its names, once each, in the order the certificate gives them.
        var names: [String] {
            var seen = Set<String>()
            return ((name_value ?? common_name ?? "").split(whereSeparator: \.isNewline)).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    struct Certificates: ServiceOperation {
        struct Input: Decodable, Sendable { let domain: String, subdomains: Bool?, expired: Bool?, limit: Int? }
        static let name = "certificates"
        static let summary = "The hosts under a domain and the other domains they share certificates with, from every certificate issued for its names, newest first."
        static let input = JSONSchema.object([
            "domain": .string("The domain, such as example.com."),
            "subdomains": .boolean("Include its subdomains' certificates. Yes when left out."),
            "expired": .boolean("Include expired certificates too, for hosts the domain once had. No when left out."),
            "limit": .integer("How many of the newest certificates to list, at most. Every name they cover is listed either way.", minimum: 1, maximum: 100),
        ], required: ["domain"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let domain = try CrtSh.domain(input.domain)
            let limit = input.limit ?? 20
            guard (1...100).contains(limit) else { throw ServiceError.input("Ask for between 1 and 100 certificates.") }
            var query: [String: String?] = ["q": input.subdomains == false ? domain : "%." + domain, "output": "json", "deduplicate": "Y"]
            if input.expired != true { query["exclude"] = "expired" }
            let entries: [Entry]
            do {
                entries = try await service.get([], query: query, trailingSlash: true, as: [Entry].self)
            } catch ServiceError.unreadable {
                throw Self.busy
            } catch ServiceError.status(let status, _) where status >= 500 {
                throw Self.busy
            }
            let kind = input.expired == true ? "certificates, current and expired," : "current certificates"
            guard !entries.isEmpty else {
                return try ServiceResult(text: "crt.sh has no \(kind.replacingOccurrences(of: "certificates", with: "certificate")) for \(domain).",
                                         structured: ["domain": domain, "certificates": "0"])
            }
            let newest = entries.sorted { ($0.not_before ?? "", $0.id) > ($1.not_before ?? "", $1.id) }
            var names = Set<String>(), others = Set<String>()
            for name in newest.flatMap(\.names) {
                let host = name.hasPrefix("*.") ? String(name.dropFirst(2)) : name
                if host == domain || host.hasSuffix("." + domain) { names.insert(name) } else { others.insert(name) }
            }
            let shownNames = names.sorted().prefix(300), shownOthers = others.sorted().prefix(50)
            var lines = ["\(entries.count) \(kind) for \(domain)\(input.subdomains == false ? "" : " and its subdomains"), naming \(names.count) hosts under it."]
            lines.append("Hosts: " + shownNames.joined(separator: ", ") + (names.count > shownNames.count ? ", and \(names.count - shownNames.count) more" : ""))
            if !others.isEmpty {
                lines.append("Other domains on the same certificates: " + shownOthers.joined(separator: ", ")
                    + (others.count > shownOthers.count ? ", and \(others.count - shownOthers.count) more" : ""))
            }
            lines.append("Newest certificates:")
            lines += newest.prefix(limit).map { entry in
                let shown = entry.names.prefix(10)
                return "\(entry.not_before?.prefix(10) ?? "?"), valid until \(entry.not_after?.prefix(10) ?? "?"), \(CrtSh.issuer(entry.issuer_name)): "
                    + shown.joined(separator: ", ") + (entry.names.count > shown.count ? ", and \(entry.names.count - shown.count) more" : "")
                    + " (crt.sh/?id=\(entry.id))"
            }
            struct Certificate: Encodable { let id: Int, names: [String], issuer: String, notBefore: String?, notAfter: String? }
            struct Kept: Encodable { let domain: String, hosts: [String], otherDomains: [String], certificates: [Certificate] }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(
                domain: domain, hosts: names.sorted(), otherDomains: others.sorted(),
                certificates: newest.prefix(limit).map { .init(id: $0.id, names: $0.names, issuer: CrtSh.issuer($0.issuer_name),
                                                               notBefore: $0.not_before, notAfter: $0.not_after) }))
        }

        static let busy = ServiceError.input(
            "crt.sh is busy and did not answer, as often happens. Wait a minute before trying again once; for a large domain, ask for a subdomain instead.")
    }
}
