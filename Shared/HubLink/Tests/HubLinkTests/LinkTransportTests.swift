import Foundation
@testable import HubLink
import XCTest

final class LinkTransportTests: XCTestCase {
    private func server(_ identity: LinkIdentity) async throws -> LinkServer {
        let server = try LinkServer(identity: identity, port: 0, admits: { _ in true }) { key, request in
            .response(key.x963 + request)
        }
        try await server.start()
        addTeardownBlock { server.stop() }
        return server
    }

    func testBothSidesProveTheirKeysOverQUIC() async throws {
        let hub = LinkIdentity(), device = LinkIdentity()
        let server = try await server(hub)
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))
        let (response, used) = try await LinkClient.exchange(Data("hello".utf8), identity: device, hubKey: hub.publicKey,
                                                             endpoints: [endpoint])
        XCTAssertEqual(used, endpoint)
        XCTAssertEqual(response, device.publicKey.x963 + Data("hello".utf8))
    }

    func testDeviceRefusesAHubWithAnotherKey() async throws {
        let server = try await server(LinkIdentity())
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))
        do {
            _ = try await LinkClient.exchange(Data(), identity: LinkIdentity(), hubKey: LinkIdentity().publicKey,
                                              endpoints: [endpoint], timeout: .seconds(5))
            XCTFail("Connected to a Hub with an unpinned key")
        } catch {}
    }

    /// A key the Hub does not admit fails the handshake, so its request never reaches the handler.
    func testTheHubRefusesKeysItDoesNotAdmitDuringTheHandshake() async throws {
        let hub = LinkIdentity(), known = LinkIdentity()
        let requests = FrameBox()
        let server = try LinkServer(identity: hub, port: 0, admits: { $0 == known.publicKey }) { _, request in
            requests.append(request)
            return .response(request)
        }
        try await server.start()
        addTeardownBlock { server.stop() }
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))
        do {
            _ = try await LinkClient.exchange(Data("stranger".utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
                                              endpoints: [endpoint], timeout: .seconds(5))
            XCTFail("A key the Hub does not admit got in")
        } catch {}
        let (response, _) = try await LinkClient.exchange(Data("known".utf8), identity: known, hubKey: hub.publicKey, endpoints: [endpoint])
        XCTAssertEqual(response, Data("known".utf8))
        XCTAssertEqual(requests.frames, [Data("known".utf8)])
    }

    func testTheFirstReachableEndpointWins() async throws {
        let hub = LinkIdentity()
        let server = try await server(hub)
        let port = try XCTUnwrap(server.port)
        let (_, used) = try await LinkClient.exchange(Data(), identity: LinkIdentity(), hubKey: hub.publicKey,
            endpoints: [LinkEndpoint(host: "unreachable.invalid", port: port), LinkEndpoint(host: "127.0.0.1", port: port)])
        XCTAssertEqual(used.host, "127.0.0.1")
    }
}

final class LinkStreamTests: XCTestCase {
    func testTheHubPushesFramesDownAnOpenStream() async throws {
        let hub = LinkIdentity(), device = LinkIdentity()
        let opened = expectation(description: "stream opened")
        let box = StreamBox()
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }, handler: { _, request in
            request == Data("subscribe".utf8) ? .stream({ stream in box.stream = stream; opened.fulfill() }) : .response(Data())
        })
        try await server.start()
        addTeardownBlock { server.stop() }
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))

        let frames = try await LinkClient.subscribe(Data("subscribe".utf8), identity: device, hubKey: hub.publicKey, endpoints: [endpoint])
        await fulfillment(of: [opened], timeout: 5)
        let stream = try XCTUnwrap(box.stream)
        XCTAssertEqual(stream.peer, device.publicKey)
        stream.send(Data("one".utf8))
        stream.send(Data(repeating: 7, count: 200_000))
        stream.send(Data("three".utf8))

        var received: [Data] = []
        for try await frame in frames.frames {
            received.append(frame)
            if received.count == 3 { break }
        }
        XCTAssertEqual(received, [Data("one".utf8), Data(repeating: 7, count: 200_000), Data("three".utf8)])
        frames.cancel()
    }

    /// A channel carries frames both ways on one stream, so input needs no connection of its own.
    func testAChannelCarriesFramesBothWaysOnOneStream() async throws {
        let hub = LinkIdentity(), device = LinkIdentity()
        let opened = expectation(description: "channel opened")
        let heard = expectation(description: "device frames arrived")
        heard.expectedFulfillmentCount = 2
        let box = StreamBox(), requests = FrameBox(), incoming = FrameBox()
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }, handler: { _, request in
            requests.append(request)
            return .stream({ stream in
                box.stream = stream
                stream.onFrame { incoming.append($0); heard.fulfill() }
                opened.fulfill()
            })
        })
        try await server.start()
        addTeardownBlock { server.stop() }
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))

        let channel = try await LinkClient.channel(Data(#"{"open":1}"#.utf8), identity: device, hubKey: hub.publicKey, endpoints: [endpoint])
        channel.send(Data("click".utf8))
        channel.send(Data(repeating: 3, count: 100_000))
        await fulfillment(of: [opened, heard], timeout: 5)
        XCTAssertEqual(requests.frames, [Data(#"{"open":1}"#.utf8)])
        XCTAssertEqual(incoming.frames, [Data("click".utf8), Data(repeating: 3, count: 100_000)])

        let stream = try XCTUnwrap(box.stream)
        stream.send(Data([1, 2, 3]))
        for try await frame in channel.frames {
            XCTAssertEqual(frame, Data([1, 2, 3]))
            break
        }
        channel.cancel()
    }

    /// A Hub that refuses answers once instead of opening a stream; the device hears why.
    func testARefusedChannelSaysWhy() async throws {
        let hub = LinkIdentity()
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }, handler: { _, _ in
            .response(LinkProtocol.encode(LinkResponse.failure("That noodlet is not this bot's.")))
        })
        try await server.start()
        addTeardownBlock { server.stop() }
        let channel = try await LinkClient.channel(Data(#"{"open":1}"#.utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
                                                   endpoints: [LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))])
        defer { channel.cancel() }
        do {
            for try await _ in channel.frames { XCTFail("a refusal arrived as a frame") }
            XCTFail("a refusal ended the stream without an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That noodlet is not this bot's.")
        }
    }

    func testClosingTheStreamOnTheHubEndsItOnTheDevice() async throws {
        let hub = LinkIdentity()
        let box = StreamBox()
        let opened = expectation(description: "stream opened")
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }, handler: { _, _ in
            .stream({ stream in box.stream = stream; opened.fulfill() })
        })
        try await server.start()
        addTeardownBlock { server.stop() }
        let frames = try await LinkClient.subscribe(Data(), identity: LinkIdentity(), hubKey: hub.publicKey,
                                                    endpoints: [LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))])
        await fulfillment(of: [opened], timeout: 5)
        box.stream?.close()
        var count = 0
        do { for try await _ in frames.frames { count += 1 } } catch {}
        XCTAssertEqual(count, 0)
    }
}

final class StreamBox: @unchecked Sendable {
    var stream: LinkStream?
}

@MainActor final class HubPairingTests: XCTestCase {
    /// What the Hub lends is known at launch, before the Hub answers again.
    func testTheHubsLastAnswerSurvivesARelaunch() async throws {
        let hub = LinkIdentity()
        let harness = LinkHarness(provider: "codex", providerName: "Codex", profileName: nil)
        let port = LockedPort()
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }) { _, _ in
            .response(LinkProtocol.encode(.status(LinkStatus(hubName: "Studio", userName: "Petko", planName: "Family",
                harnesses: [harness], endpoints: [LinkEndpoint(host: "127.0.0.1", port: port.value)]))))
        }
        try await server.start()
        addTeardownBlock { server.stop() }
        port.value = try XCTUnwrap(server.port)
        let invitation = LinkInvitation(hubName: "Studio", hubKey: hub.publicKey,
                                        endpoints: [LinkEndpoint(host: "127.0.0.1", port: port.value)],
                                        userName: "Petko", token: "t", expires: Date().addingTimeInterval(600))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let pairing = HubPairing(directory: directory, deviceName: "iPhone")
        await pairing.join(invitation.url().absoluteString)
        XCTAssertNil(pairing.error)

        let relaunched = HubPairing(directory: directory, deviceName: "iPhone")

        XCTAssertEqual(relaunched.status?.harnesses, [harness])
        XCTAssertEqual(relaunched.status?.planName, "Family")
        relaunched.leave()
        XCTAssertNil(HubPairing(directory: directory, deviceName: "iPhone").status)
    }
}

private final class LockedPort: @unchecked Sendable {
    private let lock = NSLock()
    private var port: UInt16 = 0
    var value: UInt16 {
        get { lock.withLock { port } }
        set { lock.withLock { port = newValue } }
    }
}

final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []
    var frames: [Data] { lock.withLock { stored } }
    func append(_ frame: Data) { lock.withLock { stored.append(frame) } }
}
