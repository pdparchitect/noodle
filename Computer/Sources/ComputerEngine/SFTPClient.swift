import ComputerCore
import Foundation
import NIOCore
import NIOSSH

/// SFTP version 3, as OpenSSH and most servers speak it: only what Files and transfers need.
final class SFTPClient: @unchecked Sendable {
    struct Attributes: Equatable, Sendable {
        var size: UInt64?
        var permissions: UInt32?
        var modified: UInt32?
        var kind: String {
            switch (permissions ?? 0) & 0o170000 {
            case 0o040000: "directory"
            case 0o100000: "file"
            case 0o120000: "symlink"
            default: permissions == nil ? "file" : "other"
            }
        }
        /// Changes when the file does, as far as SFTP can tell.
        var version: String { "\(size ?? 0):\(modified ?? 0)" }
    }

    struct Failure: LocalizedError {
        let code: UInt32
        let message: String
        var errorDescription: String? {
            switch code {
            case 2: "No such file or folder."
            case 3: "Permission denied."
            default: message.isEmpty ? "The server could not do that (\(code))." : message
            }
        }
    }

    private enum Packet: UInt8 {
        case open = 3, close = 4, read = 5, write = 6, lstat = 7, fstat = 8, opendir = 11, readdir = 12, remove = 13,
             mkdir = 14, rmdir = 15, realpath = 16, stat = 17, rename = 18
    }
    static let chunk = 32 * 1024

    private let channel: Channel
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<(UInt8, SSHWireReader), Error>] = [:]
    private var version: CheckedContinuation<Void, Error>?
    private var closedError: Error?

    private init(channel: Channel) { self.channel = channel }

    static func open(on connection: SSHConnection) async throws -> SFTPClient {
        let framer = SFTPFramer()
        let channel = try await connection.openSession { framer }
        let client = SFTPClient(channel: channel)
        framer.client = client
        do {
            try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)).get()
        } catch {
            try? await channel.close()
            throw ComputerError("The server does not offer SFTP, which Files needs.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.lock.withLock { client.version = continuation }
            var body = Data([1]); body.append(uint32: 3)
            client.send(body)
        }
        return client
    }

    var isOpen: Bool { lock.withLock { closedError == nil } && channel.isActive }
    func close() { channel.close(promise: nil) }

    private func send(_ body: Data) {
        var packet = Data(); packet.append(uint32: UInt32(body.count)); packet.append(body)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: packet))), promise: nil)
    }

    private func request(_ type: Packet, _ build: (inout Data) -> Void) async throws -> (UInt8, SSHWireReader) {
        try await withCheckedThrowingContinuation { continuation in
            let id: UInt32? = lock.withLock {
                if closedError != nil { return nil }
                let id = nextID; nextID &+= 1
                pending[id] = continuation
                return id
            }
            guard let id else { continuation.resume(throwing: ComputerError("The file connection closed.")); return }
            var body = Data([type.rawValue]); body.append(uint32: id)
            build(&body)
            send(body)
        }
    }

    fileprivate func receive(_ packet: Data) {
        var reader = SSHWireReader(packet)
        guard let type = try? reader.byte() else { return }
        if type == 2 {
            let continuation = lock.withLock { defer { version = nil }; return version }
            continuation?.resume()
            return
        }
        guard let id = try? reader.uint32() else { return }
        let continuation = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(returning: (type, reader))
    }

    fileprivate func ended(_ error: Error) {
        let (waiting, starting) = lock.withLock {
            closedError = error
            defer { pending.removeAll(); version = nil }
            return (Array(pending.values), version)
        }
        for continuation in waiting { continuation.resume(throwing: error) }
        starting?.resume(throwing: error)
    }

    /// Succeeds on an OK status; anything else is the server's failure.
    private func status(_ reply: (UInt8, SSHWireReader)) throws {
        var (type, reader) = reply
        guard type == 101 else { throw ComputerError("The server sent an unexpected reply.") }
        let code = try reader.uint32()
        guard code == 0 else { throw Failure(code: code, message: String(decoding: (try? reader.string()) ?? Data(), as: UTF8.self)) }
    }

    private static func attributes(_ reader: inout SSHWireReader) throws -> Attributes {
        var result = Attributes()
        let flags = try reader.uint32()
        if flags & 0x1 != 0 { result.size = try reader.uint64() }
        if flags & 0x2 != 0 { _ = try reader.uint32(); _ = try reader.uint32() }
        if flags & 0x4 != 0 { result.permissions = try reader.uint32() }
        if flags & 0x8 != 0 { _ = try reader.uint32(); result.modified = try reader.uint32() }
        if flags & 0x8000_0000 != 0 {
            for _ in 0..<(try reader.uint32()) { _ = try reader.string(); _ = try reader.string() }
        }
        return result
    }

    private func handle(_ reply: (UInt8, SSHWireReader)) throws -> Data {
        var (type, reader) = reply
        if type == 102 { return try reader.string() }
        try status(reply)
        throw ComputerError("The server sent an unexpected reply.")
    }

    private func attributes(_ reply: (UInt8, SSHWireReader)) throws -> Attributes {
        var (type, reader) = reply
        if type == 105 { return try Self.attributes(&reader) }
        try status(reply)
        throw ComputerError("The server sent an unexpected reply.")
    }

    func realpath(_ path: String) async throws -> String {
        var (type, reader) = try await request(.realpath) { $0.append(string: path) }
        guard type == 104 else { try status((type, reader)); throw ComputerError("The server sent an unexpected reply.") }
        guard try reader.uint32() >= 1 else { throw ComputerError("The server did not resolve \(path).") }
        return String(decoding: try reader.string(), as: UTF8.self)
    }

    func lstat(_ path: String) async throws -> Attributes { try attributes(await request(.lstat) { $0.append(string: path) }) }
    func stat(_ path: String) async throws -> Attributes { try attributes(await request(.stat) { $0.append(string: path) }) }
    func fstat(_ handle: Data) async throws -> Attributes { try attributes(await request(.fstat) { $0.append(string: handle) }) }

    /// Every entry but `.` and `..`, with the attributes the server gives without following links.
    func list(_ path: String, limit: Int) async throws -> [(name: Data, attributes: Attributes)] {
        let handle = try handle(await request(.opendir) { $0.append(string: path) })
        defer { Task { try? await self.closeHandle(handle) } }
        var entries: [(Data, Attributes)] = []
        while true {
            var (type, reader) = try await request(.readdir) { $0.append(string: handle) }
            if type == 101 {
                var status = reader
                if try status.uint32() == 1 { break }
                try self.status((type, reader))
            }
            guard type == 104 else { throw ComputerError("The server sent an unexpected reply.") }
            for _ in 0..<(try reader.uint32()) {
                let name = try reader.string()
                _ = try reader.string()
                let attributes = try Self.attributes(&reader)
                if name == Data(".".utf8) || name == Data("..".utf8) { continue }
                entries.append((name, attributes))
                guard entries.count <= limit else { throw ComputerError("This folder has more than \(limit) items.") }
            }
        }
        return entries
    }

    struct OpenFlags: OptionSet {
        let rawValue: UInt32
        static let read = OpenFlags(rawValue: 0x1), write = OpenFlags(rawValue: 0x2), create = OpenFlags(rawValue: 0x8),
                   exclusive = OpenFlags(rawValue: 0x20)
    }

    func openFile(_ path: String, _ flags: OpenFlags, permissions: UInt32? = nil) async throws -> Data {
        try handle(await request(.open) {
            $0.append(string: path); $0.append(uint32: flags.rawValue)
            if let permissions { $0.append(uint32: 0x4); $0.append(uint32: permissions) } else { $0.append(uint32: 0) }
        })
    }

    func closeHandle(_ handle: Data) async throws { try status(await request(.close) { $0.append(string: handle) }) }

    /// Nil at the end of the file.
    func read(_ handle: Data, offset: UInt64, length: Int) async throws -> Data? {
        var (type, reader) = try await request(.read) { $0.append(string: handle); $0.append(uint64: offset); $0.append(uint32: UInt32(length)) }
        if type == 103 { return try reader.string() }
        var status = reader
        if type == 101, try status.uint32() == 1 { return nil }
        try self.status((type, reader))
        throw ComputerError("The server sent an unexpected reply.")
    }

    func write(_ handle: Data, offset: UInt64, data: Data) async throws {
        try status(await request(.write) { $0.append(string: handle); $0.append(uint64: offset); $0.append(string: data) })
    }

    func mkdir(_ path: String) async throws {
        try status(await request(.mkdir) { $0.append(string: path); $0.append(uint32: 0x4); $0.append(uint32: 0o755) })
    }
    func rmdir(_ path: String) async throws { try status(await request(.rmdir) { $0.append(string: path) }) }
    func remove(_ path: String) async throws { try status(await request(.remove) { $0.append(string: path) }) }
    /// SFTP 3 renames never replace an existing item.
    func rename(_ old: String, to new: String) async throws {
        try status(await request(.rename) { $0.append(string: old); $0.append(string: new) })
    }

    /// Reads the whole file in order, keeping several requests in flight.
    func download(_ handle: Data, size: UInt64, into output: (Data) throws -> Void) async throws {
        var offset: UInt64 = 0, requested: UInt64 = 0
        var inFlight: [Task<Data?, Error>] = []
        defer { for task in inFlight { task.cancel() } }
        while offset < size || !inFlight.isEmpty {
            while inFlight.count < 16, requested < size {
                let at = requested, length = Int(min(UInt64(Self.chunk), size - requested))
                inFlight.append(Task { try await self.read(handle, offset: at, length: length) })
                requested += UInt64(length)
            }
            guard !inFlight.isEmpty else { break }
            let data = try await inFlight.removeFirst().value
            guard let data, !data.isEmpty else { throw ComputerError("The file changed or the transfer was incomplete.") }
            // A short read moves the next request back to where this one stopped.
            if requested > offset + UInt64(data.count), data.count < Self.chunk, offset + UInt64(data.count) < size {
                for task in inFlight { task.cancel() }
                inFlight.removeAll()
                requested = offset + UInt64(data.count)
            }
            try output(data)
            offset += UInt64(data.count)
            try Task.checkCancellation()
        }
    }

    /// Writes chunks in order, keeping several requests in flight.
    func upload<S: AsyncSequence>(_ handle: Data, from chunks: S) async throws -> UInt64 where S.Element == Data {
        var offset: UInt64 = 0
        var inFlight: [Task<Void, Error>] = []
        defer { for task in inFlight { task.cancel() } }
        for try await data in chunks {
            var start = data.startIndex
            while start < data.endIndex {
                let end = min(start + Self.chunk, data.endIndex)
                let piece = Data(data[start..<end]), at = offset
                inFlight.append(Task { try await self.write(handle, offset: at, data: piece) })
                offset += UInt64(piece.count)
                start = end
                if inFlight.count >= 16 { try await inFlight.removeFirst().value }
            }
            try Task.checkCancellation()
        }
        for task in inFlight { try await task.value }
        inFlight.removeAll()
        return offset
    }
}

/// Splits the channel's bytes into SFTP packets.
private final class SFTPFramer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    weak var client: SFTPClient?
    private var buffer = Data()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard message.type == .channel, case .byteBuffer(var bytes) = message.data,
              let read = bytes.readBytes(length: bytes.readableBytes) else { return }
        buffer.append(contentsOf: read)
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length <= 4 * 1024 * 1024 else {
                client?.ended(ComputerError("The server sent a damaged reply.")); context.close(promise: nil); return
            }
            guard buffer.count >= 4 + length else { break }
            let packet = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))
            client?.receive(packet)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        client?.ended(ComputerError("The file connection closed."))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        client?.ended(ComputerError(SSHConnection.describe(error)))
        context.close(promise: nil)
    }
}

extension Data {
    mutating func append(uint32 value: UInt32) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
    mutating func append(uint64 value: UInt64) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
    mutating func append(string value: Data) { append(uint32: UInt32(value.count)); append(value) }
    mutating func append(string value: String) { append(string: Data(value.utf8)) }
}
