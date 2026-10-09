import Foundation
@testable import HubLink
import Network
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

    /// An answer can outgrow a request, as a bot list carrying photo avatars does.
    func testTheDeviceTakesAnAnswerLargerThanARequest() async throws {
        let hub = LinkIdentity()
        let answer = Data(repeating: 7, count: 6 << 20)
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }) { _, _ in .response(answer) }
        try await server.start()
        addTeardownBlock { server.stop() }
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))
        let (response, _) = try await LinkClient.exchange(Data("bots".utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
                                                          endpoints: [endpoint])
        XCTAssertEqual(response, answer)
    }

    /// A request larger than a Hub reads fails at once, rather than waiting for an answer that never comes.
    func testARequestTooLargeFailsInsteadOfWaiting() async throws {
        let hub = LinkIdentity()
        let server = try await server(hub)
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))
        let attempt = Task {
            try await LinkClient.exchange(Data(repeating: 7, count: 3 * LinkQUIC.requestLimit), identity: LinkIdentity(),
                                          hubKey: hub.publicKey, endpoints: [endpoint])
        }
        let watchdog = Task {
            try await Task.sleep(for: .seconds(15))
            attempt.cancel()
        }
        defer { watchdog.cancel() }
        do {
            _ = try await attempt.value
            XCTFail("A Hub answered a request larger than it reads")
        } catch {
            XCTAssertFalse(error is CancellationError, "Still waiting after 15 seconds")
        }
    }

    /// A QUIC listener can be handed a stream that ends without a byte alongside a real one;
    /// it is not a request, so the handler never sees it.
    func testAStreamThatSendsNothingIsNotARequest() async throws {
        let hub = LinkIdentity(), requests = FrameBox()
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }) { _, request in
            requests.append(request)
            return .response(request)
        }
        try await server.start()
        addTeardownBlock { server.stop() }
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))
        _ = try? await LinkClient.exchange(Data(), identity: LinkIdentity(), hubKey: hub.publicKey, endpoints: [endpoint],
                                           timeout: .seconds(5))
        let (response, _) = try await LinkClient.exchange(Data("status".utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
                                                          endpoints: [endpoint])
        XCTAssertEqual(response, Data("status".utf8))
        XCTAssertEqual(requests.frames, [Data("status".utf8)])
    }

    /// Troubleshooting knocks on each address alone. A Hub that refuses this device's key still
    /// answered: the address reaches it.
    func testEachAddressIsTriedOnItsOwn() async throws {
        let hub = LinkIdentity()
        let refusing = try LinkServer(identity: hub, port: 0, admits: { _ in false }) { _, _ in .response(Data()) }
        try await refusing.start()
        addTeardownBlock { refusing.stop() }
        let open = try await server(hub)
        let silent = try await server(LinkIdentity())
        let silentPort = try XCTUnwrap(silent.port)
        silent.stop()
        let answering = LinkEndpoint(host: "::1", port: try XCTUnwrap(open.port))
        let refused = LinkEndpoint(host: "::1", port: try XCTUnwrap(refusing.port))
        let nothing = LinkEndpoint(host: "::1", port: silentPort)
        let answers = await LinkClient.probe([answering, refused, nothing], identity: LinkIdentity(), hubKey: hub.publicKey,
                                             timeout: .seconds(2))
        XCTAssertEqual(answers, [answering: true, refused: true, nothing: false])
    }

    /// Someone giving up on a Hub that does not answer is not kept waiting for the timeout.
    func testCancellingStopsWaitingForAHub() async throws {
        let silent = try await server(LinkIdentity())
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(silent.port))
        silent.stop()
        let started = Date()
        let attempt = Task {
            try await LinkClient.exchange(Data("status".utf8), identity: LinkIdentity(), hubKey: LinkIdentity().publicKey,
                                          endpoints: [endpoint], timeout: .seconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        attempt.cancel()
        do {
            _ = try await attempt.value
            XCTFail("A cancelled attempt answered")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
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
        let (_, used) = try await LinkClient.exchange(Data("status".utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
            endpoints: [LinkEndpoint(host: "unreachable.invalid", port: port), LinkEndpoint(host: "127.0.0.1", port: port)])
        XCTAssertEqual(used.host, "127.0.0.1")
    }

    /// A Hub that is not listening yet, as while it relaunches, is tried again until the timeout.
    func testTheDeviceReachesAHubThatStartsListeningAMomentLater() async throws {
        let hub = LinkIdentity()
        let earlier = try LinkServer(identity: hub, port: 0, admits: { _ in true }) { _, request in .response(request) }
        try await earlier.start()
        let port = try XCTUnwrap(earlier.port)
        earlier.stop()
        let late = try LinkServer(identity: hub, port: port, admits: { _ in true }) { _, request in .response(request) }
        addTeardownBlock { late.stop() }
        let listening = Task {
            try await Task.sleep(for: .milliseconds(500))
            try await late.start()
        }
        let (response, _) = try await LinkClient.exchange(Data("status".utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
                                                          endpoints: [LinkEndpoint(host: "::1", port: port)])
        try await listening.value
        XCTAssertEqual(response, Data("status".utf8))
    }

    /// Network.framework can pick a local port for a new Hub from a connection an earlier Hub on
    /// this Mac accepted, while that Hub still holds it, as when Hubs start and stop on one Mac.
    func testTheDeviceReachesAHubWhoseLocalPortIsTaken() async throws {
        let earlier = LinkIdentity(), hub = LinkIdentity(), device = LinkIdentity()
        let first = try await server(earlier)
        let firstEndpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(first.port))
        let used = try await localPort(to: firstEndpoint, identity: device, hubKey: earlier.publicKey)
        // The device's port frees a moment after its connection closes.
        var server: LinkServer?
        for _ in 0..<40 where server == nil {
            let candidate = try LinkServer(identity: hub, port: used, admits: { _ in true }) { key, request in .response(key.x963 + request) }
            do {
                try await candidate.start()
                server = candidate
            } catch {
                candidate.stop()
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let started = try XCTUnwrap(server)
        addTeardownBlock { started.stop() }

        let (response, _) = try await LinkClient.exchange(Data("status".utf8), identity: device, hubKey: hub.publicKey,
                                                          endpoints: [LinkEndpoint(host: "::1", port: used)], timeout: .seconds(3))
        XCTAssertEqual(response, device.publicKey.x963 + Data("status".utf8))
    }

    private func localPort(to endpoint: LinkEndpoint, identity: LinkIdentity, hubKey: LinkPublicKey) async throws -> UInt16 {
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: try XCTUnwrap(NWEndpoint.Port(rawValue: endpoint.port)),
                                      using: try LinkQUIC.parameters(identity: identity) { $0 == hubKey })
        defer { connection.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard case .hostPort(_, let port) = connection.currentPath?.localEndpoint else {
                        return once.run { continuation.resume(throwing: LinkError("No local port.")) }
                    }
                    once.run { continuation.resume(returning: port.rawValue) }
                case .failed(let error), .waiting(let error): once.run { continuation.resume(throwing: error) }
                default: break
                }
            }
            connection.start(queue: LinkQUIC.queue)
        }
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
        stream.send(Data(repeating: 8, count: 3 << 20))

        var received: [Data] = []
        for try await frame in frames.frames {
            received.append(frame)
            if received.count == 4 { break }
        }
        XCTAssertEqual(received, [Data("one".utf8), Data(repeating: 7, count: 200_000), Data("three".utf8),
                                  Data(repeating: 8, count: 3 << 20)])
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

    /// Nothing listening on a channel, as on a subscription, keeps what the device sends only so
    /// far: past that the Hub ends the stream rather than hold more.
    func testTheHubEndsAChannelWhoseUnreadFramesPileUp() async throws {
        let hub = LinkIdentity()
        let opened = expectation(description: "channel opened")
        let ended = expectation(description: "channel ended")
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }, handler: { _, _ in
            .stream({ stream in
                stream.onClose { ended.fulfill() }
                opened.fulfill()
            })
        })
        try await server.start()
        addTeardownBlock { server.stop() }
        let channel = try await LinkClient.channel(Data(#"{"open":1}"#.utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
                                                   endpoints: [LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))])
        defer { channel.cancel() }
        await fulfillment(of: [opened], timeout: 5)
        for _ in 0..<(LinkStream.unreadLimit / 100_000 + 2) { channel.send(Data(repeating: 7, count: 100_000)) }
        await fulfillment(of: [ended], timeout: 5)
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
        let frames = try await LinkClient.subscribe(Data("subscribe".utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
                                                    endpoints: [LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))])
        await fulfillment(of: [opened], timeout: 5)
        box.stream?.close()
        var count = 0
        do { for try await _ in frames.frames { count += 1 } } catch {}
        XCTAssertEqual(count, 0)
    }

    /// A Hub that says why and closes at once, as a live view that cannot open does, still gets
    /// its last words to the device.
    func testTheLastFrameBeforeTheHubClosesArrives() async throws {
        let hub = LinkIdentity()
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }, handler: { _, _ in
            .stream({ stream in
                stream.send(Data("opened".utf8))
                Task {
                    try? await Task.sleep(for: .milliseconds(20))
                    stream.send(Data("failed".utf8))
                    stream.close()
                }
            })
        })
        try await server.start()
        addTeardownBlock { server.stop() }
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))
        for attempt in 0..<30 {
            let channel = try await LinkClient.channel(Data(#"{"open":1}"#.utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
                                                       endpoints: [endpoint])
            defer { channel.cancel() }
            var frames: [Data] = []
            do { for try await frame in channel.frames { frames.append(frame) } } catch {
                XCTFail("attempt \(attempt) ended with \(error) after \(frames.count) frames")
            }
            XCTAssertEqual(frames, [Data("opened".utf8), Data("failed".utf8)], "attempt \(attempt)")
        }
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
                                        userName: "Petko", joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date().addingTimeInterval(600))
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

/// An admin's list of users against a Hub that answers what this Noodle does not expect.
@MainActor final class HubUsersTests: XCTestCase {
    /// A Hub that pairs the device, then answers every other request with `done`.
    private func paired() async throws -> HubPairing {
        let hub = LinkIdentity()
        let port = LockedPort()
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }) { _, request in
            if case .success(.enroll) = LinkProtocol.decode(request) {
                return .response(LinkProtocol.encode(.status(LinkStatus(hubName: "Studio", userName: "Grace", planName: "Default",
                    harnesses: [], endpoints: [LinkEndpoint(host: "127.0.0.1", port: port.value)], isAdmin: true))))
            }
            return .response(LinkProtocol.encode(.done))
        }
        try await server.start()
        addTeardownBlock { server.stop() }
        port.value = try XCTUnwrap(server.port)
        let invitation = LinkInvitation(hubName: "Studio", hubKey: hub.publicKey,
                                        endpoints: [LinkEndpoint(host: "127.0.0.1", port: port.value)],
                                        userName: "Grace", joinKey: LinkIdentity().privateKey.rawRepresentation,
                                        expires: Date().addingTimeInterval(600))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let pairing = HubPairing(directory: directory, deviceName: "iPhone")
        await pairing.join(invitation.url().absoluteString)
        XCTAssertNil(pairing.error)
        return pairing
    }

    private let unknown = "This Noodle Hub sent an answer this Noodle does not know. Update Noodle."

    func testAnInvitationTheHubDidNotSendSaysSo() async throws {
        let users = HubUsers(pairing: try await paired())
        let invitation = await users.invite(LinkUser(id: UUID(), name: "Ada", plan: UUID(), canPairDevices: true, isAdmin: false, devices: []))
        XCTAssertNil(invitation)
        XCTAssertEqual(users.error, unknown)
    }

    func testAListTheHubDidNotSendSaysSo() async throws {
        let users = HubUsers(pairing: try await paired())
        await users.load()
        XCTAssertTrue(users.isLoaded)
        XCTAssertEqual(users.users, [])
        XCTAssertEqual(users.error, unknown)
    }

    func testAUserTheHubDidNotSendBackIsNotAdded() async throws {
        let users = HubUsers(pairing: try await paired())
        let added = await users.add(named: "Bea")
        XCTAssertNil(added)
        XCTAssertEqual(users.error, unknown)
    }
}

/// A device keeps one connection to its Hub and opens a stream on it for each request, so only
/// the first request waits for a handshake.
final class LinkSessionTests: XCTestCase {
    private func echo(_ hub: LinkIdentity, port: UInt16 = 0) async throws -> LinkServer {
        let server = try LinkServer(identity: hub, port: port, admits: { _ in true }) { _, request in
            request == Data("subscribe".utf8) ? .stream { _ in } : .response(request)
        }
        try await server.start()
        addTeardownBlock { server.stop() }
        return server
    }

    /// QUIC lets a peer open only as many streams as the other side allows, and Network.framework
    /// never raises the first allowance, which let a connection carry seven.
    func testTheHubTakesManyStreamsOnOneConnection() async throws {
        let hub = LinkIdentity(), device = LinkIdentity()
        let server = try await echo(hub)
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: try XCTUnwrap(server.port)))
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: .hostPort(host: "::1", port: port)),
                                      using: try LinkQUIC.parameters(identity: device) { $0 == hub.publicKey })
        group.newConnectionHandler = { $0.cancel() }
        defer { group.cancel() }
        try await within(.seconds(5)) {
            await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
                let once = Once()
                group.stateUpdateHandler = { if case .ready = $0 { once.run { ready.resume() } } }
                group.start(queue: LinkQUIC.queue)
            }
        }
        for n in 0..<20 {
            let stream = try XCTUnwrap(NWConnection(from: group))
            try await within(.seconds(3)) {
                await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
                    let once = Once()
                    stream.stateUpdateHandler = { if case .ready = $0 { once.run { ready.resume() } } }
                    stream.start(queue: LinkQUIC.queue)
                }
            }
            try await LinkQUIC.send(Data("request \(n)".utf8), on: stream)
            let answer = try await LinkQUIC.receive(stream, limit: 1 << 10)
            XCTAssertEqual(answer, Data("request \(n)".utf8))
            stream.cancel()
        }
    }

    /// Requests, a subscription and a channel all ride the one connection.
    func testRequestsShareOneConnection() async throws {
        let hub = LinkIdentity(), device = LinkIdentity()
        let server = try await echo(hub)
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))
        for n in 0..<20 {
            let (answer, _) = try await LinkClient.exchange(Data("request \(n)".utf8), identity: device, hubKey: hub.publicKey,
                                                            endpoints: [endpoint])
            XCTAssertEqual(answer, Data("request \(n)".utf8))
        }
        let events = try await LinkClient.subscribe(Data("subscribe".utf8), identity: device, hubKey: hub.publicKey, endpoints: [endpoint])
        defer { events.cancel() }
        let channel = try await LinkClient.channel(Data("subscribe".utf8), identity: device, hubKey: hub.publicKey, endpoints: [endpoint])
        defer { channel.cancel() }
        XCTAssertEqual(LinkSessions.handshakes(to: hub.publicKey), 1)
    }

    /// Video can fill the link, and answers queued behind it on the same connection would wait,
    /// so a channel that asks for it gets a connection of its own.
    func testAChannelOfItsOwnGetsItsOwnConnection() async throws {
        let hub = LinkIdentity(), device = LinkIdentity()
        let server = try await echo(hub)
        let endpoint = LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))
        _ = try await LinkClient.exchange(Data("status".utf8), identity: device, hubKey: hub.publicKey, endpoints: [endpoint])
        let video = try await LinkClient.channel(Data("subscribe".utf8), identity: device, hubKey: hub.publicKey,
                                                 endpoints: [endpoint], ownConnection: true)
        defer { video.cancel() }
        _ = try await LinkClient.exchange(Data("status".utf8), identity: device, hubKey: hub.publicKey, endpoints: [endpoint])
        XCTAssertEqual(LinkSessions.handshakes(to: hub.publicKey), 1)
    }

    /// A Hub that relaunched has forgotten the connection; the device notices it stopped hearing
    /// from it and connects again instead of waiting on a connection that is gone.
    func testRequestsReachAHubThatRelaunched() async throws {
        let hub = LinkIdentity(), device = LinkIdentity()
        let first = try await echo(hub)
        let port = try XCTUnwrap(first.port)
        let endpoint = LinkEndpoint(host: "::1", port: port)
        _ = try await LinkClient.exchange(Data("before".utf8), identity: device, hubKey: hub.publicKey, endpoints: [endpoint])
        first.stop()
        try await Task.sleep(for: .seconds(LinkSession.trust + 1))
        _ = try await echo(hub, port: port)
        let answer = try await within(.seconds(10)) {
            try await LinkClient.exchange(Data("after".utf8), identity: device, hubKey: hub.publicKey, endpoints: [endpoint]).response
        }
        XCTAssertEqual(answer, Data("after".utf8))
        XCTAssertEqual(LinkSessions.handshakes(to: hub.publicKey), 2)
    }
}

/// Fails instead of waiting past `limit`, leaving `body` to itself, since a wait on the network
/// may not end when cancelled.
func within<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let once = Once()
        let work = Task {
            do {
                let value = try await body()
                once.run { continuation.resume(returning: value) }
            } catch {
                once.run { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: limit)
            once.run { continuation.resume(throwing: LinkError("Still waiting after \(limit).")) }
            work.cancel()
        }
    }
}
