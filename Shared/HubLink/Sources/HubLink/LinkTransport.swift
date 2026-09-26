import Foundation
import Network
import Security

/// Where a Hub might be reached: a name or address and its UDP port.
public struct LinkEndpoint: Codable, Hashable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

enum LinkQUIC {
    static let alpn = "noodle-hub/1"
    static let messageLimit = 1 << 20
    static let queue = DispatchQueue(label: "HubLink")

    /// Both sides present their key. `verify` decides whether the peer's key is acceptable.
    static func parameters(identity: LinkIdentity, verify: @escaping @Sendable (LinkPublicKey) -> Bool) throws -> NWParameters {
        let options = NWProtocolQUIC.Options(alpn: [alpn])
        options.idleTimeout = 30_000
        let security = options.securityProtocolOptions
        sec_protocol_options_set_local_identity(security, try identity.secIdentity())
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            complete(chain?.first.flatMap(LinkPublicKey.init(certificate:)).map(verify) ?? false)
        }, queue)
        return NWParameters(quic: options)
    }

    static func peerKey(of connection: NWConnection) -> LinkPublicKey? {
        guard let metadata = connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata else { return nil }
        var key: LinkPublicKey?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if key == nil { key = LinkPublicKey(certificate: sec_certificate_copy_ref(certificate).takeRetainedValue()) }
        }
        return key
    }

    /// Reads a request: a channel sends it as one frame and keeps its side open, anything else
    /// sends it whole and finishes. A frame starts with a zero byte, a JSON request with "{".
    static func receiveRequest(_ connection: NWConnection) async throws -> (request: Data, channel: Bool) {
        // An empty request finishes at once.
        guard let first = try await read(1, from: connection) else { return (Data(), false) }
        if first.first == 0 {
            guard let rest = try await read(3, from: connection) else { throw LinkError("The request was cut short.") }
            let length = Int((first + rest).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
            guard length <= messageLimit, let request = try await read(length, from: connection) else {
                throw LinkError("The request was too large or cut short.")
            }
            return (request, true)
        }
        return (first + (try await receive(connection)), false)
    }

    /// Reads one whole message: everything until the peer finishes its side of the stream.
    static func receive(_ connection: NWConnection) async throws -> Data {
        var data = Data()
        while true {
            let (chunk, complete) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, complete, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (chunk, complete)) }
                }
            }
            if let chunk { data.append(chunk) }
            guard data.count <= messageLimit else { throw LinkError("The message is too large.") }
            if complete || chunk == nil { return data }
        }
    }

    /// Reads exactly `count` bytes, or nil if the peer finished before sending any.
    static func read(_ count: Int, from connection: NWConnection) async throws -> Data? {
        var data = Data()
        while data.count < count {
            let (chunk, complete) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data?, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - data.count) { chunk, _, complete, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (chunk, complete)) }
                }
            }
            if let chunk { data.append(chunk) }
            if complete && data.count < count {
                if data.isEmpty { return nil }
                throw LinkError("The Hub closed the stream mid-message.")
            }
        }
        return data
    }

    /// A pushed frame: its length as four big-endian bytes, then the bytes. An empty frame keeps the stream alive.
    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }

    static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

/// What the Hub does with a request: answer it once, or keep the stream open to push frames.
public enum LinkReply: Sendable {
    case response(Data)
    case stream(@Sendable (LinkStream) -> Void)
}

/// An open stream the Hub pushes frames down until either side closes it.
public final class LinkStream: @unchecked Sendable {
    public static let keepAliveInterval: TimeInterval = 10

    public let peer: LinkPublicKey
    private let connection: NWConnection
    private let lock = NSLock()
    private var closed = false
    private var closeHandlers: [@Sendable () -> Void] = []
    private var timer: DispatchSourceTimer?
    /// Frames a channel's client sent before anyone listened, and who listens.
    private var received: [Data] = []
    private var frameHandler: (@Sendable (Data) -> Void)?
    private var unsent = 0

    init(peer: LinkPublicKey, connection: NWConnection) {
        self.peer = peer
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: LinkQUIC.queue)
        timer.schedule(deadline: .now() + Self.keepAliveInterval, repeating: Self.keepAliveInterval)
        timer.setEventHandler { [weak self] in self?.send(Data()) }
        timer.resume()
        self.timer = timer
    }

    public var isClosed: Bool { lock.withLock { closed } }

    /// Bytes sent that the network has not taken yet: how far behind the device is.
    public var pendingBytes: Int { lock.withLock { unsent } }

    /// Takes the frames a channel's client sends, including any sent before this was set.
    public func onFrame(_ handler: @escaping @Sendable (Data) -> Void) {
        let waiting = lock.withLock { () -> [Data] in
            frameHandler = handler
            defer { received = [] }
            return received
        }
        waiting.forEach(handler)
    }

    /// Reads the client's frames until it finishes or the stream ends.
    func readFrames() {
        Task { [connection] in
            while let header = try? await LinkQUIC.read(4, from: connection) {
                let length = Int(header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
                guard length <= LinkQUIC.messageLimit else { break }
                // Empty frames only keep the stream alive.
                guard length > 0 else { continue }
                guard let payload = try? await LinkQUIC.read(length, from: connection) else { break }
                let handler = lock.withLock { () -> (@Sendable (Data) -> Void)? in
                    if frameHandler == nil { received.append(payload) }
                    return frameHandler
                }
                handler?(payload)
            }
        }
    }

    /// Runs once when the stream ends, at once if it already has.
    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        let run = lock.withLock { () -> Bool in
            if closed { return true }
            closeHandlers.append(handler)
            return false
        }
        if run { handler() }
    }

    public func send(_ payload: Data) {
        guard !isClosed else { return }
        let frame = LinkQUIC.frame(payload)
        lock.withLock { unsent += frame.count }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            self?.lock.withLock { self?.unsent -= frame.count }
            if error != nil { self?.connection.cancel() }
        })
    }

    public func close() {
        guard !isClosed else { return }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish() {
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

/// Accepts QUIC connections only from keys `admits` lets in, refused during the handshake so
/// nothing a stranger sends is read, and hands each request to `handler` with the sender's
/// key, which is how the Hub knows which device is asking.
public final class LinkServer: @unchecked Sendable {
    public typealias Handler = @Sendable (LinkPublicKey, Data) async -> LinkReply

    private let listener: NWListener
    private let admits: @Sendable (LinkPublicKey) -> Bool
    private let handler: Handler
    private let lock = NSLock()
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private var pushed: [ObjectIdentifier: LinkStream] = [:]

    public init(identity: LinkIdentity, port: UInt16, admits: @escaping @Sendable (LinkPublicKey) -> Bool,
                handler: @escaping Handler) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw LinkError("The port is not valid.") }
        listener = try NWListener(using: try LinkQUIC.parameters(identity: identity, verify: admits), on: port)
        self.admits = admits
        self.handler = handler
    }

    /// Returns once the port is open.
    public func start() async throws {
        listener.newConnectionHandler = { [weak self] stream in self?.accept(stream) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                case .waiting(let error): once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: LinkError("The Hub stopped listening.")) }
                default: break
                }
            }
            listener.start(queue: LinkQUIC.queue)
        }
    }

    public var port: UInt16? { listener.port?.rawValue }

    public func stop() {
        listener.cancel()
        let open = lock.withLock { () -> [LinkStream] in
            streams.values.forEach { $0.cancel() }
            streams.removeAll()
            defer { pushed.removeAll() }
            return Array(pushed.values)
        }
        open.forEach { $0.close() }
    }

    /// Ends the connections of keys `admits` no longer lets in, such as a removed device's.
    public func disconnectRefused() {
        let (connections, open) = lock.withLock { (Array(streams.values), Array(pushed.values)) }
        for connection in connections where LinkQUIC.peerKey(of: connection).map(admits) == false { connection.cancel() }
        for stream in open where !admits(stream.peer) { stream.close() }
    }

    private func accept(_ stream: NWConnection) {
        let id = ObjectIdentifier(stream)
        lock.withLock { streams[id] = stream }
        stream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { await self?.serve(stream) }
            case .failed, .cancelled:
                self?.lock.withLock { _ = self?.streams.removeValue(forKey: id) }
            default: break
            }
        }
        stream.start(queue: LinkQUIC.queue)
    }

    private func serve(_ stream: NWConnection) async {
        guard let key = LinkQUIC.peerKey(of: stream), let request = try? await LinkQUIC.receiveRequest(stream) else {
            stream.cancel()
            return
        }
        switch await handler(key, request.request) {
        case .response(let response):
            try? await LinkQUIC.send(response, on: stream)
        case .stream(let open):
            lock.withLock { _ = streams.removeValue(forKey: ObjectIdentifier(stream)) }
            let pushed = LinkStream(peer: key, connection: stream)
            lock.withLock { self.pushed[ObjectIdentifier(pushed)] = pushed }
            pushed.onClose { [weak self] in
                self?.lock.withLock { _ = self?.pushed.removeValue(forKey: ObjectIdentifier(pushed)) }
                stream.cancel()
            }
            open(pushed)
            if request.channel { pushed.readFrames() }
        }
    }
}

/// Frames the Hub pushes, until the stream ends or `cancel` is called.
public final class LinkSubscription: Sendable {
    public let frames: AsyncThrowingStream<Data, Error>
    public let endpoint: LinkEndpoint
    private let connection: NWConnection

    init(connection: NWConnection, endpoint: LinkEndpoint) {
        self.connection = connection
        self.endpoint = endpoint
        frames = AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    while let header = try await LinkQUIC.read(4, from: connection) {
                        // A Hub that refuses answers once, in JSON, instead of opening the stream.
                        if header.first == UInt8(ascii: "{") {
                            let response = try LinkProtocol.decodeResponse(header + (try await LinkQUIC.receive(connection)))
                            if case .failure(let message) = response { throw LinkError(message) }
                            throw LinkError("The Hub sent an unexpected answer.")
                        }
                        let length = Int(header.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
                        guard length <= LinkQUIC.messageLimit else { throw LinkError("The message is too large.") }
                        // Empty frames only keep the stream alive.
                        guard length > 0 else { continue }
                        guard let payload = try await LinkQUIC.read(length, from: connection) else { break }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                connection.cancel()
            }
        }
    }

    public func cancel() { connection.cancel() }
}

/// A stream both ways: the Hub pushes frames, and this side sends its own on the same stream,
/// without opening a connection for each.
public final class LinkChannel: Sendable {
    public let frames: AsyncThrowingStream<Data, Error>
    private let subscription: LinkSubscription
    private let connection: NWConnection

    init(connection: NWConnection, endpoint: LinkEndpoint) {
        self.connection = connection
        subscription = LinkSubscription(connection: connection, endpoint: endpoint)
        frames = subscription.frames
    }

    public func send(_ payload: Data) {
        connection.send(content: LinkQUIC.frame(payload), completion: .contentProcessed { [connection] error in
            if error != nil { connection.cancel() }
        })
    }

    public func cancel() { connection.cancel() }
}

/// Sends one request to a Hub whose key is pinned, trying every endpoint at once.
public enum LinkClient {
    /// Opens a channel: the request goes as a frame, and the stream stays open both ways.
    public static func channel(_ request: Data, identity: LinkIdentity, hubKey: LinkPublicKey,
                               endpoints: [LinkEndpoint], timeout: Duration = .seconds(10)) async throws -> LinkChannel {
        guard !endpoints.isEmpty else { throw LinkError("The Hub has no addresses to try.") }
        let (connection, endpoint) = try await firstReady(endpoints, identity: identity, hubKey: hubKey, timeout: timeout)
        let channel = LinkChannel(connection: connection, endpoint: endpoint)
        channel.send(request)
        return channel
    }

    /// Opens a stream the Hub keeps pushing frames down.
    public static func subscribe(_ request: Data, identity: LinkIdentity, hubKey: LinkPublicKey,
                                 endpoints: [LinkEndpoint], timeout: Duration = .seconds(10)) async throws -> LinkSubscription {
        guard !endpoints.isEmpty else { throw LinkError("The Hub has no addresses to try.") }
        let (connection, endpoint) = try await firstReady(endpoints, identity: identity, hubKey: hubKey, timeout: timeout)
        do {
            try await LinkQUIC.send(request, on: connection)
        } catch {
            connection.cancel()
            throw error
        }
        return LinkSubscription(connection: connection, endpoint: endpoint)
    }

    public static func exchange(_ request: Data, identity: LinkIdentity, hubKey: LinkPublicKey,
                                endpoints: [LinkEndpoint], timeout: Duration = .seconds(10)) async throws -> (response: Data, endpoint: LinkEndpoint) {
        guard !endpoints.isEmpty else { throw LinkError("The Hub has no addresses to try.") }
        let (connection, endpoint) = try await firstReady(endpoints, identity: identity, hubKey: hubKey, timeout: timeout)
        defer { connection.cancel() }
        try await LinkQUIC.send(request, on: connection)
        return (try await LinkQUIC.receive(connection), endpoint)
    }

    /// The first endpoint whose handshake completes wins; the rest are cancelled.
    private static func firstReady(_ endpoints: [LinkEndpoint], identity: LinkIdentity, hubKey: LinkPublicKey,
                                   timeout: Duration) async throws -> (NWConnection, LinkEndpoint) {
        let parameters = try LinkQUIC.parameters(identity: identity) { $0 == hubKey }
        let connections = endpoints.compactMap { endpoint -> (NWConnection, LinkEndpoint)? in
            guard let port = NWEndpoint.Port(rawValue: endpoint.port) else { return nil }
            return (NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters), endpoint)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            let failures = Counter()
            @Sendable func finish(_ result: Result<(NWConnection, LinkEndpoint), Error>) {
                once.run {
                    for (connection, _) in connections {
                        if case .success(let winner) = result, winner.0 === connection { continue }
                        connection.cancel()
                    }
                    continuation.resume(with: result)
                }
            }
            for (connection, endpoint) in connections {
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success((connection, endpoint)))
                    case .failed, .waiting:
                        connection.stateUpdateHandler = nil
                        if failures.increment() == connections.count {
                            finish(.failure(LinkError("The Hub could not be reached.")))
                        }
                    default: break
                    }
                }
                connection.start(queue: LinkQUIC.queue)
            }
            LinkQUIC.queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) {
                finish(.failure(LinkError("The Hub did not answer in time.")))
            }
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}
