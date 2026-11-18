import Foundation
import NoodleCore
import NoodleMCP
@testable import PionCore
import XCTest

final class GoogleTests: XCTestCase {
    private let cloud = try! GoogleCloud.preset.makeConnection(name: "Google Cloud — Kestrel", values: [
        "level": "organizations", "id": "123456789", "clientID": "1234-abc.apps.googleusercontent.com"])
    private let project = try! GoogleCloud.preset.makeConnection(name: "Google Cloud — Prod", values: [
        "level": "projects", "id": "kestrel-prod", "clientID": "1234-abc.apps.googleusercontent.com"])
    private let workspace = try! GoogleWorkspace.preset.makeConnection(name: "Workspace", values: ["clientID": "1234-abc.apps.googleusercontent.com"])

    private func json(_ request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
    }

    func testEachAccountReachesGooglesAPIsWithoutAKeyOfItsOwn() {
        XCTAssertEqual(cloud.endpoint.absoluteString, "https://googleapis.com")
        XCTAssertEqual(workspace.endpoint.absoluteString, "https://admin.googleapis.com")
        XCTAssertFalse(cloud.keepsSecret)
        XCTAssertFalse(workspace.keepsSecret)
        XCTAssertNotNil(PionAdapters.all["google-cloud"])
        XCTAssertNotNil(PionAdapters.all["google-workspace"])
    }

    func testBothSignInWithGoogleThroughTheOrganisationsOwnClientWithTheNarrowestScopesTheirAPIsTake() throws {
        // Cloud Asset and Security Command Center take only their own scopes or all of Google Cloud's, not its read-only one.
        let scopes = [(GoogleWorkspace.preset, workspace, ["https://www.googleapis.com/auth/admin.reports.audit.readonly"]),
                      (GoogleCloud.preset, cloud, ["https://www.googleapis.com/auth/logging.read", "https://www.googleapis.com/auth/cloudasset",
                                                   "https://www.googleapis.com/auth/securitycenter"])]
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        ToolCatalog.use(PionCatalogue.entries)
        for (preset, account, scope) in scopes {
            guard case .connection(let configuration) = preset.configuration, let oauth = configuration.oauth else { return XCTFail(preset.name) }
            XCTAssertEqual(oauth.scopes, scope)
            XCTAssertTrue(oauth.clients.isEmpty, "Pion ships a Google client of its own")
            XCTAssertEqual(configuration.oauthClientField, "clientID")
            XCTAssertEqual(account.settings?["clientID"], "1234-abc.apps.googleusercontent.com")
            XCTAssertTrue(ToolConnectionService.signsInThroughBrowser(account), preset.name)
            XCTAssertEqual(ToolConnectionService.configuredRedirectURI(for: account.endpoint, bundleIdentifier: "com.pdparchitect.pion")?.absoluteString,
                           "com.pdparchitect.pion:/oauth2callback")
        }
    }

    func testAuditLogsAreFilteredForTheScope() async throws {
        let service = FakeService()
        service.answers["/v2/entries:list"] = (200, #"{"entries":[{"timestamp":"2026-11-14T09:00:00Z","logName":"organizations/123456789/logs/cloudaudit.googleapis.com%2Factivity","protoPayload":{"methodName":"SetIamPolicy","serviceName":"cloudresourcemanager.googleapis.com","resourceName":"projects/kestrel-prod","authenticationInfo":{"principalEmail":"mallory@kestrel.example"},"requestMetadata":{"callerIp":"203.0.113.77"},"status":{}}}]}"#)
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"principal":"mallory@kestrel.example","since":"2026-11-13T00:00:00Z","limit":20}"#, on: service, in: cloud)
        XCTAssertFalse(logs.isError, logs.text)
        XCTAssertTrue(logs.text.contains("SetIamPolicy by mallory@kestrel.example from 203.0.113.77"), logs.text)
        let request = try XCTUnwrap(service.requests.first)
        XCTAssertEqual(request.url?.host, "logging.googleapis.com")
        let body = try json(request)
        XCTAssertEqual(body["resourceNames"] as? [String], ["organizations/123456789"])
        XCTAssertEqual(body["filter"] as? String,
            #"logName:"cloudaudit.googleapis.com" AND protoPayload.authenticationInfo.principalEmail="mallory@kestrel.example" AND timestamp>="2026-11-13T00:00:00Z""#)
        XCTAssertEqual(body["orderBy"] as? String, "timestamp desc")
        XCTAssertEqual(body["pageSize"] as? Int, 20)
        let bad = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"principal":"x\" OR \"y"}"#, on: service, in: cloud)
        XCTAssertTrue(bad.isError)
    }

    func testSecurityCommandCenterFindings() async throws {
        let service = FakeService()
        service.answers["/v1/organizations/123456789/sources/-/findings"] = (200, #"{"listFindingsResults":[{"finding":{"name":"organizations/123456789/sources/1/findings/f1","category":"PUBLIC_BUCKET_ACL","severity":"HIGH","state":"ACTIVE","eventTime":"2026-11-14T08:00:00Z","resourceName":"//storage.googleapis.com/payroll-exports"},"resource":{"displayName":"payroll-exports","type":"google.cloud.storage.Bucket"}}]}"#)
        let findings = try await callTool(GoogleCloud.adapter, "scc-findings", #"{"severities":["HIGH","CRITICAL"]}"#, on: service, in: cloud)
        XCTAssertFalse(findings.isError, findings.text)
        XCTAssertTrue(findings.text.contains("PUBLIC_BUCKET_ACL"), findings.text)
        XCTAssertTrue(findings.text.contains("payroll-exports"), findings.text)
        XCTAssertEqual(queryItems(service.requests.first)["filter"], #"state="ACTIVE" AND (severity="HIGH" OR severity="CRITICAL")"#)
        XCTAssertEqual(service.requests.first?.url?.host, "securitycenter.googleapis.com")
    }

    func testWhoHasAccessAndWhereAResourceIs() async throws {
        let service = FakeService()
        service.answers["/v1/projects/kestrel-prod:searchAllIamPolicies"] = (200, #"{"results":[{"resource":"//cloudresourcemanager.googleapis.com/projects/kestrel-prod","policy":{"bindings":[{"role":"roles/owner","members":["user:mallory@kestrel.example"]}]}}]}"#)
        service.answers["/v1/projects/kestrel-prod:searchAllResources"] = (200, #"{"results":[{"name":"//compute.googleapis.com/projects/kestrel-prod/zones/europe-west1-b/instances/web-01","assetType":"compute.googleapis.com/Instance","displayName":"web-01","location":"europe-west1-b"}]}"#)
        let access = try await callTool(GoogleCloud.adapter, "iam-policies", #"{"member":"mallory@kestrel.example"}"#, on: service, in: project)
        XCTAssertTrue(access.text.contains("roles/owner"), access.text)
        XCTAssertEqual(queryItems(service.requests.first)["query"], #"policy:"mallory@kestrel.example""#)
        let resources = try await callTool(GoogleCloud.adapter, "find-resources", #"{"query":"name:web-01"}"#, on: service, in: project)
        XCTAssertTrue(resources.text.contains("compute.googleapis.com/Instance"), resources.text)
        XCTAssertEqual(service.requests.last?.url?.host, "cloudasset.googleapis.com")
    }

    func testWorkspaceActivityByApplicationUserAndTime() async throws {
        let service = FakeService()
        service.answers["/admin/reports/v1/activity/users/m.okafor@kestrel.example/applications/login"] = (200, #"{"items":[{"id":{"time":"2026-11-14T09:03:00.000Z","applicationName":"login"},"actor":{"email":"m.okafor@kestrel.example"},"ipAddress":"203.0.113.77","events":[{"type":"login","name":"login_success","parameters":[{"name":"login_type","value":"google_password"},{"name":"is_suspicious","boolValue":true}]}]}]}"#)
        let activity = try await callTool(GoogleWorkspace.adapter, "activity",
            #"{"application":"login","user":"m.okafor@kestrel.example","since":"2026-11-13T00:00:00Z","limit":25}"#, on: service, in: workspace)
        XCTAssertFalse(activity.isError, activity.text)
        XCTAssertTrue(activity.text.contains("login_success"), activity.text)
        XCTAssertTrue(activity.text.contains("203.0.113.77"), activity.text)
        XCTAssertTrue(activity.text.contains("is_suspicious=true"), activity.text)
        let sent = queryItems(service.requests.first)
        XCTAssertEqual(sent["startTime"], "2026-11-13T00:00:00Z")
        XCTAssertEqual(sent["maxResults"], "25")
        XCTAssertEqual(service.requests.first?.url?.host, "admin.googleapis.com")
        _ = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"token"}"#, on: service, in: workspace)
        XCTAssertEqual(service.requests.last?.url?.path, "/admin/reports/v1/activity/users/all/applications/token")
        let bad = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"gmail-everything"}"#, on: service, in: workspace)
        XCTAssertTrue(bad.isError)
    }
}
