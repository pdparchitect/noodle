import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class OTXTests: XCTestCase {
    private let connection = try! OTX.preset.makeConnection(name: "OTX")

    func testAnIndicatorsKindIsWorkedOutAndItsPulsesListed() async throws {
        XCTAssertEqual(connection.endpoint.absoluteString, "https://otx.alienvault.com/api/v1")
        XCTAssertEqual(connection.tokenHeader, "X-OTX-API-KEY")
        let service = FakeService()
        let pulses = #"{"reputation":0,"country_name":"Netherlands","pulse_info":{"count":2,"pulses":[{"name":"Payroll phishing kit","created":"2026-11-12T10:00:00","tags":["phishing"],"adversary":"","malware_families":[{"display_name":"EvilProxy"}]}]}}"#
        service.answers["/api/v1/indicators/IPv4/203.0.113.77/general"] = (200, pulses)
        service.answers["/api/v1/indicators/domain/payroll-kestrel.example/general"] = (200, pulses)
        service.answers["/api/v1/indicators/file/\(String(repeating: "ab", count: 32))/general"] = (200, pulses)
        for indicator in ["203.0.113.77", "payroll-kestrel.example", String(repeating: "ab", count: 32)] {
            let result = try await callTool(OTX.adapter, "indicator", #"{"indicator":"\#(indicator)"}"#, on: service, in: connection)
            XCTAssertFalse(result.isError, result.text)
            XCTAssertTrue(result.text.contains("2 pulses"), result.text)
            XCTAssertTrue(result.text.contains("EvilProxy"), result.text)
        }
        XCTAssertNotNil(PionAdapters.all["otx"])
    }

    func testCheckAccessSaysWhoseKeyItIs() async throws {
        let service = FakeService()
        service.answers["/api/v1/users/me"] = (200, #"{"username":"kestrel-soc","pulse_count":0}"#)
        let access = try await callTool(OTX.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("✓ API key: it belongs to the OTX user kestrel-soc"), access.text)
    }

    func testCheckAccessTakesARefusalAsAWrongKey() async throws {
        let service = FakeService()
        service.answers["/api/v1/users/me"] = (403, #"{"detail":"Authentication required"}"#)
        let access = try await callTool(OTX.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertTrue(access.text.contains("✗ API key: OTX did not accept the key"), access.text)
        XCTAssertTrue(access.text.contains("otx.alienvault.com/api"), access.text)
    }
}
