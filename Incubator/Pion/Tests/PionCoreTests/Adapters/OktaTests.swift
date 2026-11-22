import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class OktaTests: XCTestCase {
    private let acme = try! Okta.preset.makeConnection(name: "Okta — Acme", values: ["domain": "acme.okta.com"])
    private let contoso = try! Okta.preset.makeConnection(name: "Okta — Contoso", values: ["domain": "contoso.okta.com"])

    private func call(_ tool: String, _ arguments: String, on service: FakeService, in connection: ToolConnection? = nil)
        async throws -> (text: String, isError: Bool, structured: [String: Any]?) {
        let data = try await Okta.adapter.run(tool, arguments: Data(arguments.utf8), connection: connection ?? acme, access: service)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? "", result["isError"] as? Bool ?? false,
                result["structuredContent"] as? [String: Any])
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        let items = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private let user = #"{"id":"00u1","status":"ACTIVE","created":"2024-01-02T03:04:05.000Z","lastLogin":"2026-11-14T09:03:00.000Z","passwordChanged":"2026-10-01T00:00:00.000Z","profile":{"login":"m.okafor@acme.example","email":"m.okafor@acme.example","firstName":"Mira","lastName":"Okafor"}}"#

    func testEachAccountIsItsOwnOrgWithAnSSWSToken() throws {
        XCTAssertEqual(acme.endpoint.absoluteString, "https://acme.okta.com/api/v1")
        XCTAssertEqual(contoso.endpoint.absoluteString, "https://contoso.okta.com/api/v1")
        XCTAssertEqual(acme.tokenHeader, "Authorization")
        XCTAssertEqual(acme.tokenScheme, "SSWS")
        XCTAssertEqual(acme.adapter, "okta")
        XCTAssertNotEqual(acme.id, contoso.id)
        XCTAssertNotNil(PionAdapters.all["okta"])
    }

    func testFindingAUserAsksOnlyItsOwnOrg() async throws {
        let service = FakeService()
        service.answers["/api/v1/users"] = (200, "[\(user)]")
        let found = try await call("find-user", #"{"query":"m.okafor"}"#, on: service)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("Mira Okafor"), found.text)
        XCTAssertTrue(found.text.contains("ACTIVE"), found.text)
        let users = try XCTUnwrap(found.structured?["users"] as? [[String: Any]])
        XCTAssertEqual(users.first?["login"] as? String, "m.okafor@acme.example")
        XCTAssertEqual(users.first?["lastLogin"] as? String, "2026-11-14T09:03:00.000Z")
        XCTAssertEqual(query(service.requests.first), ["q": "m.okafor", "limit": "10"])
        _ = try await call("find-user", #"{"query":"m.okafor"}"#, on: service, in: contoso)
        XCTAssertEqual(service.requests.map { $0.url!.host! }, ["acme.okta.com", "contoso.okta.com"])
    }

    func testAUsersGroupsAppsAndFactors() async throws {
        let service = FakeService()
        service.answers["/api/v1/users/00u1/groups"] = (200, #"[{"id":"00g1","profile":{"name":"Finance","description":"Payroll team"}}]"#)
        service.answers["/api/v1/users/00u1/appLinks"] = (200, #"[{"label":"Workday","appName":"workday","appInstanceId":"0oa1"}]"#)
        service.answers["/api/v1/users/00u1/factors"] = (200, #"[{"id":"opf1","factorType":"push","provider":"OKTA","status":"ACTIVE","created":"2025-01-01T00:00:00.000Z"}]"#)
        let groups = try await call("user-groups", #"{"user":"00u1"}"#, on: service)
        XCTAssertTrue(groups.text.contains("Finance"), groups.text)
        let apps = try await call("user-apps", #"{"user":"00u1"}"#, on: service)
        XCTAssertEqual((apps.structured?["apps"] as? [[String: Any]])?.first?["label"] as? String, "Workday")
        let factors = try await call("user-factors", #"{"user":"00u1"}"#, on: service)
        XCTAssertTrue(factors.text.contains("push"), factors.text)
        XCTAssertEqual((factors.structured?["factors"] as? [[String: Any]])?.first?["status"] as? String, "ACTIVE")
    }

    func testSignInEventsAreFilteredOnTheServiceNewestFirst() async throws {
        let service = FakeService()
        service.answers["/api/v1/logs"] = (200, #"[{"uuid":"e1","published":"2026-11-14T09:06:00.000Z","eventType":"user.session.start","displayMessage":"User login to Okta","outcome":{"result":"SUCCESS"},"actor":{"alternateId":"m.okafor@acme.example","displayName":"Mira Okafor"},"client":{"ipAddress":"203.0.113.77","geographicalContext":{"city":"Lagos","country":"Nigeria"},"userAgent":{"rawUserAgent":"Mozilla/5.0"}}}]"#)
        let events = try await call("sign-in-events", #"{"user":"m.okafor@acme.example","ip":"203.0.113.77","failuresOnly":true,"since":"2026-11-13T00:00:00Z","limit":20}"#, on: service)
        XCTAssertFalse(events.isError, events.text)
        XCTAssertTrue(events.text.contains("203.0.113.77"), events.text)
        XCTAssertEqual((events.structured?["events"] as? [[String: Any]])?.first?["city"] as? String, "Lagos")
        let sent = query(service.requests.first)
        XCTAssertEqual(sent["filter"], #"actor.alternateId eq "m.okafor@acme.example" and client.ipAddress eq "203.0.113.77" and outcome.result eq "FAILURE""#)
        XCTAssertEqual(sent["since"], "2026-11-13T00:00:00Z")
        XCTAssertEqual(sent["limit"], "20")
        XCTAssertEqual(sent["sortOrder"], "DESCENDING")

        _ = try await call("sign-in-events", "{}", on: service)
        XCTAssertNotNil(query(service.requests.last)["since"], "an open-ended search still has a window")
    }

    func testValuesThatCouldChangeAFilterAreRefused() async throws {
        let service = FakeService()
        for arguments in [#"{"user":"x\" or actor.id pr \"y"}"#, #"{"ip":"not an ip"}"#, #"{"since":"yesterday"}"#,
                          #"{"eventType":"a\\b"}"#, #"{"limit":500}"#] {
            let result = try await call("sign-in-events", arguments, on: service)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    // MARK: Breach scope

    /// The apps a user let act for them, with what they may do: each one keeps working after a password change.
    func testAUsersGrantsSayWhichAppsActForThemAndWithWhatScopes() async throws {
        let service = FakeService()
        service.answers["/api/v1/users/00u1/grants"] = (200, #"[{"id":"oag1","clientId":"0oa-crm","scopeId":"scp1","status":"ACTIVE","source":"END_USER","created":"2026-11-14T09:00:00.000Z","issuer":"https://acme.okta.com","_embedded":{"scope":{"name":"okta.users.read"}}}]"#)
        let grants = try await callTool(Okta.adapter, "user-grants", #"{"user":"00u1"}"#, on: service, in: acme)
        XCTAssertFalse(grants.isError, grants.text)
        XCTAssertTrue(grants.text.contains("0oa-crm") && grants.text.contains("okta.users.read") && grants.text.contains("granted by the user"), grants.text)
        XCTAssertEqual(queryItems(service.requests.last)["expand"], "scope")
    }

    /// Who holds an admin role, and which: the accounts that can change the org.
    func testAdminRolesListEachAdminWithTheirRoles() async throws {
        let service = FakeService()
        service.answers["/api/v1/iam/assignees/users"] = (200, #"{"value":[{"id":"00u1"},{"id":"00u2"}]}"#)
        service.answers["/api/v1/users/00u1/roles"] = (200, #"[{"id":"ra1","type":"SUPER_ADMIN","label":"Super Administrator","status":"ACTIVE","assignmentType":"USER"}]"#)
        service.answers["/api/v1/users/00u2/roles"] = (200, #"[{"id":"ra2","type":"READ_ONLY_ADMIN","label":"Read Only Administrator","status":"ACTIVE","assignmentType":"GROUP"}]"#)
        service.answers["/api/v1/users/00u1"] = (200, #"{"id":"00u1","status":"ACTIVE","profile":{"login":"it@acme.example"}}"#)
        service.answers["/api/v1/users/00u2"] = (200, #"{"id":"00u2","status":"ACTIVE","profile":{"login":"pion@acme.example"}}"#)
        let admins = try await callTool(Okta.adapter, "admin-roles", "{}", on: service, in: acme)
        XCTAssertFalse(admins.isError, admins.text)
        let lines = admins.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("it@acme.example") && lines[0].contains("Super Administrator"), admins.text)
        XCTAssertTrue(lines.contains { $0.contains("pion@acme.example") && $0.contains("Read Only Administrator (through a group)") }, admins.text)
    }

    /// API tokens act as the admin who made them, from anywhere unless limited: who made each, and when it was last used.
    func testAPITokensSayWhoMadeEachAndWhenItExpires() async throws {
        let service = FakeService()
        service.answers["/api/v1/api-tokens"] = (200, #"[{"id":"t1","name":"terraform","userId":"00u1","clientName":"Okta API","created":"2025-01-01T00:00:00.000Z","expiresAt":"2026-12-01T00:00:00.000Z","lastUpdated":"2026-11-14T09:00:00.000Z","network":{"connection":"ANYWHERE"}}]"#)
        service.answers["/api/v1/users/00u1"] = (200, #"{"id":"00u1","status":"ACTIVE","profile":{"login":"it@acme.example"}}"#)
        let tokens = try await callTool(Okta.adapter, "api-tokens", "{}", on: service, in: acme)
        XCTAssertFalse(tokens.isError, tokens.text)
        XCTAssertTrue(tokens.text.contains("terraform") && tokens.text.contains("it@acme.example") && tokens.text.contains("from anywhere")
                      && tokens.text.contains("expires 2026-12-01"), tokens.text)
    }

    /// A refusal names the custom role the token's admin needs, as the Read-Only Administrator cannot see admins.
    func testARefusedAuditSaysWhichRoleItNeeds() async throws {
        let service = FakeService()
        service.answers["/api/v1/iam/assignees/users"] = (403, #"{"errorCode":"E0000006","errorSummary":"You do not have permission to perform the requested action"}"#)
        let refused = try await callTool(Okta.adapter, "admin-roles", "{}", on: service, in: acme)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("View roles, resources, and admin assignments"), refused.text)
    }
}

