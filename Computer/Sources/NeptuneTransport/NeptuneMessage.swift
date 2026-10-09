import Darwin
import Foundation

public struct NeptuneFence: Codable, Equatable {
    public var context: UInt32
    public var ring: UInt32?
    public var value: UInt64
    public init(context: UInt32, ring: UInt32?, value: UInt64) {
        self.context = context; self.ring = ring; self.value = value
    }
}

public struct NeptuneMessage: Codable, Equatable {
    public var operation: Int32
    public var values: [UInt64]
    public var fences: [NeptuneFence]
    public init(_ operation: Int32, _ values: [UInt64] = [], fences: [NeptuneFence] = []) {
        self.operation = operation; self.values = values; self.fences = fences
    }
}

public enum NeptuneOperation: Int32 {
    case start, poll, capset, caps, contextCreate, contextDestroy, contextAttach, contextDetach
    case resourceCreate, createBlob, createBlobAt, unref, attach, detach, map, transferWrite, transferRead
    case submit, fence, contextFence, reset
}

/// Length-delimited metadata and bytes: large transfer buffers never pass through JSON/base64.
public enum NeptuneWire {
    public static let maximumPayload = 256 * 1024 * 1024
    public enum Failure: Error { case malformed, closed, timedOut }
    public static func encode(_ message: NeptuneMessage, payload: Data = Data()) throws -> Data {
        let header = try JSONEncoder().encode(message)
        guard header.count <= 65_536, payload.count <= maximumPayload else { throw Failure.malformed }
        var bytes = Data()
        for length in [header.count, payload.count] {
            var value = UInt32(length).littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        bytes.append(header); bytes.append(payload)
        return bytes
    }
    private static func lengths(_ prefix: Data) throws -> (Int, Int) {
        guard prefix.count == 8 else { throw Failure.malformed }
        let header = Int(prefix.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        let payload = Int(prefix.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) })
        guard header <= 65_536, payload <= maximumPayload else { throw Failure.malformed }
        return (header, payload)
    }
    public static func decode(_ packet: Data) throws -> (NeptuneMessage, Data) {
        let (header, payload) = try lengths(Data(packet.prefix(8)))
        guard packet.count == 8 + header + payload else { throw Failure.malformed }
        return (try JSONDecoder().decode(NeptuneMessage.self, from: packet.subdata(in: 8..<8 + header)), packet.subdata(in: 8 + header..<packet.count))
    }
    public static func read(from handle: FileHandle, timeout: Int32 = 30_000) throws -> (NeptuneMessage, Data) {
        func exact(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, timeout)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { throw ready == 0 ? Failure.timedOut : Failure.closed }
                guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else { throw Failure.closed }
                result.append(chunk)
            }
            return result
        }
        let prefix = try exact(8)
        let (header, payload) = try lengths(prefix)
        return try decode(prefix + exact(header + payload))
    }
    public static func write(_ message: NeptuneMessage, payload: Data = Data(), to handle: FileHandle) throws {
        // A crashed helper is an I/O error, never SIGPIPE in the app process.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        try handle.write(contentsOf: encode(message, payload: payload))
    }
}
