#if os(Linux)
import Foundation
@testable import HubLink
import HubWire
import XCTest

/// A device's link to its Hub on Linux, against the Hub's own listener there: the Hub is pinned by
/// key, requests are answered, pushed frames and channels work, and a Hub gone quiet is noticed.
final class LinkClientTests: XCTestCase {
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [Data] = []
        func record(_ request: Data) { lock.withLock { requests.append(request) } }
        var all: [Data] { lock.withLock { requests } }
    }

    private let hub = LinkIdentity()
    private let device = LinkIdentity()
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    /// The Hub, letting in only this test's device.
    private func listen(_ handler: @escaping @Sendable (LinkPublicKey, Data) async -> LinkReply) async throws -> LinkEndpoint {
        let device = device.publicKey
        let listener = try QUICListener.listen(certificates: folder)(hub, 0, { $0 == device }, handler)
        try await listener.start()
        addTeardownBlock { listener.stop() }
        return LinkEndpoint(host: "127.0.0.1", port: try XCTUnwrap(listener.port))
    }

    private func exchange(_ request: Data, endpoints: [LinkEndpoint], hubKey: LinkPublicKey? = nil,
                          timeout: Duration = .seconds(5)) async throws -> (response: Data, endpoint: LinkEndpoint) {
        try await LinkClient.exchange(request, identity: device, hubKey: hubKey ?? hub.publicKey, endpoints: endpoints, timeout: timeout)
    }

    func testARequestIsAnsweredByThePinnedHub() async throws {
        let hub = try await listen { key, request in .response(Data("\(key.x963.count):".utf8) + request) }
        let (response, endpoint) = try await exchange(Data("hello".utf8), endpoints: [hub])
        XCTAssertEqual(response, Data("65:hello".utf8))
        XCTAssertEqual(endpoint, hub)
    }

    /// Something else at the Hub's address, with another key, never hears the request.
    func testAnotherServerAtTheAddressIsNeverSentTheRequest() async throws {
        let asked = Asked()
        let hub = try await listen { _, request in
            asked.record(request)
            return .response(Data("no".utf8))
        }
        do {
            _ = try await exchange(Data("secret".utf8), endpoints: [hub], hubKey: LinkIdentity().publicKey)
            XCTFail("a server with another key was answered")
        } catch let error as LinkError {
            XCTAssertTrue(error.isUnreachable, error.message)
        }
        XCTAssertEqual(asked.all, [])
    }

    func testManyRequestsAtOnceAreEachAnswered() async throws {
        let hub = try await listen { _, request in .response(request + request) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    let (response, _) = try await self.exchange(Data("r\(index)".utf8), endpoints: [hub])
                    XCTAssertEqual(response, Data("r\(index)r\(index)".utf8))
                }
            }
            try await group.waitForAll()
        }
        // A fresh connection after dropping the one kept answers as well.
        LinkClient.dropConnection(identity: device, hubKey: self.hub.publicKey)
        let again = try await exchange(Data("again".utf8), endpoints: [hub])
        XCTAssertEqual(again.response, Data("againagain".utf8))
    }

    func testAnAddressThatDoesNotAnswerIsPassedOver() async throws {
        let hub = try await listen { _, _ in .response(Data("here".utf8)) }
        let nowhere = LinkEndpoint(host: "127.0.0.1", port: 9)
        let (response, endpoint) = try await exchange(Data("hi".utf8), endpoints: [nowhere, hub])
        XCTAssertEqual(response, Data("here".utf8))
        XCTAssertEqual(endpoint, hub)
    }

    func testAHubNoAddressReachesSaysSo() async throws {
        do {
            _ = try await exchange(Data("hi".utf8), endpoints: [LinkEndpoint(host: "127.0.0.1", port: 9)], timeout: .seconds(2))
            XCTFail("an answer came from nowhere")
        } catch let error as LinkError {
            XCTAssertTrue(error.isUnreachable, error.message)
        }
    }

    func testAnAnswerLargerThanAnyRequestArrivesWhole() async throws {
        let big = Data((0..<(5 << 20)).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let hub = try await listen { _, _ in .response(big) }
        let answer = try await exchange(Data("big".utf8), endpoints: [hub])
        XCTAssertEqual(answer.response, big)
    }

    func testASubscriptionHearsWhatTheHubPushes() async throws {
        let hub = try await listen { _, _ in
            .stream { stream in
                stream.send(Data("a".utf8))
                stream.send(Data("bb".utf8))
                stream.close()
            }
        }
        let subscription = try await LinkClient.subscribe(Data("watch".utf8), identity: device, hubKey: self.hub.publicKey, endpoints: [hub])
        try await subscription.heard()
        var frames: [Data] = []
        for try await frame in subscription.frames { frames.append(frame) }
        XCTAssertEqual(frames, [Data("a".utf8), Data("bb".utf8)])
        XCTAssertEqual(subscription.endpoint, hub)
    }

    /// A Hub that will not open the stream says why, once.
    func testARefusedSubscriptionSaysWhy() async throws {
        let hub = try await listen { _, _ in .response(LinkProtocol.encode(LinkResponse.failure("Not for you."))) }
        let subscription = try await LinkClient.subscribe(Data("watch".utf8), identity: device, hubKey: self.hub.publicKey, endpoints: [hub])
        do {
            try await subscription.heard()
            XCTFail("a refusal was taken as the stream")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Not for you.")
        }
    }

    /// The Hub keeps a stream alive every ten seconds; a stream silent for longer has lost the Hub.
    func testASilentHubEndsTheSubscription() async throws {
        let hub = try await listen { _, _ in .stream { _ in } }
        let subscription = try await LinkClient.subscribe(Data("watch".utf8), identity: device, hubKey: self.hub.publicKey,
                                                          endpoints: [hub], silenceLimit: .seconds(1))
        do {
            for try await _ in subscription.frames {}
            XCTFail("the silent stream did not end")
        } catch let error as LinkError {
            XCTAssertTrue(error.isUnreachable)
            XCTAssertEqual(error.message, "The Hub stopped answering.")
        }
    }

    func testAChannelCarriesFramesBothWays() async throws {
        let hub = try await listen { _, request in
            .stream { stream in stream.onFrame { stream.send(request + Data(":".utf8) + $0) } }
        }
        let channel = try await LinkClient.channel(Data("ch".utf8), identity: device, hubKey: self.hub.publicKey, endpoints: [hub])
        channel.send(Data("x".utf8))
        channel.send(Data("y".utf8))
        var frames: [Data] = []
        for try await frame in channel.frames {
            frames.append(frame)
            if frames.count == 2 { break }
        }
        channel.cancel()
        XCTAssertEqual(frames, [Data("ch:x".utf8), Data("ch:y".utf8)])
    }
}
#endif
