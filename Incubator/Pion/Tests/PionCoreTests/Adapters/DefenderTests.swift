import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class DefenderTests: XCTestCase {
    private let defender = try! Defender.preset.makeConnection(name: "Defender", values: ["tenant": "contoso.onmicrosoft.com"])

    func testATenantIsReachedThroughGraph() {
        XCTAssertEqual(defender.endpoint.absoluteString, "https://graph.microsoft.com/v1.0")
        XCTAssertEqual(defender.adapter, "defender")
        XCTAssertNotNil(PionAdapters.all["defender"])
    }

    func testDefenderAlertsIncidentsAndHunting() async throws {
        let service = FakeService()
        service.answers["/v1.0/security/alerts_v2"] = (200, ##"{"value":[{"id":"a1","title":"Suspicious execution of hidden file","severity":"high","status":"new","category":"DefenseEvasion","serviceSource":"microsoftDefenderForEndpoint","createdDateTime":"2026-11-14T08:00:00Z","incidentId":"28282","alertWebUrl":"https://security.microsoft.com/alerts/a1","mitreTechniques":["T1564.001"],"evidence":[{"@odata.type":"#microsoft.graph.security.deviceEvidence","hostName":"lt-0423"}]}]}"##)
        service.answers["/v1.0/security/incidents"] = (200, #"{"value":[{"id":"28282","displayName":"Multi-stage incident","severity":"high","status":"active","createdDateTime":"2026-11-14T08:00:00Z","incidentWebUrl":"https://security.microsoft.com/incidents/28282"}]}"#)
        service.answers["/v1.0/security/runHuntingQuery"] = (200, #"{"schema":[{"name":"Timestamp","type":"DateTime"},{"name":"FileName","type":"String"}],"results":[{"Timestamp":"2026-11-14T08:01:00Z","FileName":"cmd.exe"}]}"#)

        let alerts = try await callTool(Defender.adapter, "alerts", #"{"severity":"high","status":"new","since":"2026-11-13T00:00:00Z"}"#, on: service, in: defender)
        XCTAssertTrue(alerts.text.contains("Suspicious execution of hidden file"), alerts.text)
        XCTAssertTrue(alerts.text.contains("lt-0423"), alerts.text)
        XCTAssertEqual(queryItems(service.requests.last)["$filter"], "severity eq 'high' and status eq 'new' and createdDateTime ge 2026-11-13T00:00:00Z")

        let incidents = try await callTool(Defender.adapter, "incidents", #"{"status":"active"}"#, on: service, in: defender)
        XCTAssertTrue(incidents.text.contains("Multi-stage incident"), incidents.text)

        let hunt = try await callTool(Defender.adapter, "hunt", #"{"query":"DeviceProcessEvents | take 1","timespan":"P7D"}"#, on: service, in: defender)
        XCTAssertFalse(hunt.isError, hunt.text)
        XCTAssertTrue(hunt.text.contains("cmd.exe"), hunt.text)
        let posted = try XCTUnwrap(service.requests.last)
        XCTAssertEqual(posted.httpMethod, "POST")
        XCTAssertEqual(posted.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: posted.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body, ["Query": "DeviceProcessEvents | take 1", "Timespan": "P7D"])
    }

    func testValuesThatCouldBreakAFilterAreRefused() async throws {
        let service = FakeService()
        for (tool, arguments) in [("alerts", #"{"severity":"catastrophic"}"#), ("hunt", #"{"query":""}"#)] {
            let result = try await callTool(Defender.adapter, tool, arguments, on: service, in: defender)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }
}
