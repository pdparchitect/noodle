import Darwin
import Foundation

/// One live view's connection between a companion and whoever relays it, over a local socket:
/// video goes one way as it is encoded, the viewer's controls come back the other way. Each
/// frame is a four-byte big-endian length and its bytes, as the companions' requests are.
///
/// Sending never waits: frames queue behind a writer of their own, and `pending` says how many
/// have not left yet, so a sender can skip frames for a reader that is behind.
public final class SurfaceSocket: @unchecked Sendable {
    /// What a companion lists among its features when it can show live views this way.
    public static let feature = "live-view-v1"

    public let frames: AsyncStream<Data>
    private let fd: Int32
    private let writer = DispatchQueue(label: "com.pdparchitect.noodle.surface-socket")
    private let lock = NSLock()
    private var queued = 0
    private var held: Bool
    private var closed = false
    private static let maxFrame = 16 << 20

    /// `held` keeps queued frames back until `start(with:)`, so an answer can go first.
    public init(fd: Int32, held: Bool = false) {
        self.fd = fd
        self.held = held
        // A viewer may sit still for as long as it likes; a reader that stops reading
        // entirely ends the view instead of holding the writer forever.
        var forever = timeval(), stuck = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stuck, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        if held { writer.suspend() }
        let (frames, continuation) = AsyncStream.makeStream(of: Data.self)
        self.frames = frames
        Thread.detachNewThread { [self] in
            while let frame = readFrame() { continuation.yield(frame) }
            continuation.finish()
            close()
            writer.async { [self] in Darwin.close(fd) }
        }
    }

    deinit { close() }

    /// Frames queued that have not been written yet.
    public var pending: Int { lock.withLock { queued } }

    public var isClosed: Bool { lock.withLock { closed } }

    public func send(_ frame: Data) {
        guard !frame.isEmpty, frame.count <= Self.maxFrame else { return }
        let accepted = lock.withLock { () -> Bool in
            guard !closed else { return false }
            queued += 1
            return true
        }
        guard accepted else { return }
        writer.async { [self] in
            let written = !isClosed && write(frame)
            lock.withLock { queued -= 1 }
            if !written { close() }
        }
    }

    /// Writes `first` ahead of anything queued, then lets the queue go.
    public func start(with first: Data) {
        let wasHeld = lock.withLock { () -> Bool in
            defer { held = false }
            return held
        }
        if !write(first) { close() }
        if wasHeld { writer.resume() }
    }

    /// Ends the view both ways. The reader finishes `frames`, and the socket closes once the
    /// writer has let go of it.
    public func close() {
        let resume = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            shutdown(fd, SHUT_RDWR)
            defer { held = false }
            return held
        }
        if resume { writer.resume() }
    }

    private func write(_ frame: Data) -> Bool {
        var length = UInt32(frame.count).bigEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(frame)
        return packet.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private func readFrame() -> Data? {
        guard let header = read(4) else { return nil }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= Self.maxFrame else { return nil }
        return read(length)
    }

    private func read(_ count: Int) -> Data? {
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < count {
                let received = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { return false }
                offset += received
            }
            return true
        }
        return complete ? data : nil
    }
}
