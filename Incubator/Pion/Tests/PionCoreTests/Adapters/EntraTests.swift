import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class EntraTests: XCTestCase {
    private let contoso = try! Entra.preset.makeConnection(name: "Entra — Contoso", values: ["tenant": "contoso.onmicrosoft.com"])
    private let fabrikam = try! Entra.preset.makeConnection(name: "Entra — Fabrikam", values: ["tenant": "4f1c2e3d-0000-4000-8000-000000000001"])

    func testEachTenantGetsItsOwnTokensFromMicrosoft() {
        XCTAssertEqual(contoso.endpoint.absoluteString, "https://graph.microsoft.com/v1.0")
        XCTAssertEqual(contoso.clientCredentials?.tokenEndpoint.absoluteString,
                       "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token")
        XCTAssertEqual(fabrikam.clientCredentials?.tokenEndpoint.absoluteString,
                       "https://login.microsoftonline.com/4f1c2e3d-0000-4000-8000-000000000001/oauth2/v2.0/token")
        XCTAssertEqual(contoso.clientCredentials?.scope, "https://graph.microsoft.com/.default")
        XCTAssertEqual(contoso.adapter, "entra")
        XCTAssertNotNil(PionAdapters.all["entra"])
        XCTAssertThrowsError(try Entra.preset.makeConnection(name: "Bad", values: ["tenant": "contoso/../x"]))
    }

    func testFindingAUserEscapesTheQueryForTheFilter() async throws {
        let service = FakeService()
        service.answers["/v1.0/users"] = (200, #"{"value":[{"id":"u1","displayName":"Ann O'Brien","userPrincipalName":"ann@contoso.example","accountEnabled":true}]}"#)
        let found = try await callTool(Entra.adapter, "find-user", #"{"query":"O'Brien"}"#, on: service, in: contoso)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("Ann O'Brien"), found.text)
        XCTAssertEqual(queryItems(service.requests.first)["$filter"],
                       "startswith(displayName,'O''Brien') or startswith(userPrincipalName,'O''Brien') or startswith(mail,'O''Brien')")
        XCTAssertEqual(queryItems(service.requests.first)["$top"], "10")
    }

    func testSignInsFilterOnTheService() async throws {
        let service = FakeService()
        service.answers["/v1.0/auditLogs/signIns"] = (200, #"{"value":[{"id":"s1","createdDateTime":"2026-11-14T09:06:00Z","userPrincipalName":"m.okafor@contoso.example","appDisplayName":"Office 365","ipAddress":"203.0.113.77","clientAppUsed":"Browser","conditionalAccessStatus":"success","riskLevelDuringSignIn":"none","status":{"errorCode":0},"location":{"city":"Lagos","countryOrRegion":"NG"}}]}"#)
        let signIns = try await callTool(Entra.adapter, "sign-ins",
            #"{"user":"m.okafor@contoso.example","ip":"203.0.113.77","failuresOnly":true,"since":"2026-11-13T00:00:00Z","limit":25}"#,
            on: service, in: contoso)
        XCTAssertFalse(signIns.isError, signIns.text)
        XCTAssertTrue(signIns.text.contains("Lagos"), signIns.text)
        XCTAssertEqual(queryItems(service.requests.first)["$filter"],
                       "userPrincipalName eq 'm.okafor@contoso.example' and ipAddress eq '203.0.113.77' and status/errorCode ne 0 and createdDateTime ge 2026-11-13T00:00:00Z")
        XCTAssertEqual(queryItems(service.requests.first)["$top"], "25")
    }

    func testGroupsMethodsAndRiskyUsers() async throws {
        let service = FakeService()
        service.answers["/v1.0/users/u1/memberOf"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.group","id":"g1","displayName":"Finance"},{"@odata.type":"#microsoft.graph.directoryRole","id":"r1","displayName":"Global Administrator"}]}"##)
        service.answers["/v1.0/users/u1/authentication/methods"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.microsoftAuthenticatorAuthenticationMethod","id":"m1","displayName":"Pixel 8"},{"@odata.type":"#microsoft.graph.phoneAuthenticationMethod","id":"m2","phoneNumber":"+1 555 0100","phoneType":"mobile"}]}"##)
        service.answers["/v1.0/identityProtection/riskyUsers"] = (200, #"{"value":[{"id":"u1","userPrincipalName":"m.okafor@contoso.example","riskLevel":"high","riskState":"atRisk","riskDetail":"none","riskLastUpdatedDateTime":"2026-11-14T09:10:00Z"}]}"#)
        // Nested groups reach a user too: through Finance, they are in All Staff.
        service.answers["/v1.0/users/u1/transitiveMemberOf"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.group","id":"g1","displayName":"Finance"},{"@odata.type":"#microsoft.graph.group","id":"g2","displayName":"All Staff"},{"@odata.type":"#microsoft.graph.directoryRole","id":"r1","displayName":"Global Administrator"}]}"##)
        let groups = try await callTool(Entra.adapter, "user-groups", #"{"user":"u1"}"#, on: service, in: contoso)
        XCTAssertTrue(groups.text.contains("Global Administrator (role)"), groups.text)
        XCTAssertTrue(groups.text.contains("All Staff (through a nested group)"), groups.text)
        XCTAssertFalse(groups.text.contains("Finance (through"), groups.text)
        let methods = try await callTool(Entra.adapter, "user-sign-in-methods", #"{"user":"u1"}"#, on: service, in: contoso)
        XCTAssertTrue(methods.text.contains("Microsoft Authenticator"), methods.text)
        XCTAssertTrue(methods.text.contains("phone"), methods.text)
        let risky = try await callTool(Entra.adapter, "risky-users", "{}", on: service, in: contoso)
        XCTAssertTrue(risky.text.contains("high"), risky.text)
        XCTAssertEqual(queryItems(service.requests.last)["$filter"], "riskState eq 'atRisk'")
    }

    func testValuesThatCouldBreakAFilterAreRefused() async throws {
        let service = FakeService()
        for (tool, arguments) in [("sign-ins", #"{"since":"last week"}"#), ("sign-ins", #"{"ip":"x"}"#), ("find-user", #"{"query":""}"#)] {
            let result = try await callTool(Entra.adapter, tool, arguments, on: service, in: contoso)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testItsTriggerFindsUsersNewlyAtHighRisk() async throws {
        let service = FakeService()
        service.answers["/v1.0/identityProtection/riskyUsers"] = (200, #"{"value":[{"id":"u2","riskLastUpdatedDateTime":"2026-11-19T09:14:00.1234567Z"},{"id":"u1","riskLastUpdatedDateTime":"2026-11-19T09:11:00Z"}]}"#)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let users = try await Entra.adapter.alerts(since: since, connection: contoso, access: service)
        XCTAssertEqual(users.map(\.id), ["u2", "u1"])
        XCTAssertEqual(queryItems(service.requests.last)["$filter"],
                       "riskLevel eq 'high' and riskState eq 'atRisk' and riskLastUpdatedDateTime ge 2026-11-19T09:00:00Z")
        XCTAssertEqual(Entra.adapter.watchedTool, "risky-users")
    }

    // MARK: Who holds what

    /// Every active directory role and who holds it, people, groups and apps, Global Administrator first.
    func testRoleHoldersListEachActiveRoleWithWhoHoldsIt() async throws {
        let service = FakeService()
        service.answers["/v1.0/directoryRoles"] = (200, #"{"value":[{"id":"r-helpdesk","displayName":"Helpdesk Administrator"},{"id":"r-global","displayName":"Global Administrator"},{"id":"r-empty","displayName":"Exchange Administrator"}]}"#)
        service.answers["/v1.0/directoryRoles/r-global/members"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.user","id":"u1","displayName":"Ada","userPrincipalName":"ada@contoso.com"},{"@odata.type":"#microsoft.graph.servicePrincipal","id":"sp1","displayName":"Deploy Bot","appId":"a1"}]}"##)
        service.answers["/v1.0/directoryRoles/r-helpdesk/members"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.group","id":"g1","displayName":"Helpdesk"}]}"##)
        service.answers["/v1.0/directoryRoles/r-empty/members"] = (200, #"{"value":[]}"#)
        let holders = try await callTool(Entra.adapter, "role-holders", "{}", on: service, in: contoso)
        XCTAssertFalse(holders.isError, holders.text)
        let lines = holders.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("Global Administrator (2): user ada@contoso.com, app Deploy Bot"), holders.text)
        XCTAssertTrue(lines.contains("Helpdesk Administrator (1): group Helpdesk"), holders.text)
        XCTAssertFalse(holders.text.contains("Exchange Administrator"), "a role nobody holds says nothing")
        XCTAssertTrue(holders.text.contains("eligible"), "says what it leaves out")
        let one = try await callTool(Entra.adapter, "role-holders", #"{"role":"helpdesk"}"#, on: service, in: contoso)
        XCTAssertFalse(one.text.contains("Global Administrator ("), one.text)
        XCTAssertTrue(one.text.contains("Helpdesk Administrator (1)"), one.text)
    }

    /// Which apps hold which Microsoft Graph permissions, granted to the app itself or consented for people, with those
    /// that can change the tenant flagged, and above all those that can make an app or a person an administrator.
    func testAppPermissionsShowWhatEachAppHoldsAndFlagWhatCanChangeTheTenant() async throws {
        let service = FakeService()
        service.answers["/v1.0/servicePrincipals"] = (200, #"{"value":[{"id":"graph-sp","appRoles":[{"id":"role-rm","value":"RoleManagement.ReadWrite.Directory"},{"id":"role-users","value":"User.Read.All"},{"id":"role-mail","value":"Mail.ReadWrite"}]}]}"#)
        service.answers["/v1.0/servicePrincipals/graph-sp/appRoleAssignedTo"] = (200, #"{"value":[{"principalId":"sp-deploy","principalDisplayName":"Deploy Bot","appRoleId":"role-rm"},{"principalId":"sp-deploy","principalDisplayName":"Deploy Bot","appRoleId":"role-users"},{"principalId":"sp-crm","principalDisplayName":"CRM Sync","appRoleId":"role-mail"}]}"#)
        service.answers["/v1.0/oauth2PermissionGrants"] = (200, #"{"value":[{"clientId":"sp-notes","consentType":"AllPrincipals","resourceId":"graph-sp","scope":" Files.ReadWrite.All User.Read "},{"clientId":"sp-notes","consentType":"Principal","principalId":"u1","resourceId":"graph-sp","scope":"Mail.Read"},{"clientId":"sp-notes","consentType":"Principal","principalId":"u2","resourceId":"other","scope":"x"}]}"#)
        service.answers["/v1.0/servicePrincipals/sp-notes"] = (200, #"{"id":"sp-notes","displayName":"Notes App"}"#)
        let permissions = try await callTool(Entra.adapter, "app-permissions", "{}", on: service, in: contoso)
        XCTAssertFalse(permissions.isError, permissions.text)
        let lines = permissions.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.contains("Deploy Bot") && $0.contains("RoleManagement.ReadWrite.Directory") && $0.contains("can make administrators") },
                      permissions.text)
        XCTAssertTrue(lines.contains { $0.contains("CRM Sync") && $0.contains("Mail.ReadWrite") && $0.contains("can change") }, permissions.text)
        XCTAssertTrue(lines.contains { $0.contains("Notes App") && $0.contains("for everyone") && $0.contains("Files.ReadWrite.All") }, permissions.text)
        XCTAssertTrue(lines.contains { $0.contains("Notes App") && $0.contains("1 person") && $0.contains("Mail.Read") }, permissions.text)
        XCTAssertEqual(queryItems(service.requests.first)["$filter"], "appId eq '00000003-0000-0000-c000-000000000000'")
    }

    // MARK: Breach scope

    /// Who changed what in the directory, and from where: the trail an attacker leaves when they add an app's secret,
    /// grant a role or change a user.
    func testDirectoryAuditFiltersOnTheServiceByTimeWhoAndWhat() async throws {
        let service = FakeService()
        service.answers["/v1.0/auditLogs/directoryAudits"] = (200, #"{"value":[{"activityDateTime":"2026-11-14T09:05:00Z","activityDisplayName":"Update application – Certificates and secrets management","category":"ApplicationManagement","result":"success","initiatedBy":{"user":{"userPrincipalName":"m.okafor@contoso.example","ipAddress":"203.0.113.77"}},"targetResources":[{"displayName":"Payroll Sync","type":"Application"}]}]}"#)
        let audit = try await callTool(Entra.adapter, "directory-audit",
            #"{"user":"m.okafor@contoso.example","activity":"Update application","since":"2026-11-13T00:00:00Z"}"#, on: service, in: contoso)
        XCTAssertFalse(audit.isError, audit.text)
        XCTAssertTrue(audit.text.contains("Update application – Certificates and secrets management by m.okafor@contoso.example from 203.0.113.77 on Application Payroll Sync"), audit.text)
        let filter = try XCTUnwrap(queryItems(service.requests.last)["$filter"])
        XCTAssertTrue(filter.contains("activityDateTime ge 2026-11-13T00:00:00Z"), filter)
        XCTAssertTrue(filter.contains("initiatedBy/user/userPrincipalName eq 'm.okafor@contoso.example'"), filter)
        XCTAssertTrue(filter.contains("startswith(activityDisplayName,'Update application')"), filter)
        // A quote in a value is doubled, so it cannot end the literal and add to the filter.
        _ = try await callTool(Entra.adapter, "directory-audit", #"{"user":"x' or 1 eq 1"}"#, on: service, in: contoso)
        XCTAssertTrue((queryItems(service.requests.last)["$filter"] ?? "").contains("eq 'x'' or 1 eq 1'"))
    }

    /// The secrets and certificates apps sign in with: one added lately may be an attacker's way back in, and one that
    /// never expires lasts as long as it is not found.
    func testAppCredentialsShowNewestFirstAndFlagRecentLongLivedAndExpired() async throws {
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
        XCTAssertTrue(lines[0].contains("Payroll Sync") && lines[0].contains("secret") && lines[0].contains("added in the last 30 days"), credentials.text)
        XCTAssertTrue(lines.contains { $0.contains("Payroll Sync") && $0.contains("certificate") && $0.contains("expired") }, credentials.text)
        XCTAssertTrue(lines.contains { $0.contains("Legacy Bot") && $0.contains("enterprise app") && $0.contains("valid for more than two years") }, credentials.text)
        XCTAssertFalse(credentials.text.contains("No Secrets"), credentials.text)
        XCTAssertEqual(queryItems(service.requests.first { $0.url?.path == "/v1.0/applications" })["$select"],
                       "id,appId,displayName,passwordCredentials,keyCredentials")
    }
}

