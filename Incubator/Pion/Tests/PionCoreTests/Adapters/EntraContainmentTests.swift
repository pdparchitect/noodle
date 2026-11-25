import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class EntraContainmentTests: XCTestCase {
    private let tenant = try! Entra.containment.makeConnection(name: "Entra Containment — Contoso",
                                                              values: ["tenant": "contoso.onmicrosoft.com", "clientID": EntraTests.client])
    private let mallory = "11111111-1111-4111-8111-111111111111", pion = "22222222-2222-4222-8222-222222222222"
    private let boss = "33333333-3333-4333-8333-333333333333", grouped = "44444444-4444-4444-8444-444444444444"
    private let admins = "55555555-5555-4555-8555-555555555555", app = "66666666-6666-4666-8666-666666666666"
    private let secret = "77777777-7777-4777-8777-777777777777", certificate = "88888888-8888-4888-8888-888888888888"
    private let other = "99999999-9999-4999-8999-999999999999"

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await callTool(Entra.containmentAdapter, tool, arguments, on: service, in: tenant)
    }

    /// The changes a call sent: every request but a read.
    private func changes(_ service: FakeService) -> [String] {
        service.requests.filter { $0.httpMethod != "GET" }.map { "\($0.httpMethod!) \($0.url!.path)" }
    }

    private func body(_ service: FakeService, _ index: Int = 0) -> [String: Any] {
        let sent = service.requests.filter { $0.httpMethod != "GET" }
        return (sent.indices.contains(index) ? sent[index].httpBody : nil).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func user(_ id: String, _ name: String, enabled: Bool = true, synced: Bool = false) -> (Int, String) {
        (200, #"{"id":"\#(id)","userPrincipalName":"\#(name)@contoso.example","displayName":"\#(name)","accountEnabled":\#(enabled),"userType":"Member","onPremisesSyncEnabled":\#(synced ? "true" : "null")}"#)
    }

    /// A tenant with Mallory, Pion's own admin, a Global Administrator and a member of a group that holds the role.
    private func service(enabled: Bool = true) -> FakeService {
        let service = FakeService()
        for (id, name) in [(mallory, "mallory"), (pion, "pion-containment"), (boss, "boss"), (grouped, "grouped")] {
            service.answers["/v1.0/users/\(id)"] = user(id, name, enabled: id == mallory ? enabled : true)
            service.answers["/v1.0/users/\(name)@contoso.example"] = service.answers["/v1.0/users/\(id)"]
        }
        service.answers["/v1.0/me"] = (200, #"{"id":"\#(pion)","userPrincipalName":"pion-containment@contoso.example"}"#)
        let global = ["$filter": "roleDefinitionId eq '\(Entra.globalAdministrator)'", "$expand": "principal"]
        service.answers[EntraTests.key("/v1.0/roleManagement/directory/roleAssignments", global)] = (200, ##"{"value":[{"id":"ga-boss","principalId":"\##(boss)","roleDefinitionId":"\##(Entra.globalAdministrator)","directoryScopeId":"/","principal":{"@odata.type":"#microsoft.graph.user","id":"\##(boss)"}},{"id":"ga-group","principalId":"\##(admins)","roleDefinitionId":"\##(Entra.globalAdministrator)","directoryScopeId":"/","principal":{"@odata.type":"#microsoft.graph.group","id":"\##(admins)","displayName":"Tier 0"}}]}"##)
        service.answers[EntraTests.key("/v1.0/roleManagement/directory/roleEligibilitySchedules", global)] = (200, #"{"value":[]}"#)
        service.answers["/v1.0/groups/\(admins)/members"] = (200, #"{"value":[{"id":"\#(grouped)"}]}"#)
        service.answers["/v1.0/roleManagement/directory/roleDefinitions"] = (200, #"{"value":[{"id":"\#(Entra.globalAdministrator)","displayName":"Global Administrator","templateId":"\#(Entra.globalAdministrator)"},{"id":"fe930be7-5e62-47db-91af-98c3a49a38b1","displayName":"User Administrator","templateId":"fe930be7-5e62-47db-91af-98c3a49a38b1"},{"id":"e8611ab8-c189-46e8-94e1-60213ab1f814","displayName":"Privileged Role Administrator"},{"id":"7be44c8a-adaf-4e2a-84d6-ab2649e08a13","displayName":"Privileged Authentication Administrator"}]}"#)
        let own = ["$filter": "principalId eq '\(mallory)'"]
        service.answers[EntraTests.key("/v1.0/roleManagement/directory/roleAssignments", own)] = (200, #"{"value":[{"id":"ra-user-admin","principalId":"\#(mallory)","roleDefinitionId":"fe930be7-5e62-47db-91af-98c3a49a38b1","directoryScopeId":"/"}]}"#)
        service.answers[EntraTests.key("/v1.0/roleManagement/directory/roleEligibilitySchedules", own)] = (200, #"{"value":[{"id":"el-pra","principalId":"\#(mallory)","roleDefinitionId":"e8611ab8-c189-46e8-94e1-60213ab1f814","directoryScopeId":"/","status":"Provisioned"}]}"#)
        service.answers["/v1.0/users/\(mallory)/authentication/methods"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.passwordAuthenticationMethod","id":"28c10230-6103-485e-b985-444c60001490"},{"@odata.type":"#microsoft.graph.microsoftAuthenticatorAuthenticationMethod","id":"auth-1","displayName":"Attacker's Pixel"},{"@odata.type":"#microsoft.graph.phoneAuthenticationMethod","id":"3179e48a-750b-4051-897c-87b9720928f7","phoneNumber":"+1 555 0100"}]}"##)
        service.answers["/v1.0/users/\(mallory)/authentication/microsoftAuthenticatorMethods/auth-1"] = (204, "")
        service.answers["/v1.0/users/\(mallory)/authentication/phoneMethods/3179e48a-750b-4051-897c-87b9720928f7"] = (400, #"{"error":{"code":"badRequest","message":"The default method cannot be deleted while others remain."}}"#)
        service.answers["/v1.0/users/\(mallory)/revokeSignInSessions"] = (200, #"{"value":true}"#)
        service.answers["/v1.0/roleManagement/directory/roleAssignments/ra-user-admin"] = (204, "")
        service.answers["/v1.0/roleManagement/directory/roleEligibilityScheduleRequests"] = (201, #"{"id":"req-1","status":"Revoked"}"#)
        service.answers["/v1.0/identityProtection/riskyUsers/\(mallory)"] = (200, #"{"id":"\#(mallory)","riskLevel":"high","riskState":"atRisk","riskLastUpdatedDateTime":"2026-11-23T09:00:00Z"}"#)
        service.answers["/v1.0/identityProtection/riskyUsers/confirmCompromised"] = (204, "")
        service.answers["/v1.0/identityProtection/riskyUsers/dismiss"] = (204, "")
        return service
    }

    func testContainmentIsItsOwnToolWithASignInOfItsOwn() throws {
        XCTAssertEqual(Entra.containment.name, "Microsoft Entra ID Containment")
        XCTAssertNotEqual(Entra.containment.id, Entra.preset.id)
        XCTAssertNotNil(UUID(uuidString: Entra.containment.id))
        XCTAssertEqual(Entra.containment.adapter, "entra-containment")
        XCTAssertNotNil(PionAdapters.all["entra-containment"])
        XCTAssertNil(Entra.containmentAdapter.watchedTool)
        XCTAssertTrue(PionCatalogue.entries.contains { $0.id == Entra.containment.id })
        XCTAssertNil(tenant.clientCredentials)
        guard case .connection(let configuration) = Entra.containment.configuration, case .connection(let audit) = Entra.preset.configuration else { return XCTFail() }
        XCTAssertEqual(configuration.oauthPathField, "tenant")
        XCTAssertEqual(configuration.oauthClientField, "clientID")
        let oauth = try XCTUnwrap(configuration.oauth(for: tenant.settings))
        XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token")
        XCTAssertEqual(Set(oauth.scopes), Set(Entra.containmentScopes))
        XCTAssertEqual(oauth.unlistedScopes, ["offline_access"])
        XCTAssertTrue(Set(oauth.scopes).isDisjoint(with: Set(audit.oauth!.scopes)), "a grant of its own, apart from Detection's read-only one")
        XCTAssertFalse(oauth.scopes.contains { ["Directory.ReadWrite.All", "User.ReadWrite.All", "Directory.AccessAsUser.All"].contains($0) }, "nothing broader than its operations take")
        XCTAssertTrue(Entra.containmentSetup.contains { $0.contains("com.pdparchitect.pion:/oauth2callback") })
        XCTAssertTrue(Entra.containmentScopes.allSatisfy { scope in Entra.containmentSetup.contains { $0.contains("`\(scope)`") } })
        for role in Set(Entra.containmentRoles.map { $0.any[0] }) {
            XCTAssertTrue(Entra.containmentSetup.contains { $0.contains("**\(role)**") }, "the setup gives \(role)")
        }
    }

    /// Everything that cuts off or restores access, removes something or changes what Identity Protection says waits for
    /// approval, and says how to recover.
    func testEveryChangeIsHeldForApprovalAndSaysHowToRecover() async throws {
        let listed = try JSONSerialization.jsonObject(with: try await Entra.containmentAdapter.tools(for: tenant)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        func tool(_ name: String) throws -> [String: Any] { try XCTUnwrap(tools.first { $0["name"] as? String == name }, name) }
        let recovery: [String: [String]] = [
            "disable-sign-in": ["enable-sign-in restores sign-in", "does not end sessions", "revoke-sessions"],
            "enable-sign-in": ["disable-sign-in again", "let an attacker back in"],
            "revoke-sessions": ["signs in again", "access tokens already issued keep working"],
            "delete-sign-in-methods": ["register each removed method again", "password"],
            "remove-directory-role": ["assign each role again", "Privileged Identity Management"],
            "remove-app-credential": ["cannot be shown again", "A certificate is refused"],
            "confirm-compromised": ["dismiss-user-risk clears it", "risk-based Conditional Access"],
            "dismiss-user-risk": ["hides the user's risk", "confirm-compromised raises it"],
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
        XCTAssertFalse(try (tool("disable-sign-in")["description"] as! String).contains("revokeSignInSessions"), "disabling and revoking stay apart")
    }

    /// Never Pion's own admin, never a user Graph resolved to someone else, never anything but a GUID or a full name,
    /// and never a Global Administrator, directly or through a group, unless the champion confirmed it.
    func testItRefusesItsOwnAdminGlobalAdministratorsAndWhatItCannotResolveExactly() async throws {
        let service = service()
        for arguments in [#"{"user":"mallory"}"#, #"{"user":"../me"}"#, #"{"user":"\#(pion)"}"#, #"{"user":"pion-containment@contoso.example"}"#,
                          #"{"user":"\#(boss)"}"#, #"{"user":"grouped@contoso.example"}"#, #"{"user":"x#EXT#@contoso.example"}"#] {
            let refused = try await call("disable-sign-in", arguments, service)
            XCTAssertTrue(refused.isError && refused.text.contains("Nothing was changed"), "\(arguments): \(refused.text)")
        }
        let own = try await call("revoke-sessions", #"{"user":"\#(pion)"}"#, service)
        XCTAssertTrue(own.text.contains("the admin signed in to this connection"), own.text)
        let grouped = try await call("revoke-sessions", #"{"user":"\#(grouped)"}"#, service)
        XCTAssertTrue(grouped.text.contains("is a Global Administrator"), "through the group that holds it: \(grouped.text)")
        service.answers["/v1.0/users/m@contoso.example"] = service.answers["/v1.0/users/\(mallory)"]
        let elsewhere = try await call("disable-sign-in", #"{"user":"m@contoso.example"}"#, service)
        XCTAssertTrue(elsewhere.text.contains("not exactly the user given"), elsewhere.text)
        XCTAssertEqual(changes(service), [])

        let allowed = try await call("disable-sign-in", #"{"user":"\#(boss)","allowGlobalAdmin":true}"#, service)
        XCTAssertFalse(allowed.isError, allowed.text)
        XCTAssertEqual(changes(service), ["PATCH /v1.0/users/\(boss)"])

        // Whether a user is a Global Administrator must be known, unless the champion confirmed it.
        let blind = self.service()
        blind.answers[EntraTests.key("/v1.0/roleManagement/directory/roleAssignments", ["$filter": "roleDefinitionId eq '\(Entra.globalAdministrator)'", "$expand": "principal"])] =
            (403, #"{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges"}}"#)
        let unknown = try await call("disable-sign-in", #"{"user":"\#(mallory)"}"#, blind)
        XCTAssertTrue(unknown.isError && unknown.text.contains("could not be read") && unknown.text.contains("RoleManagement.ReadWrite.Directory"), unknown.text)
        XCTAssertEqual(changes(blind), [])
        // Without Privileged Identity Management's licence nobody is eligible, so that is no reason to refuse.
        let unlicensed = self.service()
        unlicensed.answers[EntraTests.key("/v1.0/roleManagement/directory/roleEligibilitySchedules", ["$filter": "roleDefinitionId eq '\(Entra.globalAdministrator)'", "$expand": "principal"])] =
            (403, #"{"error":{"code":"AadPremiumLicenseRequired","message":"The tenant needs an AAD Premium 2 license."}}"#)
        let acted = try await call("disable-sign-in", #"{"user":"\#(mallory)"}"#, unlicensed)
        XCTAssertFalse(acted.isError, acted.text)
    }

    func testDisableAndRevokeAreSeparateAndSayHowToRecover() async throws {
        let service = service()
        let disabled = try await call("disable-sign-in", #"{"user":"mallory@contoso.example"}"#, service)
        XCTAssertFalse(disabled.isError, disabled.text)
        XCTAssertEqual(changes(service), ["PATCH /v1.0/users/\(mallory)"])
        XCTAssertEqual(body(service)["accountEnabled"] as? Bool, false)
        XCTAssertTrue(disabled.text.contains("✓ Disable the sign-in of mallory@contoso.example (\(mallory))"), disabled.text)
        XCTAssertTrue(disabled.text.contains(Entra.DisableSignIn.recovery) && disabled.text.contains("takes no condition on this change"), disabled.text)
        XCTAssertEqual((disabled.structured?["steps"] as? [[String: Any]])?.first?["done"] as? Bool, true)

        let revoked = try await call("revoke-sessions", #"{"user":"\#(mallory)"}"#, service)
        XCTAssertFalse(revoked.isError, revoked.text)
        XCTAssertEqual(changes(service).last, "POST /v1.0/users/\(mallory)/revokeSignInSessions")
        service.answers["/v1.0/users/\(mallory)/revokeSignInSessions"] = (200, #"{"value":false}"#)
        let unsaid = try await call("revoke-sessions", #"{"user":"\#(mallory)"}"#, service)
        XCTAssertTrue(unsaid.isError && unsaid.text.contains("Nothing was changed") && unsaid.text.contains("did not say"), unsaid.text)

        let already = try await call("disable-sign-in", #"{"user":"\#(mallory)"}"#, self.service(enabled: false))
        XCTAssertTrue(already.isError && already.text.contains("already disabled"), already.text)
        let notDisabled = try await call("enable-sign-in", #"{"user":"\#(mallory)"}"#, self.service())
        XCTAssertTrue(notDisabled.isError && notDisabled.text.contains("not disabled"), notDisabled.text)
        let restore = self.service(enabled: false)
        let enabled = try await call("enable-sign-in", #"{"user":"\#(mallory)"}"#, restore)
        XCTAssertFalse(enabled.isError, enabled.text)
        XCTAssertEqual(body(restore)["accountEnabled"] as? Bool, true)

        let synced = self.service()
        synced.answers["/v1.0/users/\(mallory)"] = user(mallory, "mallory", synced: true)
        let onPremises = try await call("disable-sign-in", #"{"user":"\#(mallory)"}"#, synced)
        XCTAssertTrue(onPremises.isError && onPremises.text.contains("on-premises Active Directory"), onPremises.text)
        XCTAssertEqual(changes(synced), [])
    }

    /// Every method is checked before any is deleted, the password is never one, and a deletion that fails part way
    /// says which were made.
    func testDeletingSignInMethodsChecksEveryOneFirstAndReportsEachStep() async throws {
        let service = service()
        for methods in [#"["auth-1","nope"]"#, #"["28c10230-6103-485e-b985-444c60001490"]"#, #"["../x"]"#, "[]"] {
            let refused = try await call("delete-sign-in-methods", #"{"user":"\#(mallory)","methods":\#(methods)}"#, service)
            XCTAssertTrue(refused.isError, "\(methods): \(refused.text)")
        }
        XCTAssertEqual(changes(service), [])
        let partial = try await call("delete-sign-in-methods", #"{"user":"\#(mallory)","methods":["auth-1","3179e48a-750b-4051-897c-87b9720928f7"]}"#, service)
        XCTAssertFalse(partial.isError, partial.text)
        XCTAssertEqual(changes(service), ["DELETE /v1.0/users/\(mallory)/authentication/microsoftAuthenticatorMethods/auth-1",
                                          "DELETE /v1.0/users/\(mallory)/authentication/phoneMethods/3179e48a-750b-4051-897c-87b9720928f7"])
        XCTAssertTrue(partial.text.contains("✓ Delete the Microsoft Authenticator (Attacker's Pixel) [auth-1]"), partial.text)
        XCTAssertTrue(partial.text.contains("✗ Failed to delete the phone") && partial.text.contains("Only part of the change was made"), partial.text)
    }

    /// Only what the user holds directly, active or eligible; one held through a group is refused, as it is the group's.
    func testRemovingDirectoryRolesTakesOnlyTheUsersOwn() async throws {
        let service = service()
        let refused = try await call("remove-directory-role", #"{"user":"\#(mallory)","assignments":["ga-group"]}"#, service)
        XCTAssertTrue(refused.isError && refused.text.contains("not one of the user's own active role assignments"), refused.text)
        let none = try await call("remove-directory-role", #"{"user":"\#(mallory)"}"#, service)
        XCTAssertTrue(none.isError, none.text)
        XCTAssertEqual(changes(service), [])
        let removed = try await call("remove-directory-role", #"{"user":"\#(mallory)","assignments":["ra-user-admin"],"eligibilities":["el-pra"]}"#, service)
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertEqual(changes(service), ["DELETE /v1.0/roleManagement/directory/roleAssignments/ra-user-admin",
                                          "POST /v1.0/roleManagement/directory/roleEligibilityScheduleRequests"])
        XCTAssertTrue(removed.text.contains("✓ Remove the active role User Administrator [ra-user-admin]") && removed.text.contains("eligibility for Privileged Role Administrator"), removed.text)
        let request = body(service, 1)
        XCTAssertEqual(request["action"] as? String, "adminRemove")
        XCTAssertEqual(request["principalId"] as? String, mallory)
        XCTAssertEqual(request["roleDefinitionId"] as? String, "e8611ab8-c189-46e8-94e1-60213ab1f814")
        XCTAssertEqual(request["directoryScopeId"] as? String, "/")
    }

    private func application(_ secrets: [String], _ certificates: [String], id: String? = nil, appId: String? = "a0a0a0a0-0000-4000-8000-0000000000a0") -> String {
        let password = secrets.map { #"{"keyId":"\#($0)","displayName":"ci","startDateTime":"2026-11-20T00:00:00Z","endDateTime":"2027-11-20T00:00:00Z"}"# }
        let keys = certificates.map { #"{"keyId":"\#($0)","type":"AsymmetricX509Cert","usage":"Verify","key":null,"displayName":"CN=cert"}"# }
        return #"{"id":"\#(id ?? app)",\#(appId.map { #""appId":"\#($0)","# } ?? "")"displayName":"Payroll Sync","passwordCredentials":[\#(password.joined(separator: ","))],"keyCredentials":[\#(keys.joined(separator: ","))]}"#
    }

    /// A secret is removed by its keyId alone, and the app read again after; a certificate is never removed, as Graph
    /// takes proof Pion does not hold, and the agent is told how the champion removes it in the portal.
    func testRemovingAnAppCredentialTakesOnlyASecretAndRefusesACertificateWithPortalSteps() async throws {
        let read = EntraTests.key("/v1.0/applications/\(app)", ["$select": "id,appId,displayName,passwordCredentials,keyCredentials"])
        let service = service()
        service.sequences[read] = [(200, application([secret, other], [certificate])), (200, application([other], [certificate]))]
        service.answers["/v1.0/applications/\(app)/removePassword"] = (204, "")
        let removed = try await call("remove-app-credential", #"{"app":"\#(app)","kind":"application","keyId":"\#(secret)"}"#, service)
        XCTAssertFalse(removed.isError, removed.text)
        XCTAssertEqual(changes(service), ["POST /v1.0/applications/\(app)/removePassword"])
        XCTAssertEqual(body(service)["keyId"] as? String, secret)
        XCTAssertTrue(removed.text.contains("✓ Remove the secret \"ci\" [\(secret)]") && removed.text.contains("Read again: the secret \(secret) is gone."), removed.text)

        // The read after is believed only when it is this very app and lists its secrets.
        let noList = #"{"id":"\#(app)","appId":"a0a0a0a0-0000-4000-8000-0000000000a0","displayName":"Payroll Sync","keyCredentials":[]}"#
        let unnamed = #"{"id":"\#(app)","appId":"a0a0a0a0-0000-4000-8000-0000000000a0","displayName":"Payroll Sync","passwordCredentials":[{}],"keyCredentials":[]}"#
        let misnamed = #"{"id":"\#(app)","appId":"a0a0a0a0-0000-4000-8000-0000000000a0","displayName":"Payroll Sync","passwordCredentials":[{"keyId":"\#(other)"},{"keyId":"k1"}],"keyCredentials":[]}"#
        for (after, said) in [(noList, "did not list Payroll Sync's secrets"), (unnamed, "without a valid key ID, which could be it"),
                              (misnamed, "without a valid key ID, which could be it"), (application([], [], id: other), "not Payroll Sync"),
                              (application([], [], appId: "b0b0b0b0-0000-4000-8000-0000000000b0"), "not Payroll Sync"),
                              (application([], [], appId: nil), "not Payroll Sync"), (application([secret], []), "still lists the secret")] {
            let again = self.service()
            again.sequences[read] = [(200, application([secret], [])), (200, after)]
            again.answers["/v1.0/applications/\(app)/removePassword"] = (204, "")
            let result = try await call("remove-app-credential", #"{"app":"\#(app)","kind":"application","keyId":"\#(secret)"}"#, again)
            XCTAssertFalse(result.isError, result.text)
            XCTAssertTrue(result.text.contains(said), "\(said): \(result.text)")
            XCTAssertFalse(result.text.contains("is gone."), result.text)
            if said != "still lists the secret" { XCTAssertTrue(result.text.contains("Graph accepted the removal, but whether the secret \(secret) is gone is not known"), result.text) }
        }
        let unreadable = self.service()
        unreadable.sequences[read] = [(200, application([secret], [])), (503, #"{"error":{"code":"ServiceUnavailable","message":"later"}}"#)]
        unreadable.answers["/v1.0/applications/\(app)/removePassword"] = (204, "")
        let unread = try await call("remove-app-credential", #"{"app":"\#(app)","kind":"application","keyId":"\#(secret)"}"#, unreadable)
        XCTAssertTrue(unread.text.contains("is not known") && unread.text.contains("could not be read again"), unread.text)

        // A certificate: nothing is sent, and the champion is told exactly where to remove it.
        let certificates = self.service()
        certificates.answers[read] = (200, application([secret], [certificate, other]))
        let refused = try await call("remove-app-credential", #"{"app":"\#(app)","kind":"application","keyId":"\#(certificate)"}"#, certificates)
        XCTAssertTrue(refused.isError && refused.text.contains("Nothing was changed") && refused.text.contains("Certificates & secrets › Certificates")
                      && refused.text.contains("Certificate ID is \(certificate)") && refused.text.contains("a0a0a0a0-0000-4000-8000-0000000000a0"), refused.text)
        let enterprise = EntraTests.key("/v1.0/servicePrincipals/\(app)", ["$select": "id,appId,displayName,passwordCredentials,keyCredentials"])
        certificates.answers[enterprise] = (200, application([], [certificate]))
        let samlRefused = try await call("remove-app-credential", #"{"app":"\#(app)","kind":"servicePrincipal","keyId":"\#(certificate)"}"#, certificates)
        XCTAssertTrue(samlRefused.isError && samlRefused.text.contains("Enterprise applications") && samlRefused.text.contains("SAML Certificates")
                      && samlRefused.text.contains("escalate to whoever manages that enterprise app"), samlRefused.text)
        XCTAssertFalse(samlRefused.text.contains("App registrations") || samlRefused.text.contains("Certificates & secrets"),
                       "the guidance stays with the enterprise app asked for: \(samlRefused.text)")
        XCTAssertFalse(samlRefused.text.contains("PowerShell") || samlRefused.text.contains("Update-Mg"), "never a whole-list replacement: \(samlRefused.text)")
        XCTAssertEqual(changes(certificates), [])

        // The app answered for must be the one asked for, with an application ID to tell it from this connection's own.
        let checks = self.service()
        for (answer, said) in [(application([secret], [], id: other), "answered for"), (application([secret], [], appId: nil), "did not give"),
                               (application([secret], [], appId: "not-a-guid"), "did not give"), (application([secret], [], appId: EntraTests.client), "signs in through")] {
            checks.answers[read] = (200, answer)
            let result = try await call("remove-app-credential", #"{"app":"\#(app)","kind":"application","keyId":"\#(secret)"}"#, checks)
            XCTAssertTrue(result.isError && result.text.contains(said), "\(said): \(result.text)")
        }
        checks.answers[read] = (200, application([secret], []))
        for arguments in [#"{"app":"\#(app)","kind":"application","keyId":"\#(other)"}"#, #"{"app":"../x","kind":"application","keyId":"\#(secret)"}"#,
                          #"{"app":"\#(app)","kind":"devices","keyId":"\#(secret)"}"#] {
            let result = try await call("remove-app-credential", arguments, checks)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertEqual(changes(checks), [])
    }

    /// Whether a user is a Global Administrator, from active assignments and from eligibility alike, is judged by each
    /// one's principalId, never by whether Graph expanded who holds it, and is unknown when a holder could be a group the
    /// user is in.
    func testWhetherAUserIsAGlobalAdministratorIsUnknownWhenAnyHolderIsNot() async throws {
        let global = ["$filter": "roleDefinitionId eq '\(Entra.globalAdministrator)'", "$expand": "principal"]
        let other = "abababab-0000-4000-8000-0000000000ab"
        let cases: [(String, String, Bool?)] = [
            ("direct by principalId, principal absent", #"{"id":"a","principalId":"\#(mallory)","roleDefinitionId":"\#(Entra.globalAdministrator)"}"#, true),
            ("untyped, unresolved assignee", #"{"id":"a","principalId":"\#(other)","roleDefinitionId":"\#(Entra.globalAdministrator)"}"#, nil),
            ("a principal of no type", #"{"id":"a","principalId":"\#(other)","principal":{"id":"\#(other)"}}"#, nil),
            ("a principal other than the one named", ##"{"id":"a","principalId":"\##(other)","principal":{"@odata.type":"#microsoft.graph.user","id":"\##(boss)"}}"##, nil),
            ("a group the user is in", ##"{"id":"a","principalId":"\##(admins)","principal":{"@odata.type":"#microsoft.graph.group","id":"\##(admins)"}}"##, true),
            ("another user", ##"{"id":"a","principalId":"\##(boss)","principal":{"@odata.type":"#microsoft.graph.user","id":"\##(boss)"}}"##, false),
            ("no assignee at all", #"{"id":"a","roleDefinitionId":"\#(Entra.globalAdministrator)"}"#, nil),
        ]
        for path in ["roleAssignments", "roleEligibilitySchedules"] {
            for (name, holder, expected) in cases {
                let service = FakeService()
                service.answers[EntraTests.key("/v1.0/roleManagement/directory/roleAssignments", global)] = (200, #"{"value":[]}"#)
                service.answers[EntraTests.key("/v1.0/roleManagement/directory/roleEligibilitySchedules", global)] = (200, #"{"value":[]}"#)
                service.answers[EntraTests.key("/v1.0/roleManagement/directory/\(path)", global)] = (200, #"{"value":[\#(holder)]}"#)
                service.answers["/v1.0/groups/\(admins)/members"] = (200, #"{"value":[{"id":"\#(boss)"},{"id":"\#(mallory)"}]}"#)
                let (held, why) = await Entra.isGlobalAdministrator(mallory, ServiceClient(base: tenant.endpoint, access: service, settings: tenant.settings ?? [:]))
                XCTAssertEqual(held, expected, "\(path), \(name): \(why ?? "")")
                if expected == nil { XCTAssertNotNil(why, "\(path), \(name)") }
            }
            // A group whose members cannot all be read leaves it unknown, and one that holds the user makes it true.
            let service = FakeService()
            service.answers[EntraTests.key("/v1.0/roleManagement/directory/roleAssignments", global)] = (200, #"{"value":[]}"#)
            service.answers[EntraTests.key("/v1.0/roleManagement/directory/roleEligibilitySchedules", global)] = (200, #"{"value":[]}"#)
            service.answers[EntraTests.key("/v1.0/roleManagement/directory/\(path)", global)] = (200, ##"{"value":[{"id":"a","principalId":"\##(admins)","principal":{"@odata.type":"#microsoft.graph.group","id":"\##(admins)"}}]}"##)
            service.answers["/v1.0/groups/\(admins)/members"] = (200, #"{"value":[{"id":"\#(boss)"}],"@odata.nextLink":"https://evil.example/v1.0/groups/\#(admins)/members?$skiptoken=x"}"#)
            let (partial, _) = await Entra.isGlobalAdministrator(mallory, ServiceClient(base: tenant.endpoint, access: service, settings: tenant.settings ?? [:]))
            XCTAssertNil(partial, "\(path): a group read only in part")
            service.answers["/v1.0/groups/\(admins)/members"] = (403, #"{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges"}}"#)
            let (unread, why) = await Entra.isGlobalAdministrator(mallory, ServiceClient(base: tenant.endpoint, access: service, settings: tenant.settings ?? [:]))
            XCTAssertNil(unread, "\(path): a group not read")
            XCTAssertTrue(why?.contains("GroupMember.Read.All") == true, why ?? "")
        }
        // Unknown is refused unless the champion confirmed acting on a Global Administrator.
        let service = service()
        service.answers[EntraTests.key("/v1.0/roleManagement/directory/roleEligibilitySchedules", global)] = (200, #"{"value":[{"id":"e","principalId":"\#(other)"}]}"#)
        let refused = try await call("disable-sign-in", #"{"user":"\#(mallory)"}"#, service)
        XCTAssertTrue(refused.isError && refused.text.contains("could not be read") && refused.text.contains("may be a group"), refused.text)
        XCTAssertEqual(changes(service), [])
        let allowed = try await call("disable-sign-in", #"{"user":"\#(mallory)","allowGlobalAdmin":true}"#, service)
        XCTAssertFalse(allowed.isError, allowed.text)
    }

    func testConfirmingAndDismissingRiskReadTheRiskFirst() async throws {
        let service = service()
        let confirmed = try await call("confirm-compromised", #"{"user":"\#(mallory)"}"#, service)
        XCTAssertFalse(confirmed.isError, confirmed.text)
        XCTAssertEqual(changes(service), ["POST /v1.0/identityProtection/riskyUsers/confirmCompromised"])
        XCTAssertEqual(body(service)["userIds"] as? [String], [mallory])
        XCTAssertTrue(confirmed.text.contains("whose risk was high (atRisk)"), confirmed.text)
        let dismissed = try await call("dismiss-user-risk", #"{"user":"\#(mallory)"}"#, service)
        XCTAssertFalse(dismissed.isError, dismissed.text)
        XCTAssertEqual(changes(service).last, "POST /v1.0/identityProtection/riskyUsers/dismiss")
        let calm = self.service()
        calm.answers["/v1.0/identityProtection/riskyUsers/\(mallory)"] = (404, #"{"error":{"code":"NotFound"}}"#)
        let nothing = try await call("dismiss-user-risk", #"{"user":"\#(mallory)"}"#, calm)
        XCTAssertTrue(nothing.isError && nothing.text.contains("nothing to dismiss"), nothing.text)
        XCTAssertEqual(changes(calm), [])
    }

    func testUserReadsTheStateBeforeActingAndChangesNothing() async throws {
        let service = service()
        let read = try await call("user", #"{"user":"mallory@contoso.example"}"#, service)
        XCTAssertFalse(read.isError, read.text)
        XCTAssertTrue(read.text.contains("sign-in enabled"), read.text)
        XCTAssertTrue(read.text.contains("User Administrator [assignment ra-user-admin]") && read.text.contains("Privileged Role Administrator (eligible) [eligibility el-pra]"), read.text)
        XCTAssertTrue(read.text.contains("Microsoft Authenticator (Attacker's Pixel) [auth-1]") && read.text.contains("Identity Protection: risk high, atRisk"), read.text)
        XCTAssertTrue(read.text.contains("Not a Global Administrator."), read.text)
        XCTAssertEqual(changes(service), [])
    }

    func testCheckAccessSaysWhichOperationsTheAdminsRolesAllow() async throws {
        let service = service()
        service.answers[EntraTests.key("/v1.0/roleManagement/directory/roleAssignments", ["$filter": "principalId eq '\(pion)'"])] = (200, #"{"value":[{"id":"r1","principalId":"\#(pion)","roleDefinitionId":"7be44c8a-adaf-4e2a-84d6-ab2649e08a13"},{"id":"r2","principalId":"\#(pion)","roleDefinitionId":"fe930be7-5e62-47db-91af-98c3a49a38b1"}]}"#)
        service.answers["/v1.0/organization"] = (200, #"{"value":[{"id":"4f1c2e3d-0000-4000-8000-000000000001","verifiedDomains":[{"name":"contoso.onmicrosoft.com"}]}]}"#)
        service.answers["/v1.0/oauth2PermissionGrants"] = (403, #"{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges"}}"#)
        service.answers["/v1.0/servicePrincipals"] = (200, #"{"value":[{"id":"7e7e7e7e-0000-4000-8000-00000000007e"}]}"#)
        let checked = try await call("check-access", "{}", service)
        XCTAssertFalse(checked.isError, checked.text)
        XCTAssertTrue(checked.text.contains("✓ disable-sign-in, enable-sign-in and revoke-sessions, as Privileged Authentication Administrator"), checked.text)
        XCTAssertTrue(checked.text.contains("✗ remove-directory-role: give the admin Privileged Role Administrator"), checked.text)
        XCTAssertTrue(checked.text.contains("⚠ The admin also holds User Administrator") == false, "User Administrator is one of its roles: \(checked.text)")
        XCTAssertTrue(checked.text.contains("could not be read") && checked.text.contains("offline_access"), checked.text)
        XCTAssertEqual(changes(service), [])
    }
}
