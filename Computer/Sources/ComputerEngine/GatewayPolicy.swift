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
    /// Log prefixes, which `GatewayEvent.parse` reads back.
    static let dropped = "gateway-drop ", denied = "gateway-deny "

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
            "    ip daddr @deniedNetworks4 log prefix \"\(denied)\" drop",
            "    ip daddr @denied4 log prefix \"\(denied)\" drop",
            "    ip daddr @allowedNetworks4 accept",
            "    ip daddr @allowed4 accept",
            "    log prefix \"\(dropped)\" drop",
            "  }",
            "}",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

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
            "log-facility=/var/log/dnsmasq.log",
        ]
        lines += domains(policy.allowed).map { "nftset=/\($0)/4#inet#gateway#allowed4" }
        lines += domains(policy.denied).map { "nftset=/\($0)/4#inet#gateway#denied4" }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// What a gateway reports back: traffic it stopped, and addresses that a denied and an allowed name share.
public enum GatewayEvent: Equatable, Sendable {
    /// `denied` when a deny rule stopped it, rather than nothing allowing it.
    case blocked(slot: Int?, destination: String, port: Int?, protocol: String, denied: Bool)
    case conflict(address: String)

    /// Reads the kernel's log lines for dropped packets.
    static func parse(kernelLog: String, slots: [GatewaySlot]) -> [GatewayEvent] {
        kernelLog.split(separator: "\n").compactMap { line in
            let denied = line.contains(GatewayConfiguration.denied)
            guard denied || line.contains(GatewayConfiguration.dropped) else { return nil }
            var fields: [String: String] = [:]
            for word in line.split(separator: " ") {
                let parts = word.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            guard let destination = fields["DST"], let proto = fields["PROTO"] else { return nil }
            let slot = slots.first { $0.computerAddress == fields["SRC"] }?.index
            return .blocked(slot: slot, destination: destination, port: fields["DPT"].flatMap { Int($0) },
                            protocol: proto, denied: denied)
        }
    }
}
