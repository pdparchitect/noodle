#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WindowsPOSIX
import WinSDK
#endif
import Foundation
import HubWire

/// What the server's own account asks the running server for, such as an invitation, which lives only in
/// its memory. The socket is in the data folder and only that account may open it. On Windows it is a named
/// pipe named after that socket's path, with the same access.
@MainActor public final class ServerControl {
    private struct Request: Codable { var invite: String }
    private struct Reply: Codable { var link: String?; var error: String? }

    private let hub: ServerHub
    private let path: String
    #if os(Windows)
    private var listening: Thread?
    private nonisolated(unsafe) var stopped = false
    #else
    private var source: (any DispatchSourceRead)?
    #endif

    public nonisolated static func socket(in data: URL) -> URL { data.appendingPathComponent("control.sock") }

    public init(hub: ServerHub, data: URL) {
        self.hub = hub
        path = Self.socket(in: data).path
    }

    private func answer(_ request: Request) -> Reply {
        // Someone left out of the file is kept, suspended, and no longer invited.
        guard let user = hub.access.users.first(where: { $0.name == request.invite && !$0.isSuspended }) else {
            return Reply(error: "There is no user called \(request.invite) on \(hub.link.hubName).")
        }
        return Reply(link: hub.link.invite(user).url().absoluteString)
    }

    #if !os(Windows)
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
    #else
    /// One pipe per data folder, named after its socket's path, which a pipe name may not contain as is.
    nonisolated static func pipeName(_ path: String) -> String {
        #"\\.\pipe\noodled-"# + String(path.lowercased().map { "\\/:".contains($0) ? "-" : $0 })
    }

    public func start() throws {
        let name = Self.pipeName(path)
        // A pipe that answers belongs to a server still running.
        if let running = try? Self.connect(name) {
            CloseHandle(running)
            throw ServerControlError("noodled is already running with its data in \(URL(fileURLWithPath: path).deletingLastPathComponent().path).")
        }
        let first = try Self.instance(name, first: true)
        let thread = Thread { [weak self] in
            var next: HANDLE? = first
            while let pipe = next {
                let connected = ConnectNamedPipe(pipe, nil) || GetLastError() == DWORD(ERROR_PIPE_CONNECTED)
                if self?.stopped ?? true { CloseHandle(pipe); return }
                next = try? Self.instance(name, first: false)
                if connected { self?.serve(pipe) } else { CloseHandle(pipe) }
            }
        }
        thread.start()
        listening = thread
    }

    public func stop() {
        stopped = true
        // Wakes the listener waiting for a client, so it sees it should stop.
        if let wake = try? Self.connect(Self.pipeName(path)) { CloseHandle(wake) }
        listening = nil
    }

    private nonisolated func serve(_ pipe: HANDLE) {
        DispatchQueue.global().async { [weak self] in
            let request = Self.readMessage(pipe).flatMap { try? JSONDecoder().decode(Request.self, from: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let reply = request.map { self?.answer($0) ?? Reply(error: "noodled is stopping.") }
                        ?? Reply(error: "noodled did not understand the request.")
                    DispatchQueue.global().async {
                        if let data = try? JSONEncoder().encode(reply) { Self.writeMessage(pipe, data) }
                        FlushFileBuffers(pipe)
                        DisconnectNamedPipe(pipe)
                        CloseHandle(pipe)
                    }
                }
            }
        }
    }

    /// An invitation for `user` from the server running with its data in `data`.
    public nonisolated static func invite(_ user: String, data: URL) throws -> String {
        let pipe: HANDLE
        do { pipe = try connect(pipeName(socket(in: data).path)) } catch {
            throw ServerControlError("noodled is not running with its data in \(data.path).")
        }
        defer { CloseHandle(pipe) }
        guard writeMessage(pipe, try JSONEncoder().encode(Request(invite: user))),
              let data = readMessage(pipe), let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw ServerControlError("noodled did not answer.")
        }
        if let link = reply.link { return link }
        throw ServerControlError(reply.error ?? "noodled did not answer.")
    }

    /// A pipe instance only this account may open, and only on this computer.
    private nonisolated static func instance(_ name: String, first: Bool) throws -> HANDLE {
        var attributes = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                                             lpSecurityDescriptor: noodle_private_security(), bInheritHandle: false)
        let access = DWORD(PIPE_ACCESS_DUPLEX) | (first ? DWORD(FILE_FLAG_FIRST_PIPE_INSTANCE) : 0)
        let mode = DWORD(PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS)
        let pipe = name.withCString(encodedAs: UTF16.self) {
            CreateNamedPipeW($0, access, mode, DWORD(PIPE_UNLIMITED_INSTANCES), 65536, 65536, 0, &attributes)
        }
        guard let pipe, pipe != INVALID_HANDLE_VALUE else {
            throw ServerControlError("noodled could not open its control pipe: error \(GetLastError()).")
        }
        return pipe
    }

    private nonisolated static func connect(_ name: String) throws -> HANDLE {
        for _ in 0..<2 {
            let pipe = name.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, GENERIC_READ | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), 0, nil)
            }
            if let pipe, pipe != INVALID_HANDLE_VALUE {
                var mode = DWORD(PIPE_READMODE_MESSAGE)
                SetNamedPipeHandleState(pipe, &mode, nil, nil)
                return pipe
            }
            guard GetLastError() == DWORD(ERROR_PIPE_BUSY) else { break }
            _ = name.withCString(encodedAs: UTF16.self) { WaitNamedPipeW($0, 2000) }
        }
        throw ServerControlError("error \(GetLastError())")
    }

    @discardableResult private nonisolated static func writeMessage(_ pipe: HANDLE, _ data: Data) -> Bool {
        var written: DWORD = 0
        return data.withUnsafeBytes { WriteFile(pipe, $0.baseAddress, DWORD($0.count), &written, nil) } && written == data.count
    }

    private nonisolated static func readMessage(_ pipe: HANDLE) -> Data? {
        var message = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var read: DWORD = 0
            let done = ReadFile(pipe, &buffer, DWORD(buffer.count), &read, nil)
            message.append(buffer, count: Int(read))
            if done { return message }
            guard GetLastError() == DWORD(ERROR_MORE_DATA), message.count < 1 << 20 else { return nil }
        }
    }
    #endif
}

public struct ServerControlError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
