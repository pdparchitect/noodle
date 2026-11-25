import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class EntraTests: XCTestCase {
    static let client = "0b1c2d3e-0000-4000-8000-000000000002"
    private let contoso = try! Entra.preset.makeConnection(name: "Entra — Contoso", values: ["tenant": "contoso.onmicrosoft.com", "clientID": EntraTests.client])
    private let fabrikam = try! Entra.preset.makeConnection(name: "Entra — Fabrikam", values: ["tenant": "4f1c2e3d-0000-4000-8000-000000000001", "clientID": EntraTests.client])

    func testEachTenantSignsInAsAnAdminAtItsOwnTenantWithReadingPermissionsOnly() throws {
        XCTAssertEqual(contoso.endpoint.absoluteString, "https://graph.microsoft.com/v1.0")
        XCTAssertNil(contoso.clientCredentials, "no client secret: an admin signs in")
        XCTAssertNil(contoso.tokenHeader)
        XCTAssertFalse(contoso.keepsSecret)
        XCTAssertEqual(contoso.settings?["clientID"], Self.client)
        XCTAssertEqual(contoso.adapter, "entra")
        XCTAssertEqual(Entra.preset.name, "Microsoft Entra ID Detection")
        guard case .connection(let configuration) = Entra.preset.configuration else { return XCTFail() }
        XCTAssertEqual(configuration.oauthClientField, "clientID")
        XCTAssertEqual(configuration.oauthPathField, "tenant")
        XCTAssertNil(configuration.oauthHostField)
        let oauth = try XCTUnwrap(configuration.oauth(for: contoso.settings))
        XCTAssertEqual(oauth.authorizationEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/authorize")
        XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token")
        XCTAssertEqual(oauth.issuer.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/v2.0")
        XCTAssertEqual(configuration.oauth(for: fabrikam.settings)?.tokenEndpoint.absoluteString,
                       "https://login.microsoftonline.com/4f1c2e3d-0000-4000-8000-000000000001/oauth2/v2.0/token")
        XCTAssertNil(oauth.revocationEndpoint, "Microsoft offers none; revoke-sessions in Containment ends sessions")
        XCTAssertNil(oauth.deviceAuthorizationEndpoint, "an authorization code with PKCE")
        XCTAssertFalse(oauth.usesResourceIndicator, "Microsoft's v2.0 endpoint refuses resource")
        XCTAssertEqual(oauth.authorizationParameters, ["prompt": "login"])
        XCTAssertEqual(oauth.unlistedScopes, ["offline_access"], "asked for, but Microsoft never lists it as granted")
        XCTAssertEqual(Set(oauth.scopes), Set(Entra.auditScopes))
        XCTAssertTrue(oauth.scopes.allSatisfy { $0.contains(".Read.") }, "Detection only reads: \(oauth.scopes)")
        XCTAssertTrue(Entra.setup.contains { $0.contains("com.pdparchitect.pion:/oauth2callback") && $0.contains("Public client") })
        XCTAssertTrue(Entra.auditScopes.allSatisfy { scope in Entra.setup.contains { $0.contains("`\(scope)`") } }, "the setup grants every permission asked for")
        XCTAssertTrue(Entra.setup.contains { $0.contains("Global Reader") })
        XCTAssertThrowsError(try Entra.preset.makeConnection(name: "Bad", values: ["tenant": "contoso/../x", "clientID": Self.client]))
        XCTAssertNil(configuration.oauth(for: ["tenant": "../evil", "clientID": Self.client]))
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        ToolCatalog.use(PionCatalogue.entries)
        XCTAssertTrue(ToolConnectionService.signsInThroughBrowser(contoso))
        XCTAssertFalse(ToolConnectionService.signsInWithCode(contoso))
        XCTAssertEqual(ToolConnectionService.configuredRedirectURI(for: contoso, bundleIdentifier: "com.pdparchitect.pion")?.absoluteString,
                       "com.pdparchitect.pion:/oauth2callback")
        XCTAssertEqual(Entra.adapter.watchedTool, "security-events")
        XCTAssertNotNil(PionAdapters.all["entra"])
    }

    /// Microsoft's addresses that stand for any tenant would sign in wherever the admin belongs, as would a tenant of
    /// dots: neither can be set up, neither resolves a sign-in, and one saved under an account reads nothing.
    func testATenantThatIsNoOneTenantIsRefusedAtSetupAndReadsNothing() async throws {
        let service = FakeService()
        for tool in [Entra.preset, Entra.containment] {
            guard case .connection(let configuration) = tool.configuration else { return XCTFail() }
            for generic in ["common", "Organizations", "consumers", "..."] {
                XCTAssertThrowsError(try tool.makeConnection(name: "Any", values: ["tenant": generic, "clientID": Self.client]), generic)
                XCTAssertNil(configuration.oauth(for: ["tenant": generic, "clientID": Self.client]), generic)
            }
        }
        for generic in ["common", "Organizations", "consumers"] {
            var connection = contoso
            connection.settings?["tenant"] = generic
            let found = try await callTool(Entra.adapter, "find-user", #"{"query":"ann"}"#, on: service, in: connection)
            XCTAssertTrue(found.isError && found.text.contains("no one tenant"), found.text)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testFindingAUserEscapesTheQueryAndSaysWhenMoreMatch() async throws {
        let service = FakeService()
        service.answers["/v1.0/users"] = (200, #"{"value":[{"id":"u1","displayName":"Ann O'Brien","userPrincipalName":"ann@contoso.example","accountEnabled":true}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/users?$skiptoken=X1"}"#)
        let found = try await callTool(Entra.adapter, "find-user", #"{"query":"O'Brien","limit":1}"#, on: service, in: contoso)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("Ann O'Brien") && found.text.contains("sign-in enabled"), found.text)
        XCTAssertTrue(found.text.contains("More users match"), found.text)
        XCTAssertEqual(found.structured?["complete"] as? Bool, false)
        XCTAssertEqual(queryItems(service.requests.first)["$filter"],
                       "startswith(displayName,'O''Brien') or startswith(userPrincipalName,'O''Brien') or startswith(mail,'O''Brien')")
        XCTAssertEqual(queryItems(service.requests.first)["$top"], "1")
        XCTAssertEqual(service.requests.count, 1, "one page for a search")
    }

    func testSignInsFilterOnTheServiceWithinTheirWindow() async throws {
        let service = FakeService()
        service.answers["/v1.0/auditLogs/signIns"] = (200, #"{"value":[{"id":"s1","createdDateTime":"2026-11-14T09:06:00Z","userPrincipalName":"m.okafor@contoso.example","appDisplayName":"Office 365","ipAddress":"203.0.113.77","clientAppUsed":"Browser","conditionalAccessStatus":"success","riskLevelDuringSignIn":"none","status":{"errorCode":0},"location":{"city":"Lagos","countryOrRegion":"NG"}},{"id":"s2","createdDateTime":"2026-11-14T09:01:00Z"}]}"#)
        let since = Entra.iso(Date().addingTimeInterval(-86_400))
        let signIns = try await callTool(Entra.adapter, "sign-ins",
            #"{"user":"m.okafor@contoso.example","ip":"203.0.113.77","failuresOnly":true,"since":"\#(since)","limit":25}"#, on: service, in: contoso)
        XCTAssertFalse(signIns.isError, signIns.text)
        XCTAssertTrue(signIns.text.contains("succeeded for m.okafor@contoso.example") && signIns.text.contains("Lagos"), signIns.text)
        XCTAssertTrue(signIns.text.contains("outcome not given"), "no status is not a success: \(signIns.text)")
        let filter = try XCTUnwrap(queryItems(service.requests.first)["$filter"])
        XCTAssertTrue(filter.hasPrefix("userPrincipalName eq 'm.okafor@contoso.example' and ipAddress eq '203.0.113.77' and status/errorCode ne 0 and createdDateTime ge \(since) and createdDateTime le "), filter)
        XCTAssertEqual(queryItems(service.requests.first)["$top"], "25")
        let old = try await callTool(Entra.adapter, "sign-ins", #"{"since":"2020-01-01T00:00:00Z"}"#, on: service, in: contoso)
        XCTAssertTrue(old.isError && old.text.contains("30 days"), old.text)
    }

    func testGroupsMethodsAndRiskyUsers() async throws {
        let service = FakeService()
        service.answers["/v1.0/users/u1@contoso.example/memberOf"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.group","id":"g1","displayName":"Finance"},{"@odata.type":"#microsoft.graph.directoryRole","id":"r1","displayName":"Global Administrator"}]}"##)
        service.answers["/v1.0/users/u1@contoso.example/authentication/methods"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.microsoftAuthenticatorAuthenticationMethod","id":"m1","displayName":"Pixel 8"},{"@odata.type":"#microsoft.graph.phoneAuthenticationMethod","id":"m2","phoneNumber":"+1 555 0100","phoneType":"mobile"}]}"##)
        service.answers["/v1.0/identityProtection/riskyUsers"] = (200, #"{"value":[{"id":"u1","userPrincipalName":"m.okafor@contoso.example","riskLevel":"high","riskState":"atRisk","riskDetail":"none","riskLastUpdatedDateTime":"2026-11-14T09:10:00Z"}]}"#)
        // Nested groups reach a user too: through Finance, they are in All Staff.
        service.answers["/v1.0/users/u1@contoso.example/transitiveMemberOf"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.group","id":"g1","displayName":"Finance"},{"@odata.type":"#microsoft.graph.group","id":"g2","displayName":"All Staff"},{"@odata.type":"#microsoft.graph.directoryRole","id":"r1","displayName":"Global Administrator"}]}"##)
        let groups = try await callTool(Entra.adapter, "user-groups", #"{"user":"u1@contoso.example"}"#, on: service, in: contoso)
        XCTAssertTrue(groups.text.contains("Global Administrator (role)"), groups.text)
        XCTAssertTrue(groups.text.contains("All Staff (through a nested group)"), groups.text)
        XCTAssertFalse(groups.text.contains("Finance (through"), groups.text)
        let methods = try await callTool(Entra.adapter, "user-sign-in-methods", #"{"user":"u1@contoso.example"}"#, on: service, in: contoso)
        XCTAssertTrue(methods.text.contains("Microsoft Authenticator (Pixel 8) [m1]"), methods.text)
        XCTAssertTrue(methods.text.contains("phone"), methods.text)
        let risky = try await callTool(Entra.adapter, "risky-users", "{}", on: service, in: contoso)
        XCTAssertTrue(risky.text.contains("high"), risky.text)
        XCTAssertEqual(queryItems(service.requests.last)["$filter"], "riskState eq 'atRisk'")
    }

    func testValuesThatCouldBreakAFilterOrPathAreRefused() async throws {
        let service = FakeService()
        for (tool, arguments) in [("sign-ins", #"{"since":"last week"}"#), ("sign-ins", #"{"ip":"x"}"#), ("find-user", #"{"query":""}"#),
                                  ("user-groups", #"{"user":"../users"}"#), ("user-groups", #"{"user":"a#EXT#@contoso.example"}"#),
                                  ("user-sign-in-methods", #"{"user":"ann"}"#), ("find-user", #"{"query":"a","limit":51}"#)] {
            let result = try await callTool(Entra.adapter, tool, arguments, on: service, in: contoso)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    // MARK: Listings

    /// A next page is followed only on graph.microsoft.com at the same path, taking only its $skiptoken with the
    /// original query; any other link stops the listing and says so; a later page that fails keeps what came before.
    func testListingsFollowOnlyGraphsOwnNextLinkAndSayWhereTheyStopped() async throws {
        let service = FakeService()
        let page = { (name: String, next: String?) in
            #"{"value":[{"keyId":"k-\#(name)","id":"a-\#(name)","displayName":"\#(name)","passwordCredentials":[{"keyId":"k-\#(name)","startDateTime":"2026-01-01T00:00:00Z"}]}]\#(next.map { #","@odata.nextLink":"\#($0)""# } ?? "")}"#
        }
        service.sequences["/v1.0/applications"] = [(200, page("one", "https://graph.microsoft.com/v1.0/applications?$select=evil&$skiptoken=T2")),
                                                   (200, page("two", "https://evil.example/v1.0/applications?$skiptoken=T3"))]
        service.sequences["/v1.0/servicePrincipals"] = [(200, page("three", "https://graph.microsoft.com/v1.0/servicePrincipals?$top=5")), (200, page("unreached", nil))]
        let read = try await callTool(Entra.adapter, "app-credentials", "{}", on: service, in: contoso)
        XCTAssertFalse(read.isError, read.text)
        XCTAssertTrue(read.text.contains("one") && read.text.contains("two") && read.text.contains("three"), read.text)
        XCTAssertFalse(read.text.contains("unreached"), read.text)
        XCTAssertTrue(read.text.contains("Incomplete: stopped at page 3 reading app registrations because Microsoft Graph gave a next page on another address"), read.text)
        XCTAssertTrue(read.text.contains("Incomplete: stopped at page 2 reading enterprise apps"), read.text)
        XCTAssertEqual(read.structured?["complete"] as? Bool, false)
        let second = try XCTUnwrap(service.requests.filter { $0.url?.path == "/v1.0/applications" }.last)
        XCTAssertEqual(queryItems(second)["$skiptoken"], "T2")
        XCTAssertEqual(queryItems(second)["$select"], "id,appId,displayName,passwordCredentials,keyCredentials", "only the token is taken from the link")
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "graph.microsoft.com" })

        // A later page that fails keeps the pages before, and says where and why.
        let failing = FakeService()
        failing.sequences["/v1.0/users/u1@contoso.example/authentication/methods"] = [
            (200, ##"{"value":[{"@odata.type":"#microsoft.graph.phoneAuthenticationMethod","id":"m2","phoneNumber":"+1 555 0100"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/users/u1@contoso.example/authentication/methods?$skiptoken=P2"}"##),
            (503, #"{"error":{"code":"ServiceUnavailable","message":"Try later"}}"#)]
        let methods = try await callTool(Entra.adapter, "user-sign-in-methods", #"{"user":"u1@contoso.example"}"#, on: failing, in: contoso)
        XCTAssertFalse(methods.isError, methods.text)
        XCTAssertTrue(methods.text.contains("phone") && methods.text.contains("read so far") && methods.text.contains("stopped at page 2"), methods.text)
    }

    /// An answer Pion cannot read is an error, never "nothing found"; a throttled one says how long Graph asked to wait.
    func testMalformedAnswersAreErrorsAndThrottlingSaysHowLongToWait() async throws {
        let service = FakeService()
        service.answers["/v1.0/identityProtection/riskyUsers"] = (200, #"{"users":[]}"#)
        let risky = try await callTool(Entra.adapter, "risky-users", "{}", on: service, in: contoso)
        XCTAssertTrue(risky.isError, risky.text)
        XCTAssertFalse(risky.text.contains("No users"), risky.text)
        service.answers["/v1.0/auditLogs/directoryAudits"] = (429, #"{"error":{"code":"TooManyRequests","message":"Too many requests"}}"#)
        service.responseHeaders = ["Retry-After": "30"]
        let audit = try await callTool(Entra.adapter, "directory-audit", "{}", on: service, in: contoso)
        XCTAssertTrue(audit.isError && audit.text.contains("asked to wait 30 seconds") && audit.text.contains("TooManyRequests"), audit.text)
    }

    /// Graph's refusals say what to change: a licence the tenant lacks, or the app's permission or the admin's role.
    func testRefusalsSayWhetherALicenceAPermissionOrARoleIsMissing() async throws {
        let service = FakeService()
        service.answers["/v1.0/auditLogs/signIns"] = (403, #"{"error":{"code":"Authentication_RequestFromNonPremiumTenantOrB2CTenant","message":"Neither tenant is B2C or tenant doesn't have premium license"}}"#)
        let signIns = try await callTool(Entra.adapter, "sign-ins", "{}", on: service, in: contoso)
        XCTAssertTrue(signIns.isError && signIns.text.contains("Microsoft Entra ID P1"), signIns.text)
        service.answers["/v1.0/auditLogs/directoryAudits"] = (403, #"{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges to complete the operation."}}"#)
        let audit = try await callTool(Entra.adapter, "directory-audit", "{}", on: service, in: contoso)
        XCTAssertTrue(audit.isError && audit.text.contains("AuditLog.Read.All") && audit.text.contains("Reports Reader") && audit.text.contains("check-access"), audit.text)
        service.answers["/v1.0/users"] = (401, #"{"error":{"code":"InvalidAuthenticationToken","message":"Access token has expired"}}"#)
        let user = try await callTool(Entra.adapter, "find-user", #"{"query":"ann"}"#, on: service, in: contoso)
        XCTAssertTrue(user.isError && user.text.contains("Connect the tool again"), user.text)
    }

    // MARK: Who holds what

    private let definitions = #"{"value":[{"id":"62e90394-69f5-4237-9190-012177145e10","displayName":"Global Administrator","templateId":"62e90394-69f5-4237-9190-012177145e10"},{"id":"729827e3-9c14-49f7-bb1b-9608f156bbb8","displayName":"Helpdesk Administrator","templateId":"729827e3-9c14-49f7-bb1b-9608f156bbb8"},{"id":"29232cdf-9323-42fd-ade2-1d097af3e4de","displayName":"Exchange Administrator","templateId":"29232cdf-9323-42fd-ade2-1d097af3e4de"}]}"#

    /// Every role held, actively or eligible in Privileged Identity Management, Global Administrator and the other
    /// privileged roles first, with groups said to give it to their members.
    func testRoleHoldersListActiveAndEligibleHoldersPrivilegedRolesFirst() async throws {
        let service = FakeService()
        service.answers["/v1.0/roleManagement/directory/roleDefinitions"] = (200, definitions)
        service.answers["/v1.0/roleManagement/directory/roleAssignments"] = (200, ##"{"value":[{"id":"a1","principalId":"u1","roleDefinitionId":"62e90394-69f5-4237-9190-012177145e10","directoryScopeId":"/","principal":{"@odata.type":"#microsoft.graph.user","id":"u1","userPrincipalName":"ada@contoso.com"}},{"id":"a2","principalId":"sp1","roleDefinitionId":"62e90394-69f5-4237-9190-012177145e10","directoryScopeId":"/","principal":{"@odata.type":"#microsoft.graph.servicePrincipal","id":"sp1","displayName":"Deploy Bot"}},{"id":"a3","principalId":"g1","roleDefinitionId":"729827e3-9c14-49f7-bb1b-9608f156bbb8","directoryScopeId":"/","principal":{"@odata.type":"#microsoft.graph.group","id":"g1","displayName":"Helpdesk"}}]}"##)
        service.answers["/v1.0/roleManagement/directory/roleEligibilitySchedules"] = (200, ##"{"value":[{"id":"e1","principalId":"u2","roleDefinitionId":"29232cdf-9323-42fd-ade2-1d097af3e4de","directoryScopeId":"/","principal":{"@odata.type":"#microsoft.graph.user","id":"u2","userPrincipalName":"bo@contoso.com"}}]}"##)
        let holders = try await callTool(Entra.adapter, "role-holders", "{}", on: service, in: contoso)
        XCTAssertFalse(holders.isError, holders.text)
        let lines = holders.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("Global Administrator (2): app Deploy Bot, user ada@contoso.com"), holders.text)
        XCTAssertTrue(lines[1].hasPrefix("Exchange Administrator (1): user bo@contoso.com (eligible)"), "privileged before the rest: \(holders.text)")
        XCTAssertTrue(lines.contains("Helpdesk Administrator (1): group Helpdesk (its members hold it)"), holders.text)
        XCTAssertEqual(holders.structured?["complete"] as? Bool, true)
        let one = try await callTool(Entra.adapter, "role-holders", #"{"role":"helpdesk"}"#, on: service, in: contoso)
        XCTAssertFalse(one.text.contains("Global Administrator ("), one.text)
        // Without Privileged Identity Management's licence, eligible roles are said to be unread, never "none".
        service.answers["/v1.0/roleManagement/directory/roleEligibilitySchedules"] = (403, #"{"error":{"code":"AadPremiumLicenseRequired","message":"The tenant needs an AAD Premium 2 license."}}"#)
        let unlicensed = try await callTool(Entra.adapter, "role-holders", "{}", on: service, in: contoso)
        XCTAssertTrue(unlicensed.text.contains("eligible in Privileged Identity Management were not read") && unlicensed.text.contains("P2"), unlicensed.text)
        XCTAssertEqual(unlicensed.structured?["complete"] as? Bool, false)
    }

    func testAppPermissionsShowWhatEachAppHoldsAndFlagWhatCanChangeTheTenant() async throws {
        let service = FakeService()
        service.answers["/v1.0/servicePrincipals"] = (200, #"{"value":[{"id":"graph-sp","appRoles":[{"id":"role-rm","value":"RoleManagement.ReadWrite.Directory"},{"id":"role-users","value":"User.Read.All"},{"id":"role-mail","value":"Mail.ReadWrite"}]}]}"#)
        service.answers["/v1.0/servicePrincipals/graph-sp/appRoleAssignedTo"] = (200, #"{"value":[{"principalId":"sp-deploy","principalDisplayName":"Deploy Bot","appRoleId":"role-rm"},{"principalId":"sp-deploy","principalDisplayName":"Deploy Bot","appRoleId":"role-users"},{"principalId":"sp-crm","principalDisplayName":"CRM Sync","appRoleId":"role-mail"}]}"#)
        service.answers["/v1.0/oauth2PermissionGrants"] = (200, #"{"value":[{"clientId":"5d6b6bb7-de71-4623-b4af-96380a352509","consentType":"AllPrincipals","resourceId":"graph-sp","scope":" Files.ReadWrite.All User.Read "},{"clientId":"5d6b6bb7-de71-4623-b4af-96380a352509","consentType":"Principal","principalId":"u1","resourceId":"graph-sp","scope":"Mail.Read"},{"clientId":"sp-notes","consentType":"Principal","principalId":"u2","resourceId":"other","scope":"x"}]}"#)
        service.answers["/v1.0/servicePrincipals/5d6b6bb7-de71-4623-b4af-96380a352509"] = (200, #"{"id":"sp-notes","displayName":"Notes App"}"#)
        let permissions = try await callTool(Entra.adapter, "app-permissions", "{}", on: service, in: contoso)
        XCTAssertFalse(permissions.isError, permissions.text)
        let lines = permissions.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.contains("Deploy Bot") && $0.contains("RoleManagement.ReadWrite.Directory") && $0.contains("can make administrators") }, permissions.text)
        XCTAssertTrue(lines.contains { $0.contains("CRM Sync") && $0.contains("Mail.ReadWrite") && $0.contains("can change") }, permissions.text)
        XCTAssertTrue(lines.contains { $0.contains("Notes App") && $0.contains("for everyone") && $0.contains("Files.ReadWrite.All") }, permissions.text)
        XCTAssertTrue(lines.contains { $0.contains("Notes App") && $0.contains("1 person") && $0.contains("Mail.Read") }, permissions.text)
        XCTAssertEqual(queryItems(service.requests.first)["$filter"], "appId eq '00000003-0000-0000-c000-000000000000'")
    }

    // MARK: Breach scope

    func testDirectoryAuditFiltersOnTheServiceByTimeWhoAndWhat() async throws {
        let service = FakeService()
        service.answers["/v1.0/auditLogs/directoryAudits"] = (200, #"{"value":[{"id":"d1","activityDateTime":"2026-11-14T09:05:00Z","activityDisplayName":"Update application – Certificates and secrets management","category":"ApplicationManagement","result":"success","initiatedBy":{"user":{"userPrincipalName":"m.okafor@contoso.example","ipAddress":"203.0.113.77"}},"targetResources":[{"displayName":"Payroll Sync","type":"Application"}]}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/auditLogs/directoryAudits?$skiptoken=N2"}"#)
        let since = Entra.iso(Date().addingTimeInterval(-86_400))
        let audit = try await callTool(Entra.adapter, "directory-audit",
            #"{"user":"m.okafor@contoso.example","activity":"Update application","category":"ApplicationManagement","since":"\#(since)","limit":1}"#, on: service, in: contoso)
        XCTAssertFalse(audit.isError, audit.text)
        XCTAssertTrue(audit.text.contains("Update application – Certificates and secrets management by m.okafor@contoso.example from 203.0.113.77 on Application Payroll Sync"), audit.text)
        XCTAssertTrue(audit.text.contains("More changes match than the 1 kept"), audit.text)
        let filter = try XCTUnwrap(queryItems(service.requests.last)["$filter"])
        XCTAssertTrue(filter.contains("activityDateTime ge \(since)") && filter.contains("activityDateTime le "), filter)
        XCTAssertTrue(filter.contains("initiatedBy/user/userPrincipalName eq 'm.okafor@contoso.example'"), filter)
        XCTAssertTrue(filter.contains("startswith(activityDisplayName,'Update application')") && filter.contains("category eq 'ApplicationManagement'"), filter)
        // A quote in a value is doubled, so it cannot end the literal and add to the filter.
        _ = try await callTool(Entra.adapter, "directory-audit", #"{"user":"x' or 1 eq 1"}"#, on: service, in: contoso)
        XCTAssertTrue((queryItems(service.requests.last)["$filter"] ?? "").contains("eq 'x'' or 1 eq 1'"))
    }

    func testAppCredentialsShowNewestFirstWithTheirKeyIDsAndFlags() async throws {
        let service = FakeService()
        let iso = ISO8601DateFormatter()
        func days(_ value: Double) -> String { iso.string(from: Date().addingTimeInterval(value * 86_400)) }
        service.answers["/v1.0/applications"] = (200, """
        {"value":[{"id":"app-1","appId":"a1","displayName":"Payroll Sync",
          "passwordCredentials":[{"keyId":"k1","displayName":"ci","startDateTime":"\(days(-2))","endDateTime":"\(days(180))"}],
          "keyCredentials":[{"keyId":"k2","displayName":"old cert","startDateTime":"\(days(-800))","endDateTime":"\(days(-30))"}]},
         {"id":"app-2","appId":"a2","displayName":"No Secrets","passwordCredentials":[],"keyCredentials":[]}]}
        """)
        service.answers["/v1.0/servicePrincipals"] = (200, """
        {"value":[{"id":"sp-1","appId":"a3","displayName":"Legacy Bot",
          "passwordCredentials":[{"keyId":"k3","startDateTime":"\(days(-400))","endDateTime":"\(days(3000))"}],"keyCredentials":[]}]}
        """)
        let credentials = try await callTool(Entra.adapter, "app-credentials", "{}", on: service, in: contoso)
        XCTAssertFalse(credentials.isError, credentials.text)
        let lines = credentials.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("Payroll Sync (app registration app-1)") && lines[0].contains("secret") && lines[0].contains("keyId k1") && lines[0].contains("added in the last 30 days"), credentials.text)
        XCTAssertTrue(lines.contains { $0.contains("Payroll Sync") && $0.contains("certificate") && $0.contains("expired") }, credentials.text)
        XCTAssertTrue(lines.contains { $0.contains("Legacy Bot (enterprise app sp-1)") && $0.contains("valid for more than two years") }, credentials.text)
        XCTAssertFalse(credentials.text.contains("No Secrets"), credentials.text)
        XCTAssertEqual(credentials.structured?["complete"] as? Bool, true)
    }

    // MARK: Access

    /// The key FakeService answers a request with this path and query by, built as requests build their address.
    static func key(_ path: String, _ query: [String: String]) -> String {
        var components = URLComponents(string: "https://graph.microsoft.com" + path)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!.path + "?" + components.url!.query!
    }

    /// check-access tries each read once, names the tenant and the admin's roles, and warns of permissions consented
    /// beyond what Detection asks for.
    func testCheckAccessSaysWhatWorksWhatToChangeAndWhatIsBroaderThanNeeded() async throws {
        let service = FakeService()
        let page = #"{"value":[]}"#
        for path in ["users", "applications", "auditLogs/directoryAudits", "identityProtection/riskyUsers", "roleManagement/directory/roleAssignments",
                     "users/0a0a0a0a-0000-4000-8000-00000000000a/authentication/methods"] {
            service.answers["/v1.0/" + path] = (200, page)
        }
        service.answers["/v1.0/auditLogs/signIns"] = (403, #"{"error":{"code":"Authentication_RequestFromNonPremiumTenantOrB2CTenant","message":"tenant doesn't have premium license"}}"#)
        service.answers["/v1.0/identityProtection/riskDetections"] = (403, #"{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges"}}"#)
        service.answers["/v1.0/organization"] = (200, #"{"value":[{"id":"4f1c2e3d-0000-4000-8000-000000000001","displayName":"Contoso","verifiedDomains":[{"name":"contoso.onmicrosoft.com"}]}]}"#)
        service.answers["/v1.0/me"] = (200, #"{"id":"0a0a0a0a-0000-4000-8000-00000000000a","userPrincipalName":"pion-detection@contoso.com"}"#)
        service.answers["/v1.0/roleManagement/directory/roleDefinitions"] = (200, #"{"value":[{"id":"f2ef992c-3afb-46b9-b7cf-a126ee74c451","displayName":"Global Reader","templateId":"f2ef992c-3afb-46b9-b7cf-a126ee74c451"},{"id":"fe930be7-5e62-47db-91af-98c3a49a38b1","displayName":"User Administrator"}]}"#)
        service.answers[Self.key("/v1.0/roleManagement/directory/roleAssignments", ["$filter": "principalId eq '0a0a0a0a-0000-4000-8000-00000000000a'"])] = (200, #"{"value":[{"id":"ra1","principalId":"0a0a0a0a-0000-4000-8000-00000000000a","roleDefinitionId":"f2ef992c-3afb-46b9-b7cf-a126ee74c451"},{"id":"ra2","principalId":"0a0a0a0a-0000-4000-8000-00000000000a","roleDefinitionId":"fe930be7-5e62-47db-91af-98c3a49a38b1"}]}"#)
        service.answers[Self.key("/v1.0/servicePrincipals", ["$filter": "appId eq '\(Self.client)'", "$select": "id,appDisplayName"])] = (200, #"{"value":[{"id":"7e7e7e7e-0000-4000-8000-00000000007e","appDisplayName":"Pion Detection"}]}"#)
        service.answers[Self.key("/v1.0/servicePrincipals", ["$filter": "appId eq '00000003-0000-0000-c000-000000000000'", "$select": "id"])] = (200, #"{"value":[{"id":"graph-sp"}]}"#)
        service.answers["/v1.0/oauth2PermissionGrants"] = (200, #"{"value":[{"consentType":"AllPrincipals","resourceId":"graph-sp","scope":"\#(Entra.auditScopes.joined(separator: " ")) User.ReadWrite.All"}]}"#)
        service.answers["/v1.0/servicePrincipals/7e7e7e7e-0000-4000-8000-00000000007e/appRoleAssignments"] = (200, page)
        let checked = try await callTool(Entra.adapter, "check-access", "{}", on: service, in: fabrikam)
        XCTAssertFalse(checked.isError, checked.text)
        let text = checked.text
        XCTAssertTrue(text.contains("✓ Signed in to the tenant Contoso"), text)
        XCTAssertTrue(text.contains("✓ Users and groups") && text.contains("✓ Directory audit log"), text)
        XCTAssertTrue(text.contains("✗ Sign-in log: this needs Microsoft Entra ID P1"), text)
        XCTAssertTrue(text.contains("✗ Risk detections: either the app lacks the delegated permission IdentityRiskEvent.Read.All"), text)
        XCTAssertTrue(text.contains("Signed in as pion-detection@contoso.com, who holds Global Reader, User Administrator"), text)
        XCTAssertTrue(text.contains("⚠ The signed-in admin's roles also allow changes: User Administrator"), text)
        XCTAssertTrue(text.contains("⚠ Consented besides what this tool asks for: User.ReadWrite.All") && text.contains("can change the tenant"), text)
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" }, "it changes nothing")
    }
}
