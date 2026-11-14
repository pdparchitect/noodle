import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class MicrosoftTests: XCTestCase {
    private let contoso = try! Entra.preset.makeConnection(name: "Entra — Contoso", values: ["tenant": "contoso.onmicrosoft.com"])
    private let fabrikam = try! Entra.preset.makeConnection(name: "Entra — Fabrikam", values: ["tenant": "4f1c2e3d-0000-4000-8000-000000000001"])
    private let defender = try! Defender.preset.makeConnection(name: "Defender", values: ["tenant": "contoso.onmicrosoft.com"])

    private func call(_ adapter: OperationAdapter, _ tool: String, _ arguments: String, on service: FakeService,
                      in connection: MCPConnectionRecord) async throws -> (text: String, isError: Bool, structured: [String: Any]?) {
        let data = try await adapter.run(tool, arguments: Data(arguments.utf8), connection: connection, access: service)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? "", result["isError"] as? Bool ?? false,
                result["structuredContent"] as? [String: Any])
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        let items = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testEachTenantGetsItsOwnTokensFromMicrosoft() {
        XCTAssertEqual(contoso.endpoint.absoluteString, "https://graph.microsoft.com/v1.0")
        XCTAssertEqual(contoso.clientCredentials?.tokenEndpoint.absoluteString,
                       "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token")
        XCTAssertEqual(fabrikam.clientCredentials?.tokenEndpoint.absoluteString,
                       "https://login.microsoftonline.com/4f1c2e3d-0000-4000-8000-000000000001/oauth2/v2.0/token")
        XCTAssertEqual(contoso.clientCredentials?.scope, "https://graph.microsoft.com/.default")
        XCTAssertEqual(contoso.adapter, "entra")
        XCTAssertEqual(defender.adapter, "defender")
        XCTAssertNotNil(PionAdapters.all["entra"])
        XCTAssertNotNil(PionAdapters.all["defender"])
        XCTAssertThrowsError(try Entra.preset.makeConnection(name: "Bad", values: ["tenant": "contoso/../x"]))
    }

    func testFindingAUserEscapesTheQueryForTheFilter() async throws {
        let service = FakeService()
        service.answers["/v1.0/users"] = (200, #"{"value":[{"id":"u1","displayName":"Ann O'Brien","userPrincipalName":"ann@contoso.example","accountEnabled":true}]}"#)
        let found = try await call(Entra.adapter, "find-user", #"{"query":"O'Brien"}"#, on: service, in: contoso)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("Ann O'Brien"), found.text)
        XCTAssertEqual(query(service.requests.first)["$filter"],
                       "startswith(displayName,'O''Brien') or startswith(userPrincipalName,'O''Brien') or startswith(mail,'O''Brien')")
        XCTAssertEqual(query(service.requests.first)["$top"], "10")
    }

    func testSignInsFilterOnTheService() async throws {
        let service = FakeService()
        service.answers["/v1.0/auditLogs/signIns"] = (200, #"{"value":[{"id":"s1","createdDateTime":"2026-11-14T09:06:00Z","userPrincipalName":"m.okafor@contoso.example","appDisplayName":"Office 365","ipAddress":"203.0.113.77","clientAppUsed":"Browser","conditionalAccessStatus":"success","riskLevelDuringSignIn":"none","status":{"errorCode":0},"location":{"city":"Lagos","countryOrRegion":"NG"}}]}"#)
        let signIns = try await call(Entra.adapter, "sign-ins",
            #"{"user":"m.okafor@contoso.example","ip":"203.0.113.77","failuresOnly":true,"since":"2026-11-13T00:00:00Z","limit":25}"#,
            on: service, in: contoso)
        XCTAssertFalse(signIns.isError, signIns.text)
        XCTAssertTrue(signIns.text.contains("Lagos"), signIns.text)
        XCTAssertEqual(query(service.requests.first)["$filter"],
                       "userPrincipalName eq 'm.okafor@contoso.example' and ipAddress eq '203.0.113.77' and status/errorCode ne 0 and createdDateTime ge 2026-11-13T00:00:00Z")
        XCTAssertEqual(query(service.requests.first)["$top"], "25")
    }

    func testGroupsMethodsAndRiskyUsers() async throws {
        let service = FakeService()
        service.answers["/v1.0/users/u1/memberOf"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.group","id":"g1","displayName":"Finance"},{"@odata.type":"#microsoft.graph.directoryRole","id":"r1","displayName":"Global Administrator"}]}"##)
        service.answers["/v1.0/users/u1/authentication/methods"] = (200, ##"{"value":[{"@odata.type":"#microsoft.graph.microsoftAuthenticatorAuthenticationMethod","id":"m1","displayName":"Pixel 8"},{"@odata.type":"#microsoft.graph.phoneAuthenticationMethod","id":"m2","phoneNumber":"+1 555 0100","phoneType":"mobile"}]}"##)
        service.answers["/v1.0/identityProtection/riskyUsers"] = (200, #"{"value":[{"id":"u1","userPrincipalName":"m.okafor@contoso.example","riskLevel":"high","riskState":"atRisk","riskDetail":"none","riskLastUpdatedDateTime":"2026-11-14T09:10:00Z"}]}"#)
        let groups = try await call(Entra.adapter, "user-groups", #"{"user":"u1"}"#, on: service, in: contoso)
        XCTAssertTrue(groups.text.contains("Global Administrator (role)"), groups.text)
        let methods = try await call(Entra.adapter, "user-sign-in-methods", #"{"user":"u1"}"#, on: service, in: contoso)
        XCTAssertTrue(methods.text.contains("Microsoft Authenticator"), methods.text)
        XCTAssertTrue(methods.text.contains("phone"), methods.text)
        let risky = try await call(Entra.adapter, "risky-users", "{}", on: service, in: contoso)
        XCTAssertTrue(risky.text.contains("high"), risky.text)
        XCTAssertEqual(query(service.requests.last)["$filter"], "riskState eq 'atRisk'")
    }

    func testDefenderAlertsIncidentsAndHunting() async throws {
        let service = FakeService()
        service.answers["/v1.0/security/alerts_v2"] = (200, ##"{"value":[{"id":"a1","title":"Suspicious execution of hidden file","severity":"high","status":"new","category":"DefenseEvasion","serviceSource":"microsoftDefenderForEndpoint","createdDateTime":"2026-11-14T08:00:00Z","incidentId":"28282","alertWebUrl":"https://security.microsoft.com/alerts/a1","mitreTechniques":["T1564.001"],"evidence":[{"@odata.type":"#microsoft.graph.security.deviceEvidence","hostName":"lt-0423"}]}]}"##)
        service.answers["/v1.0/security/incidents"] = (200, #"{"value":[{"id":"28282","displayName":"Multi-stage incident","severity":"high","status":"active","createdDateTime":"2026-11-14T08:00:00Z","incidentWebUrl":"https://security.microsoft.com/incidents/28282"}]}"#)
        service.answers["/v1.0/security/runHuntingQuery"] = (200, #"{"schema":[{"name":"Timestamp","type":"DateTime"},{"name":"FileName","type":"String"}],"results":[{"Timestamp":"2026-11-14T08:01:00Z","FileName":"cmd.exe"}]}"#)

        let alerts = try await call(Defender.adapter, "alerts", #"{"severity":"high","status":"new","since":"2026-11-13T00:00:00Z"}"#, on: service, in: defender)
        XCTAssertTrue(alerts.text.contains("Suspicious execution of hidden file"), alerts.text)
        XCTAssertTrue(alerts.text.contains("lt-0423"), alerts.text)
        XCTAssertEqual(query(service.requests.last)["$filter"], "severity eq 'high' and status eq 'new' and createdDateTime ge 2026-11-13T00:00:00Z")

        let incidents = try await call(Defender.adapter, "incidents", #"{"status":"active"}"#, on: service, in: defender)
        XCTAssertTrue(incidents.text.contains("Multi-stage incident"), incidents.text)

        let hunt = try await call(Defender.adapter, "hunt", #"{"query":"DeviceProcessEvents | take 1","timespan":"P7D"}"#, on: service, in: defender)
        XCTAssertFalse(hunt.isError, hunt.text)
        XCTAssertTrue(hunt.text.contains("cmd.exe"), hunt.text)
        let posted = try XCTUnwrap(service.requests.last)
        XCTAssertEqual(posted.httpMethod, "POST")
        XCTAssertEqual(posted.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: posted.httpBody ?? Data()) as? [String: String])
        XCTAssertEqual(body, ["Query": "DeviceProcessEvents | take 1", "Timespan": "P7D"])
    }

    func testValuesThatCouldBreakAFilterAreRefused() async throws {
        let service = FakeService()
        for (adapter, tool, arguments) in [(Entra.adapter, "sign-ins", #"{"since":"last week"}"#), (Entra.adapter, "sign-ins", #"{"ip":"x"}"#),
                                           (Defender.adapter, "alerts", #"{"severity":"catastrophic"}"#),
                                           (Defender.adapter, "hunt", #"{"query":""}"#), (Entra.adapter, "find-user", #"{"query":""}"#)] {
            let result = try await call(adapter, tool, arguments, on: service, in: tool == "alerts" || tool == "hunt" ? defender : contoso)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }
}
