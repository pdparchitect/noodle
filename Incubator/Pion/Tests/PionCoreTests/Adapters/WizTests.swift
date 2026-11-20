import Foundation
import NoodleCore
import NoodleMCP
@testable import PionCore
import XCTest

final class WizTests: XCTestCase {
    private let wiz = try! Wiz.preset.makeConnection(name: "Wiz", values: ["region": "us17"])

    func testATenantGetsWizAPITokensAndItsRegionsAddress() {
        XCTAssertEqual(wiz.endpoint.absoluteString, "https://api.us17.app.wiz.io/graphql")
        XCTAssertEqual(wiz.clientCredentials?.tokenEndpoint.absoluteString, "https://auth.app.wiz.io/oauth/token")
        XCTAssertEqual(wiz.clientCredentials?.parameters, ["audience": "wiz-api"])
        XCTAssertNotNil(PionAdapters.all["wiz"])
    }

    func testIssuesBySeverityAndStatus() async throws {
        let service = FakeService()
        service.answers["/graphql"] = (200, #"{"data":{"issues":{"nodes":[{"id":"i1","severity":"CRITICAL","status":"OPEN","createdAt":"2026-11-14T07:00:00Z","sourceRule":{"name":"Publicly exposed VM with a critical vulnerability"},"entitySnapshot":{"name":"web-01","type":"VIRTUAL_MACHINE","cloudPlatform":"AWS","subscriptionName":"prod"}}]}}}"#)
        let issues = try await callTool(Wiz.adapter, "issues", #"{"severities":["CRITICAL","HIGH"],"statuses":["OPEN"],"limit":20}"#, on: service, in: wiz)
        XCTAssertFalse(issues.isError, issues.text)
        XCTAssertTrue(issues.text.contains("web-01"), issues.text)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: service.requests.first?.httpBody ?? Data()) as? [String: Any])
        let variables = try XCTUnwrap(body["variables"] as? [String: Any])
        XCTAssertEqual(variables["first"] as? Int, 20)
        let filter = try XCTUnwrap(variables["filterBy"] as? [String: [String]])
        XCTAssertEqual(filter, ["severity": ["CRITICAL", "HIGH"], "status": ["OPEN"]])
    }

    func testAReadQueryRunsAndChangesAreRefused() async throws {
        let service = FakeService()
        service.answers["/graphql"] = (200, #"{"data":{"cloudResources":{"nodes":[{"name":"web-01"}]}}}"#)
        let read = try await callTool(Wiz.adapter, "query", #"{"query":"query { cloudResources(first: 1) { nodes { name } } }"}"#, on: service, in: wiz)
        XCTAssertFalse(read.isError, read.text)
        XCTAssertTrue(read.text.contains("web-01"), read.text)
        for query in ["mutation { deleteIssue(id: \\\"i1\\\") { id } }", "  subscription { x }", "{ a } mutation { b }", ""] {
            let refused = try await callTool(Wiz.adapter, "query", #"{"query":"\#(query)"}"#, on: service, in: wiz)
            XCTAssertTrue(refused.isError, query)
        }
        XCTAssertEqual(service.requests.count, 1)
    }

    func testItsTriggerFindsOpenHighAndCriticalIssuesSinceATime() async throws {
        let service = FakeService()
        service.answers["/graphql"] = (200, #"{"data":{"issues":{"nodes":[{"id":"i2","createdAt":"2026-11-19T09:14:00.123Z"},{"id":"i1","createdAt":"2026-11-19T09:11:00Z"}]}}}"#)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let issues = try await Wiz.adapter.alerts(since: since, connection: wiz, access: service)
        XCTAssertEqual(issues.map(\.id), ["i2", "i1"])
        func variables(_ request: URLRequest?) throws -> [String: Any] {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
            return try XCTUnwrap(body["variables"] as? [String: Any])
        }
        let sent = try variables(service.requests.last)
        let filter = try XCTUnwrap(sent["filterBy"] as? [String: Any])
        XCTAssertEqual(filter["severity"] as? [String], ["CRITICAL", "HIGH"])
        XCTAssertEqual(filter["status"] as? [String], ["OPEN", "IN_PROGRESS"])
        XCTAssertEqual((filter["createdAt"] as? [String: String])?["after"], "2026-11-19T09:00:00Z")
        XCTAssertEqual(sent["first"] as? Int, ServiceAlert.most)
        XCTAssertEqual(Wiz.adapter.watchedTool, "issues")

        // The window a wake names can be read back with the issues operation.
        _ = try await callTool(Wiz.adapter, "issues", #"{"since":"2026-11-19T09:00:00Z"}"#, on: service, in: wiz)
        XCTAssertEqual(((try variables(service.requests.last)["filterBy"] as? [String: Any])?["createdAt"] as? [String: String])?["after"], "2026-11-19T09:00:00Z")
    }
}
