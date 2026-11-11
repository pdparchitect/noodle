#if os(Linux)
import CNoodleQUIC
import Foundation
import HubWire

/// A device's link to its Hub on Linux, over msquic, with the calls Apple platforms make over
/// Network.framework: the Hub is pinned by key during the handshake, before anything is sent; each
/// request is a stream of one connection kept to the Hub; pushed frames and channels work as there.
public enum LinkClient {
    /// What a device reads from the Hub: answers and pushed frames can be far larger than any request.
    static let answerLimit = 64 << 20

    /// How long a request waits for the Hub to answer, or for the next piece of a long answer.
    public static let answerWait: Duration = .seconds(120)

    /// A Hub stops reading a request past its limit, so a larger one fails before it goes.
    static func checkSize(_ request: Data) throws {
        guard request.count <= LinkLimits.request else { throw LinkError("This is too large to send to the Hub.") }
    }

    public static func exchange(_ request: Data, identity: LinkIdentity, hubKey: LinkPublicKey,
                                endpoints: [LinkEndpoint], timeout: Duration = .seconds(10),
                                answerWait: Duration = LinkClient.answerWait) async throws -> (response: Data, endpoint: LinkEndpoint) {
        try checkSize(request)
        let (stream, endpoint) = try await LinkSessions.open(request, finish: true, identity: identity, hubKey: hubKey,
                                                             endpoints: endpoints, timeout: timeout)
        defer { stream.cancel() }
        var answer = Data()
        do {
            while let piece = try await stream.next(within: answerWait) {
                answer += piece
                guard answer.count <= answerLimit else { throw LinkError("The message is too large.") }
            }
        } catch LinkStreamError.silent {
            throw LinkError("The Hub did not answer in time.", isUnreachable: true)
        }
        return (answer, endpoint)
    }

    /// Opens a stream the Hub keeps pushing frames down. It fails once the Hub says nothing for `silenceLimit`.
    public static func subscribe(_ request: Data, identity: LinkIdentity, hubKey: LinkPublicKey,
                                 endpoints: [LinkEndpoint], timeout: Duration = .seconds(10),
                                 silenceLimit: Duration = LinkSubscription.silenceLimit) async throws -> LinkSubscription {
        try checkSize(request)
        let (stream, endpoint) = try await LinkSessions.open(request, finish: true, identity: identity, hubKey: hubKey,
                                                             endpoints: endpoints, timeout: timeout)
        return LinkSubscription(stream: stream, endpoint: endpoint, silenceLimit: silenceLimit)
    }

    /// Opens a channel: the request goes as a frame, and the stream stays open both ways. One that
    /// can fill the link takes `ownConnection`, so answers on the shared one do not queue behind it.
    public static func channel(_ request: Data, identity: LinkIdentity, hubKey: LinkPublicKey,
                               endpoints: [LinkEndpoint], timeout: Duration = .seconds(10),
                               ownConnection: Bool = false) async throws -> LinkChannel {
        try checkSize(request)
        let (stream, endpoint) = try await LinkSessions.open(LinkSessions.frame(request), finish: false, identity: identity,
                                                             hubKey: hubKey, endpoints: endpoints, timeout: timeout,
                                                             ownConnection: ownConnection)
        return LinkChannel(stream: stream, endpoint: endpoint)
    }

    /// Opens no more on the connection kept to the Hub, so the next request connects afresh and
    /// tries every address again. Streams open on it go on.
    public static func dropConnection(identity: LinkIdentity, hubKey: LinkPublicKey) {
        LinkSessions.drop(device: identity.publicKey, hub: hubKey)
    }
}

/// Frames the Hub pushes, until the stream ends or `cancel` is called.
public final class LinkSubscription: Sendable {
    /// How long the Hub may say nothing: it writes at least every keep-alive, so a stream quiet for
    /// longer has lost the Hub.
    public static let silenceLimit: Duration = .seconds(LinkLimits.keepAlive * 2.5)

    public let frames: AsyncThrowingStream<Data, Error>
    public let endpoint: LinkEndpoint
    private let stream: LinkQUICStream
    private let firstWord = LinkFirstWord()

    init(stream: LinkQUICStream, endpoint: LinkEndpoint, silenceLimit: Duration = LinkSubscription.silenceLimit) {
        self.stream = stream
        self.endpoint = endpoint
        frames = AsyncThrowingStream { [firstWord] continuation in
            let reader = Task {
                do {
                    while let header = try await stream.read(4, within: silenceLimit) {
                        // A Hub that refuses answers once, in JSON, instead of opening the stream; that is
                        // not the Hub taking the stream on, so it is checked for first.
                        if header.first == UInt8(ascii: "{") {
                            var answer = header
                            while let piece = try await stream.next(within: silenceLimit) {
                                answer += piece
                                guard answer.count <= LinkClient.answerLimit else { throw LinkError("The message is too large.") }
                            }
                            if case .failure(let message) = try LinkProtocol.decodeResponse(answer) { throw LinkError(message) }
                            throw LinkError("The Hub sent an unexpected answer.")
                        }
                        firstWord.resolve(.success(()))
                        let length = Int(header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
                        guard length <= LinkClient.answerLimit else { throw LinkError("The message is too large.") }
                        // Empty frames only keep the stream alive.
                        guard length > 0 else { continue }
                        guard let payload = try await stream.read(length, within: silenceLimit) else { break }
                        continuation.yield(payload)
                    }
                    firstWord.resolve(.failure(LinkError("The Hub ended the stream.")))
                    continuation.finish()
                } catch {
                    let error = error as? LinkStreamError == .silent ? LinkError("The Hub stopped answering.", isUnreachable: true) : error
                    firstWord.resolve(.failure(error))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                stream.cancel()
            }
        }
    }

    /// Returns once the Hub first writes down the stream, even only to keep it alive, and throws if
    /// it refuses or the stream ends first.
    public func heard() async throws {
        try await withTaskCancellationHandler {
            try await firstWord.wait()
        } onCancel: { [stream] in
            stream.cancel()
        }
    }

    public func cancel() { stream.cancel() }
}

/// A stream both ways: the Hub pushes frames, and this side sends its own on the same stream.
public final class LinkChannel: Sendable {
    public let frames: AsyncThrowingStream<Data, Error>
    private let subscription: LinkSubscription
    private let stream: LinkQUICStream

    init(stream: LinkQUICStream, endpoint: LinkEndpoint) {
        self.stream = stream
        subscription = LinkSubscription(stream: stream, endpoint: endpoint)
        frames = subscription.frames
    }

    public func send(_ payload: Data) {
        if !stream.send(LinkSessions.frame(payload), finish: false) { stream.cancel() }
    }

    public func cancel() { stream.cancel() }
}

/// Settles once, for everyone waiting on the Hub's first word down a stream.
private final class LinkFirstWord: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var waiting: [CheckedContinuation<Void, Error>] = []

    func resolve(_ outcome: Result<Void, Error>) {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            guard result == nil else { return [] }
            result = outcome
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume(with: outcome) }
    }

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let known = lock.withLock { () -> Result<Void, Error>? in
                if result == nil { waiting.append(continuation) }
                return result
            }
            if let known { continuation.resume(with: known) }
        }
    }
}

enum LinkStreamError: Error, Equatable {
    /// Nothing came for as long as the reader would wait.
    case silent
}

/// One stream of a connection to the Hub. Reads wait on a thread of their own, since msquic's
/// client hands bytes over to a waiting read; the connection stays open while the stream does.
final class LinkQUICStream: @unchecked Sendable {
    private let handle: OpaquePointer
    private let connection: LinkQUICConnection
    private let queue = DispatchQueue(label: "HubLink.stream")
    private let lock = NSLock()
    private var cancelled = false
    private var unread = Data()

    init(handle: OpaquePointer, connection: LinkQUICConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit { nq_stream_release(handle) }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// The next bytes the Hub sent; nil once it finished its side. Throws when the stream fails,
    /// is cancelled, or nothing comes for `silence`.
    func next(within silence: Duration) async throws -> Data? {
        let held = lock.withLock { () -> Data? in
            defer { unread = Data() }
            return unread.isEmpty ? nil : unread
        }
        if let held { return held }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let deadline = ContinuousClock.now + silence
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    if isCancelled { return continuation.resume(throwing: CancellationError()) }
                    let count = nq_client_read(handle, &buffer, buffer.count, 250)
                    if count > 0 { return continuation.resume(returning: Data(buffer[0..<count])) }
                    if count == 0 { return continuation.resume(returning: nil) }
                    if count == -1 {
                        return continuation.resume(throwing: isCancelled ? CancellationError()
                            : LinkError("The connection to the Hub was lost.", isUnreachable: true))
                    }
                    if ContinuousClock.now >= deadline { return continuation.resume(throwing: LinkStreamError.silent) }
                }
            }
        }
    }

    /// Exactly `count` bytes, or nil when the Hub finished before any of them came.
    func read(_ count: Int, within silence: Duration) async throws -> Data? {
        var bytes = Data()
        while bytes.count < count {
            guard let piece = try await next(within: silence) else {
                if bytes.isEmpty { return nil }
                throw LinkError("The Hub ended the stream midway.")
            }
            bytes += piece
        }
        if bytes.count > count {
            let rest = bytes.subdata(in: bytes.startIndex + count..<bytes.endIndex)
            lock.withLock { unread = rest + unread }
            bytes = bytes.prefix(count)
        }
        return Data(bytes)
    }

    func send(_ bytes: Data, finish: Bool) -> Bool {
        bytes.withUnsafeBytes { nq_stream_send(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, finish ? 1 : 0) } == 0
    }

    func cancel() {
        let first = lock.withLock { () -> Bool in
            defer { cancelled = true }
            return !cancelled
        }
        if first { nq_stream_reset(handle, 0) }
    }
}

/// One QUIC connection from a device to its Hub. It closes once nothing holds it: neither the
/// connections kept nor a stream open on it.
final class LinkQUICConnection: @unchecked Sendable {
    let handle: OpaquePointer
    let endpoint: LinkEndpoint

    init(handle: OpaquePointer, endpoint: LinkEndpoint) {
        self.handle = handle
        self.endpoint = endpoint
    }

    deinit {
        let handle = handle
        // Closing waits for the Hub to agree, which no caller should wait for.
        DispatchQueue.global().async { nq_client_close(handle) }
    }

    var isOpen: Bool { nq_client_is_closed(handle) == 0 }

    func open(_ bytes: Data, finish: Bool) -> LinkQUICStream? {
        let stream = bytes.withUnsafeBytes {
            nq_client_open(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, finish ? 1 : 0)
        }
        return stream.map { LinkQUICStream(handle: $0, connection: self) }
    }
}

/// The connection each device keeps to each Hub it talks to, and how one is made: every address
/// at once, the first whose handshake shows the pinned key winning.
enum LinkSessions {
    private struct Key: Hashable {
        let device: LinkPublicKey
        let hub: LinkPublicKey
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var connections: [Key: LinkQUICConnection] = [:]
    /// Each identity's certificate, made once: making one signs it.
    nonisolated(unsafe) private static var certificates: [LinkPublicKey: (certificate: String, key: String)] = [:]

    static func frame(_ payload: Data) -> Data {
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + payload
    }

    /// A stream carrying `bytes`, on the connection kept to the Hub, or a new one if that has ended.
    static func open(_ bytes: Data, finish: Bool, identity: LinkIdentity, hubKey: LinkPublicKey, endpoints: [LinkEndpoint],
                     timeout: Duration, ownConnection: Bool = false) async throws -> (LinkQUICStream, LinkEndpoint) {
        guard !endpoints.isEmpty else { throw LinkError("The Hub has no addresses to try.", isUnreachable: true) }
        let key = Key(device: identity.publicKey, hub: hubKey)
        if !ownConnection, let kept = lock.withLock({ connections[key] }), kept.isOpen, let stream = kept.open(bytes, finish: finish) {
            return (stream, kept.endpoint)
        }
        let connection = try await connect(identity: identity, hubKey: hubKey, endpoints: endpoints, timeout: timeout)
        if !ownConnection { lock.withLock { connections[key] = connection } }
        guard let stream = connection.open(bytes, finish: finish) else {
            throw LinkError("The Hub could not be reached.", isUnreachable: true)
        }
        return (stream, connection.endpoint)
    }

    static func drop(device: LinkPublicKey, hub: LinkPublicKey) {
        _ = lock.withLock { connections.removeValue(forKey: Key(device: device, hub: hub)) }
    }

    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<LinkQUICConnection, Error>?
        private var left: Int
        private var answered = false
        init(_ continuation: CheckedContinuation<LinkQUICConnection, Error>, entrants: Int) {
            self.continuation = continuation
            left = entrants
        }
        /// The first connection wins; one that comes after it closes as it goes. When every address
        /// has failed, the Hub could not be reached, or did not answer at all.
        func finish(_ connection: LinkQUICConnection?, answered: Bool) {
            lock.lock()
            left -= 1
            self.answered = self.answered || answered
            guard let waiting = continuation, connection != nil || left == 0 else { return lock.unlock() }
            continuation = nil
            let anyAnswered = self.answered
            lock.unlock()
            if let connection { return waiting.resume(returning: connection) }
            waiting.resume(throwing: anyAnswered ? LinkError("The Hub could not be reached.", isUnreachable: true)
                                                 : LinkError("The Hub did not answer in time.", isUnreachable: true))
        }
    }

    /// Whom a handshake is with: the key its certificate must carry.
    private final class Pin { let key: LinkPublicKey; init(_ key: LinkPublicKey) { self.key = key } }

    private static func connect(identity: LinkIdentity, hubKey: LinkPublicKey, endpoints: [LinkEndpoint],
                                timeout: Duration) async throws -> LinkQUICConnection {
        let pem = try lock.withLock { () throws -> (certificate: String, key: String) in
            if let made = certificates[identity.publicKey] { return made }
            let made = try LinkCertificate.pem(for: identity)
            certificates[identity.publicKey] = made
            return made
        }
        let milliseconds = Int32(clamping: timeout.components.seconds * 1_000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        let entrants = Array(Set(endpoints))
        return try await withCheckedThrowingContinuation { continuation in
            let race = Race(continuation, entrants: entrants.count)
            for endpoint in entrants {
                DispatchQueue.global().async {
                    let pin = Unmanaged.passRetained(Pin(hubKey))
                    defer { pin.release() }
                    var answered: Int32 = 0
                    var error = [CChar](repeating: 0, count: 256)
                    let handle = nq_connect(endpoint.host, endpoint.port, pem.certificate, pem.key, { context, bytes, length in
                        guard let context, let bytes else { return 0 }
                        let wanted = Unmanaged<Pin>.fromOpaque(context).takeUnretainedValue().key
                        return LinkCertificate.key(of: Array(UnsafeBufferPointer(start: bytes, count: length))) == wanted ? 1 : 0
                    }, pin.toOpaque(), milliseconds, &answered, &error, error.count)
                    race.finish(handle.map { LinkQUICConnection(handle: $0, endpoint: endpoint) }, answered: answered != 0)
                }
            }
        }
    }
}
#endif
