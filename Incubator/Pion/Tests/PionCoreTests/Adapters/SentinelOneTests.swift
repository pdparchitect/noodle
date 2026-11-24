import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class SentinelOneTests: XCTestCase {
    private let s1 = try! SentinelOne.preset.makeConnection(name: "SentinelOne — Kestrel", values: ["console": "usea1-kestrel.sentinelone.net"])
    private let api = "/web/api/v2.1"
    private let agentID = "1234567890123456789", threatID = "9876543210987654321"

    private func call(_ tool: String, _ arguments: String, _ service: FakeService, in connection: ToolConnection? = nil) async throws -> AdapterResult {
        try await SentinelOne.$pause.withValue({ _ in }) { try await callTool(SentinelOne.adapter, tool, arguments, on: service, in: connection ?? s1) }
    }

    private func agent(_ id: String, network: String = "connected", extra: String = "") -> String {
        #"{"id":"\#(id)","computerName":"LT-0423","osName":"Windows 11","osType":"windows","networkStatus":"\#(network)","isActive":true,"infected":true,"activeThreats":1,"lastActiveDate":"2026-11-23T09:00:00Z","agentVersion":"24.1","siteName":"HQ"\#(extra)}"#
    }

    private func threat(_ id: String, extra: String = "") -> String {
        #"{"id":"\#(id)","threatInfo":{"threatName":"procdump.exe","classification":"Hacktool","confidenceLevel":"malicious","mitigationStatus":"mitigated","incidentStatus":"unresolved","analystVerdict":"undefined","createdAt":"2026-11-23T08:59:00Z","sha1":"\#(String(repeating: "a", count: 40))","filePath":"C:\\Temp\\procdump.exe","storyline":"ABCDEF"},"agentRealtimeInfo":{"agentId":"\#(agentID)","agentComputerName":"LT-0423","agentOsType":"windows"},"mitigationStatus":[{"action":"kill","status":"success","mitigationEndedAt":"2026-11-23T09:00:00Z"}],"indicators":[{"category":"Evasion","description":"Dumped LSASS","tactics":[{"name":"Credential Access","techniques":[{"name":"T1003"}]}]}]\#(extra)}"#
    }

    func testAuditKeepsItsIDAndAdapterUnderItsNewNameWithAViewerToken() throws {
        XCTAssertEqual(SentinelOne.preset.name, "SentinelOne Audit")
        XCTAssertEqual(SentinelOne.preset.id, "9d1c01e9-bb44-4a66-876a-e60b48337ca3")
        XCTAssertEqual(s1.endpoint.absoluteString, "https://usea1-kestrel.sentinelone.net/web/api/v2.1")
        XCTAssertEqual(s1.tokenScheme, "ApiToken")
        XCTAssertEqual(s1.adapter, "sentinelone")
        XCTAssertNotNil(PionAdapters.all["sentinelone"])
        XCTAssertEqual(SentinelOne.adapter.watchedTool, "security-events")
        let setup = SentinelOne.setup.joined(separator: "\n")
        XCTAssertTrue(setup.contains("**Viewer** role") && setup.contains("Service Users") && setup.contains("sentinelone.net"), setup)
    }

    /// A console that is not a host under sentinelone.net is refused before anything is sent, by every operation and
    /// the watch.
    func testOnlyAConsoleUnderSentinelOneNetIsReached() async throws {
        for host in ["evil.example", "sentinelone.net.evil.example", "sentinelone.net", "evilsentinelone.net"] {
            let connection = try SentinelOne.preset.makeConnection(name: "Bad", values: ["console": host])
            let service = FakeService()
            for (tool, arguments) in [("agents", "{}"), ("threats", "{}"), ("check-access", "{}"), ("security-events", "{}")] {
                let result = try await call(tool, arguments, service, in: connection)
                XCTAssertTrue(result.isError && result.text.contains("Nothing was sent"), "\(host) \(tool): \(result.text)")
            }
            do { _ = try await SentinelOne.adapter.alerts(since: Date().addingTimeInterval(-600), connection: connection, access: service); XCTFail(host) } catch {}
            XCTAssertTrue(service.requests.isEmpty, host)
        }
    }

    func testAgentsFollowEveryCursorWithTheSameQuery() async throws {
        let service = FakeService()
        service.sequences["\(api)/agents"] = [(200, #"{"data":[\#(agent("1"))],"pagination":{"nextCursor":"Y3Vyc29yLTI=","totalItems":2}}"#),
                                             (200, #"{"data":[\#(agent("2", network: "disconnected"))],"pagination":{"nextCursor":null,"totalItems":2}}"#)]
        let result = try await call("agents", #"{"name":"LT-04","networkStatus":"connected","osType":"windows"}"#, service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("2 agents") && result.text.contains("disconnected from the network") && result.text.contains("infected, 1 active threat"), result.text)
        XCTAssertEqual(result.structured?["complete"] as? Bool, true)
        let first = queryItems(service.requests.first), second = queryItems(service.requests.last)
        XCTAssertEqual(first["computerName__contains"], "LT-04")
        XCTAssertEqual(first["networkStatuses"], "connected")
        XCTAssertNil(first["cursor"])
        XCTAssertEqual(second["cursor"], "Y3Vyc29yLTI=")
        XCTAssertEqual(first.filter { $0.key != "cursor" }, second.filter { $0.key != "cursor" }, "the same query with the cursor")
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "usea1-kestrel.sentinelone.net" })
    }

    /// Commas would add values to a filter, so a name holding one is refused, as are malformed IDs and limits.
    func testValuesThatCouldChangeAFilterAreRefused() async throws {
        let service = FakeService()
        for (tool, arguments) in [("agents", #"{"name":"a,b"}"#), ("agents", #"{"limit":1000}"#), ("agent", #"{"id":"12,13"}"#), ("threats", #"{"agentId":"x"}"#),
                                  ("threat", #"{"id":"../1"}"#), ("activities", #"{"types":[]}"#), ("threats", #"{"since":"2020-01-01T00:00:00Z"}"#)] {
            let result = try await call(tool, arguments, service)
            XCTAssertTrue(result.isError, "\(tool) \(arguments)")
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    /// An answer that carries any error, with a message or without, is never taken as empty; one without its list is
    /// unreadable; and one that says more match than it gave, without a next page, says it stopped.
    func testErrorsAndMissingListsAreNeverEmptyAndShortAnswersSaySo() async throws {
        for body in [#"{"data":[],"errors":[{"code":4000010}]}"#, #"{"data":[],"errors":[{"title":"Validation Error","detail":"bad filter"}]}"#, #"{"pagination":{"totalItems":3}}"#, #"{"data":{"x":1}}"#] {
            let service = FakeService()
            service.answers["\(api)/threats"] = (200, body)
            let result = try await call("threats", "{}", service)
            XCTAssertTrue(result.isError, "\(body): \(result.text)")
            XCTAssertFalse(result.text.contains("No threats"), body)
        }
        let short = FakeService()
        short.answers["\(api)/threats"] = (200, #"{"data":[\#(threat(threatID))],"pagination":{"nextCursor":null,"totalItems":5}}"#)
        let result = try await call("threats", "{}", short)
        XCTAssertTrue(result.text.contains("Incomplete") && result.text.contains("said 5 match but gave no next page after 1"), result.text)
        XCTAssertEqual(result.structured?["complete"] as? Bool, false)
        let empty = FakeService()
        empty.answers["\(api)/threats"] = (200, #"{"data":[],"pagination":{"totalItems":0}}"#)
        let none = try await call("threats", "{}", empty)
        XCTAssertTrue(none.text.contains("No threats") && !none.text.contains("in what was read"), none.text)
    }

    /// A page after the first that fails keeps what was read and says where and why it stopped; a cursor given twice
    /// stops too.
    func testAFailedOrRepeatedPageSaysWhereItStopped() async throws {
        let failing = FakeService()
        failing.sequences["\(api)/threats"] = [(200, #"{"data":[\#(threat(threatID))],"pagination":{"nextCursor":"next1"}}"#), (500, #"{"errors":[{"title":"Server Error"}]}"#)]
        let result = try await call("threats", "{}", failing)
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("1 threat") && result.text.contains("stopped at page 2"), result.text)
        let repeating = FakeService()
        repeating.sequences["\(api)/threats"] = [(200, #"{"data":[\#(threat("1"))],"pagination":{"nextCursor":"same"}}"#), (200, #"{"data":[\#(threat("2"))],"pagination":{"nextCursor":"same"}}"#)]
        let again = try await call("threats", "{}", repeating)
        XCTAssertTrue(again.text.contains("the same next page again"), again.text)
    }

    /// A refusal says which permission or token to fix; the rate limit is waited out once when SentinelOne says soon.
    func testRefusalsSayWhatToChangeAndTheRateLimitIsWaitedOut() async throws {
        let forbidden = FakeService()
        forbidden.answers["\(api)/threats"] = (403, #"{"errors":[{"code":4030010,"title":"Forbidden","detail":"Action is not allowed"}]}"#)
        let refused = try await call("threats", "{}", forbidden)
        XCTAssertTrue(refused.isError && refused.text.contains("Threats: View") && refused.text.contains("Action is not allowed") && refused.text.contains("check-access"), refused.text)
        let expired = FakeService()
        expired.answers["\(api)/agents"] = (401, #"{"errors":[{"code":4010010,"title":"Authentication Failed"}]}"#)
        let rejected = try await call("agents", "{}", expired)
        XCTAssertTrue(rejected.isError && rejected.text.contains("did not accept the API token") && rejected.text.contains("Generate API Token"), rejected.text)
        let busy = FakeService()
        busy.sequences["\(api)/agents"] = [(429, #"{"errors":[{"title":"Too Many Requests"}]}"#), (200, #"{"data":[\#(agent(agentID))],"pagination":{}}"#)]
        busy.sequenceHeaders["\(api)/agents"] = [["Retry-After": "2"], [:]]
        let waited = try await call("agents", "{}", busy)
        XCTAssertFalse(waited.isError, waited.text)
        let slow = FakeService()
        slow.answers["\(api)/agents"] = (429, #"{"errors":[{"title":"Too Many Requests"}]}"#)
        slow.responseHeaders = ["Retry-After": "120"]
        let limited = try await call("agents", "{}", slow)
        XCTAssertTrue(limited.isError && limited.text.contains("asked to wait 120 seconds"), limited.text)
    }

    /// One agent by ID is absent only when SentinelOne says so plainly; anything else is inconclusive.
    func testAnAgentByIDIsAbsentOnlyWhenTheAnswerIsUnambiguous() async throws {
        let present = FakeService()
        present.answers["\(api)/agents"] = (200, #"{"data":[\#(agent(agentID, extra: #","scanStatus":"finished""#))],"pagination":{"totalItems":1}}"#)
        present.answers["\(api)/threats"] = (200, #"{"data":[\#(threat(threatID))],"pagination":{"totalItems":1}}"#)
        let found = try await call("agent", #"{"id":"\#(agentID)"}"#, present)
        XCTAssertTrue(found.text.contains("LT-0423 [\(agentID)]") && found.text.contains("procdump.exe") && found.text.contains("Scan: finished"), found.text)
        XCTAssertEqual(queryItems(present.requests.first)["ids"], agentID)
        for (label, answer, absent) in [("empty", (200, #"{"data":[],"pagination":{"totalItems":0}}"#), true),
                                        ("structured 404", (404, #"{"errors":[{"code":404,"title":"Not Found","id":"\#(agentID)"}]}"#), true),
                                        ("a seven-digit code beginning 404", (404, #"{"errors":[{"code":4040010,"title":"Not Found","id":"\#(agentID)"}]}"#), false),
                                        ("a count as text", (200, #"{"data":[],"pagination":{"totalItems":"0"}}"#), false),
                                        ("a cursor as a number", (200, #"{"data":[],"pagination":{"nextCursor":7}}"#), false),
                                        ("a count of one with nothing given", (200, #"{"data":[],"pagination":{"totalItems":1}}"#), false),
                                        ("structured 404, numeric id", (404, #"{"errors":[{"code":404,"id":\#(agentID)}]}"#), true),
                                        ("404 naming another", (404, #"{"errors":[{"code":404,"title":"Not Found","id":"12345678901234567890"}]}"#), false),
                                        ("route 404 echoing the ID", (404, #"{"errors":[{"code":404,"title":"Not Found","detail":"route not found /agents?ids=\#(agentID)"}]}"#), false),
                                        ("404 saying not found in words", (404, #"{"errors":[{"title":"Not Found","detail":"Agent \#(agentID) not found"}]}"#), false),
                                        ("404 naming it with another code", (404, #"{"errors":[{"code":4000010,"id":"\#(agentID)"}]}"#), false),
                                        ("empty page with a next page", (200, #"{"data":[],"pagination":{"nextCursor":"more"}}"#), false),
                                        ("empty page with a next page and none counted", (200, #"{"data":[],"pagination":{"nextCursor":"more","totalItems":0}}"#), false),
                                        ("the agent while none counted", (200, #"{"data":[\#(agent(agentID))],"pagination":{"totalItems":0}}"#), false),
                                        ("the agent with a next page", (200, #"{"data":[\#(agent(agentID))],"pagination":{"nextCursor":"more"}}"#), false),
                                        ("empty page without a count", (200, #"{"data":[]}"#), true),
                                        ("404 without errors", (404, "{}"), false),
                                        ("another agent", (200, #"{"data":[\#(agent("555"))]}"#), false),
                                        ("errors", (200, #"{"data":[],"errors":[{"code":5000}]}"#), false),
                                        ("twice", (200, #"{"data":[\#(agent(agentID)),\#(agent(agentID))]}"#), false),
                                        ("no list", (200, #"{"pagination":{}}"#), false)] {
            let service = FakeService()
            service.answers["\(api)/agents"] = answer
            let result = try await call("agent", #"{"id":"\#(agentID)"}"#, service)
            if absent { XCTAssertTrue(!result.isError && result.structured?["found"] as? Bool == false, "\(label): \(result.text)") }
            else { XCTAssertTrue(result.isError && result.text.contains("could not be read"), "\(label): \(result.text)") }
        }
    }

    func testThreatsAndOneThreatInFullSayWhatTheyCouldNotRead() async throws {
        let service = FakeService()
        service.answers["\(api)/threats"] = (200, #"{"data":[\#(threat(threatID))],"pagination":{"totalItems":1}}"#)
        let listed = try await call("threats", #"{"computerName":"LT-0423","incidentStatus":"unresolved","confidence":"malicious","since":"\#(Entra.iso(Date().addingTimeInterval(-86_400)))"}"#, service)
        XCTAssertTrue(listed.text.contains("Hacktool") && listed.text.contains("incident unresolved"), listed.text)
        let sent = queryItems(service.requests.last)
        XCTAssertEqual(sent["incidentStatuses"], "unresolved")
        XCTAssertEqual(sent["confidenceLevels"], "malicious")
        XCTAssertEqual(sent["sortBy"], "createdAt")
        XCTAssertNotNil(sent["createdAt__gte"])
        XCTAssertNotNil(sent["createdAt__lte"])
        service.answers["\(api)/threats/\(threatID)/notes"] = (200, #"{"data":[{"text":"Looks like INV-12","createdAt":"2026-11-23T10:00:00Z","creator":"Ana"}],"pagination":{}}"#)
        service.answers["\(api)/threats/\(threatID)/timeline"] = (403, #"{"errors":[{"title":"Forbidden"}]}"#)
        let one = try await call("threat", #"{"id":"\#(threatID)"}"#, service)
        XCTAssertFalse(one.isError, one.text)
        for expected in ["Credential Access: T1003", "Dumped LSASS", "kill success", "storyline ABCDEF", "Looks like INV-12", "Could not read: its timeline"] {
            XCTAssertTrue(one.text.contains(expected), "\(expected): \(one.text)")
        }
    }

    func testActivitiesSitesGroupsAndExclusions() async throws {
        let service = FakeService()
        service.answers["\(api)/activities"] = (200, #"{"data":[{"id":"77","activityType":1001,"primaryDescription":"Ana disconnected LT-0423 from network","createdAt":"2026-11-23T10:00:00Z","userId":"42","agentId":"\#(agentID)","data":{"username":"Ana"}}],"pagination":{}}"#)
        let log = try await call("activities", #"{"agentId":"\#(agentID)","types":[1001,2001]}"#, service)
        XCTAssertTrue(log.text.contains("type 1001") && log.text.contains("(by Ana)"), log.text)
        XCTAssertEqual(queryItems(service.requests.last)["activityTypes"], "1001,2001")
        service.answers["\(api)/sites"] = (200, #"{"data":{"allSites":{"activeLicenses":3},"sites":[{"id":"111","name":"HQ","accountName":"Kestrel","state":"active","siteType":"Paid","activeLicenses":3,"totalLicenses":10}]},"pagination":{}}"#)
        let sites = try await call("sites", "{}", service)
        XCTAssertTrue(sites.text.contains("HQ [111]") && sites.text.contains("3 of 10"), sites.text)
        service.answers["\(api)/groups"] = (200, #"{"data":[{"id":"222","name":"Laptops","siteId":"111","type":"static","totalAgents":40,"isDefault":false}],"pagination":{}}"#)
        let groups = try await call("groups", #"{"siteId":"111"}"#, service)
        XCTAssertTrue(groups.text.contains("Laptops [222]") && groups.text.contains("40 agents"), groups.text)
        service.answers["\(api)/exclusions"] = (200, #"{"data":[{"id":"1","type":"path","value":"C:\\Old","createdAt":"2026-01-01T00:00:00Z","userName":"Ana"},{"id":"2","type":"path","value":"C:\\Users\\Public\\x","createdAt":"2026-11-23T03:00:00Z","userName":"mallory","osType":"windows","scopeName":"HQ"}],"pagination":{}}"#)
        let exclusions = try await call("exclusions", #"{"type":"path"}"#, service)
        let lines = exclusions.text.split(separator: "\n")
        XCTAssertTrue(lines.count >= 3 && lines[1].contains("added by mallory") && lines[2].contains("added by Ana"), "newest first: \(exclusions.text)")
    }

    /// check-access names the token's user, role, scope and expiry, warns of any role but Viewer, and sends only reads.
    func testCheckAccessNamesTheTokensUserRoleAndScopeAndSendsOnlyReads() async throws {
        func console(role: String) -> FakeService {
            let service = FakeService()
            service.answers["\(api)/user"] = (200, #"{"data":{"id":"42","email":"pion-audit@kestrel.example","fullName":"Pion Audit","scope":"account","lowestRole":"\#(role)","scopeRoles":[{"roleName":"\#(role)","name":"Kestrel"}],"apiToken":{"expiresAt":"2027-01-01T00:00:00Z"}}}"#)
            for path in ["agents", "threats", "activities", "groups", "exclusions"] { service.answers["\(api)/\(path)"] = (200, #"{"data":[],"pagination":{"totalItems":0}}"#) }
            service.answers["\(api)/sites"] = (200, #"{"data":{"sites":[]},"pagination":{"totalItems":0}}"#)
            return service
        }
        let viewer = console(role: "Viewer")
        let ok = try await call("check-access", "{}", viewer)
        for expected in ["Pion Audit", "scope account", "Viewer in Kestrel", "expires 2027-01-01", "✓ It holds only the Viewer role", "✓ Agents", "✓ Sites", "usea1-kestrel.sentinelone.net"] {
            XCTAssertTrue(ok.text.contains(expected), "\(expected): \(ok.text)")
        }
        XCTAssertTrue(viewer.requests.allSatisfy { $0.httpMethod == "GET" })
        let admin = try await call("check-access", "{}", console(role: "Admin"))
        XCTAssertTrue(admin.text.contains("⚠ It holds admin, not only Viewer"), admin.text)
        let refused = console(role: "Viewer")
        refused.answers["\(api)/exclusions"] = (403, #"{"errors":[{"title":"Forbidden"}]}"#)
        let partly = try await call("check-access", "{}", refused)
        XCTAssertTrue(partly.text.contains("⚠ Exclusions: the service user's role lacks Exclusions: View"), partly.text)
    }
}
