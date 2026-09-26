import Darwin
import Foundation
import HubLink
import SystemConfiguration

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
    var internalPort: UInt16
    /// Where a UPnP router takes the request that closes the port again.
    var upnpControl: URL?
    var upnpService: String?

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
    static let unanswered = RouterMappingError("The router did not answer.")
}

/// Asks the router to forward the Hub's UDP port, so devices away from home can reach it.
public protocol RouterPortMapper: Sendable {
    func map(port: UInt16) async throws -> RouterMapping
    func unmap(_ mapping: RouterMapping) async
}

/// NAT-PMP (RFC 6886), which Apple routers and most MiniUPnPd ones answer.
enum NATPMP {
    static let port: UInt16 = 5351
    static let externalAddressRequest = Data([0, 0])

    /// Asks for a UDP mapping; a zero lifetime removes it.
    static func mapRequest(internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) -> Data {
        var data = Data([0, 1, 0, 0])
        withUnsafeBytes(of: internalPort.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: externalPort.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: lifetime.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    static func externalAddress(from reply: Data) throws -> String {
        let bytes = try checked(reply, opcode: 128, length: 12)
        return bytes[8..<12].map(String.init).joined(separator: ".")
    }

    static func mapping(from reply: Data) throws -> (externalPort: UInt16, lifetime: UInt32) {
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
enum UPnP {
    static let searchRequest = Data("""
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r
        \r

        """.utf8)

    static func location(inSearchReply reply: String) -> URL? {
        for line in reply.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
            return URL(string: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// The services that can forward ports, with their control URLs resolved.
    static func connectionServices(inDescription data: Data, at location: URL) -> [(type: String, control: URL)] {
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

    static func envelope(action: String, service: String, arguments: [(String, String)]) -> Data {
        let body = arguments.map { "<\($0)>\(escaped($1))</\($0)>" }.joined()
        return Data("""
            <?xml version="1.0"?>\r
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
            <s:Body><u:\(action) xmlns:u="\(service)">\(body)</u:\(action)></s:Body></s:Envelope>
            """.utf8)
    }

    static func value(_ name: String, in reply: Data) -> String? {
        XMLElements.parse(reply).first { $0.name == name }?.text
    }

    static func faultCode(in reply: Data) -> Int? {
        value("errorCode", in: reply).flatMap(Int.init)
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

/// The router this Mac's default route goes through, asked with NAT-PMP first, then UPnP.
public struct SystemRouterPortMapper: RouterPortMapper {
    private static let requestedLifetime: UInt32 = 3600
    private static let session = URLSession(configuration: .ephemeral)

    public init() {}

    public func map(port: UInt16) async throws -> RouterMapping {
        guard let gateway = Self.gateway() else { throw RouterMappingError("This Mac is not connected to a router.") }
        let natPMPError: Error
        do { return try await natPMP(gateway: gateway, port: port) } catch { natPMPError = error }
        do {
            return try await upnp(gateway: gateway, port: port)
        } catch let error as RouterMappingError where error == .unanswered {
            guard natPMPError as? RouterMappingError == .unanswered else { throw natPMPError }
            throw RouterMappingError("The router does not open ports on request. Turn on UPnP or NAT-PMP on the router, or forward UDP port \(port) to this Mac.")
        }
    }

    public func unmap(_ mapping: RouterMapping) async {
        switch mapping.method {
        case .natPMP:
            guard let gateway = Self.gateway() else { return }
            _ = try? await Self.exchange(NATPMP.mapRequest(internalPort: mapping.internalPort, externalPort: 0, lifetime: 0),
                                         with: gateway)
        case .upnp:
            guard let control = mapping.upnpControl, let service = mapping.upnpService else { return }
            _ = try? await Self.soap("DeletePortMapping", service: service, control: control, arguments: [
                ("NewRemoteHost", ""), ("NewExternalPort", String(mapping.endpoint.port)), ("NewProtocol", "UDP"),
            ])
        }
    }

    private func natPMP(gateway: String, port: UInt16) async throws -> RouterMapping {
        let address = try NATPMP.externalAddress(from: try await Self.exchange(NATPMP.externalAddressRequest, with: gateway))
        try Self.requirePublic(address)
        let request = NATPMP.mapRequest(internalPort: port, externalPort: port, lifetime: Self.requestedLifetime)
        let grant = try NATPMP.mapping(from: try await Self.exchange(request, with: gateway))
        return RouterMapping(endpoint: LinkEndpoint(host: address, port: grant.externalPort), method: .natPMP,
                             lifetime: Int(grant.lifetime), internalPort: port)
    }

    private func upnp(gateway: String, port: UInt16) async throws -> RouterMapping {
        let (locations, internalAddress) = try await Task.detached { () throws -> ([URL], String) in
            let socket = try UDPSocket(connectedTo: gateway, port: NATPMP.port)
            defer { socket.close() }
            guard let address = socket.localAddress else { throw RouterMappingError.unanswered }
            return (try Self.search(), address)
        }.value
        // The router this Mac goes through first; others on the network cannot forward to it.
        for location in locations.filter({ $0.host == gateway }) + locations.filter({ $0.host != gateway }) {
            guard let (description, _) = try? await Self.session.data(for: URLRequest(url: location, timeoutInterval: 5)) else { continue }
            for service in UPnP.connectionServices(inDescription: description, at: location) {
                guard let reply = try? await Self.soap("GetExternalIPAddress", service: service.type, control: service.control, arguments: []),
                      let address = UPnP.value("NewExternalIPAddress", in: reply), !address.isEmpty else { continue }
                try Self.requirePublic(address)
                var lifetime = Int(Self.requestedLifetime)
                do {
                    try await addMapping(port: port, internalAddress: internalAddress, lifetime: lifetime, service: service)
                } catch UPnPFault.onlyPermanentLeases {
                    lifetime = 0
                    try await addMapping(port: port, internalAddress: internalAddress, lifetime: lifetime, service: service)
                }
                var mapping = RouterMapping(endpoint: LinkEndpoint(host: address, port: port), method: .upnp, lifetime: lifetime)
                mapping.upnpControl = service.control
                mapping.upnpService = service.type
                return mapping
            }
        }
        throw RouterMappingError.unanswered
    }

    private func addMapping(port: UInt16, internalAddress: String, lifetime: Int, service: (type: String, control: URL)) async throws {
        do {
            _ = try await Self.soap("AddPortMapping", service: service.type, control: service.control, arguments: [
                ("NewRemoteHost", ""), ("NewExternalPort", String(port)), ("NewProtocol", "UDP"),
                ("NewInternalPort", String(port)), ("NewInternalClient", internalAddress), ("NewEnabled", "1"),
                ("NewPortMappingDescription", "Noodle Hub"), ("NewLeaseDuration", String(lifetime)),
            ])
        } catch let fault as UPnPFault {
            switch fault {
            case .onlyPermanentLeases: throw fault
            case .other(718, _): throw RouterMappingError("The router already forwards UDP port \(port) to another device.")
            case .other(let code, _): throw RouterMappingError("The router refused to open a port (UPnP error \(code)).")
            }
        }
    }

    private enum UPnPFault: Error {
        case onlyPermanentLeases
        case other(Int, String?)
    }

    private static func soap(_ action: String, service: String, control: URL, arguments: [(String, String)]) async throws -> Data {
        var request = URLRequest(url: control, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = UPnP.envelope(action: action, service: service, arguments: arguments)
        let (data, response) = try await session.data(for: request)
        if let code = UPnP.faultCode(in: data) {
            throw code == 725 ? UPnPFault.onlyPermanentLeases : UPnPFault.other(code, UPnP.value("errorDescription", in: data))
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UPnPFault.other(0, nil) }
        return data
    }

    private static func requirePublic(_ address: String) throws {
        guard RouterMapping.isPublic(address) else {
            throw RouterMappingError("The router’s outside address, \(address), is not public, so devices away from home cannot reach it.")
        }
    }

    /// The IPv4 router of the default route.
    private static func gateway() -> String? {
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        return global?["Router"] as? String
    }

    /// Sends to the router and waits for its reply, sending again with growing waits as RFC 6886 asks.
    private static func exchange(_ request: Data, with gateway: String) async throws -> Data {
        try await Task.detached {
            let socket = try UDPSocket(connectedTo: gateway, port: NATPMP.port)
            defer { socket.close() }
            for wait in [0.25, 0.5, 1, 2] {
                socket.send(request)
                if let reply = socket.receive(timeout: wait) { return reply }
            }
            throw RouterMappingError.unanswered
        }.value
    }

    /// Description URLs of the gateways that answer an SSDP search within two seconds.
    private static func search() throws -> [URL] {
        let socket = try UDPSocket()
        defer { socket.close() }
        socket.send(UPnP.searchRequest, to: "239.255.255.250", port: 1900)
        var locations: [URL] = []
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            guard let reply = socket.receive(timeout: max(0.05, end.timeIntervalSinceNow)) else { continue }
            if let location = UPnP.location(inSearchReply: String(decoding: reply, as: UTF8.self)), !locations.contains(location) {
                locations.append(location)
            }
        }
        return locations
    }
}

/// A blocking IPv4 UDP socket, used off the main actor.
private struct UDPSocket {
    let descriptor: Int32

    init() throws {
        descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw RouterMappingError.unanswered }
    }

    init(connectedTo host: String, port: UInt16) throws {
        try self.init()
        var address = try Self.address(host, port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            close()
            throw RouterMappingError.unanswered
        }
    }

    func send(_ data: Data) {
        _ = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    }

    func send(_ data: Data, to host: String, port: UInt16) {
        guard var address = try? Self.address(host, port) else { return }
        _ = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func receive(timeout: TimeInterval) -> Data? {
        var wait = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = recv(descriptor, &buffer, buffer.count, 0)
        return count > 0 ? Data(buffer[0..<count]) : nil
    }

    /// The address this Mac uses toward the connected peer.
    var localAddress: String? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(cString: buffer)
    }

    func close() { Darwin.close(descriptor) }

    private static func address(_ host: String, _ port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw RouterMappingError.unanswered }
        return address
    }
}
