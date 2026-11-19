import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class SentinelTests: XCTestCase {
    private let sentinel = try! Sentinel.preset.makeConnection(name: "Sentinel",
        values: ["tenant": "contoso.onmicrosoft.com", "workspace": "8a7f3c2e-0000-4000-8000-000000000002"])

    func testAWorkspaceIsQueriedWithTokensForLogAnalytics() {
        XCTAssertEqual(sentinel.endpoint.absoluteString, "https://api.loganalytics.azure.com/v1/workspaces/8a7f3c2e-0000-4000-8000-000000000002")
        XCTAssertEqual(sentinel.clientCredentials?.tokenEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token")
        XCTAssertEqual(sentinel.clientCredentials?.scope, "https://api.loganalytics.io/.default")
        XCTAssertNotNil(PionAdapters.all["sentinel"])
    }

    func testSentinelRunsKQLOverItsWorkspace() async throws {
        let service = FakeService()
        service.answers["/v1/workspaces/8a7f3c2e-0000-4000-8000-000000000002/query"] = (200, #"{"tables":[{"name":"PrimaryResult","columns":[{"name":"TimeGenerated","type":"datetime"},{"name":"IPAddress","type":"string"}],"rows":[["2026-11-14T09:06:00Z","203.0.113.77"]]}]}"#)
        let found = try await callTool(Sentinel.adapter, "query", #"{"query":"SigninLogs | where ResultType != 0 | take 10"}"#, on: service, in: sentinel)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("203.0.113.77"), found.text)
        let body = try JSONSerialization.jsonObject(with: service.requests.first?.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["query": "SigninLogs | where ResultType != 0 | take 10", "timespan": "P7D"])
    }

    func testItsTriggerFindsHighSeverityIncidentsSinceATime() async throws {
        let service = FakeService()
        service.answers["/v1/workspaces/8a7f3c2e-0000-4000-8000-000000000002/query"] = (200, #"{"tables":[{"name":"PrimaryResult","columns":[{"name":"IncidentNumber","type":"int"},{"name":"CreatedTime","type":"datetime"}],"rows":[[42,"2026-11-19T09:14:00.123Z"],[41,"2026-11-19T09:11:00Z"]]}]}"#)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let incidents = try await Sentinel.adapter.alerts(since: since, connection: sentinel, access: service)
        XCTAssertEqual(incidents.map(\.id), ["42", "41"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: service.requests.last?.httpBody ?? Data()) as? [String: String])
        XCTAssertTrue(body["query"]?.hasPrefix("SecurityIncident") == true, body["query"] ?? "")
        XCTAssertTrue(body["query"]?.contains("CreatedTime >= datetime(2026-11-19T09:00:00Z)") == true, body["query"] ?? "")
        XCTAssertTrue(body["query"]?.contains(#"Severity == "High""#) == true, body["query"] ?? "")
        XCTAssertTrue(body["timespan"]?.hasPrefix("2026-11-19T09:00:00Z/") == true, body["timespan"] ?? "")
        XCTAssertEqual(Sentinel.adapter.watchedTool, "query")
    }
}
