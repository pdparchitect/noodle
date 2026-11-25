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

    func testCheckAccessReadsTheCreditsLeftWithoutSpendingOne() async throws {
        let service = FakeService()
        service.answers["/v3/accounts/users/credits"] = (200, #"{"result":{"balance":87,"resets_at":"2026-12-01T00:00:00Z"}}"#)
        let access = try await callTool(Censys.adapter, "check-access", "{}", on: service, in: censys)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("✓ Token: it works; 87 credits are left, renewed 2026-12-01"), access.text)
        XCTAssertEqual(service.requests.first?.url?.absoluteString, "https://api.platform.censys.io/v3/accounts/users/credits")
    }

    func testCheckAccessSaysWhatToChangeForATokenCensysRefuses() async throws {
        let service = FakeService()
        service.answers["/v3/accounts/users/credits"] = (401, #"{"error":"unauthorized"}"#)
        let access = try await callTool(Censys.adapter, "check-access", "{}", on: service, in: censys)
        XCTAssertTrue(access.text.contains("✗ Token: Censys did not accept the token"), access.text)
        XCTAssertTrue(access.text.contains("personal access token"), access.text)
    }
}
