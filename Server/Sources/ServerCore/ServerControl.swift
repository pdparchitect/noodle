#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HubWire

/// What the server's own account asks the running server for, such as an invitation, which lives only in
/// its memory. The socket is in the data folder and only that account may open it.
@MainActor public final class ServerControl {
    private struct Request: Codable { var invite: String }
    private struct Reply: Codable { var link: String?; var error: String? }

    private let hub: ServerHub
    private let path: String
    private var source: (any DispatchSourceRead)?

    public nonisolated static func socket(in data: URL) -> URL { data.appendingPathComponent("control.sock") }

    public init(hub: ServerHub, data: URL) {
        self.hub = hub
        path = Self.socket(in: data).path
    }

    public func start() throws {
        // A socket that answers belongs to a server still running; one that does not was left by one that stopped.
        if let running = try? Self.connect(path) {
            close(running)
            throw ServerControlError("noodled is already running with its data in \(URL(fileURLWithPath: path).deletingLastPathComponent().path).")
        }
        unlink(path)
        let descriptor = try Self.socket()
        var address = try Self.address(path)
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0, listen(descriptor, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(descriptor)
            throw ServerControlError("noodled could not open \(path): \(reason).")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            MainActor.assumeIsolated { self?.serve(client) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    /// Reads the request away from the main thread, so a client that says nothing holds up nothing.
    private func serve(_ client: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        DispatchQueue.global().async { [weak self] in
            let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
            let request = (try? handle.readToEnd()).flatMap { try? JSONDecoder().decode(Request.self, from: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let reply = request.map { self?.answer($0) ?? Reply(error: "noodled is stopping.") }
                        ?? Reply(error: "noodled did not understand the request.")
                    DispatchQueue.global().async { try? handle.write(contentsOf: JSONEncoder().encode(reply)) }
                }
            }
        }
    }

    private func answer(_ request: Request) -> Reply {
        // Someone left out of the file is kept, suspended, and no longer invited.
        guard let user = hub.access.users.first(where: { $0.name == request.invite && !$0.isSuspended }) else {
            return Reply(error: "There is no user called \(request.invite) on \(hub.link.hubName).")
        }
        return Reply(link: hub.link.invite(user).url().absoluteString)
    }

    /// An invitation for `user` from the server running with its data in `data`.
    public nonisolated static func invite(_ user: String, data: URL) throws -> String {
        let descriptor: Int32
        do { descriptor = try connect(socket(in: data).path) } catch {
            throw ServerControlError("noodled is not running with its data in \(data.path).")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: JSONEncoder().encode(Request(invite: user)))
        shutdown(descriptor, Int32(SHUT_WR))
        guard let data = try handle.readToEnd(), let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw ServerControlError("noodled did not answer.")
        }
        if let link = reply.link { return link }
        throw ServerControlError(reply.error ?? "noodled did not answer.")
    }

    private nonisolated static func socket() throws -> Int32 {
        #if os(Linux)
        let descriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { throw ServerControlError("noodled could not make a socket: \(String(cString: strerror(errno))).") }
        return descriptor
    }

    private nonisolated static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ServerControlError("\(path) is too long for a socket; keep the data folder's path shorter.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }

    private nonisolated static func connect(_ path: String) throws -> Int32 {
        let descriptor = try socket()
        var address = try address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Linux)
                Glibc.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #else
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                #endif
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw ServerControlError(String(cString: strerror(errno)))
        }
        return descriptor
    }
}

public struct ServerControlError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
