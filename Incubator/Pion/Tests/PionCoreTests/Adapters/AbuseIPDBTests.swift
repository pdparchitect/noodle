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

    func testCheckAccessSpendsOneCheckAndSaysHowManyAreLeft() async throws {
        let service = FakeService()
        service.answers["/api/v2/check"] = (200, #"{"data":{"ipAddress":"127.0.0.1","isPublic":false,"abuseConfidenceScore":0}}"#)
        service.responseHeaders = ["X-RateLimit-Limit": "1000", "X-RateLimit-Remaining": "998"]
        let access = try await callTool(AbuseIPDB.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("✓ API key: it works; 998 of today's 1000 checks are left"), access.text)
        XCTAssertEqual(queryItems(service.requests.first)["ipAddress"], "127.0.0.1")
        XCTAssertEqual(service.requests.count, 1)
    }

    func testCheckAccessSaysWhatToChangeForAKeyAbuseIPDBRefuses() async throws {
        let service = FakeService()
        service.answers["/api/v2/check"] = (401, #"{"errors":[{"detail":"Authentication failed. Your API key is either missing, incorrect, or revoked.","status":401}]}"#)
        let access = try await callTool(AbuseIPDB.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertTrue(access.text.contains("✗ API key: AbuseIPDB did not accept the key"), access.text)
        XCTAssertTrue(access.text.contains("Account › API"), access.text)
    }
}
