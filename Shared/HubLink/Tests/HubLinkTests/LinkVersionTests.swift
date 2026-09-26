import Foundation
@testable import HubLink
import XCTest

final class LinkVersionTests: XCTestCase {
    private func request(version: Int, body: String = #"{"status":{}}"#) -> Data {
        Data(#"{"version":\#(version),"request":\#(body)}"#.utf8)
    }

    func testRequestsCarryTheirVersion() throws {
        let data = try LinkProtocol.encode(.bots)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, LinkProtocol.version)
        XCTAssertEqual(try LinkProtocol.decode(data).get(), .bots)
    }

    func testAHubNamesTheAppToUpdate() {
        XCTAssertEqual(LinkProtocol.decode(request(version: LinkProtocol.version + 1)).failure?.message,
                       "This device needs a newer Noodle Hub. Update Noodle Hub.")
        XCTAssertEqual(LinkProtocol.decode(request(version: 0)).failure?.message,
                       "This Noodle Hub needs a newer Noodle. Update Noodle.")
        XCTAssertEqual(LinkProtocol.decode(request(version: LinkProtocol.version, body: #"{"teleport":{}}"#)).failure?.message,
                       "This Noodle Hub does not know that request. Update Noodle Hub.")
    }

    func testUnknownEventsAreSkipped() {
        XCTAssertNil(LinkProtocol.decodeEvent(Data(#"{"fireworks":{}}"#.utf8)))
        XCTAssertEqual(LinkProtocol.decodeEvent(LinkProtocol.encode(.botsChanged)), .botsChanged)
    }

    func testInvitationsFromANewerHubAskForANewerNoodle() {
        let invitation = LinkInvitation(hubName: "Hub", hubKey: LinkIdentity().publicKey, endpoints: [], userName: "Ada",
                                        joinKey: LinkIdentity().privateKey.rawRepresentation, expires: Date(), version: LinkProtocol.version + 1)
        XCTAssertThrowsError(try LinkInvitation(text: invitation.url().absoluteString)) { error in
            XCTAssertEqual((error as? LinkError)?.message, "This invitation needs a newer Noodle. Update Noodle.")
        }
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { error } else { nil } }
}
