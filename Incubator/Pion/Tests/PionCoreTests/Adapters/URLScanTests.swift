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
}
