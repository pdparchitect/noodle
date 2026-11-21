import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class GitHubTests: XCTestCase {
    private let github = try! GitHub.preset.makeConnection(name: "GitHub — Kestrel", values: ["org": "kestrel-labs", "clientID": "Ov23liKestrel"])

    func testAnOrganisationIsReachedUnderItsOwnPath() {
        XCTAssertEqual(github.endpoint.absoluteString, "https://api.github.com/orgs/kestrel-labs")
        XCTAssertNotNil(PionAdapters.all["github"])
        XCTAssertThrowsError(try GitHub.preset.makeConnection(name: "Bad", values: ["org": "a/b", "clientID": "Ov23liKestrel"]))
    }

    func testAnOrganisationSignsInWithACodeThroughItsOwnOAuthApp() throws {
        // GitHub's browser sign-in needs the app's client secret, which a Mac app cannot keep; its device sign-in does not.
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        ToolCatalog.use(PionCatalogue.entries)
        XCTAssertNil(github.tokenHeader, "No token to paste")
        XCTAssertTrue(ToolConnectionService.signsInWithCode(github))
        guard case .connection(let configuration) = GitHub.preset.configuration, let oauth = configuration.oauth else { return XCTFail() }
        XCTAssertEqual(oauth.deviceAuthorizationEndpoint?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "https://github.com/login/oauth/access_token")
        XCTAssertEqual(oauth.scopes, ["read:org", "read:audit_log", "security_events"])
        XCTAssertTrue(oauth.clients.isEmpty, "Each organisation registers its own")
        XCTAssertEqual(configuration.oauthClientField, "clientID")
    }

    func testTheAuditLogSearchesNewestFirst() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/audit-log"] = (200, #"[{"@timestamp":1763110800000,"action":"repo.destroy","actor":"mallory","actor_ip":"203.0.113.77","repo":"kestrel-labs/payroll","actor_location":{"country_code":"NG"}}]"#)
        let log = try await callTool(GitHub.adapter, "audit-log", #"{"phrase":"action:repo.destroy","limit":30}"#, on: service, in: github)
        XCTAssertFalse(log.isError, log.text)
        XCTAssertTrue(log.text.contains("repo.destroy by mallory"), log.text)
        XCTAssertTrue(log.text.contains("2025-11-14T09:00:00Z"), log.text)
        let sent = queryItems(service.requests.first)
        XCTAssertEqual(sent["phrase"], "action:repo.destroy")
        XCTAssertEqual(sent["order"], "desc")
        XCTAssertEqual(sent["include"], "all")
        XCTAssertEqual(sent["per_page"], "30")
    }

    private static let secret = #"{"number":7,"state":"open","secret_type_display_name":"AWS Access Key ID","created_at":"2026-11-19T09:14:00Z","validity":"active","repository":{"full_name":"kestrel-labs/payroll"},"html_url":"https://github.com/kestrel-labs/payroll/security/secret-scanning/7"}"#
    private static let code = #"{"number":3,"state":"open","created_at":"2026-11-19T09:11:00Z","rule":{"security_severity_level":"high","description":"SQL query built from user-controlled sources"},"repository":{"full_name":"kestrel-labs/portal"},"html_url":"https://github.com/kestrel-labs/portal/security/code-scanning/3"}"#
    private static let dependency = #"{"number":12,"state":"open","created_at":"2026-11-18T22:00:00Z","security_advisory":{"severity":"critical","summary":"Remote code execution in log4j"},"dependency":{"package":{"name":"org.apache.logging.log4j:log4j-core"}},"repository":{"full_name":"kestrel-labs/payroll"},"html_url":"https://github.com/kestrel-labs/payroll/security/dependabot/12"}"#

    func testMembersCollaboratorsAndSecurityAlerts() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/members"] = (200, #"[{"login":"avery","site_admin":false}]"#)
        service.answers["/orgs/kestrel-labs/outside_collaborators"] = (200, #"[{"login":"contractor-1"}]"#)
        service.answers["/orgs/kestrel-labs/secret-scanning/alerts"] = (200, "[\(Self.secret)]")
        service.answers["/orgs/kestrel-labs/code-scanning/alerts"] = (200, "[\(Self.code)]")
        service.answers["/orgs/kestrel-labs/dependabot/alerts"] = (200, "[\(Self.dependency)]")
        let people = try await callTool(GitHub.adapter, "people", "{}", on: service, in: github)
        XCTAssertTrue(people.text.contains("avery"), people.text)
        XCTAssertTrue(people.text.contains("contractor-1"), people.text)

        // Secret scanning, code scanning and Dependabot, open ones, newest first.
        let alerts = try await callTool(GitHub.adapter, "security-alerts", "{}", on: service, in: github)
        let lines = alerts.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, alerts.text)
        XCTAssertTrue(lines[0].contains("AWS Access Key ID") && lines[0].contains("active") && lines[0].contains("kestrel-labs/payroll"), lines[0])
        XCTAssertTrue(lines[1].contains("high") && lines[1].contains("SQL query"), lines[1])
        XCTAssertTrue(lines[2].contains("critical") && lines[2].contains("log4j-core"), lines[2])
        XCTAssertTrue(service.requests.suffix(3).allSatisfy { queryItems($0)["state"] == "open" })

        // From a time on, of one kind.
        let recent = try await callTool(GitHub.adapter, "security-alerts", #"{"kind":"secret","since":"2026-11-19T09:12:00Z"}"#, on: service, in: github)
        XCTAssertEqual(recent.text.split(separator: "\n").count, 1, recent.text)
        XCTAssertTrue(recent.text.contains("AWS Access Key ID"), recent.text)
        XCTAssertEqual(service.requests.last?.url?.path, "/orgs/kestrel-labs/secret-scanning/alerts")

        // An organisation without code scanning still has its other alerts read.
        service.answers["/orgs/kestrel-labs/code-scanning/alerts"] = (403, #"{"message":"Advanced Security must be enabled for this repository to use code scanning."}"#)
        let partial = try await callTool(GitHub.adapter, "security-alerts", "{}", on: service, in: github)
        XCTAssertFalse(partial.isError, partial.text)
        XCTAssertTrue(partial.text.contains("AWS Access Key ID") && partial.text.contains("log4j-core"), partial.text)
        XCTAssertTrue(partial.text.contains("Code scanning could not be read"), partial.text)
    }

    func testItsTriggerFindsNewSecretsAndHighAndCriticalCodeAndDependencyAlerts() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/secret-scanning/alerts"] = (200, "[\(Self.secret)]")
        service.answers["/orgs/kestrel-labs/code-scanning/alerts"] = (200, "[\(Self.code)]")
        service.answers["/orgs/kestrel-labs/dependabot/alerts"] = (200, "[\(Self.dependency)]")
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let alerts = try await GitHub.adapter.alerts(since: since, connection: github, access: service)
        XCTAssertEqual(alerts.map(\.id), ["https://github.com/kestrel-labs/payroll/security/secret-scanning/7",
                                          "https://github.com/kestrel-labs/portal/security/code-scanning/3"], "The Dependabot alert is older")
        let asked = service.requests.map { ($0.url?.path ?? "", queryItems($0)) }
        XCTAssertEqual(asked.first { $0.0.hasSuffix("/dependabot/alerts") }?.1["severity"], "critical,high")
        XCTAssertEqual(Set(asked.filter { $0.0.hasSuffix("/code-scanning/alerts") }.compactMap { $0.1["severity"] }), ["critical", "high"])
        XCTAssertNil(asked.first { $0.0.hasSuffix("/secret-scanning/alerts") }?.1["severity"], "Every leaked secret counts")
        XCTAssertEqual(GitHub.adapter.watchedTool, "security-alerts")

        // Only when no feed answers does a check fail.
        let down = FakeService()
        do { _ = try await GitHub.adapter.alerts(since: since, connection: github, access: down); XCTFail("No feed answered") } catch {}
    }

    /// Owners can do anything in the organisation, so an audit of who holds what starts with them.
    func testPeopleSaysWhoTheOwnersAre() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/members"] = (200, #"[{"login":"avery"},{"login":"mallory"}]"#)
        service.answers["/orgs/kestrel-labs/members?per_page=100&role=admin"] = (200, #"[{"login":"mallory"}]"#)
        service.answers["/orgs/kestrel-labs/outside_collaborators"] = (200, "[]")
        let people = try await callTool(GitHub.adapter, "people", "{}", on: service, in: github)
        XCTAssertFalse(people.isError, people.text)
        XCTAssertTrue(people.text.contains("1 owner: mallory"), people.text)
        XCTAssertEqual(people.structured?["owners"] as? [String], ["mallory"])
    }

    /// Teams carry access to repositories, so who is in which team says what a member reaches.
    func testTeamsListTheirMembersAndParents() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/teams"] = (200, #"[{"slug":"platform","name":"Platform","privacy":"closed","parent":null},{"slug":"payments","name":"Payments","privacy":"secret","parent":{"slug":"platform"}}]"#)
        service.answers["/orgs/kestrel-labs/teams/platform/members"] = (200, #"[{"login":"avery"}]"#)
        service.answers["/orgs/kestrel-labs/teams/payments/members"] = (200, #"[{"login":"mallory"},{"login":"jo"}]"#)
        let teams = try await callTool(GitHub.adapter, "teams", "{}", on: service, in: github)
        XCTAssertFalse(teams.isError, teams.text)
        XCTAssertTrue(teams.text.contains("Platform (1): avery"), teams.text)
        XCTAssertTrue(teams.text.contains("Payments, within Platform, secret (2): mallory, jo"), teams.text)
    }
}
