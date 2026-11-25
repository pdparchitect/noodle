import ComputerCore
import Containerization
import ContainerizationExtras
import Foundation
import Virtualization

/// A virtual cable between two computers: every frame one end's card sends comes out of the other's. The
/// computers at both ends run in this process, which holds the socket pair, so nothing on the host routes or
/// rewrites their packets; whatever sits at the far end, such as a gateway, decides where they go.
public struct NetworkLink: Sendable {
    public let first: FileHandle
    public let second: FileHandle

    public init() throws {
        var ends: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &ends) == 0 else {
            throw ComputerError("Could not link two computers: \(String(cString: strerror(errno))).")
        }
        // Virtualization asks for a receive buffer several times the send buffer, so bursts are not dropped.
        for end in ends {
            var send: Int32 = 1 << 20, receive: Int32 = 4 << 20
            setsockopt(end, SOL_SOCKET, SO_SNDBUF, &send, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(end, SOL_SOCKET, SO_RCVBUF, &receive, socklen_t(MemoryLayout<Int32>.size))
        }
        first = FileHandle(fileDescriptor: ends[0], closeOnDealloc: true)
        second = FileHandle(fileDescriptor: ends[1], closeOnDealloc: true)
    }
}

/// A Linux computer's card on one end of a `NetworkLink`, with the address the computer gives itself on it.
public struct LinkInterface: Interface, VZInterface {
    public var ipv4Address: CIDRv4
    public var ipv4Gateway: IPv4Address?
    public var macAddress: MACAddress?
    public var mtu: UInt32 = 1500
    public let end: FileHandle

    public init(end: FileHandle, ipv4Address: CIDRv4, ipv4Gateway: IPv4Address? = nil, macAddress: MACAddress? = nil) {
        self.end = end
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
    }

    /// What plugs the card into its end, at start or into a running computer's card.
    public func attachment() -> VZFileHandleNetworkDeviceAttachment {
        VZFileHandleNetworkDeviceAttachment(fileHandle: end)
    }

    public func device() throws -> VZVirtioNetworkDeviceConfiguration {
        let config = VZVirtioNetworkDeviceConfiguration()
        if let macAddress {
            guard let mac = VZMACAddress(string: macAddress.description) else { throw ComputerError("Invalid MAC address \(macAddress).") }
            config.macAddress = mac
        }
        config.attachment = attachment()
        return config
    }
}
