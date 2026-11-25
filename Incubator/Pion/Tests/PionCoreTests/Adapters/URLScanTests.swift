import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class URLScanTests: XCTestCase {
    private let connection = try! URLScan.preset.makeConnection(name: "urlscan")

    func testPastScansAreSearchedWithoutSubmittingAnything() async throws {
        XCTAssertEqual(connection.endpoint.absoluteString, "https://urlscan.io/api/v1")
        XCTAssertEqual(connection.tokenHeader, "API-Key")
        let service = FakeService()
        service.answers["/api/v1/search"] = (200, #"{"total":1,"results":[{"_id":"u1","task":{"url":"https://payroll-kestrel.example/login","time":"2026-11-13T16:30:00.000Z"},"page":{"domain":"payroll-kestrel.example","ip":"203.0.113.77","country":"NL","title":"Sign in to your account","status":"200"},"verdicts":{"overall":{"malicious":true,"score":100}},"result":"https://urlscan.io/api/v1/result/u1/","screenshot":"https://urlscan.io/screenshots/u1.png"}]}"#)
        let result = try await callTool(URLScan.adapter, "search", #"{"query":"domain:payroll-kestrel.example","limit":10}"#, on: service, in: connection)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("malicious"), result.text)
        XCTAssertTrue(result.text.contains("Sign in to your account"), result.text)
        XCTAssertEqual(queryItems(service.requests.first), ["q": "domain:payroll-kestrel.example", "size": "10"])
        XCTAssertEqual(service.requests.first?.httpMethod, "GET")
        XCTAssertTrue(service.requests.first?.url?.absoluteString.hasPrefix("https://urlscan.io/api/v1/search/?") == true,
                      "without the slash urlscan redirects, which is not followed")
        XCTAssertNotNil(PionAdapters.all["urlscan"])
    }

    func testCheckAccessSaysHowManySearchesAreLeft() async throws {
        let service = FakeService()
        service.answers["/api/v1/quotas"] = (200, #"{"scope":"user","limits":{"search":{"minute":{"limit":120,"used":1,"remaining":119},"hour":{"limit":1000,"used":10,"remaining":990},"day":{"limit":1000,"used":10,"remaining":990}},"public":{"day":{"limit":5000,"used":0,"remaining":5000}}}}"#)
        let access = try await callTool(URLScan.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("✓ API key: it works; searches left: 119 of 120 this minute, 990 of 1000 this hour, 990 of 1000 this day"), access.text)
    }

    func testCheckAccessSaysWhatToChangeForAKeyURLScanRefuses() async throws {
        let service = FakeService()
        service.answers["/api/v1/quotas"] = (401, #"{"message":"Unauthorized","status":401}"#)
        let access = try await callTool(URLScan.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertTrue(access.text.contains("✗ API key: urlscan.io did not accept the key"), access.text)
        XCTAssertTrue(access.text.contains("Settings & API › API Keys"), access.text)
    }
}
