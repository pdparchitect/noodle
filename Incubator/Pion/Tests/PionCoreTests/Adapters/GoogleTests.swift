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
        // The narrowest each API takes: Logging's read-only scope, Cloud Asset's own, whose methods only read, and
        // Security Command Center's own, as it has no read-only one. Never all of Google Cloud.
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
        // Google retired v1; v2 takes the same filter and answers in the same shape.
        service.answers["/v2/organizations/123456789/sources/-/findings"] = (200, #"{"listFindingsResults":[{"finding":{"name":"organizations/123456789/sources/1/findings/f1","category":"PUBLIC_BUCKET_ACL","severity":"HIGH","state":"ACTIVE","eventTime":"2026-11-14T08:00:00Z","resourceName":"//storage.googleapis.com/payroll-exports"},"resource":{"displayName":"payroll-exports","type":"google.cloud.storage.Bucket"}}]}"#)
        let findings = try await callTool(GoogleCloud.adapter, "scc-findings", #"{"severities":["HIGH","CRITICAL"]}"#, on: service, in: cloud)
        XCTAssertFalse(findings.isError, findings.text)
        XCTAssertTrue(findings.text.contains("PUBLIC_BUCKET_ACL"), findings.text)
        XCTAssertTrue(findings.text.contains("payroll-exports"), findings.text)
        XCTAssertEqual(queryItems(service.requests.first)["filter"], #"state="ACTIVE" AND (severity="HIGH" OR severity="CRITICAL")"#)
        XCTAssertEqual(service.requests.first?.url?.host, "securitycenter.googleapis.com")
    }

    func testWhoHasAccessAndWhereAResourceIsThroughCloudAssetsReadOnlyMethods() async throws {
        let service = FakeService()
        service.answers["/v1/projects/kestrel-prod:analyzeIamPolicy"] = (200, #"""
        {"mainAnalysis":{"fullyExplored":true,"analysisResults":[{"attachedResourceFullName":"//cloudresourcemanager.googleapis.com/projects/kestrel-prod",
          "iamBinding":{"role":"roles/owner","members":["group:admins@kestrel.example"]},
          "accessControlLists":[{"resources":[{"fullResourceName":"//cloudresourcemanager.googleapis.com/projects/kestrel-prod"}],"accesses":[{"role":"roles/owner"}]}],
          "identityList":{"identities":[{"name":"user:mallory@kestrel.example"}]}}]}}
        """#)
        service.answers["/v1/projects/kestrel-prod/assets"] = (200, #"""
        {"assets":[{"name":"//compute.googleapis.com/projects/kestrel-prod/zones/europe-west1-b/instances/web-01","assetType":"compute.googleapis.com/Instance",
                    "resource":{"location":"europe-west1-b","data":{"status":"RUNNING"}}},
                   {"name":"//compute.googleapis.com/projects/kestrel-prod/zones/europe-west1-b/instances/db-01","assetType":"compute.googleapis.com/Instance",
                    "resource":{"location":"europe-west1-b"}},
                   {"name":"//cloudresourcemanager.googleapis.com/projects/604757830675","assetType":"cloudresourcemanager.googleapis.com/Project",
                    "resource":{"data":{"projectId":"kestrel-web","name":"Kestrel Web","lifecycleState":"ACTIVE","labels":{"env":"prod"}}}}]}
        """#)
        let access = try await callTool(GoogleCloud.adapter, "iam-policies", #"{"member":"mallory@kestrel.example"}"#, on: service, in: project)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("roles/owner"), access.text)
        XCTAssertTrue(access.text.contains("group:admins@kestrel.example"), "access through a group was not shown: \(access.text)")
        let asked = queryItems(service.requests.first)
        XCTAssertEqual(asked["analysisQuery.identitySelector.identity"], "user:mallory@kestrel.example")
        XCTAssertEqual(asked["analysisQuery.options.expandGroups"], "true")
        let onResource = try await callTool(GoogleCloud.adapter, "iam-policies",
            #"{"resource":"//cloudresourcemanager.googleapis.com/projects/kestrel-prod","role":"roles/owner"}"#, on: service, in: project)
        XCTAssertFalse(onResource.isError, onResource.text)
        XCTAssertEqual(queryItems(service.requests.last)["analysisQuery.resourceSelector.fullResourceName"], "//cloudresourcemanager.googleapis.com/projects/kestrel-prod")
        XCTAssertEqual(queryItems(service.requests.last)["analysisQuery.accessSelector.roles"], "roles/owner")
        let neither = try await callTool(GoogleCloud.adapter, "iam-policies", "{}", on: service, in: project)
        XCTAssertTrue(neither.isError)

        let resources = try await callTool(GoogleCloud.adapter, "find-resources",
            #"{"assetTypes":["compute.googleapis.com/Instance","cloudresourcemanager.googleapis.com/Project"],"name":"web"}"#, on: service, in: project)
        XCTAssertFalse(resources.isError, resources.text)
        XCTAssertTrue(resources.text.contains("web-01 (compute.googleapis.com/Instance) in europe-west1-b, RUNNING"), resources.text)
        // A project by its ID and its own name, not the number in its address, matched by either.
        XCTAssertTrue(resources.text.contains("kestrel-web, Kestrel Web (cloudresourcemanager.googleapis.com/Project), ACTIVE"), resources.text)
        XCTAssertFalse(resources.text.contains("db-01"), "a resource whose name does not match was shown")
        // Cloud Asset takes each type as a parameter of its own.
        let sent = service.requests.last?.url?.query ?? ""
        XCTAssertTrue(sent.contains("assetTypes=compute.googleapis.com/Instance&assetTypes=cloudresourcemanager.googleapis.com/Project"), sent)
        XCTAssertEqual(queryItems(service.requests.last)["contentType"], "RESOURCE")
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
