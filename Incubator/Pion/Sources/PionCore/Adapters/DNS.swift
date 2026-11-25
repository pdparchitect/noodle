import Foundation
import NoodleCore
import NoodleToolConnections

/// Public DNS, read through Google Public DNS's JSON API (https://developers.google.com/speed/public-dns/docs/doh/json),
/// which answers without a key. It shows what any mail server or attacker sees of a domain: where its mail goes, which
/// servers may send as it (SPF), what receivers do with mail that fails (DMARC), and its signing keys (DKIM).
public enum DNS {
    public static let preset = ToolDefinition(
        id: "baa9ed1e-0761-497a-bb43-dfa34222bf32", name: "DNS",
        summary: "A domain's public DNS records, and how well it protects its mail from spoofing.",
        defaultInstructions: """
        Use DNS to read a domain's public records: email-security checks where its mail goes and whether others can send \
        mail as it (SPF, DMARC, DKIM, MTA-STS), and says what is weak; records looks up any name, or an address backwards. \
        Use it in phishing and spoofing investigations, to check the organisation's own domains and the domains mail \
        came from or links point to, and to see whether a domain changed hands or moved its mail. DKIM keys are found only \
        under selectors that are asked for: give the one a message's DKIM-Signature names (s=) when there is one. \
        Lookups go through Google Public DNS, which sees the names asked; ask only for domains the investigation needs.
        """,
        iconName: "dns",
        configuration: .connection(.init(endpoint: URL(string: "https://dns.google")!, adapter: "dns")))

    public static let adapter = OperationAdapter(operations: [Records(), EmailSecurity()])

    /// The record types `records` takes, by name, with their numbers as DNS gives them.
    static let types: [(name: String, number: Int)] = [("A", 1), ("AAAA", 28), ("CNAME", 5), ("MX", 15), ("NS", 2), ("TXT", 16),
                                                       ("CAA", 257), ("SOA", 6), ("PTR", 12), ("SRV", 33)]

    static func typeName(_ number: Int) -> String { types.first { $0.number == number }?.name ?? "TYPE\(number)" }

    /// A name as DNS takes it: lowercase, without the root's dot, labels of letters, digits, hyphens and underscores,
    /// as _dmarc and _domainkey names have.
    static func name(_ value: String) throws -> String {
        var name = value.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        let label = "[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9])?"
        guard name.count <= 253, name.range(of: "^(\(label)\\.)+\(label)$", options: .regularExpression) != nil else {
            throw ServiceError.input("Give a domain or host name, such as example.com or _dmarc.example.com, or an IP address.")
        }
        return name
    }

    /// The name an address is looked up backwards under, or nil when `value` is not an address.
    static func reverseName(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespaces)
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, value, &v4) == 1 {
            return value.split(separator: ".").reversed().joined(separator: ".") + ".in-addr.arpa"
        }
        guard inet_pton(AF_INET6, value, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        let nibbles = bytes.flatMap { [String($0 >> 4, radix: 16), String($0 & 0xf, radix: 16)] }
        return nibbles.reversed().joined(separator: ".") + ".ip6.arpa"
    }

    /// Google Public DNS's answer: its status (0 answered, 3 no such name) and its records.
    struct Answer: Decodable {
        struct Record: Decodable { let name: String, type: Int, data: String }
        let Status: Int
        let AD: Bool?
        let Answer: [Record]?
    }

    /// One question's answer. A name that does not exist answers with no records; any other failure is an error.
    struct Lookup {
        let exists: Bool
        let validated: Bool
        let records: [(type: Int, data: String)]

        /// Its text records of the type asked, each as one string, however many strings DNS split it into.
        func text(_ type: Int = 16) -> [String] { records.filter { $0.type == type }.map { DNS.unquoted($0.data) } }
    }

    static func lookup(_ name: String, _ type: String, on service: ServiceClient) async throws -> Lookup {
        let answer = try await service.get(["resolve"], query: ["name": name, "type": type], as: Answer.self)
        switch answer.Status {
        case 0: return Lookup(exists: true, validated: answer.AD == true, records: (answer.Answer ?? []).map { ($0.type, $0.data) })
        case 3: return Lookup(exists: false, validated: answer.AD == true, records: [])
        case 2: throw ServiceError.input("\(name)'s name servers did not answer properly (SERVFAIL), which is often a broken DNSSEC signature or delegation.")
        default: throw ServiceError.input("DNS answered \(name) \(type) with error code \(answer.Status).")
        }
    }

    /// A TXT record's strings joined, when DNS gives them quoted: "v=spf1 a " "-all" is v=spf1 a -all.
    static func unquoted(_ data: String) -> String {
        guard data.hasPrefix("\"") else { return data }
        var result = "", inside = false, escaped = false
        for character in data {
            if escaped { result.append(character); escaped = false }
            else if character == "\\" && inside { escaped = true }
            else if character == "\"" { inside.toggle() }
            else if inside { result.append(character) }
        }
        return result
    }

    struct Records: ServiceOperation {
        struct Input: Decodable, Sendable { let name: String, types: [String]? }
        static let name = "records"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "A name's public DNS records of the types asked, or the names an IP address points back to."
        static let input = JSONSchema.object([
            "name": .string("A domain or host, such as example.com or _dmarc.example.com, or an IP address to look up backwards."),
            "types": .array(.string("A, AAAA, CNAME, MX, NS, TXT, CAA, SOA, PTR or SRV."),
                            "The record types. A, AAAA, CNAME, MX, NS and TXT when left out; PTR for an address."),
        ], required: ["name"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let reverse = DNS.reverseName(input.name)
            let name = try reverse ?? DNS.name(input.name)
            let asked = (input.types ?? (reverse == nil ? ["A", "AAAA", "CNAME", "MX", "NS", "TXT"] : ["PTR"])).map { $0.uppercased() }
            let unknown = asked.filter { type in !DNS.types.contains { $0.name == type } }
            guard unknown.isEmpty, !asked.isEmpty else {
                throw ServiceError.input("Ask for record types among " + DNS.types.map(\.name).joined(separator: ", ") + ".")
            }
            var lines: [String] = [], seen = Set<String>(), validated = false, kept: [String: [String]] = [:]
            for type in asked {
                let lookup = try await DNS.lookup(name, type, on: service)
                guard lookup.exists else {
                    return try ServiceResult(text: "\(name) does not exist in public DNS.", structured: ["name": name, "exists": "false"])
                }
                validated = validated || lookup.validated
                for record in lookup.records {
                    let data = record.type == 16 ? DNS.unquoted(record.data) : record.data
                    let line = "\(DNS.typeName(record.type)): \(data)"
                    if seen.insert(line).inserted { lines.append(line); kept[DNS.typeName(record.type), default: []].append(data) }
                }
            }
            let header = "\(name)\(reverse == nil ? "" : " (\(input.name.trimmingCharacters(in: .whitespaces)) backwards)"): "
                + (lines.isEmpty ? "no \(asked.joined(separator: ", ")) records." : "\(lines.count) record\(lines.count == 1 ? "" : "s")"
                    + (validated ? ", signed and validated with DNSSEC." : "."))
            struct Kept: Encodable { let name: String, dnssec: Bool, records: [String: [String]] }
            return try ServiceResult(text: ([header] + lines).joined(separator: "\n"), structured: Kept(name: name, dnssec: validated, records: kept))
        }
    }

    struct EmailSecurity: ServiceOperation {
        struct Input: Decodable, Sendable { let domain: String, selectors: [String]? }
        static let name = "email-security"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Where a domain's mail goes and how well it stops others sending as it: SPF with its DNS lookups counted, DMARC, DKIM keys, MTA-STS and TLS reporting, with what is weak."
        static let input = JSONSchema.object([
            "domain": .string("The domain mail is sent as, such as example.com."),
            "selectors": .array(.string("A DKIM selector, as s= in a message's DKIM-Signature."),
                                "The DKIM selectors to look for. Google Workspace's google and Microsoft 365's selector1 and selector2 when left out."),
        ], required: ["domain"])

        /// The usual DKIM selectors of the mail services most organisations use.
        static let usualSelectors = ["google", "selector1", "selector2"]

        /// Mail services by the end of their MX hosts' names.
        static let mailServices = [("google.com.", "Google"), ("googlemail.com.", "Google"),
                                   ("mail.protection.outlook.com.", "Microsoft 365"), ("pphosted.com.", "Proofpoint"),
                                   ("mimecast.com.", "Mimecast"), ("iphmx.com.", "Cisco Secure Email")]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let domain = try DNS.name(input.domain)
            let selectors = try (input.selectors ?? Self.usualSelectors).map { selector in
                let trimmed = selector.trimmingCharacters(in: .whitespaces).lowercased()
                guard trimmed.range(of: "^[a-z0-9_]([a-z0-9_.-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil else {
                    throw ServiceError.input("A DKIM selector is a name such as google or s1, as s= in a DKIM-Signature.")
                }
                return trimmed
            }
            var lines = ["Email security of \(domain), from its public DNS:"]

            let mail = try await DNS.lookup(domain, "MX", on: service)
            guard mail.exists else {
                return try ServiceResult(text: "\(domain) does not exist in public DNS.", structured: ["domain": domain, "exists": "false"])
            }
            let exchangers = mail.records.filter { $0.type == 15 }.map(\.data)
                .sorted { (Int($0.split(separator: " ").first ?? "") ?? 0, $0) < (Int($1.split(separator: " ").first ?? "") ?? 0, $1) }
            let services = Set(exchangers.compactMap { host in Self.mailServices.first { host.lowercased().hasSuffix($0.0) }?.1 }).sorted()
            if exchangers.isEmpty || exchangers == ["0 ."] {
                lines.append("No MX records: \(domain) receives no mail\(exchangers.isEmpty ? "" : ", and says so with a null MX").")
            } else {
                lines.append("Mail goes to: " + exchangers.joined(separator: ", ") + (services.isEmpty ? "" : " (\(services.joined(separator: ", ")))"))
            }

            // SPF: the domain's own record, then every record it names, to count the lookups receivers make.
            let spfRecords = try await DNS.lookup(domain, "TXT", on: service).text().filter { $0.lowercased().hasPrefix("v=spf1") }
            var spfFindings: [String] = [], lookups = 0
            if spfRecords.isEmpty {
                lines.append("SPF: none")
                spfFindings.append("No SPF record: receivers cannot tell which servers may send as \(domain), so anyone can send as \(domain) and pass.")
            } else {
                lines.append("SPF: " + spfRecords.joined(separator: " | "))
                if spfRecords.count > 1 {
                    spfFindings.append("\(spfRecords.count) SPF records: receivers treat that as an error (permerror), so SPF fails for all of \(domain)'s mail.")
                } else {
                    let terms = spfRecords[0].lowercased().split(separator: " ").map(String.init)
                    let all = terms.first { $0.hasSuffix("all") && ["all", "+all", "-all", "~all", "?all"].contains($0) }
                    switch all {
                    case "+all", "all": spfFindings.append("ends \(all!): any server in the world passes SPF as \(domain).")
                    case "?all": spfFindings.append("ends ?all: mail from other servers is neither passed nor failed, so SPF protects nothing.")
                    case "~all": spfFindings.append("ends ~all: mail from other servers is marked suspicious but usually delivered; DMARC decides what happens to it.")
                    case "-all": break
                    default: if !terms.contains(where: { $0.hasPrefix("redirect=") }) {
                        spfFindings.append("has no all term: mail from servers it does not list gets a neutral result.")
                    }
                    }
                    var visited: Set<String> = [domain]
                    lookups = try await Self.countLookups(terms, visited: &visited, on: service)
                    spfFindings.append(lookups > 10
                        ? "uses \(lookups) DNS lookups, over the 10 SPF allows: receivers fail SPF for all of \(domain)'s mail (permerror)."
                        : "uses \(lookups) of the 10 DNS lookups SPF allows.")
                }
            }
            lines += spfFindings.map { "  - " + $0 }

            let dmarcRecords = try await DNS.lookup("_dmarc." + domain, "TXT", on: service).text().filter { $0.lowercased().hasPrefix("v=dmarc1") }
            var dmarcFindings: [String] = [], policy: String?
            if dmarcRecords.isEmpty {
                lines.append("DMARC: none")
                dmarcFindings.append("No DMARC record: receivers have no policy for mail that fails SPF and DKIM, so anyone can send as \(domain) and it is usually delivered.")
            } else {
                lines.append("DMARC: " + dmarcRecords.joined(separator: " | "))
                if dmarcRecords.count > 1 {
                    dmarcFindings.append("\(dmarcRecords.count) DMARC records: receivers ignore them all, as if there were none.")
                } else {
                    var tags: [String: String] = [:]
                    for part in dmarcRecords[0].split(separator: ";") {
                        let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        if pair.count == 2 { tags[pair[0].lowercased()] = pair[1] }
                    }
                    policy = tags["p"]?.lowercased()
                    switch policy {
                    case "reject": break
                    case "quarantine": dmarcFindings.append("p=quarantine: spoofed mail goes to spam rather than being refused.")
                    case "none": dmarcFindings.append("p=none: spoofed mail is reported, not stopped; it is delivered as usual.")
                    default: dmarcFindings.append("no valid p= policy: receivers treat the record as if there were none.")
                    }
                    if let sp = tags["sp"]?.lowercased(), sp == "none", policy != "none" {
                        dmarcFindings.append("sp=none: mail spoofed from subdomains is not stopped.")
                    }
                    if let pct = tags["pct"].flatMap(Int.init), pct < 100 {
                        dmarcFindings.append("pct=\(pct): the policy covers only \(pct == 50 ? "half" : "\(pct)%") of mail that fails; the rest is delivered.")
                    }
                    if tags["rua"] == nil {
                        dmarcFindings.append("no rua=: nobody receives the daily reports that show which servers send as \(domain).")
                    }
                }
            }
            lines += dmarcFindings.map { "  - " + $0 }

            var dkim: [String: String] = [:]
            for selector in selectors {
                let keys = try await DNS.lookup("\(selector)._domainkey.\(domain)", "TXT", on: service).text()
                    .filter { $0.lowercased().contains("p=") }
                let state: String
                if let key = keys.first {
                    let tags = Dictionary(key.split(separator: ";").compactMap { part -> (String, String)? in
                        let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        return pair.count == 2 ? (pair[0].lowercased(), pair[1]) : nil
                    }, uniquingKeysWith: { first, _ in first })
                    state = (tags["p"] ?? "").isEmpty ? "revoked (empty key)" : "published (\(tags["k"] ?? "rsa"))"
                } else {
                    state = "none"
                }
                dkim[selector] = state
                lines.append("DKIM \(selector): \(state)")
            }

            let mtaSTS = try await DNS.lookup("_mta-sts." + domain, "TXT", on: service).text().first { $0.lowercased().hasPrefix("v=stsv1") }
            let tlsRPT = try await DNS.lookup("_smtp._tls." + domain, "TXT", on: service).text().first { $0.lowercased().hasPrefix("v=tlsrptv1") }
            lines.append("MTA-STS: " + (mtaSTS ?? "none"))
            lines.append("TLS reporting: " + (tlsRPT ?? "none"))
            if !dkim.values.contains(where: { $0.hasPrefix("published") }) {
                lines.append("No DKIM key under the selectors looked up; a message's DKIM-Signature names the selector it uses (s=).")
            }

            struct Kept: Encodable {
                let domain: String, mx: [String], mailServices: [String], spf: [String], spfLookups: Int, dmarc: [String], dmarcPolicy: String?
                let dkim: [String: String], mtaSTS: String?, tlsReporting: String?, findings: [String]
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(
                domain: domain, mx: exchangers, mailServices: services, spf: spfRecords, spfLookups: lookups, dmarc: dmarcRecords, dmarcPolicy: policy,
                dkim: dkim, mtaSTS: mtaSTS, tlsReporting: tlsRPT, findings: spfFindings.map { "SPF " + $0 } + dmarcFindings.map { "DMARC " + $0 }))
        }

        /// The DNS lookups an SPF record's terms make, its includes' and redirect's own counted in, as receivers count
        /// them. A name already followed is counted but not read again, so a record that names itself ends; reading stops
        /// past the limit, as receivers do.
        static func countLookups(_ terms: [String], visited: inout Set<String>, on service: ServiceClient) async throws -> Int {
            var count = 0
            for term in terms {
                let bare = term.trimmingCharacters(in: CharacterSet(charactersIn: "+-~?"))
                let mechanism = bare.split(separator: ":", maxSplits: 1).first.map(String.init) ?? bare
                let name = mechanism.split(separator: "/").first.map(String.init) ?? mechanism
                let target: String?
                if bare.hasPrefix("include:") { target = String(bare.dropFirst("include:".count)) }
                else if bare.hasPrefix("redirect=") { target = String(bare.dropFirst("redirect=".count)) }
                else { target = nil }
                guard target != nil || ["a", "mx", "ptr", "exists"].contains(name) else { continue }
                count += 1
                guard let target, count <= 10, !target.contains("%"), visited.insert(target).inserted else { continue }
                let records = try await DNS.lookup(target, "TXT", on: service).text().filter { $0.lowercased().hasPrefix("v=spf1") }
                guard records.count == 1 else { continue }
                count += try await countLookups(records[0].lowercased().split(separator: " ").map(String.init), visited: &visited, on: service)
            }
            return count
        }
    }
}
