import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class AbuseIPDBTests: XCTestCase {
    private let connection = try! AbuseIPDB.preset.makeConnection(name: "AbuseIPDB")

    func testAnAddressIsCheckedWithTheKeyHeader() async throws {
        XCTAssertEqual(connection.endpoint.absoluteString, "https://api.abuseipdb.com/api/v2")
        XCTAssertEqual(connection.tokenHeader, "Key")
        let service = FakeService()
        service.answers["/api/v2/check"] = (200, #"{"data":{"ipAddress":"203.0.113.77","isPublic":true,"abuseConfidenceScore":87,"countryCode":"NL","usageType":"Data Center/Web Hosting/Transit","isp":"Example Hosting","domain":"example-hosting.net","hostnames":[],"isTor":false,"totalReports":42,"numDistinctUsers":17,"lastReportedAt":"2026-11-14T06:00:00+00:00"}}"#)
        let result = try await callTool(AbuseIPDB.adapter, "check-ip", #"{"ip":"203.0.113.77","days":30}"#, on: service, in: connection)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("87%"), result.text)
        XCTAssertTrue(result.text.contains("42 reports from 17 users"), result.text)
        XCTAssertEqual(queryItems(service.requests.first), ["ipAddress": "203.0.113.77", "maxAgeInDays": "30"])
        let refused = try await callTool(AbuseIPDB.adapter, "check-ip", #"{"ip":"nope"}"#, on: service, in: connection)
        XCTAssertTrue(refused.isError)
        XCTAssertNotNil(PionAdapters.all["abuseipdb"])
    }
}
