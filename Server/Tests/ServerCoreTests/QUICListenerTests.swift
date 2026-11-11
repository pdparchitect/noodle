#if os(Linux)
import CNoodleQUIC
import Foundation
import HubWire
@testable import ServerCore
import XCTest

/// The Linux listener serves devices as Noodle Hub's does on a Mac: pinned keys at the handshake and on
/// every stream, a request per stream, pushed frames, and channels both ways.
final class QUICListenerTests: XCTestCase {
    private final class Admitted: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: Set<LinkPublicKey> = []
        func insert(_ key: LinkPublicKey) { lock.withLock { _ = keys.insert(key) } }
        func remove(_ key: LinkPublicKey) { lock.withLock { _ = keys.remove(key) } }
        func contains(_ key: LinkPublicKey) -> Bool { lock.withLock { keys.contains(key) } }
    }

    private let hub = LinkIdentity()
    private let device = LinkIdentity()
    private let admitted = Admitted()
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        admitted.insert(device.publicKey)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func listen(_ handler: @escaping @Sendable (LinkPublicKey, Data) async -> LinkReply) async throws -> any LinkListening {
        let admitted = admitted
        let listener = try QUICListener.listen(certificates: folder.appendingPathComponent("hub"))(hub, 0, { admitted.contains($0) }, handler)
        try await listener.start()
        addTeardownBlock { listener.stop() }
        return listener
    }

    /// Connects as `identity`, returning the client and the key the server's certificate carries.
    private func connect(to listener: any LinkListening, as identity: LinkIdentity? = nil) throws -> (OpaquePointer, LinkPublicKey?) {
        let pem = try LinkCertificate.pem(for: identity ?? device)
        let files = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try Data(pem.certificate.utf8).write(to: files.appendingPathComponent("certificate.pem"))
        try Data(pem.key.utf8).write(to: files.appendingPathComponent("key.pem"))
        var peer = [UInt8](repeating: 0, count: 4096), peerLength = 0, error = [CChar](repeating: 0, count: 256)
        guard let client = nq_connect("127.0.0.1", listener.port!, files.appendingPathComponent("certificate.pem").path,
                                      files.appendingPathComponent("key.pem").path, &peer, peer.count, &peerLength, &error, error.count) else {
            throw LinkError(String(cString: error))
        }
        addTeardownBlock { nq_client_close(client) }
        return (client, LinkCertificate.key(of: Array(peer.prefix(peerLength))))
    }

    private func open(_ client: OpaquePointer, _ bytes: Data, finish: Bool = true) -> OpaquePointer {
        let stream = bytes.withUnsafeBytes { nq_client_open(client, $0.baseAddress, $0.count, finish ? 1 : 0) }!
        addTeardownBlock { nq_stream_release(stream) }
        return stream
    }

    /// Everything until the server finishes; nil if the stream fails or goes quiet.
    private func readAll(_ stream: OpaquePointer, timeout: Int32 = 5_000) -> Data? {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = nq_client_read(stream, &buffer, buffer.count, timeout)
            if count == 0 { return data }
            if count < 0 { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func frame(_ payload: Data) -> Data {
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + payload
    }

    func testARequestIsAnsweredWithWhoAskedAndTheServerIsWhoItSays() async throws {
        let listener = try await listen { key, request in .response(Data("\(key.x963.count):".utf8) + request) }
        let (client, serverKey) = try connect(to: listener)
        XCTAssertEqual(serverKey, hub.publicKey)
        XCTAssertEqual(readAll(open(client, Data("hello".utf8))), Data("65:hello".utf8))
    }

    func testManyRequestsShareOneConnection() async throws {
        let listener = try await listen { _, request in .response(request + request) }
        let (client, _) = try connect(to: listener)
        let streams = (0..<40).map { open(client, Data("r\($0)".utf8)) }
        for (index, stream) in streams.enumerated() {
            XCTAssertEqual(readAll(stream), Data("r\(index)r\(index)".utf8))
        }
    }

    func testAnAnswerLargerThanAnyRequestArrivesWhole() async throws {
        let big = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let listener = try await listen { _, _ in .response(big) }
        let (client, _) = try connect(to: listener)
        XCTAssertEqual(readAll(open(client, Data("big".utf8)), timeout: 15_000), big)
    }

    /// TLS 1.3 lets a client count the handshake done before the server has checked its certificate,
    /// so a stranger may seem to connect; it is refused there, and nothing it sends reaches the Hub.
    func testAKeyTheHubDoesNotKnowIsRefusedAtTheHandshake() async throws {
        let asked = Admitted()
        let listener = try await listen { key, _ in
            asked.insert(key)
            return .response(Data("no".utf8))
        }
        let stranger = LinkIdentity()
        if let (client, _) = try? connect(to: listener, as: stranger) {
            XCTAssertNil(readAll(open(client, Data("hello".utf8)), timeout: 3_000))
        }
        XCTAssertFalse(asked.contains(stranger.publicKey))
    }

    func testAStreamPushesFramesUntilTheHubEndsIt() async throws {
        let listener = try await listen { _, _ in
            .stream { stream in
                stream.send(Data("a".utf8))
                stream.send(Data("bb".utf8))
                stream.close()
            }
        }
        let (client, _) = try connect(to: listener)
        XCTAssertEqual(readAll(open(client, Data("watch".utf8))), frame(Data("a".utf8)) + frame(Data("bb".utf8)))
    }

    /// A channel's request is a frame and the stream stays open both ways; frames sent with it, before
    /// anyone listens, are kept.
    func testAChannelCarriesFramesBothWays() async throws {
        let listener = try await listen { _, request in
            .stream { stream in stream.onFrame { stream.send(request + Data(":".utf8) + $0) } }
        }
        let (client, _) = try connect(to: listener)
        let channel = open(client, frame(Data("ch".utf8)) + frame(Data("x".utf8)), finish: false)
        var buffer = [UInt8](repeating: 0, count: 64)
        var received = Data()
        while received.count < 8 {
            let count = nq_client_read(channel, &buffer, buffer.count, 5_000)
            guard count > 0 else { return XCTFail("the channel's answer did not come") }
            received.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertEqual(received, frame(Data("ch:x".utf8)))
    }

    /// A device removed while watching loses the stream; a new request on the same connection is refused.
    func testARemovedDeviceLosesWhatItHasOpen() async throws {
        let listener = try await listen { _, request in
            request == Data("watch".utf8) ? .stream { _ in } : .response(Data("ok".utf8))
        }
        let (client, _) = try connect(to: listener)
        let watching = open(client, Data("watch".utf8))
        try await Task.sleep(for: .milliseconds(300))
        admitted.remove(device.publicKey)
        listener.disconnectRefused()
        XCTAssertEqual(readAll(watching), Data())
        XCTAssertNil(readAll(open(client, Data("again".utf8))))
    }
}
#endif
