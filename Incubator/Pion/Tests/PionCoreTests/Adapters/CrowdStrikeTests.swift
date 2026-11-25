import Foundation
import NoodleCore
import NoodleToolConnections
import Synchronization
@testable import PionCore
import XCTest

final class CrowdStrikeTests: XCTestCase {
    private let falconEU = try! CrowdStrike.preset.makeConnection(name: "Falcon — EU", values: ["region": "api.eu-1.crowdstrike.com"])
    private let falconUS = try! CrowdStrike.preset.makeConnection(name: "Falcon — US", values: ["region": "api.crowdstrike.com"])
    private let laptop = "0123456789abcdef0123456789abcdef"

    private func call(_ tool: String, _ arguments: String, _ service: FakeService, in connection: ToolConnection? = nil) async throws -> AdapterResult {
        try await CrowdStrike.$pause.withValue({ _ in }) { try await callTool(CrowdStrike.adapter, tool, arguments, on: service, in: connection ?? falconEU) }
    }

    private func body(_ request: URLRequest?) -> [String: Any] {
        request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func host(_ id: String, status: String = "normal", extra: String = "") -> String {
        #"{"device_id":"\#(id)","hostname":"LT-0423","local_ip":"10.0.4.23","external_ip":"203.0.113.9","platform_name":"Windows","os_version":"Windows 11","product_type_desc":"Workstation","agent_version":"7.20","first_seen":"2026-01-01T00:00:00Z","last_seen":"2026-11-23T09:00:00Z","status":"\#(status)","tags":["SensorGroupingTags/Finance"],"groups":["g1"]\#(extra)}"#
    }

    func testItIsAuditOnEachFalconCloudItsOwnAddressAndTokenServiceAndNoOther() throws {
        XCTAssertEqual(CrowdStrike.preset.name, "CrowdStrike Falcon Detection")
        XCTAssertEqual(CrowdStrike.preset.id, "fc56ba9d-c4aa-4ff9-80cf-507f21273249", "the tool keeps its ID")
        XCTAssertEqual(falconEU.endpoint.absoluteString, "https://api.eu-1.crowdstrike.com")
        XCTAssertEqual(falconEU.clientCredentials?.tokenEndpoint.absoluteString, "https://api.eu-1.crowdstrike.com/oauth2/token")
        XCTAssertEqual(falconUS.clientCredentials?.tokenEndpoint.absoluteString, "https://api.crowdstrike.com/oauth2/token")
        XCTAssertEqual(falconEU.adapter, "crowdstrike")
        for host in ["api.us-2.crowdstrike.com", "api.laggar.gcw.crowdstrike.com"] {
            XCTAssertEqual(try CrowdStrike.preset.makeConnection(name: "Falcon", values: ["region": host]).endpoint.host, host)
        }
        for bad in ["evil.example", "api.crowdstrike.com.evil.example", "https://api.crowdstrike.com", "api.crowdstrike.com/x"] {
            XCTAssertThrowsError(try CrowdStrike.preset.makeConnection(name: "Bad", values: ["region": bad]), bad)
        }
        XCTAssertNotNil(PionAdapters.all["crowdstrike"])
        // A client whose address is no Falcon cloud reaches nothing.
        let elsewhere = ServiceClient(base: URL(string: "https://evil.example")!, access: FakeService())
        XCTAssertThrowsError(try CrowdStrike.cloud(elsewhere))
    }

    /// Detection's client is made with Read scopes alone, and its operations only read.
    func testItsSetupAsksOnlyForReadScopesAndEveryOperationOnlyReads() async throws {
        let setup = CrowdStrike.setup.joined(separator: "\n")
        for scope in CrowdStrike.auditScopes {
            XCTAssertEqual(scope.access, "Read")
            XCTAssertTrue(setup.contains(scope.shown), scope.plain)
        }
        XCTAssertTrue(setup.contains("Give it no **Write** scope at all"))
        XCTAssertTrue(setup.contains("`falcon.eu-1.crowdstrike.com` is EU-1"))
        let listed = try JSONSerialization.jsonObject(with: try await CrowdStrike.adapter.tools(for: falconEU)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }),
                       ["hosts", "host", "alerts", "alert", "rtr-sessions", "host-groups", "container-images", "users", "security-events", "check-access"])
        for tool in tools { XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true, "\(tool["name"] ?? "")") }
        XCTAssertEqual(CrowdStrike.adapter.watchedTool, "security-events")
    }

    func testHostsAreFoundThenDescribedAndSayWhenMoreMatched() async throws {
        let service = FakeService()
        service.answers["/devices/queries/devices/v1"] = (200, #"{"meta":{"pagination":{"offset":0,"limit":2,"total":7}},"resources":["\#(laptop)","\#(String(repeating: "f", count: 32))"]}"#)
        service.answers["/devices/entities/devices/v2"] = (200, #"{"resources":[\#(host(laptop, status: "contained"))],"errors":[]}"#)
        let hosts = try await call("hosts", #"{"name":"LT-04","platform":"Windows","limit":2}"#, service)
        XCTAssertFalse(hosts.isError, hosts.text)
        XCTAssertTrue(hosts.text.contains("LT-0423 [\(laptop)]") && hosts.text.contains("containment contained"), hosts.text)
        XCTAssertTrue(hosts.text.contains("Falcon listed 1 host it then did not describe"), hosts.text)
        XCTAssertTrue(hosts.text.contains("More hosts match than the 1 kept (Falcon says 7 match)"), hosts.text)
        XCTAssertEqual(queryItems(service.requests.first)["filter"], "hostname:*'LT-04*'+platform_name:'Windows'")
        XCTAssertEqual(queryItems(service.requests.first)["sort"], "last_seen.desc")
        let described = try XCTUnwrap(service.requests.last)
        XCTAssertEqual(described.httpMethod, "POST")
        XCTAssertEqual(body(described)["ids"] as? [String], [laptop, String(repeating: "f", count: 32)])
        XCTAssertEqual(hosts.structured?["complete"] as? Bool, false)
        XCTAssertEqual(service.requests.first?.url?.host, "api.eu-1.crowdstrike.com")
    }

    /// A page Falcon answers without its list, or a host without its device ID, is an error, never "nothing".
    func testMalformedAnswersAreErrorsNotNothing() async throws {
        let service = FakeService()
        service.answers["/devices/queries/devices/v1"] = (200, #"{"meta":{"pagination":{"total":3}}}"#)
        let missing = try await call("hosts", "{}", service)
        XCTAssertTrue(missing.isError && missing.text.contains("could not be read"), missing.text)
        service.answers["/devices/queries/devices/v1"] = (200, #"{"meta":{"pagination":{"offset":0,"limit":50,"total":1}},"resources":["\#(laptop)"]}"#)
        service.answers["/devices/entities/devices/v2"] = (200, #"{"resources":[{"hostname":"no-id"}]}"#)
        let noID = try await call("hosts", "{}", service)
        XCTAssertTrue(noID.isError, noID.text)
        // An empty list that comes with an error, with no message at all, is no proof of nothing.
        service.answers["/devices/queries/devices/v1"] = (200, #"{"meta":{"pagination":{"offset":0,"limit":50,"total":0}},"resources":[],"errors":[{"code":500}]}"#)
        let erred = try await call("hosts", "{}", service)
        XCTAssertTrue(erred.isError && erred.text.contains("error 500 without a message") && !erred.text.contains("No host matches"), erred.text)
        service.answers["/devices/queries/devices/v1"] = (200, #"{"meta":{"pagination":{"offset":0,"limit":50,"total":0}},"resources":[]}"#)
        let none = try await call("hosts", "{}", service)
        XCTAssertFalse(none.isError, none.text)
        XCTAssertTrue(none.text.contains("No host matches."), none.text)
    }

    func testAHostIsReadWithItsContainmentOnlineStateKubernetesSignsAndAlerts() async throws {
        let service = FakeService()
        service.answers["/devices/entities/devices/v2"] = (200, #"{"resources":[\#(host(laptop, status: "containment_pending", extra: #","deployment_type":"DaemonSet","k8s_cluster_id":"k8s-prod","pod_name":"""#))]}"#)
        service.answers["/devices/entities/online-state/v1"] = (200, #"{"resources":[{"id":"\#(laptop)","state":"online"}]}"#)
        service.answers["/alerts/combined/alerts/v1"] = (200, #"{"meta":{"pagination":{"limit":20,"total":1}},"resources":[{"composite_id":"cid:ind:1","display_name":"CredentialDumping","severity_name":"High","status":"new","created_timestamp":"2026-11-23T08:59:00Z","device":{"hostname":"LT-0423","device_id":"\#(laptop)"}}]}"#)
        let read = try await call("host", #"{"host":"\#(laptop.uppercased())"}"#, service)
        XCTAssertFalse(read.isError, read.text)
        for words in ["containment pending (asked for, not yet in force)", "Sensor online now", "suggests this host runs Kubernetes workloads (hint:", "not verified",
                      "k8s_cluster_id k8s-prod", "deployment type DaemonSet",
                      "CredentialDumping", "SensorGroupingTags/Finance"] {
            XCTAssertTrue(read.text.contains(words), "\(words): \(read.text)")
        }
        XCTAssertEqual(read.structured?["workloads"] as? String, "kubernetes-suggested")
        let alerts = try XCTUnwrap(service.requests.first { $0.url?.path == "/alerts/combined/alerts/v1" })
        XCTAssertEqual(body(alerts)["filter"] as? String, "device.device_id:'\(laptop)'")
        XCTAssertEqual(queryItems(service.requests.first { $0.url?.path == "/devices/entities/online-state/v1" })["ids"], laptop)
        // A host whose record shows nothing either way: Pion cannot tell.
        service.answers["/devices/entities/devices/v2"] = (200, #"{"resources":[\#(host(laptop))]}"#)
        let plain = try await call("host", #"{"host":"\#(laptop)"}"#, service)
        XCTAssertTrue(plain.text.contains("Pion cannot tell; that is not proof it runs none"), plain.text)
    }

    /// Alerts are read whole from the combined listing, page after page by the token each gives, with the search in
    /// the body each time; a page that fails keeps what came before and says where it stopped.
    func testAlertsPageByTokenAndSayWhereTheyStopped() async throws {
        let service = FakeService()
        func alert(_ id: Int) -> String {
            #"{"composite_id":"cid:ind:\#(id)","display_name":"Alert \#(id)","severity_name":"Critical","status":"new","created_timestamp":"2026-11-23T08:\#(String(format: "%02d", id)):00Z","filename":"procdump.exe","cmdline":"procdump -ma lsass.exe","technique_id":"T1003","technique":"OS Credential Dumping","device":{"hostname":"LT-0423","device_id":"\#(laptop)"}}"#
        }
        service.sequences["/alerts/combined/alerts/v1"] = [
            (200, #"{"meta":{"pagination":{"limit":2,"total":5,"after":"token-1"}},"resources":[\#(alert(1)),\#(alert(2))]}"#),
            (200, #"{"meta":{"pagination":{"limit":2,"total":5,"after":"token-2"}},"resources":[\#(alert(3)),\#(alert(4))]}"#),
            (500, #"{"errors":[{"code":500,"message":"internal error"}]}"#),
        ]
        let since = Entra.iso(Date().addingTimeInterval(-86_400))
        let alerts = try await call("alerts", #"{"host":"LT-0423","severity":"High","since":"\#(since)","limit":100}"#, service)
        XCTAssertFalse(alerts.isError, alerts.text)
        XCTAssertTrue(alerts.text.contains("4 alerts") && alerts.text.contains("procdump.exe") && alerts.text.contains("T1003 OS Credential Dumping"), alerts.text)
        XCTAssertTrue(alerts.text.contains("Incomplete: stopped at page 3 reading alerts because"), alerts.text)
        let posts = service.requests.filter { $0.url?.path == "/alerts/combined/alerts/v1" }.map(body)
        XCTAssertEqual(posts.count, 3)
        XCTAssertNil(posts[0]["after"])
        XCTAssertEqual(posts[1]["after"] as? String, "token-1")
        XCTAssertEqual(posts[2]["after"] as? String, "token-2")
        XCTAssertTrue(posts.allSatisfy { $0["filter"] as? String == posts[0]["filter"] as? String }, "the same search each time")
        let filter = try XCTUnwrap(posts[0]["filter"] as? String)
        XCTAssertTrue(filter.hasPrefix("created_timestamp:>='\(since)'+created_timestamp:<='"), filter)
        XCTAssertTrue(filter.hasSuffix("+device.hostname:'LT-0423'+severity_name:['High','Critical']"), filter)
        XCTAssertEqual(alerts.structured?["complete"] as? Bool, false)
    }

    func testAnAlertIsReadInFull() async throws {
        let service = FakeService()
        service.answers["/alerts/entities/alerts/v2"] = (200, #"{"resources":[{"composite_id":"cid:ind:1","display_name":"CredentialDumping","description":"A process accessed LSASS memory.","severity_name":"High","severity":70,"status":"new","created_timestamp":"2026-11-23T08:59:00Z","tactic":"Credential Access","technique":"OS Credential Dumping","technique_id":"T1003","filename":"procdump.exe","filepath":"C:\\Tools\\procdump.exe","cmdline":"procdump -ma lsass.exe","sha256":"\#(String(repeating: "a", count: 64))","user_name":"ana","product":"epp","pattern_disposition_description":"Detection, process would have been blocked if related prevention policy setting was enabled.","parent_details":{"filename":"cmd.exe","cmdline":"cmd /c run.bat"},"device":{"hostname":"LT-0423","device_id":"\#(laptop)"}}]}"#)
        let read = try await call("alert", #"{"id":"cid:ind:1"}"#, service)
        XCTAssertFalse(read.isError, read.text)
        for words in ["device ID \(laptop)", "Parent: cmd.exe `cmd /c run.bat`", "SHA256 \(String(repeating: "a", count: 64))", "MITRE: Credential Access", "Falcon's response: Detection"] {
            XCTAssertTrue(read.text.contains(words), "\(words): \(read.text)")
        }
        XCTAssertEqual(body(service.requests.last)["composite_ids"] as? [String], ["cid:ind:1"])
        service.answers["/alerts/entities/alerts/v2"] = (200, #"{"resources":[{"composite_id":"cid:ind:2"}]}"#)
        let other = try await call("alert", #"{"id":"cid:ind:1"}"#, service)
        XCTAssertTrue(other.isError, "an answer for another alert is not taken: \(other.text)")
    }

    /// Falcon's rate limit is waited out once, as long as X-RateLimit-RetryAfter asks, when that is soon; otherwise the
    /// result says how long it asked to wait.
    func testTheRateLimitIsWaitedOutOnceThenSaid() async throws {
        let service = FakeService()
        let soon = Int((Date().timeIntervalSince1970 + 5) * 1_000)
        service.responseHeaders = ["X-RateLimit-RetryAfter": String(soon)]
        service.sequences["/devices/queries/devices/v1"] = [(429, #"{"errors":[{"code":429,"message":"API rate limit exceeded."}]}"#),
                                                            (200, #"{"meta":{"pagination":{"total":0}},"resources":[]}"#)]
        let waits = Mutex<[Double]>([])
        let result = try await CrowdStrike.$pause.withValue({ wait in waits.withLock { $0.append(wait) } }) {
            try await callTool(CrowdStrike.adapter, "hosts", "{}", on: service, in: falconEU)
        }
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(waits.withLock { $0.count }, 1)
        XCTAssertTrue((3...6).contains(waits.withLock { $0[0] }), "\(waits.withLock { $0 })")
        service.responseHeaders = ["X-RateLimit-RetryAfter": String(Int(Date().timeIntervalSince1970) + 90)]
        service.answers["/devices/queries/devices/v1"] = (429, #"{"errors":[{"code":429,"message":"API rate limit exceeded."}]}"#)
        let refused = try await call("hosts", "{}", service)
        XCTAssertTrue(refused.isError && refused.text.contains("Falcon asked to wait") && refused.text.contains("rate limit"), refused.text)
    }

    /// A refusal names the scope to add.
    func testARefusalNamesTheScopeToAdd() async throws {
        let service = FakeService()
        service.answers["/real-time-response-audit/combined/sessions/v1"] = (403, #"{"errors":[{"code":403,"message":"access denied, authorization failed"}]}"#)
        let refused = try await call("rtr-sessions", "{}", service)
        XCTAssertTrue(refused.isError && refused.text.contains("Real time response audit: Read") && refused.text.contains("access denied"), refused.text)
        service.answers["/devices/queries/devices/v1"] = (401, #"{"errors":[{"code":401,"message":"access denied, invalid bearer token"}]}"#)
        let rejected = try await call("hosts", "{}", service)
        XCTAssertTrue(rejected.isError && rejected.text.contains("did not accept the API client's ID and secret"), rejected.text)
    }

    func testValuesThatCouldChangeAFilterAreRefused() async throws {
        let service = FakeService()
        for (tool, arguments) in [("hosts", #"{"name":"x'+platform_name:'Mac"}"#), ("host", #"{"host":"a'b"}"#), ("alerts", #"{"since":"soon"}"#),
                                  ("alerts", #"{"host":"x' ,status:'closed"}"#), ("rtr-sessions", #"{"host":"not-an-id"}"#), ("rtr-sessions", #"{"user":"a'b"}"#),
                                  ("host-groups", #"{"group":"g'1"}"#), ("alert", #"{"id":"x"}"#), ("alerts", #"{"since":"2020-01-01T00:00:00Z"}"#)] {
            let result = try await call(tool, arguments, service)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testRealTimeResponseSessionsListWhoRanWhatOnWhichHost() async throws {
        let service = FakeService()
        service.answers["/real-time-response-audit/combined/sessions/v1"] = (200, #"{"meta":{"pagination":{"offset":0,"limit":50,"total":1}},"resources":[{"id":"s-1","device_id":"\#(laptop)","hostname":"LT-0423","user_id":"responder@kestrel.example","origin":"console","created_at":"2026-11-23T08:00:00Z","deleted_at":"2026-11-23T08:10:00Z","logs":[{"base_command":"ls","command_string":"ls C:\\Users","created_at":"2026-11-23T08:01:00Z","current_directory":"C:\\"},{"base_command":"get","command_string":"get C:\\Users\\ana\\secrets.xlsx","created_at":"2026-11-23T08:02:00Z"}]}]}"#)
        let sessions = try await call("rtr-sessions", #"{"host":"\#(laptop)"}"#, service)
        XCTAssertFalse(sessions.isError, sessions.text)
        XCTAssertTrue(sessions.text.contains("responder@kestrel.example opened a session on LT-0423") && sessions.text.contains("get C:\\Users\\ana\\secrets.xlsx"), sessions.text)
        let query = queryItems(service.requests.first)
        XCTAssertEqual(query["with_command_info"], "true")
        XCTAssertTrue(query["filter"]?.hasSuffix("+device_id:'\(laptop)'") == true, query["filter"] ?? "")
        XCTAssertEqual(sessions.structured?["complete"] as? Bool, true)
    }

    func testHostGroupsAndTheirMembersAndContainerImages() async throws {
        let service = FakeService()
        service.answers["/devices/combined/host-groups/v1"] = (200, #"{"meta":{"pagination":{"offset":0,"limit":100,"total":1}},"resources":[{"id":"g1","name":"Finance","group_type":"dynamic","assignment_rule":"tags:'SensorGroupingTags/Finance'"}]}"#)
        let groups = try await call("host-groups", "{}", service)
        XCTAssertTrue(groups.text.contains("Finance [g1]: dynamic, rule `tags:'SensorGroupingTags/Finance'`"), groups.text)
        service.answers["/devices/queries/host-group-members/v1"] = (200, #"{"meta":{"pagination":{"offset":0,"limit":100,"total":1}},"resources":["\#(laptop)"]}"#)
        service.answers["/devices/entities/devices/v2"] = (200, #"{"resources":[\#(host(laptop))]}"#)
        let members = try await call("host-groups", #"{"group":"g1"}"#, service)
        XCTAssertTrue(members.text.contains("1 host in host group g1") && members.text.contains("LT-0423"), members.text)
        XCTAssertEqual(queryItems(service.requests.first { $0.url?.path == "/devices/queries/host-group-members/v1" })["id"], "g1")
        service.answers["/container-security/combined/image-assessment/images/v1"] = (200, #"{"meta":{"pagination":{"offset":0,"limit":50,"total":1}},"resources":[{"registry":"ghcr.io","repository":"kestrel/api","tag":"1.4","image_id":"sha256:abc","highest_vulnerability_severity":"CRITICAL","vulnerabilities":12,"detections":1,"base_os":"Alpine 3.18","first_seen":"2026-11-01T00:00:00Z","last_seen":"2026-11-23T00:00:00Z"}]}"#)
        let images = try await call("container-images", #"{"repository":"kestrel/api"}"#, service)
        XCTAssertTrue(images.text.contains("ghcr.io/kestrel/api:1.4") && images.text.contains("highest vulnerability CRITICAL") && images.text.contains("vulnerabilities 12"), images.text)
        XCTAssertEqual(queryItems(service.requests.last)["filter"], "repository:'kestrel/api'")
    }

    /// Who can use the Falcon console and with which roles, administrators first; roles that could not be read are
    /// said so, never taken for none.
    func testUsersListEveryConsoleUserWithTheirRolesAdministratorsFirst() async throws {
        let service = FakeService()
        service.answers["/user-management/queries/users/v1"] = (200, #"{"meta":{"pagination":{"offset":0,"limit":500,"total":3}},"resources":["u-1","u-2","u-3"]}"#)
        service.answers["/user-management/entities/users/GET/v1"] = (200, #"{"resources":[{"uuid":"u-1","uid":"analyst@kestrel.example"},{"uuid":"u-2","uid":"admin@kestrel.example"},{"uuid":"u-3","uid":"new@kestrel.example"}]}"#)
        service.answers["/user-management/combined/user-roles/v1?user_uuid=u-1"] = (200, #"{"resources":[{"role_id":"falcon_console_guest","role_name":"Falcon Console Guest"}]}"#)
        service.answers["/user-management/combined/user-roles/v1?user_uuid=u-2"] = (200, #"{"resources":[{"role_id":"falcon_administrator","role_name":"Falcon Administrator"}]}"#)
        service.answers["/user-management/combined/user-roles/v1?user_uuid=u-3"] = (500, #"{"errors":[{"code":500,"message":"try later"}]}"#)
        let users = try await call("users", "{}", service, in: falconUS)
        XCTAssertFalse(users.isError, users.text)
        let lines = users.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("admin@kestrel.example") && lines[0].contains("Falcon Administrator"), users.text)
        XCTAssertTrue(lines.contains { $0.contains("new@kestrel.example: roles could not be read") }, users.text)
        XCTAssertTrue(users.text.contains("whether they are administrators is unknown"), users.text)
        XCTAssertEqual(users.structured?["complete"] as? Bool, false)
    }

    /// check-access tries each read once and names the cloud; it sends no request that could change anything, so it
    /// warns of Real Time Response's write and admin scopes only where a read that needs them shows them, and says the
    /// rest are not verified.
    func testCheckAccessSendsOnlyReadsAndSaysWhatItCannotVerify() async throws {
        let service = FakeService()
        let empty = (200, #"{"meta":{"pagination":{"offset":0,"limit":1,"total":0}},"resources":[]}"#)
        for path in ["/devices/queries/devices/v1", "/alerts/queries/alerts/v2", "/devices/queries/host-groups/v1", "/user-management/queries/users/v1"] { service.answers[path] = empty }
        service.answers["/real-time-response-audit/combined/sessions/v1"] = (403, #"{"errors":[{"code":403,"message":"access denied, authorization failed"}]}"#)
        service.answers["/container-security/combined/image-assessment/images/v1"] = (403, #"{"errors":[{"code":403,"message":"This feature requires a Falcon Cloud Security subscription."}]}"#)
        service.answers["/real-time-response/entities/active-responder-command/v1"] = (404, #"{"errors":[{"code":404,"message":"no such request"}]}"#)
        service.answers["/real-time-response/entities/admin-command/v1"] = (403, #"{"errors":[{"code":403,"message":"access denied, authorization failed"}]}"#)
        let checked = try await call("check-access", "{}", service)
        XCTAssertFalse(checked.isError, checked.text)
        for words in ["Falcon cloud EU-1, api.eu-1.crowdstrike.com", "✓ Hosts (Hosts: Read)", "✓ Alerts (Alerts: Read)",
                      "⚠ Real Time Response sessions: the API client lacks the scope Real time response audit: Read",
                      "⚠ Container image assessments: this needs a Falcon subscription",
                      "⚠ Appears to hold Real time response: Write, which Detection must not have", "✓ Holds no Real time response (admin): Write",
                      "Hosts: Write, Host groups: Write, Alerts: Write, IOC Management: Write: write access not verified — Falcon offers no way to list a client's scopes without attempting a change",
                      "and no Write scope at all"] {
            XCTAssertTrue(checked.text.contains(words), "\(words): \(checked.text)")
        }
        XCTAssertEqual(service.requests.filter { $0.httpMethod != "GET" }.count, 0, "no request that could change anything")
        XCTAssertEqual(queryItems(service.requests.first { $0.url?.path == "/real-time-response/entities/active-responder-command/v1" })["cloud_request_id"],
                       "00000000-0000-0000-0000-000000000000")
    }
}
