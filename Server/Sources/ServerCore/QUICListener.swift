#if os(Linux)
import CNoodleQUIC
import Foundation
import HubWire

/// The Hub's link on Linux, over msquic: it admits only the keys `admits` lets in, refused during the
/// handshake and again on every stream, and hands each request to `handler` with the sender's key.
/// It serves devices exactly as Noodle Hub's listener on a Mac does.
public final class QUICListener: LinkListening, @unchecked Sendable {
    /// Listens with the link's certificate and key written to `folder`, readable only by the server.
    public static func listen(certificates folder: URL) -> LinkListen {
        { identity, port, admits, handler in
            try QUICListener(identity: identity, port: port, folder: folder, admits: admits, handler: handler)
        }
    }

    private let identityFiles: (certificate: URL, key: URL)
    private let requestedPort: UInt16
    private let admits: @Sendable (LinkPublicKey) -> Bool
    private let handler: @Sendable (LinkPublicKey, Data) async -> LinkReply
    private let lock = NSLock()
    private var listener: OpaquePointer?
    private var keys: [OpaquePointer: LinkPublicKey] = [:]
    private var incoming: [OpaquePointer: Incoming] = [:]

    init(identity: LinkIdentity, port: UInt16, folder: URL, admits: @escaping @Sendable (LinkPublicKey) -> Bool,
         handler: @escaping @Sendable (LinkPublicKey, Data) async -> LinkReply) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let pem = try LinkCertificate.pem(for: identity)
        identityFiles = (folder.appendingPathComponent("link-certificate.pem"), folder.appendingPathComponent("link-key.pem"))
        try Data(pem.certificate.utf8).write(to: identityFiles.certificate, options: .atomic)
        FileManager.default.createFile(atPath: identityFiles.key.path, contents: Data(pem.key.utf8), attributes: [.posixPermissions: 0o600])
        requestedPort = port
        self.admits = admits
        self.handler = handler
    }

    public func start() async throws {
        var callbacks = nq_callbacks()
        callbacks.context = Unmanaged.passUnretained(self).toOpaque()
        callbacks.admit = { context, connection, bytes, length in
            QUICListener.from(context).admit(connection!, Array(UnsafeBufferPointer(start: bytes, count: length))) ? 1 : 0
        }
        callbacks.stream_opened = { context, connection, stream in QUICListener.from(context).opened(stream!, on: connection!) }
        callbacks.received = { context, stream, bytes, length in
            QUICListener.from(context).received(Data(UnsafeBufferPointer(start: bytes, count: length)), on: stream!)
        }
        callbacks.peer_finished = { context, stream in QUICListener.from(context).peerFinished(stream!) }
        callbacks.sent = { context, stream, length in QUICListener.from(context).sent(length, on: stream!) }
        callbacks.stream_closed = { context, stream in QUICListener.from(context).closed(stream!) }
        callbacks.connection_closed = { context, connection in QUICListener.from(context).forget(connection!) }
        var error = [CChar](repeating: 0, count: 256)
        guard let opened = nq_listen(identityFiles.certificate.path, identityFiles.key.path, requestedPort,
                                     UInt16(LinkLimits.idleTimeout), callbacks, &error, error.count) else {
            throw LinkError(String(cString: error))
        }
        lock.withLock { listener = opened }
    }

    public var port: UInt16? { lock.withLock { listener.map { nq_listener_port($0) } } }

    public func stop() {
        guard let listener = lock.withLock({ () -> OpaquePointer? in defer { self.listener = nil }; return self.listener }) else { return }
        // Waits for every connection to close, so no callback comes after.
        nq_listener_close(listener)
    }

    /// Ends the open streams of keys `admits` no longer lets in, such as a removed device's.
    public func disconnectRefused() {
        let open = lock.withLock { incoming.values.compactMap(\.pushed) }
        for stream in open where !admits(stream.peer) { stream.close() }
    }

    private static func from(_ context: UnsafeMutableRawPointer?) -> QUICListener {
        Unmanaged<QUICListener>.fromOpaque(context!).takeUnretainedValue()
    }

    // MARK: Events, on msquic's threads

    private func admit(_ connection: OpaquePointer, _ certificate: [UInt8]) -> Bool {
        guard let key = LinkCertificate.key(of: certificate), admits(key) else { return false }
        lock.withLock { keys[connection] = key }
        return true
    }

    private func opened(_ stream: OpaquePointer, on connection: OpaquePointer) {
        // A connection outlives the handshake that let it in, so each stream is checked again: a
        // removed device or a used invitation reaches nothing on the connection it already has.
        guard let key = lock.withLock({ keys[connection] }), admits(key) else {
            nq_stream_reset(stream, 1)
            lock.withLock { incoming[stream] = Incoming(stream: stream, key: nil) }
            return
        }
        lock.withLock { incoming[stream] = Incoming(stream: stream, key: key) }
    }

    private func received(_ bytes: Data, on stream: OpaquePointer) {
        guard let entry = lock.withLock({ incoming[stream] }), let key = entry.key else { return }
        guard let request = entry.read(bytes) else { return }
        switch request {
        case .tooLarge: nq_stream_reset(stream, 1)
        case .channel(let request, let rest): answer(request, from: key, on: entry, channel: true, rest: rest)
        }
    }

    private func peerFinished(_ stream: OpaquePointer) {
        guard let entry = lock.withLock({ incoming[stream] }), let key = entry.key else { return }
        // A stream that ends without a byte carries no request.
        guard let request = entry.whole() else { return }
        guard !request.isEmpty else { return nq_stream_reset(stream, 0) }
        answer(request, from: key, on: entry, channel: false, rest: Data())
    }

    private func sent(_ length: Int, on stream: OpaquePointer) {
        lock.withLock { incoming[stream] }?.pushed?.left(length)
    }

    private func closed(_ stream: OpaquePointer) {
        let entry = lock.withLock { incoming.removeValue(forKey: stream) }
        entry?.pushed?.finish()
    }

    private func forget(_ connection: OpaquePointer) {
        _ = lock.withLock { keys.removeValue(forKey: connection) }
    }

    private func answer(_ request: Data, from key: LinkPublicKey, on entry: Incoming, channel: Bool, rest: Data) {
        Task { [handler] in
            switch await handler(key, request) {
            case .response(let response):
                _ = response.withUnsafeBytes { nq_stream_send(entry.stream, $0.baseAddress, $0.count, 1) }
                // A device that never ends its side has the stream reset once it has had time to read.
                entry.resetAfterGrace()
            case .stream(let open):
                let pushed = QUICServerStream(peer: key, stream: entry.stream)
                open(pushed)
                entry.push(pushed, rest: rest)
            }
        }
    }
}

/// One stream a device opened, until its request is read and answered.
private final class Incoming: @unchecked Sendable {
    enum Request { case tooLarge, channel(Data, rest: Data) }

    let stream: OpaquePointer
    /// Nil for a stream from a key no longer let in, which is being reset.
    let key: LinkPublicKey?
    private let lock = NSLock()
    private var buffer = Data()
    private var answered = false
    private(set) var pushed: QUICServerStream? {
        get { lock.withLock { _pushed } }
        set { lock.withLock { _pushed = newValue } }
    }
    private var _pushed: QUICServerStream?

    /// What came after the request while it was being answered, for the stream it opens.
    private var after = Data()
    private var peerEnded = false

    /// Takes over the reference `stream_opened` gave.
    init(stream: OpaquePointer, key: LinkPublicKey?) {
        self.stream = stream
        self.key = key
    }

    deinit { nq_stream_release(stream) }

    /// Takes bytes of the request. A channel's request is one frame, starting with a zero byte; once
    /// it is whole, it comes back with whatever followed it. Bytes after that go to the stream it opens.
    func read(_ bytes: Data) -> Request? {
        let pushed = lock.withLock { () -> QUICServerStream? in
            if _pushed == nil, answered { after.append(bytes) }
            return _pushed
        }
        if let pushed { pushed.received(bytes); return nil }
        return lock.withLock {
            guard !answered else { return nil }
            buffer.append(bytes)
            guard buffer.first == 0 else { return buffer.count > LinkLimits.request ? .tooLarge : nil }
            guard buffer.count >= 4 else { return nil }
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= LinkLimits.request else { return .tooLarge }
            guard buffer.count >= 4 + length else { return nil }
            answered = true
            let start = buffer.startIndex
            return .channel(Data(buffer[(start + 4)..<(start + 4 + length)]), rest: Data(buffer[(start + 4 + length)...]))
        }
    }

    /// The whole request, once the device finished sending it. Nil once answered: the device ending
    /// its side of a channel ends the stream the channel opened.
    func whole() -> Data? {
        let (request, pushed) = lock.withLock { () -> (Data?, QUICServerStream?) in
            guard !answered else {
                peerEnded = true
                return (nil, _pushed)
            }
            answered = true
            return (buffer, nil)
        }
        pushed?.close()
        return request
    }

    func push(_ stream: QUICServerStream, rest: Data) {
        let (waiting, ended) = lock.withLock { () -> (Data, Bool) in
            _pushed = stream
            defer { after = Data() }
            return (rest + after, peerEnded)
        }
        stream.received(waiting)
        if ended { stream.close() }
    }

    func resetAfterGrace() {
        DispatchQueue.global().asyncAfter(deadline: .now() + LinkLimits.closeGrace) { [self] in nq_stream_reset(stream, 0) }
    }
}

/// An open stream the Hub pushes frames down, and for a channel reads the device's frames from.
final class QUICServerStream: LinkServerStream, @unchecked Sendable {
    let peer: LinkPublicKey
    private let stream: OpaquePointer
    private let lock = NSLock()
    private var closed = false
    private var unsent = 0
    private var closeHandlers: [@Sendable () -> Void] = []
    private var frameHandler: (@Sendable (Data) -> Void)?
    /// Frames a channel's device sent before anyone listened, and the bytes of one not whole yet.
    private var waiting: [Data] = []
    private var partial = Data()
    private var timer: DispatchSourceTimer?

    init(peer: LinkPublicKey, stream: OpaquePointer) {
        self.peer = peer
        self.stream = stream
        nq_stream_retain(stream)
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + LinkLimits.keepAlive, repeating: LinkLimits.keepAlive)
        timer.setEventHandler { [weak self] in self?.send(Data()) }
        timer.resume()
        self.timer = timer
    }

    deinit { nq_stream_release(stream) }

    var isClosed: Bool { lock.withLock { closed } }
    var pendingBytes: Int { lock.withLock { unsent } }

    func onFrame(_ handler: @escaping @Sendable (Data) -> Void) {
        let frames = lock.withLock { () -> [Data] in
            frameHandler = handler
            defer { waiting = [] }
            return waiting
        }
        frames.forEach(handler)
    }

    func onClose(_ handler: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            if closed { return true }
            closeHandlers.append(handler)
            return false
        }
        if now { handler() }
    }

    func send(_ payload: Data) {
        var frame = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) }
        frame.append(payload)
        guard lock.withLock({ () -> Bool in
            guard !closed else { return false }
            unsent += frame.count
            return true
        }) else { return }
        let failed = frame.withUnsafeBytes { nq_stream_send(stream, $0.baseAddress, $0.count, 0) } != 0
        if failed { lock.withLock { unsent -= frame.count } }
    }

    func close() {
        guard !isClosed else { return }
        timer?.cancel()
        _ = nq_stream_send(stream, nil, 0, 1)
        // The device ends its side once it has read the last frames; this catches one that never does.
        DispatchQueue.global().asyncAfter(deadline: .now() + LinkLimits.closeGrace) { [self] in nq_stream_reset(stream, 0) }
    }

    /// Bytes from the device: frames of a four-byte length and their bytes. Empty frames only keep it alive.
    func received(_ bytes: Data) {
        var frames: [Data] = []
        let (handler, overflowing) = lock.withLock { () -> ((@Sendable (Data) -> Void)?, Bool) in
            partial.append(bytes)
            while partial.count >= 4 {
                let length = partial.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard length <= LinkLimits.request else { return (nil, true) }
                guard partial.count >= 4 + length else { break }
                let start = partial.startIndex
                if length > 0 { frames.append(Data(partial[(start + 4)..<(start + 4 + length)])) }
                partial = Data(partial[(start + 4 + length)...])
            }
            guard frameHandler == nil else { return (frameHandler, false) }
            waiting += frames
            frames = []
            return (nil, waiting.reduce(0) { $0 + $1.count } > LinkLimits.request)
        }
        if overflowing { return nq_stream_reset(stream, 1) }
        if let handler { frames.forEach(handler) }
    }

    func left(_ length: Int) {
        lock.withLock { unsent = max(0, unsent - length) }
    }

    func finish() {
        let handlers = lock.withLock { () -> [@Sendable () -> Void] in
            guard !closed else { return [] }
            closed = true
            defer { closeHandlers = [] }
            return closeHandlers
        }
        timer?.cancel()
        handlers.forEach { $0() }
    }
}
#endif
