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

    func testCheckAccessTriesTheWorkbenchAndSaysWhoseKeysTheyAre() async throws {
        let service = FakeService()
        service.answers["/workbenches/assets"] = (200, #"{"assets":[],"total":0}"#)
        service.answers["/session"] = (200, #"{"username":"pion@kestrel.example","permissions":16,"container_name":"Kestrel"}"#)
        let access = try await callTool(Tenable.adapter, "check-access", "{}", on: service, in: tenable)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("✓ Keys and the asset workbench"), access.text)
        XCTAssertTrue(access.text.contains("The keys belong to pion@kestrel.example, with the Basic role, in Kestrel."), access.text)
        XCTAssertEqual(queryItems(service.requests.first)["filter.0.value"], "192.0.2.1")
    }

    func testCheckAccessSaysWhatToChangeForRefusedKeysOrARoleWithoutAccess() async throws {
        let service = FakeService()
        service.answers["/workbenches/assets"] = (401, #"{"statusCode":401,"error":"Unauthorized","message":"Invalid Credentials"}"#)
        let wrong = try await callTool(Tenable.adapter, "check-access", "{}", on: service, in: tenable)
        XCTAssertTrue(wrong.text.contains("✗ Keys and the asset workbench: Tenable did not accept the keys"), wrong.text)
        XCTAssertEqual(service.requests.count, 1)
        service.answers["/workbenches/assets"] = (403, #"{"statusCode":403,"error":"Forbidden","message":"You do not have permission to view this resource"}"#)
        let role = try await callTool(Tenable.adapter, "check-access", "{}", on: service, in: tenable)
        XCTAssertTrue(role.text.contains("give it the Basic role or higher, with Can View on the assets"), role.text)
    }
}
