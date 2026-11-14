import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class GreyNoiseTests: XCTestCase {
    private let connection = try! GreyNoise.preset.makeConnection(name: "GreyNoise")

    func testAnAddressSaysWhetherItIsInternetNoise() async throws {
        XCTAssertEqual(connection.endpoint.absoluteString, "https://api.greynoise.io/v3")
        XCTAssertEqual(connection.tokenHeader, "key")
        let service = FakeService()
        service.answers["/v3/community/203.0.113.77"] = (200, #"{"ip":"203.0.113.77","noise":true,"riot":false,"classification":"malicious","name":"unknown","link":"https://viz.greynoise.io/ip/203.0.113.77","last_seen":"2026-11-14","message":"Success"}"#)
        let seen = try await callTool(GreyNoise.adapter, "ip-context", #"{"ip":"203.0.113.77"}"#, on: service, in: connection)
        XCTAssertFalse(seen.isError, seen.text)
        XCTAssertTrue(seen.text.contains("scanning the internet"), seen.text)
        XCTAssertTrue(seen.text.contains("malicious"), seen.text)
        let unseen = try await callTool(GreyNoise.adapter, "ip-context", #"{"ip":"192.0.2.1"}"#, on: service, in: connection)
        XCTAssertFalse(unseen.isError, "an address GreyNoise has not seen is a finding, not a failure")
        XCTAssertTrue(unseen.text.contains("has not seen"), unseen.text)
        XCTAssertNotNil(PionAdapters.all["greynoise"])
    }
}
