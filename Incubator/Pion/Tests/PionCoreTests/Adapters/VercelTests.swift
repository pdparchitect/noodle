import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class VercelTests: XCTestCase {
    static let team = "team_kestrel0123456789"
    static let project = "prj_web0123456789"
    private let vercel = try! Vercel.preset.makeConnection(name: "Vercel — Kestrel", values: ["team": VercelTests.team])

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await callTool(Vercel.adapter, tool, arguments, on: service, in: vercel)
    }

    static func projects(_ service: FakeService, _ items: String = #"{"id":"\#(project)","name":"web"}"#) {
        service.answers["/v10/projects"] = (200, #"{"projects":[\#(items)],"pagination":{"count":1,"next":null,"prev":null}}"#)
        service.answers["/v9/projects/web"] = (200, items)
        service.answers["/v9/projects/\(project)"] = (200, items)
    }

    func testDetectionIsReadOnlyWithABearerTokenAndTheMCPServerStaysApart() async throws {
        XCTAssertEqual(Vercel.preset.name, "Vercel Detection")
        XCTAssertEqual(vercel.endpoint.absoluteString, "https://api.vercel.com")
        XCTAssertEqual(vercel.tokenHeader, "Authorization")
        XCTAssertEqual(vercel.tokenScheme, "Bearer")
        XCTAssertEqual(vercel.adapter, "vercel")
        XCTAssertNotNil(PionAdapters.all["vercel"])
        XCTAssertEqual(Vercel.adapter.watchedTool, "security-events")
        XCTAssertEqual(Vercel.mcp.name, "Vercel")
        guard case .connection(let mcp) = Vercel.mcp.configuration else { return XCTFail("no connection") }
        XCTAssertEqual(mcp.endpoint.absoluteString, "https://mcp.vercel.com")
        XCTAssertNil(Vercel.mcp.adapter)
        for id in [Vercel.preset.id, Vercel.containment.id, Vercel.mcp.id] { XCTAssertTrue(PionCatalogue.entries.contains { $0.id == id }, id) }
        let setup = Vercel.setup.joined(separator: "\n")
        XCTAssertTrue(setup.contains("not finely scoped"), setup)
        XCTAssertTrue(setup.contains("**Pro Viewer**") && setup.contains("**Enterprise Viewer**"), setup)
        let listed = try JSONSerialization.jsonObject(with: try await Vercel.adapter.tools(for: vercel)) as! [String: Any]
        for tool in try XCTUnwrap(listed["tools"] as? [[String: Any]]) {
            XCTAssertEqual((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true, "\(tool["name"] ?? "")")
        }
    }

    /// Nothing goes anywhere but api.vercel.com, every request names the team, and a team Vercel would not give is
    /// refused before anything is sent.
    func testOnlyAPIVercelComAndAWellFormedTeamAreReached() async throws {
        let service = FakeService()
        for base in ["https://api.vercel.com.evil.example", "http://api.vercel.com", "https://api.vercel.com:8443", "https://api.vercel.com/v2"] {
            let client = ServiceClient(base: URL(string: base)!, access: service, settings: ["team": Self.team])
            do { _ = try await Vercel.Domains().run(.init(domain: nil), on: client); XCTFail(base) }
            catch { XCTAssertTrue(error.localizedDescription.contains("Nothing was sent"), "\(base): \(error.localizedDescription)") }
        }
        let wrong = try Vercel.preset.makeConnection(name: "Vercel", values: ["team": "-bad-"])
        let refused = try await callTool(Vercel.adapter, "domains", "{}", on: service, in: wrong)
        XCTAssertTrue(refused.isError && refused.text.contains("Team ID"), refused.text)
        XCTAssertTrue(service.requests.isEmpty)

        service.answers["/v5/domains"] = (200, #"{"domains":[],"pagination":{"count":0,"next":null,"prev":null}}"#)
        _ = try await call("domains", "{}", service)
        XCTAssertEqual(queryItems(service.requests.last)["teamId"], Self.team)
        let slug = try Vercel.preset.makeConnection(name: "Vercel", values: ["team": "kestrel"])
        _ = try await callTool(Vercel.adapter, "domains", "{}", on: service, in: slug)
        XCTAssertEqual(queryItems(service.requests.last)["slug"], "kestrel")
        XCTAssertNil(queryItems(service.requests.last)["teamId"])
    }

    /// Vercel's 403 for a token it does not accept is told as the token rejected, not a missing role; a plan that lacks
    /// something is said plainly.
    func testRefusalsSayWhatToChange() async throws {
        let service = FakeService()
        service.answers["/v5/domains"] = (403, #"{"error":{"code":"forbidden","message":"Not authorized","invalidToken":true}}"#)
        let rejected = try await call("domains", "{}", service)
        XCTAssertTrue(rejected.isError && rejected.text.contains("did not accept the access token"), rejected.text)
        service.answers["/v5/domains"] = (403, #"{"error":{"code":"forbidden","message":"You don't have permission to list domains."}}"#)
        let forbidden = try await call("domains", "{}", service)
        XCTAssertTrue(forbidden.isError && forbidden.text.contains("Viewer"), forbidden.text)
        service.answers["/v5/domains"] = (402, #"{"error":{"code":"payment_required","message":"This feature is only available on the Enterprise plan."}}"#)
        let plan = try await call("domains", "{}", service)
        XCTAssertTrue(plan.isError && plan.text.contains("plan does not include it"), plan.text)
    }

    /// Deployments are read page after page, each next page from Vercel's next time as until, and say who made each
    /// and how.
    func testDeploymentsFollowVercelsNextTimeAndNameTheirCreator() async throws {
        let service = FakeService()
        let one = #"{"uid":"dpl_1","name":"web","url":"web-1.vercel.app","created":1764000000000,"state":"READY","target":"production","source":"cli","creator":{"uid":"u1","username":"mallory"},"meta":{"githubCommitRef":"main","githubCommitSha":"abcdef1234567890","githubCommitAuthorLogin":"alice"}}"#
        let two = #"{"uid":"dpl_2","name":"web","url":"web-2.vercel.app","created":1763990000000,"state":"READY","source":"git","creator":{"uid":"u2","username":"alice"}}"#
        service.sequences["/v7/deployments"] = [
            (200, #"{"deployments":[\#(one)],"pagination":{"count":1,"next":1763999999999,"prev":null}}"#),
            (200, #"{"deployments":[\#(two)],"pagination":{"count":1,"next":null,"prev":null}}"#),
        ]
        let result = try await call("deployments", #"{"limit":1}"#, service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("production READY by mallory through cli, branch main at abcdef123456 by alice"), result.text)
        XCTAssertTrue(result.text.contains("More deployments match"), result.text)

        let paged = FakeService()
        paged.sequences["/v7/deployments"] = [
            (200, #"{"deployments":[\#(one)],"pagination":{"count":1,"next":1763999999999,"prev":null}}"#),
            (200, #"{"deployments":[\#(two)],"pagination":{"count":1,"next":null,"prev":null}}"#),
        ]
        let both = try await call("deployments", "{}", paged)
        XCTAssertEqual(both.structured?["complete"] as? Bool, true, both.text)
        XCTAssertEqual(paged.requests.map { queryItems($0)["until"] }.last, "1763999999999")
        XCTAssertTrue(paged.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "api.vercel.com" })
    }

    /// The same next page given twice, or an empty page that says more follow, is never taken as the end.
    func testContradictoryPagingIsNeverTakenAsWhole() async throws {
        let service = FakeService()
        let member = #"{"uid":"u1","email":"a@kestrel.example","role":"OWNER","confirmed":true}"#
        service.sequences["/v3/teams/\(Self.team)/members"] = [
            (200, #"{"members":[\#(member)],"pagination":{"hasNext":true,"count":1,"next":1700,"prev":null}}"#),
            (200, #"{"members":[\#(member)],"pagination":{"hasNext":true,"count":1,"next":1700,"prev":null}}"#),
        ]
        let result = try await call("members", "{}", service)
        XCTAssertTrue(result.text.contains("same next page again"), result.text)
        XCTAssertEqual(result.structured?["complete"] as? Bool, false)
    }

    /// Members come owners first, with invitations said.
    func testMembersComeOwnersFirst() async throws {
        let service = FakeService()
        service.answers["/v3/teams/\(Self.team)/members"] = (200, #"{"members":[{"uid":"u2","email":"v@kestrel.example","role":"VIEWER","confirmed":true},{"uid":"u1","email":"o@kestrel.example","role":"OWNER","confirmed":true},{"uid":"u3","email":"n@kestrel.example","role":"MEMBER","confirmed":false}],"pagination":{"count":3,"next":null,"prev":null}}"#)
        let result = try await call("members", "{}", service)
        let lines = result.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("3 members, 1 owner"), result.text)
        XCTAssertTrue(lines[1].hasPrefix("o@kestrel.example: OWNER"), result.text)
        XCTAssertTrue(result.text.contains("n@kestrel.example: MEMBER, invited, not yet joined"), result.text)
    }

    /// Environment variables are listed by name, type and target: decrypt is never asked for, and no value Vercel
    /// gives reaches the result.
    func testEnvVarsNeverAskForValuesAndFlagWhatIsReadable() async throws {
        let service = FakeService()
        Self.projects(service)
        service.answers["/v10/projects/\(Self.project)/env"] = (200, #"{"envs":[{"id":"e1","key":"DATABASE_URL","type":"plain","value":"postgres://admin:hunter2@db","target":["production","preview"]},{"id":"e2","key":"STRIPE_KEY","type":"sensitive","value":"","target":["production"]},{"id":"e3","key":"API_TOKEN","type":"encrypted","value":"eyJ2IjoiZW5jcnlwdGVkIn0","target":"development"}]}"#)
        let result = try await call("env-vars", "{}", service)
        XCTAssertFalse(result.isError, result.text)
        let everything = result.text + String(data: try JSONSerialization.data(withJSONObject: result.structured ?? [:]), encoding: .utf8)!
        for secret in ["hunter2", "postgres://", "eyJ2IjoiZW5jcnlwdGVkIn0"] { XCTAssertFalse(everything.contains(secret), secret) }
        XCTAssertTrue(result.text.contains("3 variables in 1 project, 2 flagged"), result.text)
        XCTAssertTrue(result.text.contains("web DATABASE_URL (plain; production, preview)\n  ⚠ plain"), result.text)
        XCTAssertTrue(result.text.contains("API_TOKEN (encrypted; development)\n  ⚠ not sensitive"), result.text)
        XCTAssertFalse(result.text.contains("STRIPE_KEY (sensitive; production)\n"), "a sensitive production-only variable is not flagged: \(result.text)")
        XCTAssertTrue(service.requests.allSatisfy { queryItems($0)["decrypt"] == nil && $0.httpMethod == "GET" })
    }

    /// Bypass secrets, which Vercel gives as keys, are counted, never shown.
    func testProjectProtectionCountsBypassSecretsWithoutShowingThem() async throws {
        let service = FakeService()
        Self.projects(service, #"{"id":"\#(Self.project)","name":"web","ssoProtection":{"deploymentType":"preview"},"passwordProtection":null,"protectionBypass":{"s3cr3tBypassValue0123456789abcdef":{"scope":"automation-bypass","createdAt":1}},"gitForkProtection":false}"#)
        let result = try await call("project-protection", "{}", service)
        XCTAssertFalse(result.isError, result.text)
        let everything = result.text + String(data: try JSONSerialization.data(withJSONObject: result.structured ?? [:]), encoding: .utf8)!
        XCTAssertFalse(everything.contains("s3cr3tBypassValue"))
        XCTAssertTrue(result.text.contains("bypass secrets: 1"), result.text)
        XCTAssertTrue(result.text.contains("⚠ only previews are protected"), result.text)
        XCTAssertTrue(result.text.contains("⚠ Git fork protection is off"), result.text)
    }

    /// Domains list the records Vercel hosts, from the current API.
    func testDomainsReadTheirRecords() async throws {
        let service = FakeService()
        service.answers["/v5/domains"] = (200, #"{"domains":[{"name":"kestrel.example","verified":true,"serviceType":"zeit.world","expiresAt":1800000000000}],"pagination":{"count":1,"next":null,"prev":null}}"#)
        service.answers["/v5/domains/kestrel.example/records"] = (200, #"{"records":[{"id":"rec_1","name":"old","type":"CNAME","value":"kestrel-old.herokuapp.com","ttl":60,"createdAt":1600000000000}],"pagination":{"count":1,"next":null,"prev":null}}"#)
        let result = try await call("domains", "{}", service)
        XCTAssertTrue(result.text.contains("kestrel.example: verified, DNS on Vercel"), result.text)
        XCTAssertTrue(result.text.contains("CNAME old → kestrel-old.herokuapp.com TTL 60"), result.text)
        XCTAssertEqual(result.structured?["complete"] as? Bool, true)
    }

    /// The activity log is read newest first, each next page asking for what came before the oldest the last gave.
    func testActivityLogPagesBackByTheOldestEvent() async throws {
        let service = FakeService()
        func event(_ id: String, _ ms: Int, _ type: String = "user-token-created") -> String {
            #"{"id":"\#(id)","type":"\#(type)","text":"mallory created a token","createdAt":\#(ms),"principal":{"type":"user","username":"mallory"}}"#
        }
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        service.sequences["/v3/events"] = [
            (200, #"{"events":[\#(event("e1", now - 1_000)),\#(event("e2", now - 2_000))]}"#),
            (200, #"{"events":[\#(event("e2", now - 2_000)),\#(event("e3", now - 3_000))]}"#),
            (200, #"{"events":[\#(event("e4", now - 4_000))]}"#),
        ]
        let result = try await Vercel.$activityPage.withValue(2) { try await call("activity-log", "{}", service) }
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.hasPrefix("4 events"), result.text)
        XCTAssertTrue(result.text.contains("user-token-created by mallory: mallory created a token"), result.text)
        let untils = service.requests.map { queryItems($0)["until"] ?? "" }
        XCTAssertEqual(ServiceAlert.time(untils[1]).map { Int($0.timeIntervalSince1970) }, (now - 2_000) / 1_000, "\(untils)")
        XCTAssertEqual(result.structured?["complete"] as? Bool, true)
    }

    /// security-events names watched activity and attacks, and what it could not read.
    func testSecurityEventsReadsWatchedActivityAndAttacks() async throws {
        let service = FakeService()
        Self.projects(service)
        let now = Int(Date().timeIntervalSince1970 * 1_000)
        service.answers["/v3/events"] = (200, #"{"events":[{"id":"e1","type":"team-member-role-update","text":"mallory made eve an Owner","createdAt":\#(now - 60_000),"principal":{"type":"user","username":"mallory"}},{"id":"e2","type":"deployment","text":"a deployment","createdAt":\#(now - 30_000)}]}"#)
        service.answers["/v1/security/firewall/attack-status"] = (200, #"{"anomalies":[{"projectId":"\#(Self.project)","ownerId":"\#(Self.team)","startTime":\#(now - 120_000),"endTime":null,"atMinute":0,"affectedHostMap":{"kestrel.example":{"ddosAlerts":{"x":{"atMinute":"0","totalReqs":90000}}}}}]}"#)
        let result = try await call("security-events", "{}", service)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Member added or role changed: "), result.text)
        XCTAssertFalse(result.text.contains("a deployment"), result.text)
        XCTAssertTrue(result.text.contains("DDoS attack detected on web [\(Self.project)], hitting kestrel.example, still going on"), result.text)
        let types = queryItems(service.requests.first { $0.url?.path == "/v3/events" })["types"] ?? ""
        XCTAssertTrue(types.contains("user-token-created") && types.contains("project-sso-protection"), types)

        service.answers["/v1/security/firewall/attack-status"] = (403, #"{"error":{"code":"forbidden","message":"no"}}"#)
        let partly = try await call("security-events", "{}", service)
        XCTAssertTrue(partly.text.contains("Could not read attacks the Vercel Firewall detected"), partly.text)
    }

    /// The watch wakes once for each watched event, tells a feed it cannot read once, and never repeats an event.
    func testWatchTellsEachEventOnceAndAnUnreadableFeedOnce() async throws {
        let service = FakeService()
        Self.projects(service)
        let now = Date()
        let ms = Int(now.timeIntervalSince1970 * 1_000)
        service.answers["/v3/events"] = (200, #"{"events":[{"id":"e1","type":"user-token-created","text":"t","createdAt":\#(ms - 60_000)}]}"#)
        service.answers["/v1/security/firewall/attack-status"] = (403, #"{"error":{"code":"forbidden","message":"no"}}"#)
        let account = UUID()
        let client = ServiceClient(base: vercel.endpoint, access: service, settings: ["team": Self.team], account: account)
        let trigger = Vercel.NewSecurityEvents()
        let first = try await trigger.alerts(since: now.addingTimeInterval(-3_600), on: client, account: account, now: now)
        XCTAssertEqual(first.filter { $0.id.hasPrefix("activity/") }.count, 1, "\(first)")
        XCTAssertEqual(first.filter { $0.id.hasPrefix("unreadable/attacks") }.count, 1, "\(first)")
        let second = try await trigger.alerts(since: now.addingTimeInterval(-3_600), on: client, account: account, now: now.addingTimeInterval(300))
        XCTAssertTrue(second.isEmpty, "\(second)")
    }

    /// check-access says whose token it is, the team's plan and role, and warns of a role that changes things.
    func testCheckAccessWarnsOfARoleThatChangesThings() async throws {
        let service = FakeService()
        service.answers["/v2/user"] = (200, #"{"user":{"id":"u9","email":"pion-detection@kestrel.example","username":"pion"}}"#)
        service.answers["/v2/teams/\(Self.team)"] = (200, #"{"id":"\#(Self.team)","slug":"kestrel","name":"Kestrel","billing":{"plan":"pro"},"membership":{"role":"MEMBER","confirmed":true}}"#)
        Self.projects(service)
        let result = try await call("check-access", "{}", service)
        XCTAssertTrue(result.text.contains("on the pro plan: they are MEMBER there"), result.text)
        XCTAssertTrue(result.text.contains("⚠ The MEMBER role can change things"), result.text)
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
