import Darwin
import Foundation
import HubCore
import HubLink
import SystemConfiguration

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

    public func renew(_ mapping: RouterMapping) async throws -> RouterMapping {
        guard let gateway = Self.gateway() else { throw RouterMappingError("This Mac is not connected to a router.") }
        switch mapping.method {
        case .natPMP:
            // Asking again for the port it holds is how NAT-PMP renews, and opens it again if the router forgot.
            return try await natPMP(gateway: gateway, port: mapping.internalPort, externalPort: mapping.endpoint.port)
        case .upnp:
            return try await renewUPnP(mapping, gateway: gateway)
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

    private func natPMP(gateway: String, port: UInt16, externalPort: UInt16? = nil) async throws -> RouterMapping {
        let address = try NATPMP.externalAddress(from: try await Self.exchange(NATPMP.externalAddressRequest, with: gateway))
        try Self.requirePublic(address)
        let request = NATPMP.mapRequest(internalPort: port, externalPort: externalPort ?? port, lifetime: Self.requestedLifetime)
        let grant = try NATPMP.mapping(from: try await Self.exchange(request, with: gateway))
        return RouterMapping(endpoint: LinkEndpoint(host: address, port: grant.externalPort), method: .natPMP,
                             lifetime: Int(grant.lifetime), internalPort: port)
    }

    private func upnp(gateway: String, port: UInt16) async throws -> RouterMapping {
        let (locations, internalAddress) = try await Task.detached { () throws -> ([URL], String) in
            let address = try Self.internalAddress(toward: gateway)
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
                mapping.upnpClient = internalAddress
                return mapping
            }
        }
        throw RouterMappingError.unanswered
    }

    /// Asks the router that opened the port, without searching the network for it again.
    private func renewUPnP(_ mapping: RouterMapping, gateway: String) async throws -> RouterMapping {
        guard let control = mapping.upnpControl, let type = mapping.upnpService else { throw RouterMappingError.unanswered }
        let service = (type: type, control: control), port = mapping.endpoint.port
        let internalAddress = try Self.internalAddress(toward: gateway)
        guard let reply = try? await Self.soap("GetExternalIPAddress", service: type, control: control, arguments: []),
              let address = UPnP.value("NewExternalIPAddress", in: reply), !address.isEmpty else { throw RouterMappingError.unanswered }
        try Self.requirePublic(address)
        let entry = try? await Self.soap("GetSpecificPortMappingEntry", service: type, control: control, arguments: [
            ("NewRemoteHost", ""), ("NewExternalPort", String(port)), ("NewProtocol", "UDP"),
        ])
        let client = entry.flatMap { UPnP.forwardedClient(in: $0, port: mapping.internalPort) }
        if client != internalAddress {
            // Forwarded to this Mac's old address on the network: the Hub's own entry, in the way of the new one.
            if let client, client == mapping.upnpClient {
                _ = try? await Self.soap("DeletePortMapping", service: type, control: control, arguments: [
                    ("NewRemoteHost", ""), ("NewExternalPort", String(port)), ("NewProtocol", "UDP"),
                ])
            }
            try await addMapping(port: port, internalAddress: internalAddress, lifetime: mapping.lifetime, service: service)
        } else if mapping.lifetime > 0 {
            // A router that will not overwrite its own entry to extend the lease still forwards the port for now.
            try? await addMapping(port: port, internalAddress: internalAddress, lifetime: mapping.lifetime, service: service)
        }
        var renewed = mapping
        renewed.endpoint.host = address
        renewed.upnpClient = internalAddress
        return renewed
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

    /// The address this Mac has on the router's network. Connecting a UDP socket sends nothing.
    private static func internalAddress(toward gateway: String) throws -> String {
        let socket = try UDPSocket(connectedTo: gateway, port: NATPMP.port)
        defer { socket.close() }
        guard let address = socket.localAddress else { throw RouterMappingError.unanswered }
        return address
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
