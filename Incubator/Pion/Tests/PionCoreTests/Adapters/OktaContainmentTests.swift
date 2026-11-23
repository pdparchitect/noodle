import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class OktaContainmentTests: XCTestCase {
    private let org = try! Okta.containment.makeConnection(name: "Okta Containment — Acme", values: ["domain": "acme.okta.com", "clientID": "0oaPionContain"])
    private let mallory = "00umallory0000000001", pion = "00upion0000000000001", boss = "00uboss0000000000001"
    private let finance = "00gfinance000000001x", appGroup = "00gadgroup000000001x"

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await callTool(Okta.containmentAdapter, tool, arguments, on: service, in: org)
    }

    /// The changes a call sent: every request but a read.
    private func changes(_ service: FakeService) -> [String] {
        service.requests.filter { $0.httpMethod != "GET" }.map { "\($0.httpMethod!) \($0.url!.path)" + ($0.url!.query.map { "?" + $0 } ?? "") }
    }

    /// An org with Mallory, active, Pion's own admin and a super administrator.
    private func service(status: String = "ACTIVE") -> FakeService {
        let service = FakeService()
        service.answers["/api/v1/users/\(mallory)"] = (200, #"{"id":"\#(mallory)","status":"\#(status)","profile":{"login":"mallory@acme.example"}}"#)
        service.answers["/api/v1/users/mallory@acme.example"] = service.answers["/api/v1/users/\(mallory)"]
        service.answers["/api/v1/users/\(mallory)/roles"] = (200, #"[{"id":"ra1orgadmin","type":"ORG_ADMIN","label":"Organization Administrator","assignmentType":"USER"},{"id":"ra2helpdesk","type":"HELP_DESK_ADMIN","label":"Help Desk Administrator","assignmentType":"GROUP"}]"#)
        service.answers["/api/v1/users/me"] = (200, #"{"id":"\#(pion)","profile":{"login":"pion-containment@acme.example"}}"#)
        service.answers["/api/v1/users/\(pion)"] = service.answers["/api/v1/users/me"]
        service.answers["/api/v1/users/\(boss)"] = (200, #"{"id":"\#(boss)","status":"ACTIVE","profile":{"login":"boss@acme.example"}}"#)
        service.answers["/api/v1/users/\(boss)/roles"] = (200, #"[{"id":"ra3super","type":"SUPER_ADMIN","label":"Super Administrator","assignmentType":"USER"}]"#)
        for path in ["lifecycle/suspend", "lifecycle/unsuspend", "lifecycle/deactivate", "lifecycle/reset_factors", "lifecycle/expire_password", "sessions",
                     "grants", "roles/ra1orgadmin", "factors/opfpush0000000000001"] {
            service.answers["/api/v1/users/\(mallory)/\(path)"] = (path == "sessions" || path == "grants" || path.hasPrefix("roles/") || path.hasPrefix("factors/") ? 204 : 200, path == "lifecycle/expire_password" ? #"{"tempPassword":"SENTINEL-Wq9-s3cret"}"# : "{}")
        }
        service.answers["/api/v1/users/\(boss)/lifecycle/suspend"] = (200, "{}")
        return service
    }

    func testContainmentIsItsOwnToolWithASignInOfItsOwn() throws {
        XCTAssertEqual(Okta.containment.name, "Okta Containment")
        XCTAssertNotEqual(Okta.containment.id, Okta.preset.id)
        XCTAssertNotNil(UUID(uuidString: Okta.containment.id))
        XCTAssertEqual(Okta.containment.adapter, "okta-containment")
        XCTAssertNotNil(PionAdapters.all["okta-containment"])
        XCTAssertNil(Okta.containmentAdapter.watchedTool)
        XCTAssertTrue(PionCatalogue.entries.contains { $0.id == Okta.containment.id })
        XCTAssertNil(org.tokenHeader)
        XCTAssertNil(org.tokenScheme)
        XCTAssertEqual(org.endpoint.absoluteString, "https://acme.okta.com/api/v1")
        guard case .connection(let configuration) = Okta.containment.configuration,
              case .connection(let audit) = Okta.preset.configuration else { return XCTFail() }
        XCTAssertNil(configuration.tokenRevocation)
        XCTAssertEqual(configuration.oauthClientField, "clientID")
        XCTAssertEqual(configuration.oauthHostField, "domain")
        let oauth = try XCTUnwrap(configuration.oauth(for: org.settings))
        XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "https://acme.okta.com/oauth2/v1/token")
        XCTAssertEqual(Set(oauth.scopes), ["okta.users.manage", "okta.users.read.self", "okta.groups.manage", "okta.roles.manage",
                                           "okta.apiTokens.manage", "offline_access"])
        XCTAssertTrue(Set(oauth.scopes).isDisjoint(with: Set(audit.oauth!.scopes).subtracting(["okta.users.read.self", "offline_access"])),
                      "a grant of its own, apart from Okta Audit's read-only one")
        XCTAssertTrue(Okta.containmentSetup.contains { $0.contains("com.pdparchitect.pion:/oauth2callback") })
        XCTAssertTrue(Okta.containmentScopes.allSatisfy { scope in Okta.containmentSetup.contains { $0.contains("`\(scope)`") } })
        XCTAssertTrue(Okta.containmentSetup.contains { $0.contains("okta.users.lifecycle.suspend") && $0.contains("okta.users.apitokens.clear") })
        for need in Okta.containmentNeeds {
            XCTAssertTrue(Okta.containmentPermissions.contains { $0.permission == need.any[0] }, "the setup gives \(need.operation)'s permission")
        }
    }

    /// Everything that cuts off or restores access, or removes something, waits for approval, and says how to recover.
    func testEveryChangeIsHeldForApprovalAndSaysHowToRecover() async throws {
        let listed = try JSONSerialization.jsonObject(with: try await Okta.containmentAdapter.tools(for: org)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        func tool(_ name: String) throws -> [String: Any] { try XCTUnwrap(tools.first { $0["name"] as? String == name }, name) }
        // What each one's recovery must say.
        let recovery: [String: [String]] = [
            "suspend": ["unsuspend restores sign-in", "sessions ended meanwhile are not restored", "does not end sessions"],
            "unsuspend": ["suspend again", "let an attacker back in"],
            "deactivate": ["no simple undo", "deprovisions", "reactivating"],
            "clear-sessions": ["signs in afresh", "re-consent"],
            "reset-factors": ["re-enroll every MFA factor"],
            "delete-factor": ["enroll that factor again"],
            "expire-password": ["change their password at their next sign-in", "does not stop a stolen password"],
            "remove-from-group": ["re-add the user", "group rule"],
            "revoke-admin-role": ["re-assign each role by hand"],
            "revoke-app-grants": ["consent to each app again"],
            "revoke-api-token": ["gone for good", "new token"],
        ]
        for (name, words) in recovery {
            let annotations = try XCTUnwrap(try tool(name)["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, false, name)
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, true, name)
            let summary = try XCTUnwrap(try tool(name)["description"] as? String)
            XCTAssertTrue(summary.contains("Recovery:"), name)
            for word in words { XCTAssertTrue(summary.contains(word), "\(name) says \(word): \(summary)") }
        }
        for name in ["user", "check-access"] {
            XCTAssertEqual((try tool(name)["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true, name)
        }
        XCTAssertEqual(tools.count, recovery.count + 2)
        // Suspending and ending sessions stay apart, so each is approved for what it does.
        XCTAssertFalse(try (tool("suspend")["description"] as! String).contains("revoke"))
    }

    /// Never a short name, never Pion's own admin, never a user Okta resolved to someone else, and never a super
    /// administrator unless the champion confirmed it; nothing is changed when refused.
    func testItRefusesShortNamesItsOwnAdminAndSuperAdministrators() async throws {
        let service = service()
        for arguments in [#"{"user":"mallory"}"#, #"{"user":"00u1"}"#, #"{"user":"\#(pion)"}"#, #"{"user":"\#(boss)"}"#, #"{"user":"x@y\"z"}"#] {
            let refused = try await call("suspend", arguments, service)
            XCTAssertTrue(refused.isError, arguments)
            XCTAssertTrue(refused.text.contains("Nothing was changed"), refused.text)
        }
        // The signed-in admin is who the access token says, by /users/me, never an API token's owner.
        service.answers["/api/v1/users/pion-containment@acme.example"] = service.answers["/api/v1/users/me"]
        let own = try await call("suspend", #"{"user":"pion-containment@acme.example"}"#, service)
        XCTAssertTrue(own.isError && own.text.contains("the admin signed in to this connection"), own.text)
        service.answers["/api/v1/users/m@acme.example"] = service.answers["/api/v1/users/\(mallory)"]
        let other = try await call("suspend", #"{"user":"m@acme.example"}"#, service)
        XCTAssertTrue(other.text.contains("not exactly the user given"), other.text)
        XCTAssertEqual(changes(service), [])

        let allowed = try await call("suspend", #"{"user":"\#(boss)","allowSuperAdmin":true}"#, service)
        XCTAssertFalse(allowed.isError, allowed.text)
        XCTAssertEqual(changes(service), ["POST /api/v1/users/\(boss)/lifecycle/suspend"])

        // Whether a user is a super administrator must be known, unless the champion confirmed it.
        let blind = service
        blind.answers["/api/v1/users/\(mallory)/roles"] = (403, #"{"errorCode":"E0000006","errorSummary":"You do not have permission"}"#)
        let unknown = try await call("suspend", #"{"user":"\#(mallory)"}"#, blind)
        XCTAssertTrue(unknown.isError && unknown.text.contains("okta.iam.read"), unknown.text)
        XCTAssertEqual(changes(service).count, 1)
    }

    func testSuspendAndClearSessionsAreSeparateAndReportTheirRecovery() async throws {
        let service = service()
        let suspended = try await call("suspend", #"{"user":"mallory@acme.example"}"#, service)
        XCTAssertFalse(suspended.isError, suspended.text)
        XCTAssertEqual(changes(service), ["POST /api/v1/users/\(mallory)/lifecycle/suspend"])
        XCTAssertTrue(suspended.text.contains("✓ Suspend mallory@acme.example (\(mallory)), who was ACTIVE"), suspended.text)
        XCTAssertTrue(suspended.text.contains(Okta.Suspend.recovery) && suspended.text.contains("Okta takes no condition on a change"), suspended.text)
        XCTAssertEqual((suspended.structured?["steps"] as? [[String: Any]])?.first?["done"] as? Bool, true)

        let cleared = try await call("clear-sessions", #"{"user":"\#(mallory)"}"#, service)
        XCTAssertFalse(cleared.isError, cleared.text)
        XCTAssertEqual(changes(service).last, "DELETE /api/v1/users/\(mallory)/sessions?forgetDevices=true&oauthTokens=true")
        XCTAssertTrue(cleared.text.contains(Okta.ClearSessions.recovery), cleared.text)

        let already = try await call("suspend", #"{"user":"\#(mallory)"}"#, self.service(status: "SUSPENDED"))
        XCTAssertTrue(already.isError && already.text.contains("already suspended"), already.text)
        let notSuspended = try await call("unsuspend", #"{"user":"\#(mallory)"}"#, service)
        XCTAssertTrue(notSuspended.isError && notSuspended.text.contains("not suspended"), notSuspended.text)
    }

    func testDeactivateRunsOnlyWhenDeprovisioningIsConfirmed() async throws {
        let service = service()
        for arguments in [#"{"user":"\#(mallory)"}"#, #"{"user":"\#(mallory)","confirmDeprovision":false}"#] {
            let refused = try await call("deactivate", arguments, service)
            XCTAssertTrue(refused.isError && refused.text.contains("confirmDeprovision"), refused.text)
        }
        XCTAssertTrue(service.requests.isEmpty)
        let done = try await call("deactivate", #"{"user":"\#(mallory)","confirmDeprovision":true}"#, service)
        XCTAssertFalse(done.isError, done.text)
        XCTAssertEqual(changes(service), ["POST /api/v1/users/\(mallory)/lifecycle/deactivate?sendEmail=false"])
        XCTAssertTrue(done.text.contains("no simple undo"), done.text)
    }

    func testFactorsAndPasswordsSayWhatWasRemovedAndHowToRecover() async throws {
        let service = service()
        service.answers["/api/v1/users/\(mallory)/factors"] = (200, #"[{"id":"opfpush0000000000001","factorType":"push","provider":"OKTA"}]"#)
        let reset = try await call("reset-factors", #"{"user":"\#(mallory)"}"#, service)
        XCTAssertFalse(reset.isError, reset.text)
        XCTAssertTrue(reset.text.contains("push (OKTA) [opfpush0000000000001]") && reset.text.contains("re-enroll"), reset.text)
        let missing = try await call("delete-factor", #"{"user":"\#(mallory)","factor":"smsother000000000001"}"#, service)
        XCTAssertTrue(missing.isError && missing.text.contains("has no factor"), missing.text)
        let bad = try await call("delete-factor", #"{"user":"\#(mallory)","factor":"../x"}"#, service)
        XCTAssertTrue(bad.isError)
        _ = try await call("delete-factor", #"{"user":"\#(mallory)","factor":"opfpush0000000000001"}"#, service)
        XCTAssertEqual(changes(service), ["POST /api/v1/users/\(mallory)/lifecycle/reset_factors", "DELETE /api/v1/users/\(mallory)/factors/opfpush0000000000001"])
    }

    /// expire-password only forces a change at the next sign-in: it never asks Okta for a temporary password, and
    /// whatever Okta answers, no password reaches the result, its structured data or the conversation, even when a bot
    /// asks for one.
    func testExpirePasswordNeverMakesOrShowsATemporaryPassword() async throws {
        let service = service()
        let schema = try JSONSerialization.jsonObject(with: try await Okta.containmentAdapter.tools(for: org)) as! [String: Any]
        let tool = try XCTUnwrap((schema["tools"] as? [[String: Any]])?.first { $0["name"] as? String == "expire-password" })
        XCTAssertNil(((tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["tempPassword"], "not offered")
        XCTAssertTrue((tool["description"] as? String ?? "").contains("an admin issues one in the Okta Admin Console"))
        for arguments in [#"{"user":"\#(mallory)"}"#, #"{"user":"\#(mallory)","tempPassword":true}"#] {
            let expired = try await call("expire-password", arguments, service)
            XCTAssertFalse(expired.isError, expired.text)
            XCTAssertTrue(expired.text.contains("✓ Expire the password of mallory@acme.example"), expired.text)
            let structured = String(data: try JSONSerialization.data(withJSONObject: expired.structured ?? [:]), encoding: .utf8)!
            for leaked in ["SENTINEL", "Wq9", "s3cret"] {
                XCTAssertFalse(expired.text.contains(leaked), expired.text)
                XCTAssertFalse(structured.contains(leaked), structured)
            }
        }
        let sent = service.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(sent.map { $0.url!.path }, Array(repeating: "/api/v1/users/\(mallory)/lifecycle/expire_password", count: 2))
        XCTAssertTrue(sent.allSatisfy { $0.url!.query == nil && $0.httpBody == nil }, "it never asks for a temporary password")
    }

    /// Every group is checked before any change; a removal that fails part way says which were made and which not.
    func testGroupRemovalChecksEveryGroupFirstAndReportsEachStep() async throws {
        let service = service()
        let other = "00gsales00000000001x"
        service.answers["/api/v1/users/\(mallory)/groups"] = (200, #"[{"id":"\#(finance)","type":"OKTA_GROUP","profile":{"name":"Finance"}},{"id":"\#(other)","type":"OKTA_GROUP","profile":{"name":"Sales"}},{"id":"\#(appGroup)","type":"APP_GROUP","profile":{"name":"AD Admins"}}]"#)
        let refused = try await call("remove-from-group", #"{"user":"\#(mallory)","groups":["\#(finance)","\#(appGroup)"]}"#, service)
        XCTAssertTrue(refused.isError && refused.text.contains("AD Admins") && refused.text.contains("Nothing was changed"), refused.text)
        let bad = try await call("remove-from-group", #"{"user":"\#(mallory)","groups":["Finance"]}"#, service)
        XCTAssertTrue(bad.isError && bad.text.contains("00g"), bad.text)
        XCTAssertEqual(changes(service), [])

        service.answers["/api/v1/groups/\(finance)/users/\(mallory)"] = (204, "")
        service.answers["/api/v1/groups/\(other)/users/\(mallory)"] = (500, #"{"errorCode":"E0000009","errorSummary":"Internal Server Error"}"#)
        let failing = try await call("remove-from-group", #"{"user":"\#(mallory)","groups":["\#(other)"]}"#, service)
        XCTAssertTrue(failing.isError && failing.text.contains("Nothing was changed. Failed to remove"), failing.text)
        service.requests = []
        let partial = try await call("remove-from-group", #"{"user":"\#(mallory)","groups":["\#(finance)","\#(other)","\#(finance)"]}"#, service)
        XCTAssertTrue(partial.text.contains("✓ Remove mallory@acme.example (\(mallory)) from Finance"), partial.text)
        XCTAssertTrue(partial.text.contains("✗ Failed to remove mallory@acme.example (\(mallory)) from Sales"), partial.text)
        XCTAssertTrue(partial.text.contains("Only part of the change was made"), partial.text)
        XCTAssertEqual(changes(service), ["DELETE /api/v1/groups/\(finance)/users/\(mallory)", "DELETE /api/v1/groups/\(other)/users/\(mallory)"], "each group once")
    }

    func testAdminRolesAreRevokedOnlyWhenHeldDirectly() async throws {
        let service = service()
        let group = try await call("revoke-admin-role", #"{"user":"\#(mallory)","assignments":["ra2helpdesk"]}"#, service)
        XCTAssertTrue(group.isError && group.text.contains("held through a group"), group.text)
        let unknown = try await call("revoke-admin-role", #"{"user":"\#(mallory)","assignments":["raother"]}"#, service)
        XCTAssertTrue(unknown.isError && unknown.text.contains("not one of the user's role assignments"), unknown.text)
        XCTAssertEqual(changes(service), [])
        let revoked = try await call("revoke-admin-role", #"{"user":"\#(mallory)","assignments":["ra1orgadmin"]}"#, service)
        XCTAssertFalse(revoked.isError, revoked.text)
        XCTAssertTrue(revoked.text.contains("Organization Administrator") && revoked.text.contains("re-assign"), revoked.text)
        XCTAssertEqual(changes(service), ["DELETE /api/v1/users/\(mallory)/roles/ra1orgadmin"])
    }

    func testGrantsAndTokensAreRevokedSayingWhatTheyWere() async throws {
        let service = service()
        service.answers["/api/v1/users/\(mallory)/grants"] = (200, #"[{"id":"oag1crm0000000000001","clientId":"0oa-crm"},{"id":"oag2mail000000000001","clientId":"0oa-mail"}]"#)
        let grants = try await call("revoke-app-grants", #"{"user":"\#(mallory)"}"#, service)
        XCTAssertFalse(grants.isError, grants.text)
        XCTAssertTrue(grants.text.contains("2 grants to 0oa-crm, 0oa-mail"), grants.text)
        XCTAssertEqual(changes(service), ["DELETE /api/v1/users/\(mallory)/grants"])

        let malformed = try await call("revoke-api-token", #"{"token":"00T/../x"}"#, service)
        XCTAssertTrue(malformed.isError)
        service.answers["/api/v1/api-tokens/00Tterraform00000001"] = nil
        service.sequences["/api/v1/api-tokens/00Tterraform00000001"] = [(200, #"{"id":"00Tterraform00000001","name":"terraform","userId":"\#(boss)"}"#), (204, "")]
        let token = try await call("revoke-api-token", #"{"token":"00Tterraform00000001"}"#, service)
        XCTAssertFalse(token.isError, token.text)
        XCTAssertTrue(token.text.contains("terraform") && token.text.contains("gone for good"), token.text)
        XCTAssertEqual(changes(service).last, "DELETE /api/v1/api-tokens/00Tterraform00000001")
        XCTAssertFalse(service.requests.contains { $0.url!.path.hasSuffix("/current") }, "it signs in through OAuth, with no API token of its own")
    }

    /// check-access reads the admin's custom role and says, for each operation, whether it may run and what to add.
    func testCheckAccessSaysWhichOperationsTheAdminsRoleAllows() async throws {
        let service = service()
        service.answers["/api/v1/users/\(pion)/roles"] = (200, #"[{"id":"ra9","type":"CUSTOM","label":"Pion Containment","role":"cr0contain"}]"#)
        service.answers["/api/v1/iam/roles/cr0contain/permissions"] = (200, #"{"permissions":[{"label":"okta.users.read"},{"label":"okta.iam.read"},{"label":"okta.users.lifecycle.suspend"},{"label":"okta.users.lifecycle.clearSessions"},{"label":"okta.apps.manage"}]}"#)
        let checked = try await call("check-access", "{}", service)
        XCTAssertFalse(checked.isError, checked.text)
        XCTAssertTrue(checked.text.contains("✓ suspend") && checked.text.contains("✓ clear-sessions"), checked.text)
        XCTAssertTrue(checked.text.contains("✗ unsuspend: add okta.users.lifecycle.unsuspend"), checked.text)
        XCTAssertTrue(checked.text.contains("✗ revoke-admin-role") && checked.text.contains("okta.apps.manage"), checked.text)
        XCTAssertTrue(checked.text.contains("Signed in as pion-containment@acme.example") && checked.text.contains("okta.users.manage")
                      && checked.text.contains("0oaPionContain"), checked.text)
        XCTAssertEqual(changes(service), [])

        service.answers["/api/v1/users/\(pion)/roles"] = (200, #"[{"id":"ra8","type":"SUPER_ADMIN","label":"Super Administrator"}]"#)
        let superAdmin = try await call("check-access", "{}", service)
        XCTAssertTrue(superAdmin.text.contains("⚠ The admin is a super administrator"), superAdmin.text)
    }
}
