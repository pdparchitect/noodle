import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class SumoLogicTests: XCTestCase {
    private let sumo = try! SumoLogic.preset.makeConnection(name: "Sumo Logic", values: ["deployment": "api.eu.sumologic.com"])

    func testASearchJobRunsWithItsCookieAndIsRemovedAfter() async throws {
        XCTAssertEqual(sumo.endpoint.absoluteString, "https://api.eu.sumologic.com/api/v1")
        XCTAssertEqual(sumo.tokenScheme, "Basic")
        let service = FakeService()
        service.responseHeaders = ["Set-Cookie": "AWSALB=node-7; Path=/"]
        service.answers["/api/v1/search/jobs"] = (202, #"{"id":"J1"}"#)
        service.answers["/api/v1/search/jobs/J1"] = (200, #"{"state":"DONE GATHERING RESULTS","messageCount":1,"recordCount":0}"#)
        service.answers["/api/v1/search/jobs/J1/messages"] = (200, #"{"fields":[{"name":"_messagetime"},{"name":"src_ip"}],"messages":[{"map":{"_messagetime":"1763110800000","src_ip":"203.0.113.77"}}]}"#)
        let rows = try await callTool(SumoLogic.adapter, "search", #"{"query":"_sourceCategory=auth | where src_ip=\"203.0.113.77\"","since":"2026-11-13T00:00:00Z"}"#, on: service, in: sumo)
        XCTAssertFalse(rows.isError, rows.text)
        XCTAssertTrue(rows.text.contains("203.0.113.77"), rows.text)
        let start = try XCTUnwrap(service.requests.first)
        XCTAssertEqual(start.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: start.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body["from"], "2026-11-13T00:00:00Z")
        XCTAssertEqual(body["timeZone"], "UTC")
        XCTAssertTrue(service.requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "AWSALB=node-7" },
                      "a later request of the job went without its cookie")
        XCTAssertEqual(service.requests.last?.httpMethod, "DELETE")
        XCTAssertNotNil(PionAdapters.all["sumologic"])
    }

    func testCheckAccessStartsOneSearchOverTheLastMinuteAndRemovesIt() async throws {
        let service = FakeService()
        service.answers["/api/v1/search/jobs"] = (202, #"{"id":"6F1B2C3D","link":{"rel":"self","href":"https://api.eu.sumologic.com/api/v1/search/jobs/6F1B2C3D"}}"#)
        service.answers["/api/v1/search/jobs/6F1B2C3D"] = (200, "{}")
        let access = try await callTool(SumoLogic.adapter, "check-access", "{}", on: service, in: sumo)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("Sumo Logic deployment EU"), access.text)
        XCTAssertTrue(access.text.contains("✓ Search jobs: the key may search"), access.text)
        XCTAssertEqual(service.requests.map(\.httpMethod), ["POST", "DELETE"])
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(service.requests.first?.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["query"] as? String, "* | limit 1")
    }

    func testCheckAccessSaysWhatToChangeWhenSumoRefusesTheKeyOrSearching() async throws {
        let service = FakeService()
        service.answers["/api/v1/search/jobs"] = (401, #"{"status":401,"id":"X","code":"unauthorized","message":"Credential could not be verified."}"#)
        let wrong = try await callTool(SumoLogic.adapter, "check-access", "{}", on: service, in: sumo)
        XCTAssertTrue(wrong.text.contains("✗ Search jobs: Sumo Logic did not accept the access ID and key"), wrong.text)
        service.answers["/api/v1/search/jobs"] = (403, #"{"status":403,"code":"forbidden","message":"Forbidden"}"#)
        let plan = try await callTool(SumoLogic.adapter, "check-access", "{}", on: service, in: sumo)
        XCTAssertTrue(plan.text.contains("✗ Search jobs: Sumo Logic refused searching through the API"), plan.text)
        XCTAssertTrue(plan.text.contains("Enterprise"), plan.text)
        XCTAssertEqual(service.requests.count, 2, "nothing to remove when no job started")
    }
}
