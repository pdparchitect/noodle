import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class CensysTests: XCTestCase {
    private let censys = try! Censys.preset.makeConnection(name: "Censys")

    func testAHostsServicesFromThePlatformAPI() async throws {
        XCTAssertEqual(censys.endpoint.absoluteString, "https://api.platform.censys.io/v3/global")
        XCTAssertEqual(censys.tokenHeader, "Authorization")
        XCTAssertNil(censys.tokenScheme, "a personal access token goes as a bearer token")
        let service = FakeService()
        service.answers["/v3/global/asset/host/203.0.113.77"] = (200, #"{"result":{"resource":{"ip":"203.0.113.77","autonomous_system":{"asn":64500,"name":"EXAMPLE-HOSTING"},"location":{"country":"Netherlands","city":"Amsterdam"},"services":[{"port":443,"protocol":"HTTP","transport_protocol":"tcp"},{"port":22,"protocol":"SSH","transport_protocol":"tcp"}],"dns":{"names":["mail.kestrel-logistlcs.example"]}}}}"#)
        let host = try await callTool(Censys.adapter, "host", #"{"ip":"203.0.113.77"}"#, on: service, in: censys)
        XCTAssertFalse(host.isError, host.text)
        XCTAssertTrue(host.text.contains("443/HTTP"), host.text)
        XCTAssertTrue(host.text.contains("EXAMPLE-HOSTING"), host.text)
        XCTAssertNotNil(PionAdapters.all["censys"])
    }
}
