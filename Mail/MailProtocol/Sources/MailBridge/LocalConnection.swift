import Darwin
import Foundation
import Security

/// The signed socket between Noodle Mail and its clients: Noodle and Noodle's Mail tool extension.
public enum MailConnection {
    public static var providerID: String { MailBuildIdentity.current.providerID }
    public static var clientIDs: [String] { MailBuildIdentity.current.clientIDs }
    public static let maxFrame = 32 * 1_048_576

    /// `m.sock` in the Mail group container, for a bundle whose identity, group and team agree.
    public static func socketURL(bundle: Bundle = .main) throws -> URL {
        guard let identity = MailBuildIdentity.identify(bundle.bundleIdentifier),
              let group = bundle.object(forInfoDictionaryKey: "NoodleMailGroup") as? String else {
            throw MailError("Mail integration is not configured in this signed build.")
        }
        try identity.validateGroup(group, team: signingTeam(bundle: bundle))
        guard identity == MailBuildIdentity.processIdentity else { throw MailError("Mail environment mismatch.") }
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw MailError("The Mail connection container is unavailable.")
        }
        return root.appendingPathComponent("m.sock")
    }
    public static func signingTeam(bundle: Bundle = .main) throws -> String {
        guard let team = bundle.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw MailError("Mail integration requires a team-signed build.")
        }
        return team
    }
    /// Runs `connect` or `bind` on the address, sized to its path rather than to `sockaddr_un`:
    /// a long home folder name outgrows its 104 bytes, and Darwin takes up to 255.
    static func withAddress(_ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) throws -> Int32 {
        let path = Array(url.path.utf8) + [0]
        let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path)!
        guard offset + path.count <= SOCK_MAXADDRLEN else { throw MailError("Mail connection path is too long.") }
        var address = [UInt8](repeating: 0, count: max(offset + path.count, MemoryLayout<sockaddr_un>.size))
        address[0] = UInt8(address.count)
        address[1] = UInt8(AF_UNIX)
        address.replaceSubrange(offset..<offset + path.count, with: path)
        return address.withUnsafeBufferPointer {
            $0.baseAddress!.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(address.count)) }
        }
    }
    static func configure(_ fd: Int32, seconds: Int = 10) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    /// Checks the kernel's audit token for the peer, never a claimed PID or JSON identity.
    static func authenticate(_ fd: Int32, team: String, identifiers: [String]) throws -> String {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else {
            throw MailError("Cannot authenticate the Mail connection.")
        }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let lookup = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data, kSecGuestAttributeDynamicCode: true] as CFDictionary, [], &code)
        guard lookup == errSecSuccess, let code else { throw MailError("Untrusted Mail connection (\(lookup)).") }
        var lastStatus: OSStatus = errSecSuccess
        for id in identifiers {
            guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { continue }
            var requirement: SecRequirement?
            let text = "anchor apple generic and identifier \"\(id)\" and certificate leaf[subject.OU] = \"\(team)\""
            if SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess {
                lastStatus = SecCodeCheckValidity(code, [], requirement)
                if lastStatus == errSecSuccess { return id }
            }
        }
        throw MailError("The peer is not an authorized Noodle application (\(lastStatus)).")
    }
    static func read(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let received = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw MailError("Noodle Mail disconnected or timed out. Reading mail is safe to retry.") }
                offset += received
            }
        }
        return data
    }
    static func receive(_ fd: Int32) throws -> Data {
        let header = try read(fd, count: 4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maxFrame else { throw MailError("Invalid Mail message size.") }
        return try read(fd, count: count)
    }
    static func send(_ data: Data, _ fd: Int32) throws {
        guard !data.isEmpty, data.count <= maxFrame else { throw MailError("The Mail message is too large.") }
        var count = UInt32(data.count).bigEndian
        var packet = withUnsafeBytes(of: &count) { Data($0) }
        packet.append(data)
        try packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw MailError("Mail connection write failed.") }
                offset += written
            }
        }
    }
    public static func call(_ request: MailRequest, socket url: URL, team: String, providerID: String = providerID) async throws -> MailResponse {
        try request.validate()
        return try await Task.detached(priority: .userInitiated) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw MailError("Cannot open the Mail connection.") }
            defer { Darwin.close(fd) }
            configure(fd, seconds: request.operation.timeout)
            guard try withAddress(url, { Darwin.connect(fd, $0, $1) }) == 0 else {
                throw MailError("Noodle Mail is unavailable.", unavailable: true)
            }
            _ = try authenticate(fd, team: team, identifiers: [providerID])
            do { try send(JSONEncoder().encode(request), fd) } catch {
                if let reply = try? JSONDecoder().decode(MailResponse.self, from: receive(fd)), let message = reply.error {
                    throw MailError(message)
                }
                throw error
            }
            return try JSONDecoder().decode(MailResponse.self, from: receive(fd))
        }.value
    }
}

/// Noodle Mail's end of the socket. Four connections are served at once; the rest wait in the backlog.
public final class MailConnectionServer: @unchecked Sendable {
    private let slots = ConnectionSlots(4)
    private let url: URL
    public init(socket url: URL, team: String, clientIDs: [String] = MailConnection.clientIDs,
                handler: @escaping @Sendable (MailRequest, String) async -> MailResponse) throws {
        self.url = url
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw MailError("Unsafe Mail connection path.") }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw MailError("Cannot inspect the Mail connection.") }
            let active = (try? MailConnection.withAddress(url, { Darwin.connect(probe, $0, $1) })) == 0
            Darwin.close(probe)
            guard !active else { throw MailError("Noodle Mail is already running.") }
            guard unlink(url.path) == 0 else { throw MailError("Cannot replace a stale Mail connection.") }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MailError("Cannot create the Mail connection.") }
        MailConnection.configure(fd)
        guard (try? MailConnection.withAddress(url, { Darwin.bind(fd, $0, $1) })) == 0,
              chmod(url.path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw MailError("Cannot register Noodle Mail (\(errno)).")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        let slots = self.slots
        source.setEventHandler {
            // With every slot busy the rest wait in the listen backlog, not dropped unanswered.
            guard slots.take() else { return }
            let peer = Darwin.accept(fd, nil, nil)
            guard peer >= 0 else { slots.signal(); return }
            // Darwin inherits the listener's O_NONBLOCK. Each accepted socket is served on a
            // worker with bounded I/O timeouts, so a slow signature check can't race the payload.
            _ = fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) & ~O_NONBLOCK)
            MailConnection.configure(peer)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let identity = try MailConnection.authenticate(peer, team: team, identifiers: clientIDs)
                    let request = try MailRequest.read(MailConnection.receive(peer))
                    try request.validate()
                    Task {
                        let response = await handler(request, identity)
                        try? MailConnection.send(JSONEncoder().encode(response), peer)
                        Darwin.close(peer)
                        slots.signal()
                    }
                } catch {
                    try? MailConnection.send(JSONEncoder().encode(MailResponse(error: error.localizedDescription)), peer)
                    Darwin.close(peer)
                    slots.signal()
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
            unlink(url.path)
        }
        slots.source = source
        source.resume()
    }
    deinit { slots.cancel() }
}

/// Connections served at once. While none is free the listener stops accepting.
private final class ConnectionSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var free: Int
    private var paused = false
    var source: DispatchSourceRead?
    init(_ count: Int) { free = count }
    func take() -> Bool {
        lock.withLock {
            if free > 0 { free -= 1; return true }
            if !paused { paused = true; source?.suspend() }
            return false
        }
    }
    func signal() {
        lock.withLock {
            free += 1
            if paused { paused = false; source?.resume() }
        }
    }
    func cancel() {
        lock.withLock {
            // Releasing a suspended source traps.
            if paused { paused = false; source?.resume() }
            source?.cancel()
        }
    }
}
