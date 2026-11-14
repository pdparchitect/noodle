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
        let groups = try await callTool(Entra.adapter, "user-groups", #"{"user":"u1"}"#, on: service, in: contoso)
        XCTAssertTrue(groups.text.contains("Global Administrator (role)"), groups.text)
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
}
