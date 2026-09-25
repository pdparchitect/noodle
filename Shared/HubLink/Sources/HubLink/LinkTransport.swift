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
            if complete { return data }
        }
    }

    static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

/// Accepts QUIC connections from any key and hands each request to `handler` with the
/// sender's key, which is how the Hub knows which device is asking.
public final class LinkServer: @unchecked Sendable {
    public typealias Handler = @Sendable (LinkPublicKey, Data) async -> Data

    private let listener: NWListener
    private let handler: Handler
    private let lock = NSLock()
    private var streams: [ObjectIdentifier: NWConnection] = [:]

    public init(identity: LinkIdentity, port: UInt16, handler: @escaping Handler) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw LinkError("The port is not valid.") }
        listener = try NWListener(using: try LinkQUIC.parameters(identity: identity) { _ in true }, on: port)
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
        lock.withLock { streams.values.forEach { $0.cancel() }; streams.removeAll() }
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
        guard let key = LinkQUIC.peerKey(of: stream), let request = try? await LinkQUIC.receive(stream) else {
            stream.cancel()
            return
        }
        let response = await handler(key, request)
        try? await LinkQUIC.send(response, on: stream)
    }
}

/// Sends one request to a Hub whose key is pinned, trying every endpoint at once.
public enum LinkClient {
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
