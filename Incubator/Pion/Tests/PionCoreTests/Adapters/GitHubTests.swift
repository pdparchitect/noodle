import Foundation
import NoodleCore
import NoodleMCP
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

    func testMembersCollaboratorsAndSecretAlerts() async throws {
        let service = FakeService()
        service.answers["/orgs/kestrel-labs/members"] = (200, #"[{"login":"avery","site_admin":false}]"#)
        service.answers["/orgs/kestrel-labs/outside_collaborators"] = (200, #"[{"login":"contractor-1"}]"#)
        service.answers["/orgs/kestrel-labs/secret-scanning/alerts"] = (200, #"[{"number":7,"state":"open","secret_type_display_name":"AWS Access Key ID","created_at":"2026-11-13T10:00:00Z","validity":"active","repository":{"full_name":"kestrel-labs/payroll"},"html_url":"https://github.com/kestrel-labs/payroll/security/secret-scanning/7"}]"#)
        let people = try await callTool(GitHub.adapter, "people", "{}", on: service, in: github)
        XCTAssertTrue(people.text.contains("avery"), people.text)
        XCTAssertTrue(people.text.contains("contractor-1"), people.text)
        let secrets = try await callTool(GitHub.adapter, "secret-alerts", "{}", on: service, in: github)
        XCTAssertTrue(secrets.text.contains("AWS Access Key ID"), secrets.text)
        XCTAssertTrue(secrets.text.contains("active"), secrets.text)
        XCTAssertEqual(queryItems(service.requests.last)["state"], "open")
    }
}
