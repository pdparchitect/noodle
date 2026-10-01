import Darwin
import Foundation
import Synchronization
#if os(macOS)
import SystemConfiguration
#endif

extension LinkEndpoint {
    public static let defaultPort: UInt16 = 38_415

    public enum Network: Equatable, Sendable { case home, tailnet, internet }

    /// Where a device has to be to reach this address. Hubs list their routable IPv6 addresses too;
    /// home routers rarely let those in from outside, so they count as the home network.
    public var network: Network {
        let host = host.lowercased()
        if host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:") { return .tailnet }
        if host.hasSuffix(".local") || host.contains(":") { return .home }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard octets.count == 4 else { return .internet }
        switch (octets[0], octets[1]) {
        case (100, 64...127): return .tailnet
        case (10, _), (172, 16...31), (192, 168): return .home
        default: return .internet
        }
    }

    #if os(macOS)
    /// This Mac's own addresses: its Bonjour name, its Tailscale MagicDNS name, then every IPv4
    /// and routable IPv6 address on an active interface. Loopback and link-local addresses are left out: a device on
    /// the same Mac reaches the Hub the same way a device across the room does.
    public static func local(port: UInt16) -> [LinkEndpoint] {
        var hosts: [String] = []
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            hosts.append("\(name).local")
        }
        var ipv4: [String] = [], ipv6: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return hosts.map { LinkEndpoint(host: $0, port: port) } }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else { continue }
                let text = String(cString: buffer)
                guard !text.hasPrefix("169.254.") else { continue }
                ipv4.append(text)
                if let name = tailnetName(of: text, resolve: cachedReverseLookup) { hosts.append(name) }
            case AF_INET6:
                var value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                // Link-local addresses need an interface to be usable, and temporary ones rotate.
                let bytes = withUnsafeBytes(of: value) { Array($0) }
                guard !(bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) else { continue }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &value, &buffer, socklen_t(buffer.count)) != nil else { continue }
                ipv6.append(String(cString: buffer))
            default: continue
            }
        }
        var seen = Set<String>()
        return (hosts + ipv4 + ipv6).filter { seen.insert($0).inserted }.map { LinkEndpoint(host: $0, port: port) }
    }
    #endif

    /// The name Tailscale gives an address in its 100.64.0.0/10 range, which stays reachable
    /// wherever the device is on the tailnet. Nil for any other address.
    static func tailnetName(of address: String, resolve: (String) -> String?) -> String? {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, octets[0] == 100, octets[1] & 0xC0 == 64,
              let name = resolve(address).map({ $0.hasSuffix(".") ? String($0.dropLast()) : $0 }),
              !name.isEmpty, name != address else { return nil }
        return name
    }

    /// Posted when a Tailscale name turns up after the addresses were read without it.
    public static let localNamesChanged = Notification.Name("HubLink.localNamesChanged")

    /// Settings reads the endpoints on every redraw, so each address is looked up rarely, and never on the caller.
    private static let reverseLookups = ReverseLookups(
        now: Date.init, run: { DispatchQueue.global(qos: .utility).async(execute: $0) },
        found: { NotificationCenter.default.post(name: localNamesChanged, object: nil) },
        resolve: TailnetDNS.name(of:))

    private static func cachedReverseLookup(_ address: String) -> String? { reverseLookups.name(of: address) }

    /// Reads "host", "host:port", "[v6]:port" or a bare IPv6 address.
    public init?(text: String, defaultPort: UInt16) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.isEmpty || rest.hasPrefix(":"), let port = rest.isEmpty ? defaultPort : UInt16(rest.dropFirst()) else { return nil }
            self.init(host: host, port: port)
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            guard let port = UInt16(text[text.index(after: colon)...]) else { return nil }
            self.init(host: String(text[..<colon]), port: port)
        } else {
            self.init(host: text, port: defaultPort)
        }
    }
}

/// Names found for addresses, kept for good. Each is looked up through `run`, so the caller
/// gets nil until it arrives and `found` says when it has. A miss is asked again after a
/// while: Tailscale's resolver may not be up yet when Settings first draws.
final class ReverseLookups: @unchecked Sendable {
    static let missLifetime: TimeInterval = 30

    private enum Answer {
        case asking
        case name(String)
        case miss(Date)
    }

    private let now: () -> Date
    private let run: (@escaping () -> Void) -> Void
    private let found: () -> Void
    private let resolve: (String) -> String?
    private let answers = Mutex<[String: Answer]>([:])

    init(now: @escaping () -> Date, run: @escaping (@escaping () -> Void) -> Void, found: @escaping () -> Void,
         resolve: @escaping (String) -> String?) {
        self.now = now
        self.run = run
        self.found = found
        self.resolve = resolve
    }

    func name(of address: String) -> String? {
        let date = now()
        let known: Answer? = answers.withLock { answers in
            if let answer = answers[address] {
                guard case .miss(let asked) = answer, date.timeIntervalSince(asked) > Self.missLifetime else { return answer }
            }
            answers[address] = .asking
            return nil
        }
        switch known {
        case .name(let name): return name
        case .asking, .miss: return nil
        case nil:
            run { [self] in
                let name = resolve(address)
                answers.withLock { $0[address] = name.map(Answer.name) ?? .miss(now()) }
                if name != nil { found() }
            }
            return nil
        }
    }
}

/// Asks Tailscale's resolver for an address's name directly: inside the app sandbox the system
/// resolver refuses reverse lookups with kDNSServiceErr_PolicyDenied, while a plain DNS query goes through.
enum TailnetDNS {
    static let resolver = "100.100.100.100"

    static func name(of address: String) -> String? {
        let id = UInt16.random(in: .min ... .max)
        guard let query = query(for: address, id: id) else { return nil }
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var server = sockaddr_in()
        server.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        server.sin_family = sa_family_t(AF_INET)
        server.sin_port = UInt16(53).bigEndian
        inet_pton(AF_INET, resolver, &server.sin_addr)
        let sent = query.withUnsafeBytes { bytes in
            withUnsafePointer(to: &server) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == query.count else { return nil }
        var reply = [UInt8](repeating: 0, count: 512)
        let received = recv(socket, &reply, reply.count, 0)
        guard received > 0 else { return nil }
        return name(inReply: Data(reply.prefix(received)), id: id)
    }

    /// A PTR question for an IPv4 address.
    static func query(for address: String, id: UInt16) -> Data? {
        let octets = address.split(separator: ".")
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        var query = Data([UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in octets.reversed() + ["in-addr", "arpa"] {
            query.append(UInt8(label.utf8.count))
            query.append(contentsOf: label.utf8)
        }
        query.append(contentsOf: [0, 0, 12, 0, 1])
        return query
    }

    /// The first PTR answer in a reply to the query with this id.
    static func name(inReply reply: Data, id: UInt16) -> String? {
        let bytes = [UInt8](reply)
        guard bytes.count >= 12, UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == id, bytes[3] & 0x0F == 0 else { return nil }
        let questions = Int(bytes[4]) << 8 | Int(bytes[5]), answers = Int(bytes[6]) << 8 | Int(bytes[7])
        var index = 12
        for _ in 0..<questions {
            guard let end = skipName(bytes, from: index) else { return nil }
            index = end + 4
        }
        for _ in 0..<answers {
            guard let end = skipName(bytes, from: index), end + 10 <= bytes.count else { return nil }
            let type = Int(bytes[end]) << 8 | Int(bytes[end + 1])
            let length = Int(bytes[end + 8]) << 8 | Int(bytes[end + 9])
            guard end + 10 + length <= bytes.count else { return nil }
            if type == 12 { return readName(bytes, from: end + 10) }
            index = end + 10 + length
        }
        return nil
    }

    private static func skipName(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            let length = Int(bytes[index])
            if length == 0 { return index + 1 }
            if length & 0xC0 == 0xC0 { return index + 2 <= bytes.count ? index + 2 : nil }
            index += length + 1
        }
        return nil
    }

    private static func readName(_ bytes: [UInt8], from start: Int) -> String? {
        var labels: [String] = [], index = start, jumps = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            if length == 0 { return labels.isEmpty ? nil : labels.joined(separator: ".") }
            if length & 0xC0 == 0xC0 {
                guard index + 1 < bytes.count, jumps < 16 else { return nil }
                index = (length & 0x3F) << 8 | Int(bytes[index + 1])
                jumps += 1
                continue
            }
            guard index + 1 + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[(index + 1)..<(index + 1 + length)], as: UTF8.self))
            index += length + 1
        }
        return nil
    }
}
