import Foundation
import XCTest
@testable import HubLink

/// A managed device reaches Hubs only at the addresses its manager allows.
@MainActor final class HubPairingPolicyTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run {
            HubPairing.allowsEndpoint = { _ in true }
            HubPairing.refusal = "This Noodle Hub isn't allowed on this device."
        }
    }

    func testOnlyAllowedAddressesAreTriedAndAHubWithNoneIsRefused() async throws {
        let home = LinkEndpoint(host: "192.168.1.4", port: 38_415), office = LinkEndpoint(host: "hub.example.com", port: 38_415)
        XCTAssertEqual(try HubPairing.allowed([home, office]), [home, office])
        HubPairing.allowsEndpoint = { $0.host.hasSuffix("example.com") }
        HubPairing.refusal = "Not here."
        XCTAssertEqual(try HubPairing.allowed([home, office]), [office])
        XCTAssertThrowsError(try HubPairing.allowed([home])) { XCTAssertEqual($0.localizedDescription, "Not here.") }

        let pairing = HubPairing(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                                 deviceName: "Mac")
        let invitation = LinkInvitation(hubName: "Office", hubKey: LinkIdentity().publicKey, endpoints: [home], userName: "Ada",
                                        joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date().addingTimeInterval(600))
        await pairing.join(invitation.url().absoluteString)
        XCTAssertEqual(pairing.error, "Not here.", "Refused before any address is tried")
        XCTAssertNil(pairing.hub)
    }
}
