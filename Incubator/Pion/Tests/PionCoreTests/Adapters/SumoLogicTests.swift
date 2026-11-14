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
}
