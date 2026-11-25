import Foundation

/// What a gateway lets the computers behind it reach. Everything else is dropped and logged. The host app decides
/// what goes in, such as a Mission's targets and the services opened for it; the gateway does not tell them apart.
public struct GatewayPolicy: Equatable, Sendable {
    public enum Rule: Hashable, Sendable {
        /// A name and every name under it. A gateway cannot yet tell a name from its subdomains: it opens what DNS
        /// answers for any name under a domain it was given.
        // TODO: Exact names and subdomains-only rules both open the whole domain, because dnsmasq matches by suffix.
        // Holding them apart needs a resolver of our own in the gateway, or the hostname proxy planned for services.
        case domain(String)
        case address(String)
        case network(String, prefix: Int)
    }

    // TODO: Services and package sources open by address, so whatever shares their CDN addresses opens with them.
    // A proxy on 80 and 443 that lets through by hostname (TLS SNI, HTTP Host) is planned for them, on top of this.
    public var allowed: [Rule]
    /// Wins over `allowed`, even for an address that an allowed name also resolves to.
    public var denied: [Rule]

    public init(allowed: [Rule] = [], denied: [Rule] = []) {
        self.allowed = allowed
        self.denied = denied
    }

    /// Where Linux computers install software from, open behind every gateway.
    // TODO: http.kali.org redirects to mirrors around the world, which are not listed; pin the Kali images to
    // kali.download, or list the mirrors. Other package sources (Go, RubyGems, GitHub) are left out on purpose.
    public static let packageSources: [Rule] = [
        "http.kali.org", "kali.download", "archive.kali.org",
        "dl-cdn.alpinelinux.org",
        "deb.debian.org", "security.debian.org",
        "pypi.org", "files.pythonhosted.org",
    ].map { .domain($0) }
}

/// A computer's place behind a gateway: its card's addresses inside, and the address its traffic leaves under.
public struct GatewaySlot: Equatable, Sendable {
    /// The gateway's card for this slot is eth<index>; eth0 is the gateway's own way out, through NAT.
    public let index: Int
    /// Each slot is a network of its own: the gateway is .1, the computer .2.
    public var gatewayAddress: String { "10.77.\(index).1" }
    public var computerAddress: String { "10.77.\(index).2" }
    /// An address of NAT's network the computer's packets leave under, so even those Linux's connection tracking
    /// rejects, such as FIN and Xmas probes, find their way back: NAT takes any address of its network.
    public let outsideAddress: String

    public init(index: Int, outsideAddress: String) {
        self.index = index
        self.outsideAddress = outsideAddress
    }
}

/// The gateway's nftables ruleset and dnsmasq configuration for a policy.
public enum GatewayConfiguration {
    /// Log prefixes, which `GatewayFirewallEntry.parse` reads back as verdicts.
    static let allowed = "gateway-allow ", dropped = "gateway-drop ", denied = "gateway-deny "
    /// Where ulogd writes every logged connection, one JSON object a line, and dnsmasq every lookup.
    public static let firewallLog = "/var/log/gateway.json", dnsLog = "/var/log/dnsmasq.log"

    public static func ruleset(_ policy: GatewayPolicy, slots: [GatewaySlot]) -> String {
        func networks(_ rules: [GatewayPolicy.Rule]) -> [String] {
            rules.compactMap {
                switch $0 {
                case .address(let address): address.contains(":") ? nil : address + "/32"
                case .network(let address, let prefix): address.contains(":") ? nil : network(address, prefix: prefix)
                case .domain: nil
                }
            }
        }
        func set(_ name: String, _ elements: [String]) -> String {
            "  set \(name) { type ipv4_addr; flags interval; auto-merge;\(elements.isEmpty ? "" : " elements = { \(elements.joined(separator: ", ")) };") }"
        }
        var lines = [
            "flush ruleset",
            "table inet gateway {",
            // What DNS answers for allowed and denied names; an address stays a day after its last answer.
            // TODO: Expire each address with its record's TTL rather than a fixed day.
            "  set allowed4 { type ipv4_addr; flags timeout; timeout 1d; }",
            "  set denied4 { type ipv4_addr; flags timeout; timeout 1d; }",
            set("allowedNetworks4", networks(policy.allowed)),
            set("deniedNetworks4", networks(policy.denied)),
            // What connection tracking follows is SNATed as usual, which also rewrites the packet an ICMP error quotes.
            "  chain nat_out {",
            "    type nat hook postrouting priority srcnat;",
        ]
        lines += slots.map { "    oifname \"eth0\" ip saddr \($0.computerAddress) snat ip to \($0.outsideAddress)" }
        lines += [
            "  }",
            // What it rejects (FIN, NULL, Xmas and ACK probes, and what answers them) skips NAT, so it is rewritten
            // without state; the gateway's own traffic is always tracked, so it is never touched.
            "  chain stateless_out {",
            "    type filter hook postrouting priority srcnat + 10;",
        ]
        lines += slots.map { "    oifname \"eth0\" ct state invalid,untracked ip saddr \($0.computerAddress) ip saddr set \($0.outsideAddress)" }
        lines += [
            "  }",
            "  chain stateless_in {",
            "    type filter hook prerouting priority dstnat + 10;",
        ]
        lines += slots.map { "    iifname \"eth0\" ct state invalid,untracked ip daddr \($0.outsideAddress) ip daddr set \($0.computerAddress)" }
        lines += [
            "  }",
            "  chain forward {",
            "    type filter hook forward priority filter; policy drop;",
            // Answers coming back, and the computers behind one gateway reaching each other.
            "    iifname \"eth0\" accept",
            "    iifname != \"eth0\" oifname != \"eth0\" accept",
            // TODO: IPv6 is dropped whatever the policy says; the computers get no IPv6 address behind a gateway.
            "    meta nfproto ipv6 drop",
            // Every verdict goes to ulogd, which keeps up with a scan where the kernel's own log drops lines.
            "    ip daddr @deniedNetworks4 log group 1 prefix \"\(denied)\" drop",
            "    ip daddr @denied4 log group 1 prefix \"\(denied)\" drop",
            "    ip daddr @allowedNetworks4 jump allow",
            "    ip daddr @allowed4 jump allow",
            "    log group 1 prefix \"\(dropped)\" drop",
            "  }",
            // Each connection is logged as it opens, and each probe that opens none; not every packet of it.
            "  chain allow {",
            "    ct state new,invalid,untracked log group 1 prefix \"\(allowed)\"",
            "    accept",
            "  }",
            "}",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// ulogd, writing what the ruleset logs as JSON lines.
    static let ulogd = """
        [global]
        logfile="/var/log/ulogd.log"
        loglevel=3
        plugin="/usr/lib/ulogd/ulogd_inppkt_NFLOG.so"
        plugin="/usr/lib/ulogd/ulogd_raw2packet_BASE.so"
        plugin="/usr/lib/ulogd/ulogd_filter_IFINDEX.so"
        plugin="/usr/lib/ulogd/ulogd_filter_IP2STR.so"
        plugin="/usr/lib/ulogd/ulogd_output_JSON.so"
        stack=log1:NFLOG,base1:BASE,ifi1:IFINDEX,ip2str1:IP2STR,json1:JSON
        [log1]
        group=1
        [json1]
        sync=1
        file="\(firewallLog)"

        """

    /// The network an address and prefix name, as nftables wants it: 10.0.0.5/8 is 10.0.0.0/8.
    static func network(_ address: String, prefix: Int) -> String? {
        let octets = address.split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 < 256 }), (0...32).contains(prefix) else { return nil }
        let value = octets.reduce(0) { $0 << 8 | $1 }
        let masked = prefix == 0 ? 0 : value & ~UInt32(0) << (32 - prefix)
        return (0..<4).map { String(masked >> (24 - 8 * $0) & 255) }.joined(separator: ".") + "/\(prefix)"
    }

    /// dnsmasq answers the computers' lookups through `upstream`, putting what it resolves for policy names in the sets.
    // TODO: A deny broader than an allow (deny target.com, allow a.target.com) loses to it, as dnsmasq takes the longest
    // match; only the address sets apply "deny wins".
    public static func dnsmasq(_ policy: GatewayPolicy, slots: [GatewaySlot], upstream: String) -> String {
        func domains(_ rules: [GatewayPolicy.Rule]) -> [String] {
            var seen: [String] = []
            for case .domain(let name) in rules where !seen.contains(name) { seen.append(name) }
            return seen
        }
        var lines = [
            "except-interface=eth0",
            "bind-dynamic",
            "no-resolv",
            "no-hosts",
            "server=\(upstream)",
            // TODO: Every name is answered, so a computer can still make lookups of names outside the policy; a strict
            // mode would answer only names it allows.
            "log-queries",
            "log-facility=\(dnsLog)",
        ]
        lines += domains(policy.allowed).map { "nftset=/\($0)/4#inet#gateway#allowed4" }
        lines += domains(policy.denied).map { "nftset=/\($0)/4#inet#gateway#denied4" }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A connection the gateway let through or stopped, or a probe that opened none.
public struct GatewayFirewallEntry: Equatable, Sendable {
    public enum Verdict: String, Sendable {
        case allowed
        /// Nothing in the policy allows it.
        case outsideScope = "outside-scope"
        /// A deny rule stopped it.
        case denied
    }

    public let time: Date
    /// The slot whose computer sent it; nil for anything else.
    public let slot: Int?
    public let verdict: Verdict
    public let source: String
    public let destination: String
    /// The name the destination was last looked up as, when a computer reached it by name.
    public var name: String?
    public let port: Int?
    /// TCP, UDP, ICMP or the protocol's number.
    public let `protocol`: String
    /// The TCP flags set, such as SYN or FIN.
    public let flags: [String]

    /// Reads ulogd's JSON lines; anything else is skipped.
    static func parse(_ lines: String, slots: [GatewaySlot]) -> [GatewayFirewallEntry] {
        lines.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let prefix = object["oob.prefix"] as? String, let source = object["src_ip"] as? String,
                  let destination = object["dest_ip"] as? String else { return nil }
            let verdict: Verdict
            switch prefix {
            case GatewayConfiguration.allowed: verdict = .allowed
            case GatewayConfiguration.denied: verdict = .denied
            case GatewayConfiguration.dropped: verdict = .outsideScope
            default: return nil
            }
            let seconds = (object["oob.time.sec"] as? Double) ?? Date().timeIntervalSince1970
            let micro = (object["oob.time.usec"] as? Double) ?? 0
            let number = object["ip.protocol"] as? Int
            let proto = switch number { case 6: "TCP"; case 17: "UDP"; case 1: "ICMP"; default: number.map(String.init) ?? "IP" }
            let flags = ["syn", "ack", "fin", "rst", "psh", "urg"].filter { (object["tcp.\($0)"] as? Int) == 1 }.map { $0.uppercased() }
            return GatewayFirewallEntry(time: Date(timeIntervalSince1970: seconds + micro / 1_000_000),
                                        slot: slots.first { $0.computerAddress == source }?.index, verdict: verdict,
                                        source: source, destination: destination, name: nil,
                                        port: object["dest_port"] as? Int, protocol: proto, flags: flags)
        }
    }
}

/// A name a computer looked up through the gateway, and what it was told.
public struct GatewayLookup: Equatable, Sendable {
    public let time: Date
    public let slot: Int?
    public let name: String
    /// A, AAAA and so on.
    public let type: String
    /// Addresses and CNAMEs as dnsmasq gave them, or what it said instead, such as NXDOMAIN.
    public var answers: [String]

    /// Reads dnsmasq's log: each query, with the answers that follow it. `year` places its dates, which have none.
    static func parse(_ lines: String, slots: [GatewaySlot], year: Int) -> (lookups: [GatewayLookup], names: [String: String]) {
        var lookups: [GatewayLookup] = []
        var names: [String: String] = [:]
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.timeZone = TimeZone(identifier: "UTC")
        dates.dateFormat = "yyyy MMM d HH:mm:ss"
        for line in lines.split(separator: "\n") {
            // Nov 25 14:42:14 dnsmasq[45]: query[A] example.com from 10.66.0.2
            guard let colon = line.range(of: "]: ") else { continue }
            let stamp = line[..<colon.lowerBound].split(separator: " ").prefix(3).joined(separator: " ")
            let time = dates.date(from: "\(year) \(stamp)") ?? Date()
            let words = line[colon.upperBound...].split(separator: " ").map(String.init)
            guard words.count >= 3 else { continue }
            if words[0].hasPrefix("query["), words.count >= 4, words[2] == "from" {
                let type = String(words[0].dropFirst("query[".count).dropLast())
                lookups.append(GatewayLookup(time: time, slot: slots.first { $0.computerAddress == words[3] }?.index,
                                             name: words[1], type: type, answers: []))
            } else if ["reply", "cached", "config"].contains(words[0]), words.count >= 4, words[2] == "is" {
                let answer = words[3...].joined(separator: " ")
                // A and AAAA are asked together, before either is answered: an address goes to the query of its kind.
                let kind: String? = answer.first?.isHexDigit == true && answer.contains(":") ? "AAAA"
                    : answer.first?.isNumber == true ? "A" : nil
                if let index = lookups.lastIndex(where: { $0.name == words[1] && (kind == nil || $0.type == kind) })
                    ?? lookups.lastIndex(where: { $0.name == words[1] }) { lookups[index].answers.append(answer) }
                if answer.first?.isNumber == true, !answer.contains(":") { names[answer] = words[1] }
            }
        }
        return (lookups, names)
    }
}

/// What a gateway's logs gained since it was last asked, and addresses newly shared by a denied and an allowed name.
public struct GatewayRecords: Sendable {
    public var firewall: [GatewayFirewallEntry] = []
    public var lookups: [GatewayLookup] = []
    public var conflicts: [String] = []
    /// More was waiting than one call reads; ask again.
    public var more = false
}

/// Reading a log in pieces: what a piece holds up to its last whole line, and how many bytes that is.
enum LogChunk {
    static func wholeLines(_ text: String) -> (text: String, bytes: Int) {
        guard let end = text.lastIndex(of: "\n") else { return ("", 0) }
        let kept = String(text[...end])
        return (kept, kept.utf8.count)
    }
}
