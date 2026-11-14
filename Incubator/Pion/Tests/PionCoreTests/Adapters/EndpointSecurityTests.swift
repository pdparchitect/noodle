import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class EndpointSecurityTests: XCTestCase {
    private let falconEU = try! CrowdStrike.preset.makeConnection(name: "Falcon — EU", values: ["region": "api.eu-1.crowdstrike.com"])
    private let falconUS = try! CrowdStrike.preset.makeConnection(name: "Falcon — US", values: ["region": "api.crowdstrike.com"])
    private let s1 = try! SentinelOne.preset.makeConnection(name: "SentinelOne", values: ["console": "acme.sentinelone.net"])

    private func call(_ adapter: OperationAdapter, _ tool: String, _ arguments: String, on service: FakeService,
                      in connection: MCPConnectionRecord) async throws -> (text: String, isError: Bool, structured: [String: Any]?) {
        let data = try await adapter.run(tool, arguments: Data(arguments.utf8), connection: connection, access: service)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? "", result["isError"] as? Bool ?? false,
                result["structuredContent"] as? [String: Any])
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        let items = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testEachFalconCloudIsItsOwnAddressAndTokenService() {
        XCTAssertEqual(falconEU.endpoint.absoluteString, "https://api.eu-1.crowdstrike.com")
        XCTAssertEqual(falconEU.clientCredentials?.tokenEndpoint.absoluteString, "https://api.eu-1.crowdstrike.com/oauth2/token")
        XCTAssertEqual(falconUS.clientCredentials?.tokenEndpoint.absoluteString, "https://api.crowdstrike.com/oauth2/token")
        XCTAssertEqual(falconEU.adapter, "crowdstrike")
        XCTAssertThrowsError(try CrowdStrike.preset.makeConnection(name: "Bad", values: ["region": "evil.example"]))
        XCTAssertEqual(s1.endpoint.absoluteString, "https://acme.sentinelone.net/web/api/v2.1")
        XCTAssertEqual(s1.tokenScheme, "ApiToken")
        XCTAssertNotNil(PionAdapters.all["crowdstrike"])
        XCTAssertNotNil(PionAdapters.all["sentinelone"])
    }

    func testFalconHostsAreFoundThenDescribed() async throws {
        let service = FakeService()
        service.answers["/devices/queries/devices/v1"] = (200, #"{"resources":["d1"]}"#)
        service.answers["/devices/entities/devices/v2"] = (200, #"{"resources":[{"device_id":"d1","hostname":"LT-0423","local_ip":"10.0.4.23","external_ip":"203.0.113.9","platform_name":"Windows","os_version":"Windows 11","agent_version":"7.20","last_seen":"2026-11-14T09:00:00Z","status":"contained"}]}"#)
        let hosts = try await call(CrowdStrike.adapter, "find-host", #"{"hostname":"LT-0423"}"#, on: service, in: falconEU)
        XCTAssertFalse(hosts.isError, hosts.text)
        XCTAssertTrue(hosts.text.contains("LT-0423"), hosts.text)
        XCTAssertTrue(hosts.text.contains("contained"), hosts.text)
        XCTAssertEqual(query(service.requests.first)["filter"], "hostname:'LT-0423'")
        XCTAssertEqual(query(service.requests.last)["ids"], "d1")
        XCTAssertEqual(service.requests.first?.url?.host, "api.eu-1.crowdstrike.com")
    }

    func testFalconAlertsAreQueriedThenFetchedByCompositeID() async throws {
        let service = FakeService()
        service.answers["/alerts/queries/alerts/v2"] = (200, #"{"resources":["cid:ind:1"]}"#)
        service.answers["/alerts/entities/alerts/v2"] = (200, #"{"resources":[{"composite_id":"cid:ind:1","name":"CredentialDumping","description":"A process accessed LSASS memory.","severity_name":"High","status":"new","created_timestamp":"2026-11-14T08:59:00Z","tactic":"Credential Access","technique":"OS Credential Dumping","filename":"procdump.exe","cmdline":"procdump -ma lsass.exe","device":{"hostname":"LT-0423","device_id":"d1"},"falcon_host_link":"https://falcon.eu-1.crowdstrike.com/activity-v2/detections/x"}]}"#)
        let alerts = try await call(CrowdStrike.adapter, "alerts", #"{"hostname":"LT-0423","since":"2026-11-13T00:00:00Z"}"#, on: service, in: falconEU)
        XCTAssertFalse(alerts.isError, alerts.text)
        XCTAssertTrue(alerts.text.contains("procdump.exe"), alerts.text)
        XCTAssertEqual(query(service.requests.first)["filter"], "created_timestamp:>='2026-11-13T00:00:00Z'+device.hostname:'LT-0423'")
        XCTAssertEqual(query(service.requests.first)["sort"], "created_timestamp.desc")
        let posted = try XCTUnwrap(service.requests.last)
        XCTAssertEqual(posted.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: posted.httpBody ?? Data()) as? [String: [String]], ["composite_ids": ["cid:ind:1"]])
    }

    func testSentinelOneAgentsAndThreats() async throws {
        let service = FakeService()
        service.answers["/web/api/v2.1/agents"] = (200, #"{"data":[{"id":"a1","computerName":"LT-0423","osName":"Windows 11","networkStatus":"connected","isActive":true,"infected":true,"activeThreats":1,"lastActiveDate":"2026-11-14T09:00:00Z","externalIp":"203.0.113.9","agentVersion":"24.1","siteName":"HQ"}]}"#)
        service.answers["/web/api/v2.1/threats"] = (200, #"{"data":[{"id":"t1","threatInfo":{"threatName":"procdump.exe","classification":"Hacktool","confidenceLevel":"malicious","mitigationStatus":"mitigated","analystVerdict":"undefined","createdAt":"2026-11-14T08:59:00Z","sha256":"ab12","filePath":"C:\\Temp\\procdump.exe"},"agentRealtimeInfo":{"agentComputerName":"LT-0423"}}]}"#)
        let agents = try await call(SentinelOne.adapter, "find-agent", #"{"computerName":"LT-04"}"#, on: service, in: s1)
        XCTAssertTrue(agents.text.contains("infected"), agents.text)
        XCTAssertEqual(query(service.requests.first)["computerName__contains"], "LT-04")
        let threats = try await call(SentinelOne.adapter, "threats", #"{"computerName":"LT-0423","unresolvedOnly":true,"since":"2026-11-13T00:00:00Z"}"#, on: service, in: s1)
        XCTAssertFalse(threats.isError, threats.text)
        XCTAssertTrue(threats.text.contains("Hacktool"), threats.text)
        let sent = query(service.requests.last)
        XCTAssertEqual(sent["createdAt__gt"], "2026-11-13T00:00:00Z")
        XCTAssertEqual(sent["resolved"], "false")
        XCTAssertEqual(sent["sortBy"], "createdAt")
        XCTAssertEqual(sent["sortOrder"], "desc")
    }

    func testValuesThatCouldChangeAFilterAreRefused() async throws {
        let service = FakeService()
        for (adapter, connection, tool, arguments) in [
            (CrowdStrike.adapter, falconEU, "find-host", #"{"hostname":"x'+platform_name:'Mac"}"#),
            (CrowdStrike.adapter, falconEU, "find-host", "{}"),
            (CrowdStrike.adapter, falconEU, "alerts", #"{"since":"soon"}"#),
            (SentinelOne.adapter, s1, "threats", #"{"limit":1000}"#),
        ] {
            let result = try await call(adapter, tool, arguments, on: service, in: connection)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }
}
