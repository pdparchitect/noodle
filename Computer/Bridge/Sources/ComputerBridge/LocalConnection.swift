import Darwin
import Foundation
import Security

public enum ComputerConnection {
    public static let providerID = "com.pdparchitect.noodle.computer"
    public static let clientIDs = ["com.pdparchitect.noodle", "com.pdparchitect.noodle.local"]
    public static let maxFrame = 4 * 1_048_576

    public static func socketURL(bundle: Bundle = .main) throws -> URL {
        guard let group = bundle.object(forInfoDictionaryKey: "NoodleComputerGroup") as? String,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ComputerBridgeError("Computer integration is not configured in this signed build.")
        }
        return root.appendingPathComponent("c.sock")
    }
    public static func signingTeam(bundle: Bundle = .main) throws -> String {
        guard let team = bundle.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw ComputerBridgeError("Computer integration requires a team-signed build.")
        }
        return team
    }
    static func address(_ url: URL) throws -> sockaddr_un {
        let path = Array(url.path.utf8) + [0]
        var address = sockaddr_un()
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ComputerBridgeError("Computer connection path is too long.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        return address
    }
    static func withAddress<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        } }
    }
    static func configure(_ fd: Int32, seconds: Int = 10) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    /// Authenticate the kernel's peer audit token, not a claimed PID or JSON identity.
    static func authenticate(_ fd: Int32, team: String, identifiers: [String]) throws -> String {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else {
            throw ComputerBridgeError("Cannot authenticate the computer connection.")
        }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let lookup = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data,
            kSecGuestAttributeDynamicCode: true] as CFDictionary, [], &code)
        guard lookup == errSecSuccess,
              let code else { throw ComputerBridgeError("Untrusted computer connection (\(lookup)).") }
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
        throw ComputerBridgeError("The peer is not an authorized Noodle application (\(lastStatus)).")
    }
    static func read(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let received = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw ComputerBridgeError("Computer disconnected or timed out. Check its state before retrying.") }
                offset += received
            }
        }
        return data
    }
    static func receive(_ fd: Int32) throws -> Data {
        let header = try read(fd, count: 4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maxFrame else { throw ComputerBridgeError("Invalid computer message size.") }
        return try read(fd, count: count)
    }
    static func send(_ data: Data, _ fd: Int32) throws {
        guard !data.isEmpty, data.count <= maxFrame else { throw ComputerBridgeError("Computer response is too large.") }
        var count = UInt32(data.count).bigEndian
        var packet = withUnsafeBytes(of: &count) { Data($0) }
        packet.append(data)
        try packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ComputerBridgeError("Computer connection write failed.") }
                offset += written
            }
        }
    }
    public static func call(_ request: ComputerRequest, socket url: URL, team: String,
                            providerID: String = providerID) async throws -> ComputerResponse {
        try request.validate()
        return try await Task.detached(priority: .userInitiated) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ComputerBridgeError("Cannot open computer connection.") }
            defer { Darwin.close(fd) }
            configure(fd, seconds: request.operation.isFileTransfer ? request.operation.timeout : (request.operation == .start ? 180 : 30))
            var address = try address(url)
            guard withAddress(&address, { Darwin.connect(fd, $0, $1) }) == 0 else {
                throw ComputerBridgeError("Computer is unavailable.", unavailable: true)
            }
            _ = try authenticate(fd, team: team, identifiers: [providerID])
            do { try send(JSONEncoder().encode(request), fd) }
            catch {
                if let reply = try? JSONDecoder().decode(ComputerResponse.self, from: receive(fd)), let message = reply.error {
                    throw ComputerBridgeError(message)
                }
                throw error
            }
            return try JSONDecoder().decode(ComputerResponse.self, from: receive(fd)).checked()
        }.value
    }
}

public final class ComputerConnectionServer: @unchecked Sendable {
    private var source: DispatchSourceRead?
    private let permits = DispatchSemaphore(value: 16)
    private let url: URL
    public init(socket url: URL, team: String, clientIDs: [String] = ComputerConnection.clientIDs,
                handler: @escaping @Sendable (ComputerRequest, String) async -> ComputerResponse) throws {
        self.url = url
        var address = try ComputerConnection.address(url)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
                throw ComputerBridgeError("Unsafe computer connection path.")
            }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw ComputerBridgeError("Cannot inspect computer connection.") }
            let active = ComputerConnection.withAddress(&address, { Darwin.connect(probe, $0, $1) }) == 0
            Darwin.close(probe)
            guard !active else { throw ComputerBridgeError("A computer provider is already running.") }
            guard unlink(url.path) == 0 else { throw ComputerBridgeError("Cannot replace stale computer connection.") }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ComputerBridgeError("Cannot create computer connection.") }
        ComputerConnection.configure(fd)
        guard ComputerConnection.withAddress(&address, { Darwin.bind(fd, $0, $1) }) == 0,
              chmod(url.path, 0o600) == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw ComputerBridgeError("Cannot register the computer provider (\(errno)).")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        let permits = self.permits
        source.setEventHandler {
            let peer = Darwin.accept(fd, nil, nil)
            guard peer >= 0 else { return }
            guard permits.wait(timeout: .now()) == .success else { Darwin.close(peer); return }
            // Darwin inherits the listener's O_NONBLOCK. Each accepted socket is
            // serviced on a worker with bounded I/O timeouts, not the read source.
            // Without this, a slower signature check can race the first payload.
            _ = fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) & ~O_NONBLOCK)
            ComputerConnection.configure(peer)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let identity = try ComputerConnection.authenticate(peer, team: team, identifiers: clientIDs)
                    let request = try JSONDecoder().decode(ComputerRequest.self, from: ComputerConnection.receive(peer))
                    try request.validate()
                    Task {
                        let response = await handler(request, identity)
                        try? ComputerConnection.send(JSONEncoder().encode(response), peer)
                        Darwin.close(peer); permits.signal()
                    }
                } catch {
                    try? ComputerConnection.send(JSONEncoder().encode(ComputerResponse(error: error.localizedDescription)), peer)
                    Darwin.close(peer); permits.signal()
                }
            }
        }
        source.setCancelHandler { Darwin.close(fd); unlink(url.path) }
        self.source = source
        source.resume()
    }
    deinit { source?.cancel() }
}
