import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class SentinelTests: XCTestCase {
    private let sentinel = try! Sentinel.preset.makeConnection(name: "Sentinel",
        values: ["tenant": "contoso.onmicrosoft.com", "clientID": EntraTests.client, "workspace": "8a7f3c2e-0000-4000-8000-000000000002"])
    private let queryPath = "/v1/workspaces/8a7f3c2e-0000-4000-8000-000000000002/query"

    func testAWorkspaceIsQueriedAsAnAdminSignedInForLogAnalytics() throws {
        XCTAssertEqual(sentinel.endpoint.absoluteString, "https://api.loganalytics.azure.com/v1/workspaces/8a7f3c2e-0000-4000-8000-000000000002")
        XCTAssertNil(sentinel.clientCredentials, "no client secret: an admin signs in")
        XCTAssertFalse(sentinel.keepsSecret)
        XCTAssertEqual(sentinel.settings?["clientID"], EntraTests.client)
        guard case .connection(let configuration) = Sentinel.preset.configuration else { return XCTFail() }
        XCTAssertEqual(configuration.fields.map(\.key), ["tenant", "clientID", "workspace"])
        XCTAssertEqual(configuration.oauthClientField, "clientID")
        XCTAssertEqual(configuration.oauthPathField, "tenant")
        XCTAssertEqual(configuration.oauthPathExcludes, Entra.generic)
        let oauth = try XCTUnwrap(configuration.oauth(for: sentinel.settings))
        XCTAssertEqual(oauth.authorizationEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/authorize")
        XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token")
        XCTAssertFalse(oauth.usesResourceIndicator)
        XCTAssertEqual(oauth.authorizationParameters, ["prompt": "login"])
        XCTAssertEqual(oauth.unlistedScopes, ["offline_access"])
        XCTAssertEqual(oauth.scopes, ["https://api.loganalytics.io/Data.Read"], "the Log Analytics API's one delegated permission, with its resource in front")
        XCTAssertNil(configuration.oauth(for: ["tenant": "common", "clientID": EntraTests.client, "workspace": "8a7f3c2e-0000-4000-8000-000000000002"]))
        XCTAssertTrue(Sentinel.setup.contains { $0.contains("com.pdparchitect.pion:/oauth2callback") && $0.contains("Public client") })
        XCTAssertTrue(Sentinel.setup.contains { $0.contains("**Log Analytics API**") && $0.contains("`Data.Read`") && $0.contains("Grant admin consent") })
        XCTAssertTrue(Sentinel.setup.contains { $0.contains("**Log Analytics Reader**") && $0.contains("that admin") })
        XCTAssertFalse(Sentinel.setup.contains { $0.contains("Certificates & secrets") }, "no secret to keep")
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        ToolCatalog.use(PionCatalogue.entries)
        XCTAssertTrue(ToolConnectionService.signsInThroughBrowser(sentinel))
        XCTAssertNotNil(PionAdapters.all["sentinel"])
    }

    func testARefusedQuerySaysWhatToChange() async throws {
        let service = FakeService()
        service.answers[queryPath] = (403, #"{"error":{"code":"InsufficientAccessError","message":"The provided credentials have insufficient access"}}"#)
        let denied = try await callTool(Sentinel.adapter, "query", #"{"query":"SigninLogs | take 1"}"#, on: service, in: sentinel)
        XCTAssertTrue(denied.isError, denied.text)
        XCTAssertTrue(denied.text.contains("Log Analytics Reader or Microsoft Sentinel Reader") && denied.text.contains("insufficient access"), denied.text)
        service.answers[queryPath] = (401, #"{"error":{"code":"InvalidTokenError","message":"expired"}}"#)
        let expired = try await callTool(Sentinel.adapter, "query", #"{"query":"SigninLogs | take 1"}"#, on: service, in: sentinel)
        XCTAssertTrue(expired.text.contains("Microsoft did not accept the sign-in") && expired.text.contains("Connect the tool again in Settings › Tools"), expired.text)
    }

    func testCheckAccessTriesTheWorkspaceAndIncidentsAndNamesTheSignIn() async throws {
        let service = FakeService()
        service.answers[queryPath] = (200, #"{"tables":[{"name":"PrimaryResult","columns":[{"name":"ok","type":"long"}],"rows":[[1]]}]}"#)
        let found = try await callTool(Sentinel.adapter, "check-access", "{}", on: service, in: sentinel)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("✓ Querying the workspace"), found.text)
        XCTAssertTrue(found.text.contains("✓ Microsoft Sentinel's incidents"), found.text)
        XCTAssertTrue(found.text.contains("· Signed in through the app \(EntraTests.client), asking for https://api.loganalytics.io/Data.Read, offline_access."), found.text)
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.path == queryPath })
        service.answers[queryPath] = (403, #"{"error":{"message":"no"}}"#)
        let denied = try await callTool(Sentinel.adapter, "check-access", "{}", on: service, in: sentinel)
        XCTAssertTrue(denied.text.contains("✗ Querying the workspace: Log Analytics refused the query") && denied.text.contains("Log Analytics Reader"), denied.text)
    }

    func testSentinelRunsKQLOverItsWorkspace() async throws {
        let service = FakeService()
        service.answers["/v1/workspaces/8a7f3c2e-0000-4000-8000-000000000002/query"] = (200, #"{"tables":[{"name":"PrimaryResult","columns":[{"name":"TimeGenerated","type":"datetime"},{"name":"IPAddress","type":"string"}],"rows":[["2026-11-14T09:06:00Z","203.0.113.77"]]}]}"#)
        let found = try await callTool(Sentinel.adapter, "query", #"{"query":"SigninLogs | where ResultType != 0 | take 10"}"#, on: service, in: sentinel)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("203.0.113.77"), found.text)
        let body = try JSONSerialization.jsonObject(with: service.requests.first?.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["query": "SigninLogs | where ResultType != 0 | take 10", "timespan": "P7D"])
    }

    func testItsTriggerFindsHighSeverityIncidentsSinceATime() async throws {
        let service = FakeService()
        service.answers["/v1/workspaces/8a7f3c2e-0000-4000-8000-000000000002/query"] = (200, #"{"tables":[{"name":"PrimaryResult","columns":[{"name":"IncidentNumber","type":"int"},{"name":"CreatedTime","type":"datetime"}],"rows":[[42,"2026-11-19T09:14:00.123Z"],[41,"2026-11-19T09:11:00Z"]]}]}"#)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let incidents = try await Sentinel.adapter.alerts(since: since, connection: sentinel, access: service)
        XCTAssertEqual(incidents.map(\.id), ["42", "41"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: service.requests.last?.httpBody ?? Data()) as? [String: String])
        XCTAssertTrue(body["query"]?.hasPrefix("SecurityIncident") == true, body["query"] ?? "")
        XCTAssertTrue(body["query"]?.contains("CreatedTime >= datetime(2026-11-19T09:00:00Z)") == true, body["query"] ?? "")
        XCTAssertTrue(body["query"]?.contains(#"Severity == "High""#) == true, body["query"] ?? "")
        XCTAssertTrue(body["timespan"]?.hasPrefix("2026-11-19T09:00:00Z/") == true, body["timespan"] ?? "")
        XCTAssertEqual(Sentinel.adapter.watchedTool, "query")
    }

    /// What an account did in Microsoft 365 and the directory is in Sentinel's tables when their connectors are on.
    func testItsInstructionsSayWhereMicrosoft365AndDirectoryActivityAre() {
        for table in ["OfficeActivity", "AuditLogs", "SigninLogs", "FileDownloaded"] {
            XCTAssertTrue(Sentinel.preset.defaultInstructions.contains(table), table)
        }
    }
}
