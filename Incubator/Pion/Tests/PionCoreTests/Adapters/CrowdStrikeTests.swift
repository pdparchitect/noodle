import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class CrowdStrikeTests: XCTestCase {
    private let falconEU = try! CrowdStrike.preset.makeConnection(name: "Falcon — EU", values: ["region": "api.eu-1.crowdstrike.com"])
    private let falconUS = try! CrowdStrike.preset.makeConnection(name: "Falcon — US", values: ["region": "api.crowdstrike.com"])

    func testEachFalconCloudIsItsOwnAddressAndTokenService() {
        XCTAssertEqual(falconEU.endpoint.absoluteString, "https://api.eu-1.crowdstrike.com")
        XCTAssertEqual(falconEU.clientCredentials?.tokenEndpoint.absoluteString, "https://api.eu-1.crowdstrike.com/oauth2/token")
        XCTAssertEqual(falconUS.clientCredentials?.tokenEndpoint.absoluteString, "https://api.crowdstrike.com/oauth2/token")
        XCTAssertEqual(falconEU.adapter, "crowdstrike")
        XCTAssertThrowsError(try CrowdStrike.preset.makeConnection(name: "Bad", values: ["region": "evil.example"]))
        XCTAssertNotNil(PionAdapters.all["crowdstrike"])
    }

    func testFalconHostsAreFoundThenDescribed() async throws {
        let service = FakeService()
        service.answers["/devices/queries/devices/v1"] = (200, #"{"resources":["d1"]}"#)
        service.answers["/devices/entities/devices/v2"] = (200, #"{"resources":[{"device_id":"d1","hostname":"LT-0423","local_ip":"10.0.4.23","external_ip":"203.0.113.9","platform_name":"Windows","os_version":"Windows 11","agent_version":"7.20","last_seen":"2026-11-14T09:00:00Z","status":"contained"}]}"#)
        let hosts = try await callTool(CrowdStrike.adapter, "find-host", #"{"hostname":"LT-0423"}"#, on: service, in: falconEU)
        XCTAssertFalse(hosts.isError, hosts.text)
        XCTAssertTrue(hosts.text.contains("LT-0423"), hosts.text)
        XCTAssertTrue(hosts.text.contains("contained"), hosts.text)
        XCTAssertEqual(queryItems(service.requests.first)["filter"], "hostname:'LT-0423'")
        XCTAssertEqual(queryItems(service.requests.last)["ids"], "d1")
        XCTAssertEqual(service.requests.first?.url?.host, "api.eu-1.crowdstrike.com")
    }

    func testFalconAlertsAreQueriedThenFetchedByCompositeID() async throws {
        let service = FakeService()
        service.answers["/alerts/queries/alerts/v2"] = (200, #"{"resources":["cid:ind:1"]}"#)
        service.answers["/alerts/entities/alerts/v2"] = (200, #"{"resources":[{"composite_id":"cid:ind:1","name":"CredentialDumping","description":"A process accessed LSASS memory.","severity_name":"High","status":"new","created_timestamp":"2026-11-14T08:59:00Z","tactic":"Credential Access","technique":"OS Credential Dumping","filename":"procdump.exe","cmdline":"procdump -ma lsass.exe","device":{"hostname":"LT-0423","device_id":"d1"},"falcon_host_link":"https://falcon.eu-1.crowdstrike.com/activity-v2/detections/x"}]}"#)
        let alerts = try await callTool(CrowdStrike.adapter, "alerts", #"{"hostname":"LT-0423","since":"2026-11-13T00:00:00Z"}"#, on: service, in: falconEU)
        XCTAssertFalse(alerts.isError, alerts.text)
        XCTAssertTrue(alerts.text.contains("procdump.exe"), alerts.text)
        XCTAssertEqual(queryItems(service.requests.first)["filter"], "created_timestamp:>='2026-11-13T00:00:00Z'+device.hostname:'LT-0423'")
        XCTAssertEqual(queryItems(service.requests.first)["sort"], "created_timestamp.desc")
        let posted = try XCTUnwrap(service.requests.last)
        XCTAssertEqual(posted.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: posted.httpBody ?? Data()) as? [String: [String]], ["composite_ids": ["cid:ind:1"]])
    }

    func testValuesThatCouldChangeAFilterAreRefused() async throws {
        let service = FakeService()
        for (tool, arguments) in [("find-host", #"{"hostname":"x'+platform_name:'Mac"}"#), ("find-host", "{}"), ("alerts", #"{"since":"soon"}"#)] {
            let result = try await callTool(CrowdStrike.adapter, tool, arguments, on: service, in: falconEU)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testItsTriggerFindsHighAndCriticalAlertsSinceATime() async throws {
        let service = FakeService()
        service.answers["/alerts/queries/alerts/v2"] = (200, #"{"resources":["cid:ind:2","cid:ind:1"]}"#)
        service.answers["/alerts/entities/alerts/v2"] = (200, #"{"resources":[{"composite_id":"cid:ind:1","created_timestamp":"2026-11-19T09:11:00.123456789Z"},{"composite_id":"cid:ind:2","created_timestamp":"2026-11-19T09:14:00Z"}]}"#)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let alerts = try await CrowdStrike.adapter.alerts(since: since, connection: falconEU, access: service)
        XCTAssertEqual(alerts.map(\.id), ["cid:ind:2", "cid:ind:1"])
        let query = queryItems(service.requests.first)
        XCTAssertEqual(query["filter"], "severity_name:['High','Critical']+created_timestamp:>='2026-11-19T09:00:00Z'")
        XCTAssertEqual(query["limit"], String(ServiceAlert.most))
        XCTAssertEqual(CrowdStrike.adapter.watchedTool, "alerts")
    }
}
