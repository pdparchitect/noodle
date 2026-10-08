import Darwin
import Foundation
import Security

/// What the command-line tool sends: the app's own request, and who is asking.
public struct ExternalEnvelope<Request: Codable & Sendable>: Codable, Sendable {
    public var launcher: ExternalLauncher
    public var request: Request
    public init(launcher: ExternalLauncher, request: Request) { self.launcher = launcher; self.request = request }
}

/// The external connection: a socket in an app group that only the app and its command-line
/// tool hold. Noodle and Noodle Hub are not in that group, so nothing running in their sandbox
/// can reach it. Each side checks the other's code signature on every connection.
public enum ExternalConnection {
    public static let maxFrame = 32 * 1_048_576
    /// The answer a refused or broken call gets, readable as either app's response.
    public static func failure(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["version": 1, "error": message])) ?? Data()
    }

    /// Accepts the peer only if the kernel's audit token belongs to `identifier`, signed by `team`.
    public static func requireSigned(_ fd: Int32, identifier: String, team: String) throws {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else {
            throw ExternalToolsError("Cannot check who is connecting.")
        }
        guard identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw ExternalToolsError("Invalid signing requirement.")
        }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?, requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw ExternalToolsError("The other side of the connection is not the signed app it should be.")
        }
    }

    /// Sends one request and waits for its answer, checking the listener with `verify`.
    public static func call(_ data: Data, socket url: URL, seconds: Int, verify: (Int32) throws -> Void) throws -> Data {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ExternalToolsError("Cannot open a connection.") }
        defer { Darwin.close(fd) }
        configure(fd, seconds: seconds)
        guard try withAddress(url, { Darwin.connect(fd, $0, $1) }) == 0 else {
            throw ExternalToolsError("The app is not accepting external tools.")
        }
        try verify(fd)
        try send(data, fd)
        return try receive(fd)
    }

    static func configure(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// Sized to the path rather than to `sockaddr_un`: a long home folder name outgrows its 104
    /// bytes, and Darwin takes up to 255.
    static func withAddress(_ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) throws -> Int32 {
        let path = Array(url.path.utf8) + [0]
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
        guard offset + path.count <= SOCK_MAXADDRLEN else { throw ExternalToolsError("The connection path is too long.") }
        var address = [UInt8](repeating: 0, count: max(offset + path.count, MemoryLayout<sockaddr_un>.size))
        address[0] = UInt8(address.count)
        address[1] = UInt8(AF_UNIX)
        address.replaceSubrange(offset..<offset + path.count, with: path)
        return address.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(address.count)) }
        }
    }

    static func read(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let received = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw ExternalToolsError("The connection closed or timed out.") }
                offset += received
            }
        }
        return data
    }

    static func receive(_ fd: Int32) throws -> Data {
        let count = try read(fd, count: 4).reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maxFrame else { throw ExternalToolsError("Invalid message size.") }
        return try read(fd, count: count)
    }

    static func send(_ data: Data, _ fd: Int32) throws {
        guard !data.isEmpty, data.count <= maxFrame else { throw ExternalToolsError("The message is too large.") }
        var count = UInt32(data.count).bigEndian
        var packet = withUnsafeBytes(of: &count) { Data($0) }
        packet.append(data)
        try packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ExternalToolsError("The connection closed.") }
                offset += written
            }
        }
    }
}

/// Listens on the external socket. Each connection carries one request; a peer `verify` refuses
/// gets a failure without reaching `handler`.
public final class ExternalConnectionServer: @unchecked Sendable {
    private var source: DispatchSourceRead?

    public init(socket url: URL, limit: Int = 32, verify: @escaping @Sendable (Int32) throws -> Void,
                handler: @escaping @Sendable (Data) async -> Data) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw ExternalToolsError("Unsafe connection path.") }
            let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw ExternalToolsError("Cannot inspect the connection.") }
            let active = (try? ExternalConnection.withAddress(url, { Darwin.connect(probe, $0, $1) })) == 0
            Darwin.close(probe)
            guard !active else { throw ExternalToolsError("Another copy of the app is already listening.") }
            guard unlink(url.path) == 0 else { throw ExternalToolsError("Cannot replace a stale connection.") }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ExternalToolsError("Cannot create the connection.") }
        ExternalConnection.configure(fd, seconds: 10)
        guard (try? ExternalConnection.withAddress(url, { Darwin.bind(fd, $0, $1) })) == 0,
              chmod(url.path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw ExternalToolsError("Cannot listen for external tools (\(errno)).")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let permits = DispatchSemaphore(value: limit)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            let peer = Darwin.accept(fd, nil, nil)
            guard peer >= 0 else { return }
            _ = fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) & ~O_NONBLOCK)
            // Calls waiting on the person hold their connections; one more is told why, not dropped.
            guard permits.wait(timeout: .now()) == .success else {
                ExternalConnection.configure(peer, seconds: 2)
                try? ExternalConnection.send(ExternalConnection.failure("The app is busy with other calls. Try again shortly."), peer)
                Darwin.close(peer)
                return
            }
            // Reading the request has a short limit; the answer may wait on a person.
            ExternalConnection.configure(peer, seconds: 10)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try verify(peer)
                    let request = try ExternalConnection.receive(peer)
                    ExternalConnection.configure(peer, seconds: 30)
                    Task {
                        let answer = await handler(request)
                        try? ExternalConnection.send(answer, peer)
                        Darwin.close(peer)
                        permits.signal()
                    }
                } catch {
                    try? ExternalConnection.send(ExternalConnection.failure(error.localizedDescription), peer)
                    Darwin.close(peer)
                    permits.signal()
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd); unlink(url.path) }
        self.source = source
        source.resume()
    }

    deinit { source?.cancel() }
}
