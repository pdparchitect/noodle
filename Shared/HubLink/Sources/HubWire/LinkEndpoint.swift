import Foundation

/// Where a Hub might be reached: a name or address and its UDP port.
public struct LinkEndpoint: Codable, Hashable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

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
