import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class SentinelOneTests: XCTestCase {
    private let s1 = try! SentinelOne.preset.makeConnection(name: "SentinelOne", values: ["console": "acme.sentinelone.net"])

    func testEachConsoleIsItsOwnAddressWithAnApiToken() {
        XCTAssertEqual(s1.endpoint.absoluteString, "https://acme.sentinelone.net/web/api/v2.1")
        XCTAssertEqual(s1.tokenScheme, "ApiToken")
        XCTAssertNotNil(PionAdapters.all["sentinelone"])
    }

    func testSentinelOneAgentsAndThreats() async throws {
        let service = FakeService()
        service.answers["/web/api/v2.1/agents"] = (200, #"{"data":[{"id":"a1","computerName":"LT-0423","osName":"Windows 11","networkStatus":"connected","isActive":true,"infected":true,"activeThreats":1,"lastActiveDate":"2026-11-14T09:00:00Z","externalIp":"203.0.113.9","agentVersion":"24.1","siteName":"HQ"}]}"#)
        service.answers["/web/api/v2.1/threats"] = (200, #"{"data":[{"id":"t1","threatInfo":{"threatName":"procdump.exe","classification":"Hacktool","confidenceLevel":"malicious","mitigationStatus":"mitigated","analystVerdict":"undefined","createdAt":"2026-11-14T08:59:00Z","sha256":"ab12","filePath":"C:\\Temp\\procdump.exe"},"agentRealtimeInfo":{"agentComputerName":"LT-0423"}}]}"#)
        let agents = try await callTool(SentinelOne.adapter, "find-agent", #"{"computerName":"LT-04"}"#, on: service, in: s1)
        XCTAssertTrue(agents.text.contains("infected"), agents.text)
        XCTAssertEqual(queryItems(service.requests.first)["computerName__contains"], "LT-04")
        let threats = try await callTool(SentinelOne.adapter, "threats", #"{"computerName":"LT-0423","unresolvedOnly":true,"since":"2026-11-13T00:00:00Z"}"#, on: service, in: s1)
        XCTAssertFalse(threats.isError, threats.text)
        XCTAssertTrue(threats.text.contains("Hacktool"), threats.text)
        let sent = queryItems(service.requests.last)
        XCTAssertEqual(sent["createdAt__gt"], "2026-11-13T00:00:00Z")
        XCTAssertEqual(sent["resolved"], "false")
        XCTAssertEqual(sent["sortBy"], "createdAt")
        XCTAssertEqual(sent["sortOrder"], "desc")
    }

    func testValuesThatCouldChangeAFilterAreRefused() async throws {
        let service = FakeService()
        for (tool, arguments) in [("threats", #"{"limit":1000}"#), ("find-agent", #"{"computerName":"x'y"}"#)] {
            let result = try await callTool(SentinelOne.adapter, tool, arguments, on: service, in: s1)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testItsTriggerFindsThreatsSinceATime() async throws {
        // Every threat an agent detects is serious; SentinelOne gives them no severity to filter by.
        let service = FakeService()
        service.answers["/web/api/v2.1/threats"] = (200, #"{"data":[{"id":"t2","threatInfo":{"createdAt":"2026-11-19T09:14:00.512000Z"}},{"id":"t1","threatInfo":{"createdAt":"2026-11-19T09:11:00Z"}}]}"#)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let threats = try await SentinelOne.adapter.alerts(since: since, connection: s1, access: service)
        XCTAssertEqual(threats.map(\.id), ["t2", "t1"])
        let query = queryItems(service.requests.first)
        XCTAssertEqual(query["createdAt__gte"], "2026-11-19T09:00:00Z")
        XCTAssertEqual(query["limit"], String(ServiceAlert.most))
        XCTAssertEqual(SentinelOne.adapter.watchedTool, "threats")
    }
}
