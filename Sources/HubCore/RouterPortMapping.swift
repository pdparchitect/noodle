import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import HubWire

/// A port the router forwards to this Mac, and the outside address devices reach it on.
public struct RouterMapping: Equatable, Sendable {
    public enum Method: String, Sendable {
        case natPMP = "NAT-PMP"
        case upnp = "UPnP"
    }

    public var endpoint: LinkEndpoint
    public var method: Method
    /// Seconds the router keeps the port open; zero means until it is closed.
    public var lifetime: Int
    package var internalPort: UInt16
    /// Where a UPnP router takes the request that closes the port again.
    package var upnpControl: URL?
    package var upnpService: String?
    /// This Mac's address on the network, which the UPnP router forwards the port to.
    package var upnpClient: String?

    public init(endpoint: LinkEndpoint, method: Method, lifetime: Int, internalPort: UInt16? = nil) {
        self.endpoint = endpoint
        self.method = method
        self.lifetime = lifetime
        self.internalPort = internalPort ?? endpoint.port
    }

    /// Whether devices away from home can reach this IPv4 address. A private one means
    /// another router stands in front of this one; 100.64/10 is a provider sharing one
    /// address among many homes (CGNAT).
    public static func isPublic(_ address: String) -> Bool {
        var value = in_addr()
        guard inet_pton(AF_INET, address, &value) == 1 else { return false }
        let bytes = withUnsafeBytes(of: value) { Array($0) }
        switch (bytes[0], bytes[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (172, 16...31), (100, 64...127): return false
        default: return bytes[0] < 224
        }
    }
}

public struct RouterMappingError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    /// Nothing on the network answered the protocol.
    package static let unanswered = RouterMappingError("The router did not answer.")
}

/// Asks the router to forward the Hub's UDP port, so devices away from home can reach it.
public protocol RouterPortMapper: Sendable {
    func map(port: UInt16) async throws -> RouterMapping
    /// Makes sure the router still forwards a port it opened, opening it again if the router
    /// forgot it and extending its lease, and returns it with the router's outside address now.
    /// Throws when that router cannot be asked again; the Hub then maps the port afresh.
    func renew(_ mapping: RouterMapping) async throws -> RouterMapping
    func unmap(_ mapping: RouterMapping) async
}

/// How often the Hub makes sure the router still forwards its port. A router that restarts,
/// cuts a lease short or gets a new outside address would otherwise leave devices away from
/// home without the Hub until the lease was next renewed.
public struct RouterChecks: Sendable {
    /// Between checks of a port the router opened.
    public var interval: Duration
    /// The wait after the router first refuses or does not answer; each failure in a row doubles
    /// it, up to `longestRetry`.
    public var firstRetry: Duration
    public var longestRetry: Duration
    /// How long a changed network gets to settle on its router and addresses before the port is opened again.
    public var settle: Duration

    public init(interval: Duration, firstRetry: Duration, longestRetry: Duration, settle: Duration) {
        self.interval = interval
        self.firstRetry = firstRetry
        self.longestRetry = longestRetry
        self.settle = settle
    }

    public static let standard = RouterChecks(interval: .seconds(180), firstRetry: .seconds(30),
                                              longestRetry: .seconds(300), settle: .seconds(2))

    /// When to check a port again: after the interval, or halfway through a shorter lease.
    func delay(keeping mapping: RouterMapping) -> Duration {
        guard mapping.lifetime > 0 else { return interval }
        return min(interval, .seconds(max(10, mapping.lifetime / 2)))
    }

    /// When to ask again after this many failures in a row.
    func retry(after failures: Int) -> Duration {
        min(longestRetry, firstRetry * (1 << min(max(failures - 1, 0), 16)))
    }
}

/// NAT-PMP (RFC 6886), which Apple routers and most MiniUPnPd ones answer.
package enum NATPMP {
    package static let port: UInt16 = 5351
    package static let externalAddressRequest = Data([0, 0])

    /// Asks for a UDP mapping; a zero lifetime removes it.
    package static func mapRequest(internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) -> Data {
        var data = Data([0, 1, 0, 0])
        withUnsafeBytes(of: internalPort.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: externalPort.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: lifetime.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    package static func externalAddress(from reply: Data) throws -> String {
        let bytes = try checked(reply, opcode: 128, length: 12)
        return bytes[8..<12].map(String.init).joined(separator: ".")
    }

    package static func mapping(from reply: Data) throws -> (externalPort: UInt16, lifetime: UInt32) {
        let bytes = try checked(reply, opcode: 129, length: 16)
        return (UInt16(bytes[10]) << 8 | UInt16(bytes[11]),
                bytes[12..<16].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    private static func checked(_ reply: Data, opcode: UInt8, length: Int) throws -> [UInt8] {
        let bytes = [UInt8](reply)
        guard bytes.count >= length, bytes[0] == 0, bytes[1] == opcode else {
            throw RouterMappingError("The router sent an unexpected NAT-PMP reply.")
        }
        switch UInt16(bytes[2]) << 8 | UInt16(bytes[3]) {
        case 0: return bytes
        case 2: throw RouterMappingError("The router refused to open a port.")
        case 3: throw RouterMappingError("The router is not connected to the internet.")
        case 4: throw RouterMappingError("The router has no ports left to open.")
        case let code: throw RouterMappingError("The router could not open a port (NAT-PMP error \(code)).")
        }
    }
}

/// UPnP Internet Gateway Device: SSDP to find the router, SOAP to ask it.
package enum UPnP {
    package static let searchRequest = Data("""
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r
        \r

        """.utf8)

    package static func location(inSearchReply reply: String) -> URL? {
        for line in reply.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
            return URL(string: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// The services that can forward ports, with their control URLs resolved.
    package static func connectionServices(inDescription data: Data, at location: URL) -> [(type: String, control: URL)] {
        let elements = XMLElements.parse(data)
        let base = elements.first { $0.name == "URLBase" }.flatMap { URL(string: $0.text) } ?? location
        var services: [(type: String, control: URL)] = []
        var type: String?, control: String?
        for element in elements {
            switch element.name {
            case "serviceType": type = element.text
            case "controlURL": control = element.text
            case "service":
                if let type, type.contains(":service:WANIPConnection:") || type.contains(":service:WANPPPConnection:"),
                   let control, let url = URL(string: control, relativeTo: base).flatMap({ URL(string: $0.absoluteString) }) {
                    services.append((type, url))
                }
                type = nil
                control = nil
            default: continue
            }
        }
        return services
    }

    package static func envelope(action: String, service: String, arguments: [(String, String)]) -> Data {
        let body = arguments.map { "<\($0)>\(escaped($1))</\($0)>" }.joined()
        return Data("""
            <?xml version="1.0"?>\r
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
            <s:Body><u:\(action) xmlns:u="\(service)">\(body)</u:\(action)></s:Body></s:Envelope>
            """.utf8)
    }

    package static func value(_ name: String, in reply: Data) -> String? {
        XMLElements.parse(reply).first { $0.name == name }?.text
    }

    package static func faultCode(in reply: Data) -> Int? {
        value("errorCode", in: reply).flatMap(Int.init)
    }

    /// The address a GetSpecificPortMappingEntry reply forwards to, if it forwards to `port` there and is on.
    package static func forwardedClient(in reply: Data, port: UInt16) -> String? {
        let elements = XMLElements.parse(reply)
        func value(_ name: String) -> String? { elements.first { $0.name == name }?.text }
        guard value("NewInternalPort") == String(port), !["0", "false"].contains(value("NewEnabled")?.lowercased() ?? "1"),
              let client = value("NewInternalClient"), !client.isEmpty else { return nil }
        return client
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Every element of a document in closing order, by local name, with its own text.
private final class XMLElements: NSObject, XMLParserDelegate {
    private var elements: [(name: String, text: String)] = []
    private var texts: [String] = []

    static func parse(_ data: Data) -> [(name: String, text: String)] {
        let collector = XMLElements()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.elements
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        texts.append("")
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !texts.isEmpty { texts[texts.count - 1] += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let text = texts.popLast() ?? ""
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        elements.append((name, text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
