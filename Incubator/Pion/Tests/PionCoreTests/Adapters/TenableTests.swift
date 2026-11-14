import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class TenableTests: XCTestCase {
    private let tenable = try! Tenable.preset.makeConnection(name: "Tenable")

    func testAnAssetsVulnerabilitiesByIP() async throws {
        XCTAssertEqual(tenable.endpoint.absoluteString, "https://cloud.tenable.com")
        XCTAssertEqual(tenable.tokenHeader, "X-ApiKeys")
        guard case .connection(let configuration) = Tenable.preset.configuration else { return XCTFail() }
        XCTAssertEqual(try configuration.composedToken?.compose("A1", "S1"), "accessKey=A1;secretKey=S1")
        let service = FakeService()
        service.answers["/workbenches/assets"] = (200, #"{"assets":[{"id":"a-1","ipv4":["10.0.4.23"],"fqdn":["lt-0423.kestrel.example"],"operating_system":["Windows 11"],"last_seen":"2026-11-14T06:00:00Z"}]}"#)
        service.answers["/workbenches/assets/a-1/vulnerabilities"] = (200, #"{"vulnerabilities":[{"plugin_id":12345,"plugin_name":"OpenSSH < 9.8 RCE (regreSSHion)","severity":4,"count":1,"vulnerability_state":"Active"}]}"#)
        let result = try await callTool(Tenable.adapter, "asset-vulnerabilities", #"{"ip":"10.0.4.23"}"#, on: service, in: tenable)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("lt-0423.kestrel.example"), result.text)
        XCTAssertTrue(result.text.contains("critical"), result.text)
        XCTAssertTrue(result.text.contains("regreSSHion"), result.text)
        let sent = queryItems(service.requests.first)
        XCTAssertEqual(sent["filter.0.filter"], "ipv4")
        XCTAssertEqual(sent["filter.0.quality"], "eq")
        XCTAssertEqual(sent["filter.0.value"], "10.0.4.23")
        XCTAssertNotNil(PionAdapters.all["tenable"])
    }
}
