import Foundation
@testable import HubLink
import XCTest

final class LinkTransportTests: XCTestCase {
    private func server(_ identity: LinkIdentity) async throws -> LinkServer {
        let server = try LinkServer(identity: identity, port: 0) { key, request in
            key.x963 + request
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

    func testTheFirstReachableEndpointWins() async throws {
        let hub = LinkIdentity()
        let server = try await server(hub)
        let port = try XCTUnwrap(server.port)
        let (_, used) = try await LinkClient.exchange(Data(), identity: LinkIdentity(), hubKey: hub.publicKey,
            endpoints: [LinkEndpoint(host: "unreachable.invalid", port: port), LinkEndpoint(host: "127.0.0.1", port: port)])
        XCTAssertEqual(used.host, "127.0.0.1")
    }
}
