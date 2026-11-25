import Foundation
import NoodleCore
import NoodleToolConnections
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
        let scopes = [(GoogleWorkspace.preset, workspace, ["https://www.googleapis.com/auth/admin.reports.audit.readonly",
                                                           "https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly",
                                                           "https://www.googleapis.com/auth/admin.directory.user.readonly",
                                                           "https://www.googleapis.com/auth/admin.directory.group.readonly",
                                                           "https://www.googleapis.com/auth/admin.directory.device.mobile.readonly",
                                                           "https://www.googleapis.com/auth/admin.directory.domain.readonly",
                                                           "https://www.googleapis.com/auth/cloud-identity.policies.readonly"]),
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

    func testAuditLogsAreFilteredForTheScopeAndReachEachOfItsProjectsLogs() async throws {
        let service = FakeService()
        // A project keeps its own audit logs, so an organisation's search names its live projects too.
        service.answers["/v1/organizations/123456789/assets"] = (200, #"""
        {"assets":[{"name":"//cloudresourcemanager.googleapis.com/projects/1001","assetType":"cloudresourcemanager.googleapis.com/Project",
                    "resource":{"data":{"projectId":"kestrel-prod","lifecycleState":"ACTIVE"}}},
                   {"name":"//cloudresourcemanager.googleapis.com/projects/1002","assetType":"cloudresourcemanager.googleapis.com/Project",
                    "resource":{"data":{"projectId":"kestrel-old","lifecycleState":"DELETE_REQUESTED"}}}]}
        """#)
        // Logging answers in pages, however many entries were asked for.
        service.sequences["/v2/entries:list"] = [
            (200, #"{"entries":[{"timestamp":"2026-11-14T09:00:00Z","logName":"organizations/123456789/logs/cloudaudit.googleapis.com%2Factivity","protoPayload":{"methodName":"SetIamPolicy","serviceName":"cloudresourcemanager.googleapis.com","resourceName":"projects/kestrel-prod","authenticationInfo":{"principalEmail":"mallory@kestrel.example"},"requestMetadata":{"callerIp":"203.0.113.77"},"status":{}}}],"nextPageToken":"page-2"}"#),
            (200, #"{"entries":[{"timestamp":"2026-11-14T08:00:00Z","logName":"projects/kestrel-prod/logs/cloudaudit.googleapis.com%2Factivity","protoPayload":{"methodName":"google.iam.admin.v1.CreateServiceAccountKey","resourceName":"projects/-/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com","authenticationInfo":{"principalEmail":"mallory@kestrel.example"},"requestMetadata":{"callerIp":"203.0.113.77"},"status":{}}}]}"#),
            // The project pending deletion, searched on its own.
            (200, #"{"entries":[]}"#),
        ]
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"principal":"mallory@kestrel.example","since":"2026-11-13T00:00:00Z","limit":20}"#, on: service, in: cloud)
        XCTAssertFalse(logs.isError, logs.text)
        XCTAssertTrue(logs.text.contains("SetIamPolicy by mallory@kestrel.example from 203.0.113.77"), logs.text)
        XCTAssertTrue(logs.text.contains("CreateServiceAccountKey by mallory@kestrel.example from 203.0.113.77 on projects/-/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com in projects/kestrel-prod"), logs.text)
        let searches = service.requests.filter { $0.url?.host == "logging.googleapis.com" }
        XCTAssertEqual(searches.count, 3, "the second page, or the project pending deletion, was not read")
        let body = try json(searches.first)
        XCTAssertEqual(body["resourceNames"] as? [String], ["organizations/123456789", "projects/kestrel-prod"], "a live project's logs were left out, or a deleted one's put in")
        XCTAssertEqual(try json(searches.last)["resourceNames"] as? [String], ["projects/kestrel-old"], "a project pending deletion was not searched apart")
        XCTAssertTrue(logs.text.contains("Searched, though pending deletion: projects/kestrel-old"), logs.text)
        // Named logs, which Logging finds by index, rather than a search through every log's name.
        XCTAssertEqual(body["filter"] as? String,
            #"(log_id("cloudaudit.googleapis.com/activity") OR log_id("cloudaudit.googleapis.com/data_access") OR log_id("cloudaudit.googleapis.com/system_event") OR log_id("cloudaudit.googleapis.com/policy") OR log_id("cloudaudit.googleapis.com/access_transparency")) AND (protoPayload.authenticationInfo.principalEmail="mallory@kestrel.example" OR protoPayload.authenticationInfo.serviceAccountDelegationInfo.firstPartyPrincipal.principalEmail="mallory@kestrel.example") AND timestamp>="2026-11-13T00:00:00Z""#)
        XCTAssertEqual(body["orderBy"] as? String, "timestamp desc")
        XCTAssertEqual(body["pageSize"] as? Int, 20)
        XCTAssertEqual(try json(searches.dropFirst().first)["pageToken"] as? String, "page-2")

        // A project's account searches only that project's logs.
        let one = FakeService()
        one.answers["/v2/entries:list"] = (200, #"{"entries":[]}"#)
        _ = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: one, in: project)
        XCTAssertEqual(try json(one.requests.first)["resourceNames"] as? [String], ["projects/kestrel-prod"])
        XCTAssertEqual(one.requests.count, 1)

        let bad = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"principal":"x\" OR \"y"}"#, on: service, in: cloud)
        XCTAssertTrue(bad.isError)
    }

    func testAnAuditLogSearchLoggingDidNotFinishIsNotTakenForNoEntries() async throws {
        // Logging hands back empty pages that still lead on while a search runs long; ten of them is not "none".
        let service = FakeService()
        service.sequences["/v2/entries:list"] = Array(repeating: (200, #"{"nextPageToken":"more"}"#), count: 10)
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"since":"2026-11-19T00:00:00Z"}"#, on: service, in: project)
        XCTAssertFalse(logs.isError, logs.text)
        XCTAssertFalse(logs.text.contains("No audit log entries match"), logs.text)
        XCTAssertTrue(logs.text.contains("did not finish"), logs.text)
    }

    func testAuditLogsTryAgainOnceWhenLoggingFailsAndSayWhatGoogleSaid() async throws {
        let failed = (500, #"{"error":{"code":500,"message":"Internal error encountered.","status":"INTERNAL"}}"#)
        let service = FakeService()
        service.sequences["/v2/entries:list"] = [failed, (200, #"{"entries":[{"timestamp":"2026-11-19T09:00:00Z","protoPayload":{"methodName":"SetIamPolicy"}}]}"#)]
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: service, in: project)
        XCTAssertFalse(logs.isError, logs.text)
        XCTAssertTrue(logs.text.contains("SetIamPolicy"), logs.text)

        let down = FakeService()
        down.sequences["/v2/entries:list"] = [failed, failed, failed]
        let failure = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: down, in: project)
        XCTAssertTrue(failure.isError)
        XCTAssertTrue(failure.text.contains("HTTP 500") && failure.text.contains("Internal error encountered."), failure.text)
        XCTAssertEqual(down.requests.count, 3, "once again, then once in small pages, and no more")

        // A quota names itself and the project it counts against, which is what the person can raise.
        let limited = FakeService()
        limited.answers["/v1/projects/kestrel-prod:analyzeIamPolicy"] = (429, #"{"error":{"code":429,"message":"Quota exceeded for quota metric 'AnalyzeIamPolicy requests' and limit 'AnalyzeIamPolicy requests per minute' of service 'cloudasset.googleapis.com' for consumer 'project_number:604757830675'.","status":"RESOURCE_EXHAUSTED"}}"#)
        let access = try await callTool(GoogleCloud.adapter, "iam-policies", #"{"member":"mallory@kestrel.example"}"#, on: limited, in: project)
        XCTAssertTrue(access.isError)
        XCTAssertTrue(access.text.contains("rate limiting") && access.text.contains("for consumer 'project_number:604757830675'"), access.text)
        XCTAssertEqual(limited.requests.count, 1, "a quota was spent again at once")
    }

    func testAuditLogsLoggingKeepsFailingAreReadInSmallPagesAndKeepWhatWasFound() async throws {
        // Google fails larger searches over some entries every time, where small pages still come back.
        let failed = (500, #"{"error":{"code":500,"message":"Internal error encountered.","status":"INTERNAL"}}"#)
        let entry = #"{"timestamp":"2026-11-19T09:00:00Z","protoPayload":{"methodName":"SetIamPolicy"}}"#
        let small = FakeService()
        small.sequences["/v2/entries:list"] = [failed, failed, (200, #"{"entries":[\#(entry)]}"#)]
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"limit":50}"#, on: small, in: project)
        XCTAssertFalse(logs.isError, logs.text)
        XCTAssertTrue(logs.text.contains("SetIamPolicy"), logs.text)
        XCTAssertEqual(try small.requests.map { try json($0)["pageSize"] as? Int }, [50, 50, 5])

        // Failing partway keeps the entries already read and says where Logging stopped, instead of losing them.
        let partway = FakeService()
        partway.sequences["/v2/entries:list"] = [(200, #"{"entries":[\#(entry)],"nextPageToken":"more"}"#), failed, failed, failed]
        let partial = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: partway, in: project)
        XCTAssertFalse(partial.isError, partial.text)
        XCTAssertTrue(partial.text.contains("SetIamPolicy"), partial.text)
        XCTAssertTrue(partial.text.contains("HTTP 500") && partial.text.contains("2026-11-19T09:00:00Z"), partial.text)
        XCTAssertEqual(partway.requests.count, 4)
    }

    func testSecurityCommandCenterFindings() async throws {
        let service = FakeService()
        // Google retired v1; v2 takes the same filter and answers in the same shape.
        service.answers["/v2/organizations/123456789/sources/-/findings"] = (200, #"{"listFindingsResults":[{"finding":{"name":"organizations/123456789/sources/1/findings/f1","category":"PUBLIC_BUCKET_ACL","severity":"HIGH","state":"ACTIVE","eventTime":"2026-11-14T08:00:00Z","resourceName":"//storage.googleapis.com/payroll-exports"},"resource":{"displayName":"payroll-exports","type":"google.cloud.storage.Bucket"}}]}"#)
        let findings = try await callTool(GoogleCloud.adapter, "scc-findings", #"{"severities":["HIGH","CRITICAL"]}"#, on: service, in: cloud)
        XCTAssertFalse(findings.isError, findings.text)
        XCTAssertTrue(findings.text.contains("PUBLIC_BUCKET_ACL"), findings.text)
        XCTAssertTrue(findings.text.contains("payroll-exports"), findings.text)
        XCTAssertEqual(queryItems(service.requests.first)["filter"], #"state="ACTIVE" AND NOT mute="MUTED" AND (severity="HIGH" OR severity="CRITICAL")"#)
        XCTAssertEqual(service.requests.first?.url?.host, "securitycenter.googleapis.com")
    }

    func testCloudsTriggerFindsHighAndCriticalFindingsSinceATime() async throws {
        let service = FakeService()
        service.answers["/v2/organizations/123456789/sources/-/findings"] = (200, #"{"listFindingsResults":[{"finding":{"name":"organizations/123456789/sources/1/findings/f2","severity":"HIGH","eventTime":"2026-11-19T09:14:22.500Z"}},{"finding":{"name":"organizations/123456789/sources/1/findings/f1","severity":"HIGH","eventTime":"2026-11-19T09:11:00Z"}}]}"#)
        service.answers["/v1/organizations/123456789/assets"] = (200, #"{"assets":[]}"#)
        service.answers["/v2/entries:list"] = (200, "{}")
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let findings = try await GoogleCloud.adapter.alerts(since: since, connection: cloud, access: service)
        XCTAssertEqual(findings.map(\.id), ["organizations/123456789/sources/1/findings/f2", "organizations/123456789/sources/1/findings/f1"])
        let query = queryItems(service.requests.first { $0.url?.host == "securitycenter.googleapis.com" })
        XCTAssertEqual(query["filter"], #"state="ACTIVE" AND NOT mute="MUTED" AND (create_time>="2026-11-19T09:00:00Z" OR event_time>="2026-11-19T09:00:00Z") AND severity="CRITICAL""#)
        XCTAssertEqual(query["pageSize"], String(ServiceAlert.most))
        XCTAssertEqual(GoogleCloud.adapter.watchedTool, "security-events")

        // The window a wake names can be read back with the findings operation too.
        _ = try await callTool(GoogleCloud.adapter, "scc-findings", #"{"since":"2026-11-19T09:00:00Z"}"#, on: service, in: cloud)
        XCTAssertEqual(queryItems(service.requests.last)["filter"], #"state="ACTIVE" AND NOT mute="MUTED" AND (severity="CRITICAL" OR severity="HIGH") AND event_time>="2026-11-19T09:00:00Z""#)
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
        // The member's groups are analysed with it; Google takes no group expansion alongside a member.
        XCTAssertNil(asked["analysisQuery.options.expandGroups"])
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

    func testWhatSitsInAProjectPendingDeletionIsMarkedSoItIsNotTakenForLive() async throws {
        let service = FakeService()
        service.answers["/v1/organizations/123456789/assets?assetTypes=cloudresourcemanager.googleapis.com/Project&contentType=RESOURCE&pageSize=1000"] = (200, #"""
        {"assets":[{"name":"//cloudresourcemanager.googleapis.com/projects/1001","resource":{"data":{"projectId":"kestrel-prod","lifecycleState":"ACTIVE"}}},
                   {"name":"//cloudresourcemanager.googleapis.com/projects/1002","resource":{"data":{"projectId":"kestrel-old","lifecycleState":"DELETE_REQUESTED"}}}]}
        """#)
        service.answers["/v1/organizations/123456789:analyzeIamPolicy"] = (200, #"""
        {"mainAnalysis":{"analysisResults":[
          {"attachedResourceFullName":"//cloudresourcemanager.googleapis.com/projects/kestrel-old","iamBinding":{"role":"roles/owner","members":["user:nick@kestrel.example"]}},
          {"attachedResourceFullName":"//cloudresourcemanager.googleapis.com/projects/kestrel-prod","iamBinding":{"role":"roles/owner","members":["user:nick@kestrel.example"]}}]}}
        """#)
        let access = try await callTool(GoogleCloud.adapter, "iam-policies", #"{"member":"nick@kestrel.example"}"#, on: service, in: cloud)
        XCTAssertTrue(access.text.contains("projects/kestrel-old (project pending deletion): roles/owner"), access.text)
        XCTAssertTrue(access.text.contains("projects/kestrel-prod: roles/owner"), access.text)

        service.answers["/v1/organizations/123456789/assets"] = (200, #"""
        {"assets":[{"name":"//iam.googleapis.com/projects/kestrel-old/serviceAccounts/ci@kestrel-old.iam.gserviceaccount.com/keys/k1",
                    "assetType":"iam.googleapis.com/ServiceAccountKey","ancestors":["projects/1002","organizations/123456789"]},
                   {"name":"//iam.googleapis.com/projects/kestrel-prod/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com/keys/k2",
                    "assetType":"iam.googleapis.com/ServiceAccountKey","ancestors":["projects/1001","organizations/123456789"]}]}
        """#)
        let keys = try await callTool(GoogleCloud.adapter, "find-resources", #"{"assetTypes":["iam.googleapis.com/ServiceAccountKey"]}"#, on: service, in: cloud)
        XCTAssertTrue(keys.text.contains("k1 (iam.googleapis.com/ServiceAccountKey), in a project pending deletion"), keys.text)
        XCTAssertTrue(keys.text.contains("k2 (iam.googleapis.com/ServiceAccountKey)\n") || keys.text.hasSuffix("k2 (iam.googleapis.com/ServiceAccountKey)"), keys.text)
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

    /// The audit events that mean an account or the domain may be under attack wake the agents: suspicious sign-ins
    /// and accounts Google disabled, admin privileges and sign-in settings changed, compromised devices, and rules that
    /// fired above low. Each event is asked for by name, or its report read whole, and only the watched events of an
    /// answer count.
    func testWorkspacesTriggerFindsTheAuditEventsThatMeanAnAttack() async throws {
        let service = FakeService()
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        service.answers[reports + "login"] = (200, #"{"items":[{"id":{"time":"2026-11-19T09:20:00.000Z","uniqueQualifier":"101","applicationName":"login"},"actor":{"email":"m.okafor@kestrel.example"},"ipAddress":"203.0.113.77","events":[{"type":"account_warning","name":"suspicious_login","parameters":[{"name":"affected_email_address","value":"m.okafor@kestrel.example"}]}]},{"id":{"time":"2026-11-19T09:19:00.000Z","uniqueQualifier":"102","applicationName":"login"},"actor":{"email":"j.lee@kestrel.example"},"events":[{"type":"login","name":"login_success"}]}]}"#)
        service.answers[reports + "admin"] = (200, #"{"items":[{"id":{"time":"2026-11-19T09:18:00.000Z","uniqueQualifier":"201","applicationName":"admin"},"actor":{"email":"it@kestrel.example"},"events":[{"type":"USER_SETTINGS","name":"GRANT_ADMIN_PRIVILEGE","parameters":[{"name":"USER_EMAIL","value":"intern@kestrel.example"}]}]},{"id":{"time":"2026-11-19T09:17:00.000Z","uniqueQualifier":"202","applicationName":"admin"},"events":[{"type":"USER_SETTINGS","name":"CHANGE_LAST_NAME"}]}]}"#)
        service.answers[reports + "mobile"] = (200, #"{"items":[{"id":{"time":"2026-11-19T09:16:00.000Z","uniqueQualifier":"301","applicationName":"mobile"},"events":[{"type":"suspicious_activity","name":"DEVICE_COMPROMISED_EVENT","parameters":[{"name":"DEVICE_COMPROMISED_STATE","value":"COMPROMISED"}]}]},{"id":{"time":"2026-11-19T09:15:00.000Z","uniqueQualifier":"302","applicationName":"mobile"},"events":[{"type":"suspicious_activity","name":"DEVICE_COMPROMISED_EVENT","parameters":[{"name":"DEVICE_COMPROMISED_STATE","value":"NOT_COMPROMISED"}]}]}]}"#)
        for report in ["user_accounts", "takeout", "vault", "token", "drive"] { service.answers[reports + report] = (200, "{}") }
        service.answers[reports + "rules"] = (200, #"{"items":[{"id":{"time":"2026-11-19T09:14:00.000Z","uniqueQualifier":"401","applicationName":"rules"},"events":[{"type":"rule_trigger_type","name":"rule_trigger","parameters":[{"name":"rule_name","value":"Mass download"},{"name":"severity","value":"HIGH"}]}]},{"id":{"time":"2026-11-19T09:13:00.000Z","uniqueQualifier":"402","applicationName":"rules"},"events":[{"type":"rule_trigger_type","name":"rule_trigger","parameters":[{"name":"rule_name","value":"External share"},{"name":"severity","value":"LOW"}]}]}]}"#)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let found = try await GoogleWorkspace.adapter.alerts(since: since, connection: workspace, access: service)
        // Each ID carries the record's time and qualifier and the event's place in it, so no two events are taken for one.
        XCTAssertEqual(found.map(\.id), ["login/2026-11-19T09:20:00.000Z/101/suspicious_login/0", "admin/2026-11-19T09:18:00.000Z/201/GRANT_ADMIN_PRIVILEGE/0",
                                         "mobile/2026-11-19T09:16:00.000Z/301/DEVICE_COMPROMISED_EVENT/0", "rules/2026-11-19T09:14:00.000Z/401/rule_trigger/0"])
        XCTAssertEqual(found.first?.time, ISO8601DateFormatter().date(from: "2026-11-19T09:20:00Z"))
        let asked = Set(service.requests.compactMap { request in
            queryItems(request)["eventName"].map { (request.url!.lastPathComponent, $0) }.map { "\($0.0)/\($0.1)" }
        })
        for event in ["login/suspicious_login", "login/account_disabled_password_leak", "login/gov_attack_warning", "login/account_disabled_hijacked",
                      "mobile/DEVICE_COMPROMISED_EVENT", "rules/rule_trigger", "token/authorize"] {
            XCTAssertTrue(asked.contains(event), event)
        }
        // The admin, account, Takeout and Vault reports are quiet enough to read whole, once each, not event by event.
        for report in ["admin", "user_accounts", "takeout", "vault"] {
            let reads = service.requests.filter { $0.url?.lastPathComponent == report }
            XCTAssertEqual(reads.count, 1, report)
            XCTAssertNil(queryItems(reads.first)["eventName"], report)
        }
        XCTAssertTrue(service.requests.allSatisfy { queryItems($0)["startTime"] == "2026-11-19T09:00:00Z" })
        XCTAssertEqual(GoogleWorkspace.adapter.watchedTool, "security-events")
    }

    /// What a wake names is read back with security-events, for its window: each event with who it concerns.
    func testWorkspaceSecurityEventsReadTheWatchedEventsForAWindow() async throws {
        let service = FakeService()
        for report in ["admin", "mobile", "rules", "user_accounts"] { service.answers["/admin/reports/v1/activity/users/all/applications/" + report] = (200, "{}") }
        service.answers["/admin/reports/v1/activity/users/all/applications/login"] = (200, #"{"items":[{"id":{"time":"2026-11-19T09:20:00.000Z","uniqueQualifier":"101","applicationName":"login"},"actor":{"email":"m.okafor@kestrel.example"},"ipAddress":"203.0.113.77","events":[{"type":"account_warning","name":"suspicious_login","parameters":[{"name":"affected_email_address","value":"m.okafor@kestrel.example"}]}]}]}"#)
        let events = try await callTool(GoogleWorkspace.adapter, "security-events",
            #"{"since":"2026-11-19T09:00:00Z","until":"2026-11-19T10:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(events.isError, events.text)
        XCTAssertTrue(events.text.contains("suspicious_login"), events.text)
        XCTAssertTrue(events.text.contains("m.okafor@kestrel.example"), events.text)
        XCTAssertTrue(events.text.contains("203.0.113.77"), events.text)
        XCTAssertEqual((events.structured?["events"] as? [Any])?.count, 1)
        XCTAssertTrue(service.requests.allSatisfy { queryItems($0)["endTime"] == "2026-11-19T10:00:00Z" })
        let none = try await callTool(GoogleWorkspace.adapter, "security-events", #"{"since":"yesterday"}"#, on: service, in: workspace)
        XCTAssertTrue(none.isError)
    }

    /// The Reports API turns part of a burst away, so a connection sends it only so many requests at once; a quota
    /// that still refuses, which Google says with a 403, is told as rate limiting rather than missing permission.
    func testWorkspaceTakesItsRequestsInTurnAndToldAQuotaFromAMissingPermission() async throws {
        XCTAssertEqual(GoogleWorkspace.adapter.simultaneousRequests, 8)
        let service = FakeService()
        service.answers["/admin/reports/v1/activity/users/all/applications/login"] = (403, #"{"error":{"code":403,"message":"Request rate higher than configured.","errors":[{"message":"Request rate higher than configured.","domain":"usageLimits","reason":"quotaExceeded"}]}}"#)
        let limited = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"login"}"#, on: service, in: workspace)
        XCTAssertTrue(limited.isError)
        XCTAssertTrue(limited.text.contains("rate limiting") && limited.text.contains("Request rate higher than configured."), limited.text)
        XCTAssertFalse(limited.text.contains("permissions"), limited.text)
    }

    // MARK: Containment

    private let containment = try! GoogleWorkspace.containment.makeConnection(name: "Workspace Containment",
                                                                             values: ["clientID": "1234-abc.apps.googleusercontent.com"])

    /// The containment tool signs in on its own, through the same client, asking only for the Directory scopes
    /// suspending, ending sessions and acting on phones take; the detection tool keeps its read-only scopes.
    func testContainmentSignsInSeparatelyWithOnlyTheScopesItsActionsTake() throws {
        XCTAssertNotNil(PionAdapters.all["google-workspace-containment"])
        XCTAssertEqual(containment.endpoint.absoluteString, "https://admin.googleapis.com")
        guard case .connection(let configuration) = GoogleWorkspace.containment.configuration, let oauth = configuration.oauth else {
            return XCTFail("no sign-in")
        }
        XCTAssertEqual(oauth.scopes, ["https://www.googleapis.com/auth/admin.directory.user",
                                      "https://www.googleapis.com/auth/admin.directory.user.security",
                                      "https://www.googleapis.com/auth/admin.directory.device.mobile.action"])
        // Each scope is one Data Access takes, named in the Setup Steps.
        for scope in oauth.scopes { XCTAssertTrue(GoogleWorkspace.containmentSetup.joined().contains("`\(scope)`"), scope) }
        XCTAssertEqual(configuration.oauthClientField, "clientID")
        XCTAssertNotEqual(GoogleWorkspace.containment.id, GoogleWorkspace.preset.id)
        XCTAssertEqual(GoogleWorkspace.preset.name, "Google Workspace Detection")
        XCTAssertEqual(GoogleWorkspace.containment.name, "Google Workspace Containment")
    }

    func testContainmentReadsAUsersStateTheirAppsAndAppPasswords() async throws {
        let service = FakeService()
        let user = "/admin/directory/v1/users/m.okafor@kestrel.example"
        service.answers[user] = (200, #"{"primaryEmail":"m.okafor@kestrel.example","name":{"fullName":"Mara Okafor"},"suspended":false,"isAdmin":false,"isDelegatedAdmin":false,"isEnrolledIn2Sv":true,"lastLoginTime":"2026-11-20T08:00:00.000Z","orgUnitPath":"/Finance"}"#)
        service.answers[user + "/tokens"] = (200, #"{"items":[{"clientId":"999-evil.apps.googleusercontent.com","displayText":"Docs Helper","scopes":["https://mail.google.com/"],"anonymous":false,"nativeApp":false}]}"#)
        service.answers[user + "/asps"] = (200, #"{"items":[{"codeId":42,"name":"Old mail client","creationTime":"1763625600000","lastTimeUsed":"1763712000000"}]}"#)
        let state = try await callTool(GoogleWorkspace.containmentAdapter, "user", #"{"user":"M.Okafor@kestrel.example"}"#, on: service, in: containment)
        XCTAssertFalse(state.isError, state.text)
        XCTAssertTrue(state.text.contains("active"), state.text)
        XCTAssertTrue(state.text.contains("2-step verification on"), state.text)
        XCTAssertTrue(state.text.contains("/Finance"), state.text)
        XCTAssertEqual(service.requests.last?.httpMethod, "GET")
        let tokens = try await callTool(GoogleWorkspace.containmentAdapter, "tokens", #"{"user":"m.okafor@kestrel.example"}"#, on: service, in: containment)
        XCTAssertTrue(tokens.text.contains("Docs Helper (999-evil.apps.googleusercontent.com)"), tokens.text)
        XCTAssertTrue(tokens.text.contains("https://mail.google.com/"), tokens.text)
        let passwords = try await callTool(GoogleWorkspace.containmentAdapter, "app-passwords", #"{"user":"m.okafor@kestrel.example"}"#, on: service, in: containment)
        XCTAssertTrue(passwords.text.contains("42: Old mail client"), passwords.text)
        let bad = try await callTool(GoogleWorkspace.containmentAdapter, "user", #"{"user":"../../domains"}"#, on: service, in: containment)
        XCTAssertTrue(bad.isError)
    }

    /// Every action is marked destructive, so Pion's broker holds a bot's call for the champion; once approved, each
    /// sends exactly its one request.
    func testContainmentActionsAreDestructiveAndEachSendsItsOneRequest() async throws {
        let listed = try JSONSerialization.jsonObject(with: try await GoogleWorkspace.containmentAdapter.tools(for: containment)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        for name in ["sign-out", "revoke-token", "delete-app-password", "invalidate-backup-codes", "suspend", "unsuspend"] {
            let hints = try XCTUnwrap(tools.first { $0["name"] as? String == name }?["annotations"] as? [String: Any], name)
            XCTAssertEqual(hints["readOnlyHint"] as? Bool, false, name)
            XCTAssertEqual(hints["destructiveHint"] as? Bool, true, name)
        }
        for name in ["user", "tokens", "app-passwords"] {
            let hints = try XCTUnwrap(tools.first { $0["name"] as? String == name }?["annotations"] as? [String: Any], name)
            XCTAssertEqual(hints["readOnlyHint"] as? Bool, true, name)
            XCTAssertNil(hints["destructiveHint"], name)
        }
        let service = FakeService()
        let user = "/admin/directory/v1/users/m.okafor@kestrel.example"
        for path in [user, user + "/signOut", user + "/tokens/999-evil.apps.googleusercontent.com", user + "/asps/42", user + "/verificationCodes/invalidate"] {
            service.answers[path] = (200, "{}")
        }
        let runs: [(String, String, String, String)] = [
            ("sign-out", #"{"user":"m.okafor@kestrel.example"}"#, "POST", user + "/signOut"),
            ("revoke-token", #"{"user":"m.okafor@kestrel.example","clientId":"999-evil.apps.googleusercontent.com"}"#, "DELETE", user + "/tokens/999-evil.apps.googleusercontent.com"),
            ("delete-app-password", #"{"user":"m.okafor@kestrel.example","codeId":42}"#, "DELETE", user + "/asps/42"),
            ("suspend", #"{"user":"m.okafor@kestrel.example"}"#, "PATCH", user),
            ("unsuspend", #"{"user":"m.okafor@kestrel.example"}"#, "PATCH", user),
            ("invalidate-backup-codes", #"{"user":"m.okafor@kestrel.example"}"#, "POST", user + "/verificationCodes/invalidate"),
        ]
        for (name, arguments, method, path) in runs {
            let result = try await callTool(GoogleWorkspace.containmentAdapter, name, arguments, on: service, in: containment)
            XCTAssertFalse(result.isError, "\(name): \(result.text)")
            XCTAssertEqual(service.requests.last?.httpMethod, method, name)
            XCTAssertEqual(service.requests.last?.url?.path, path, name)
        }
        XCTAssertEqual(service.requests.count, runs.count)
        XCTAssertEqual(try json(service.requests[3])["suspended"] as? Bool, true)
        XCTAssertEqual(try json(service.requests[4])["suspended"] as? Bool, false)
    }

    /// A refusal names what the signed-in admin's role lacks, as Google answers 403 for anything outside it.
    func testContainmentExplainsARefusalByTheAdminsRole() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/users/ceo@kestrel.example/tokens"] = (403, #"{"error":{"code":403,"message":"Not Authorized to access this resource/api"}}"#)
        let refused = try await callTool(GoogleWorkspace.containmentAdapter, "tokens", #"{"user":"ceo@kestrel.example"}"#, on: service, in: containment)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("User Security Management"), refused.text)
        XCTAssertTrue(refused.text.contains("admin"), refused.text)
    }

    // MARK: Who holds what

    /// Every admin role with what it allows and who holds it, super admins first, read with read-only scopes.
    func testAdminRolesShowEachRoleWhatItAllowsAndWhoHoldsIt() async throws {
        let service = FakeService()
        let directory = "/admin/directory/v1"
        service.answers[directory + "/users"] = (200, #"{"users":[{"id":"u-1","primaryEmail":"ceo@kestrel.example","isAdmin":true,"isEnrolledIn2Sv":false},{"id":"u-2","primaryEmail":"it@kestrel.example","isAdmin":true,"isEnrolledIn2Sv":true}]}"#)
        service.answers[directory + "/customer/my_customer/roles"] = (200, #"{"items":[{"roleId":"r-super","roleName":"_SEED_ADMIN_ROLE","isSystemRole":true,"isSuperAdminRole":true,"rolePrivileges":[{"privilegeName":"SUPER_ADMIN","serviceId":"x"}]},{"roleId":"r-pion","roleName":"Pion Containment","rolePrivileges":[{"privilegeName":"USERS_RETRIEVE","serviceId":"x"},{"privilegeName":"USERS_SUSPEND","serviceId":"x"}]},{"roleId":"r-unused","roleName":"Groups Reader","rolePrivileges":[]}]}"#)
        service.answers[directory + "/customer/my_customer/roleassignments"] = (200, #"{"items":[{"roleAssignmentId":"a1","roleId":"r-super","assignedTo":"u-1","assigneeType":"USER","scopeType":"CUSTOMER"},{"roleAssignmentId":"a2","roleId":"r-super","assignedTo":"u-2","assigneeType":"USER","scopeType":"CUSTOMER"},{"roleAssignmentId":"a3","roleId":"r-pion","assignedTo":"u-3","assigneeType":"USER","scopeType":"ORG_UNIT","orgUnitId":"03ph8a2z1"},{"roleAssignmentId":"a4","roleId":"r-pion","assignedTo":"g-1","assigneeType":"GROUP","scopeType":"CUSTOMER","condition":"api.getAttribute('cloudidentity.googleapis.com/groups.labels', []).hasAny(['groups.security'])"}]}"#)
        service.answers[directory + "/users/u-3"] = (200, #"{"id":"u-3","primaryEmail":"pion@kestrel.example","isDelegatedAdmin":true}"#)
        service.answers[directory + "/groups/g-1"] = (200, #"{"id":"g-1","email":"helpdesk@kestrel.example","name":"Helpdesk"}"#)
        service.answers[directory + "/groups/g-1/members"] = (200, #"{"members":[{"email":"sam@kestrel.example","type":"USER"},{"email":"temp@agency.example","type":"USER"}]}"#)
        let roles = try await callTool(GoogleWorkspace.adapter, "admin-roles", "{}", on: service, in: workspace)
        XCTAssertFalse(roles.isError, roles.text)
        let lines = roles.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("Super admins (2):") && lines[0].contains("ceo@kestrel.example (2-step verification off)"), roles.text)
        XCTAssertTrue(lines.contains { $0.contains("Pion Containment") && $0.contains("USERS_SUSPEND")
            && $0.contains("pion@kestrel.example (only in organisational unit 03ph8a2z1)")
            && $0.contains("group helpdesk@kestrel.example (members: sam@kestrel.example, temp@agency.example (outside the domain))")
            && $0.contains("only when api.getAttribute") }, roles.text)
        XCTAssertFalse(roles.text.contains("g-1"), "the group is named, not given by its ID")
        XCTAssertFalse(roles.text.contains("Groups Reader"), "a role nobody holds says nothing")
        XCTAssertEqual(queryItems(service.requests.first { $0.url?.path == directory + "/users" })["query"], "isAdmin=true")
    }

    /// A refusal says what the Detection admin's role lacks, as Google answers 403 for anything outside it.
    func testAdminRolesExplainARefusalByTheAdminsRole() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/users"] = (403, #"{"error":{"code":403,"message":"Not Authorized to access this resource/api"}}"#)
        let refused = try await callTool(GoogleWorkspace.adapter, "admin-roles", "{}", on: service, in: workspace)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("Users › Read"), refused.text)
    }

    // MARK: Breach scope

    /// What left the domain and how: exports through Takeout and Vault, mail, chat and meetings are audited too.
    func testActivityCoversExportsMailChatAndMeetings() async throws {
        let service = FakeService()
        for application in ["takeout", "vault", "gmail", "chat", "meet"] {
            service.answers["/admin/reports/v1/activity/users/all/applications/" + application] = (200, "{}")
            let read = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"\#(application)"}"#, on: service, in: workspace)
            XCTAssertFalse(read.isError, "\(application): \(read.text)")
        }
    }

    /// Everyone in the domain, or those a search picks, such as who has 2-step verification off, with when each last
    /// signed in.
    func testUsersAreListedBySearchWithWhatMattersForABreach() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/users"] = (200, #"{"users":[{"id":"u-1","primaryEmail":"m.okafor@kestrel.example","isAdmin":false,"isEnrolledIn2Sv":false,"suspended":false,"lastLoginTime":"2026-11-20T08:00:00.000Z","creationTime":"2024-01-02T00:00:00.000Z","orgUnitPath":"/Finance"}]}"#)
        let users = try await callTool(GoogleWorkspace.adapter, "users", #"{"query":"isEnrolledIn2Sv=false"}"#, on: service, in: workspace)
        XCTAssertFalse(users.isError, users.text)
        XCTAssertTrue(users.text.contains("m.okafor@kestrel.example") && users.text.contains("2-step verification off")
                      && users.text.contains("last signed in 2026-11-20T08:00:00.000Z") && users.text.contains("/Finance"), users.text)
        let sent = queryItems(service.requests.last)
        XCTAssertEqual(sent["query"], "isEnrolledIn2Sv=false")
        XCTAssertEqual(sent["customer"], "my_customer")
    }

    /// What a user reaches through groups, and the phones and tablets that hold their mail and files.
    func testAUsersGroupsAndDevices() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/groups"] = (200, #"{"groups":[{"id":"g-1","email":"finance@kestrel.example","name":"Finance","directMembersCount":"12"}]}"#)
        service.answers["/admin/directory/v1/customer/my_customer/devices/mobile"] = (200, #"{"mobiledevices":[{"resourceId":"d-1","email":["m.okafor@kestrel.example"],"model":"Pixel 8","os":"Android 15","type":"ANDROID","status":"APPROVED","lastSync":"2026-11-20T09:00:00.000Z","deviceCompromisedStatus":"Compromised"},{"resourceId":"d-2","email":["m.okafor.sabia@kestrel.example"],"model":"iPhone"}]}"#)
        let groups = try await callTool(GoogleWorkspace.adapter, "user-groups", #"{"user":"m.okafor@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertTrue(groups.text.contains("Finance <finance@kestrel.example>"), groups.text)
        XCTAssertEqual(queryItems(service.requests.last)["userKey"], "m.okafor@kestrel.example")
        let devices = try await callTool(GoogleWorkspace.adapter, "user-devices", #"{"user":"m.okafor@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertFalse(devices.isError, devices.text)
        XCTAssertTrue(devices.text.contains("Pixel 8") && devices.text.contains("Compromised"), devices.text)
        XCTAssertFalse(devices.text.contains("iPhone"), "another user whose address starts the same is not theirs")
        XCTAssertEqual(queryItems(service.requests.last)["query"], "email:m.okafor@kestrel.example")
    }

    /// Every phone and tablet in the domain, read page after page, counted and listed longest unsynced first, so one
    /// sold a year ago but still approved stands out; and narrowed by owner, status or how long since it synced.
    func testAllDevicesListsTheDomainsPhonesLongestUnsyncedFirst() async throws {
        let path = "/admin/directory/v1/customer/my_customer/devices/mobile"
        let ago = { (days: Double) in ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 86400 - 3600)) }
        let first = #"{"mobiledevices":[{"resourceId":"d-old","email":["a.sold@kestrel.example"],"model":"iPhone 12","os":"iOS 16.1","type":"IOS_SYNC","status":"APPROVED","firstSync":"2023-02-01T10:00:00.000Z","lastSync":"\#(ago(400))"},{"resourceId":"d-new","email":["b@kestrel.example"],"model":"Pixel 8","os":"Android 15","type":"ANDROID","status":"APPROVED","lastSync":"\#(ago(1))","deviceCompromisedStatus":"Compromise detected","managedAccountIsOnOwnerProfile":false}],"nextPageToken":"p2"}"#
        let second = #"{"mobiledevices":[{"resourceId":"d-never","email":["c@kestrel.example"],"model":"Galaxy S23","status":"PENDING","lastSync":"1970-01-01T00:00:00.000Z"},{"resourceId":"d-blocked","email":["m.okafor@kestrel.example"],"model":"iPad","type":"IOS_SYNC","status":"BLOCKED","lastSync":"\#(ago(200))","deviceCompromisedStatus":"No compromise detected"},{"resourceId":"d-other","email":["m.okafor.sabia@kestrel.example"],"model":"iPhone 15","status":"APPROVED","lastSync":"\#(ago(10))"}]}"#
        let service = FakeService()
        service.sequences[path] = [(200, first), (200, second)]
        let all = try await callTool(GoogleWorkspace.adapter, "all-devices", "{}", on: service, in: workspace)
        XCTAssertFalse(all.isError, all.text)
        XCTAssertEqual(service.requests.count, 2, "the second page was not read")
        let asked = queryItems(service.requests.first), next = queryItems(service.requests.last)
        XCTAssertEqual(asked["maxResults"], "100")
        XCTAssertEqual(asked["projection"], "FULL")
        XCTAssertTrue(asked["fields"]?.contains("lastSync") == true && asked["fields"]?.contains("nextPageToken") == true, asked["fields"] ?? "")
        XCTAssertNil(asked["query"], "the whole domain is not searched")
        XCTAssertEqual(next["pageToken"], "p2")
        let lines = all.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "5 phones and tablets in the domain.")
        XCTAssertEqual(lines.dropFirst().first, "1 approved but not synced for 90 days or more, 1 blocked, 1 pending, 1 found compromised by Google.")
        let order = lines.compactMap { line in ["d-never", "d-old", "d-blocked", "d-other", "d-new"].first { line.hasSuffix("resource ID " + $0) } }
        XCTAssertEqual(order, ["d-old", "d-other", "d-new", "d-never", "d-blocked"], all.text)
        let old = try XCTUnwrap(lines.first { $0.hasPrefix("a.sold@kestrel.example: ") })
        XCTAssertTrue(old.contains("iPhone 12 (iOS 16.1, IOS_SYNC, APPROVED)") && old.contains("(400 days ago)")
                      && old.contains("first synced 2023-02-01T10:00:00.000Z"), old)
        XCTAssertTrue(lines.contains { $0.hasPrefix("c@kestrel.example: ") && $0.contains("never synced") && !$0.contains("first synced") }, all.text)
        let new = try XCTUnwrap(lines.first { $0.hasPrefix("b@kestrel.example: ") })
        XCTAssertTrue(new.contains("Compromise detected") && new.contains("account in a work profile"), new)
        XCTAssertFalse(lines.contains { $0.hasPrefix("m.okafor@") && $0.contains("ompromise") }, "a device Google found clean is not flagged")
        XCTAssertEqual(all.structured?["stale"] as? Int, 1)
        XCTAssertEqual(all.structured?["compromised"] as? Int, 1)
        XCTAssertEqual(all.structured?["incomplete"] as? Bool, false)
        XCTAssertEqual((all.structured?["mobiledevices"] as? [[String: Any]])?.count, 5)

        // One owner's, by the Directory's search, keeping only theirs and not an address that starts the same.
        service.answers[path] = (200, second)
        let owned = try await callTool(GoogleWorkspace.adapter, "all-devices", #"{"owner":"M.Okafor@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertEqual(queryItems(service.requests.last)["query"], "email:m.okafor@kestrel.example")
        XCTAssertTrue(owned.text.hasPrefix("1 phone or tablet syncing m.okafor@kestrel.example.") && owned.text.contains("d-blocked")
                      && !owned.text.contains("d-other"), owned.text)

        // By status and by days since the last sync, which also sets what counts as stale.
        service.answers[path] = nil
        service.sequences[path] = [(200, first), (200, second)]
        let blocked = try await callTool(GoogleWorkspace.adapter, "all-devices", #"{"status":"blocked"}"#, on: service, in: workspace)
        XCTAssertTrue(blocked.text.hasPrefix("1 of the 5 phones and tablets in the domain match status BLOCKED.") && blocked.text.contains("d-blocked")
                      && !blocked.text.contains("d-old"), blocked.text)
        service.sequences[path] = [(200, first), (200, second)]
        let stale = try await callTool(GoogleWorkspace.adapter, "all-devices", #"{"inactiveDays":300,"limit":1}"#, on: service, in: workspace)
        let staleLines = stale.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(staleLines.first, "2 of the 5 phones and tablets in the domain match not synced for 300 days or more.")
        XCTAssertTrue(staleLines.contains("1 approved but not synced for 300 days or more, 0 blocked, 1 pending, 0 found compromised by Google."), stale.text)
        XCTAssertTrue(stale.text.contains("d-old") && !stale.text.contains("d-never") && !stale.text.contains("d-blocked"), stale.text)
        XCTAssertTrue(staleLines.last?.hasPrefix("1 more matched than are listed") == true, stale.text)
        XCTAssertEqual(stale.structured?["matched"] as? Int, 2)

        let wrong = try await callTool(GoogleWorkspace.adapter, "all-devices", #"{"status":"LOST"}"#, on: service, in: workspace)
        XCTAssertTrue(wrong.isError && wrong.text.contains("APPROVED"), wrong.text)
    }

    /// The organisation's current settings, read page after page: those an audit asks about first, said plainly
    /// and in Google's order where several apply, then the rest as Google gives them, and which it asks about were not
    /// listed at all.
    func testPolicySettingsSayTheSettingsAnAuditChecksFirst() async throws {
        let path = "/v1/policies"
        let first = #"{"policies":[{"name":"policies/a","customer":"customers/C01","type":"ADMIN","policyQuery":{"orgUnit":"orgUnits/root1","sortOrder":1},"setting":{"type":"settings/security.two_step_verification_enforcement","value":{"enforcedFrom":"2025-01-01T00:00:00Z"}}},{"name":"policies/b","type":"ADMIN","policyQuery":{"orgUnit":"orgUnits/eng","group":"groups/contractors","sortOrder":2},"setting":{"type":"settings/security.two_step_verification_enforcement","value":{"enforcedFrom":"2099-01-01T00:00:00Z"}}},{"name":"policies/c","type":"ADMIN","policyQuery":{"orgUnit":"orgUnits/root1","sortOrder":1},"setting":{"type":"settings/drive_and_docs.external_sharing","value":{"externalSharingMode":"ALLOWED","allowPublishingFiles":true,"warnForExternalSharing":false}}}],"nextPageToken":"p2"}"#
        let second = #"{"policies":[{"name":"policies/d","type":"SYSTEM","policyQuery":{"orgUnit":"orgUnits/root1"},"setting":{"type":"settings/security.less_secure_apps","value":{"allowLessSecureApps":true}}},{"name":"policies/e","type":"ADMIN","policyQuery":{"orgUnit":"orgUnits/root1"},"setting":{"type":"settings/gmail.mail_delegation","value":{"enableMailDelegation":false}}},{"name":"policies/f","type":"ADMIN","policyQuery":{"orgUnit":"orgUnits/root1"},"setting":{"type":"settings/drive_and_docs.general_access_default","value":{"default_file_access":"PRIMARY_AUDIENCE_WITH_LINK"}}}]}"#
        let service = FakeService()
        service.sequences[path] = [(200, first), (200, second)]
        let all = try await callTool(GoogleWorkspace.adapter, "policy-settings", "{}", on: service, in: workspace)
        XCTAssertFalse(all.isError, all.text)
        XCTAssertEqual(service.requests.count, 2, "the second page was not read")
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "cloudidentity.googleapis.com" })
        XCTAssertEqual(queryItems(service.requests.first)["pageSize"], "100")
        XCTAssertNil(queryItems(service.requests.first)["filter"])
        XCTAssertEqual(queryItems(service.requests.last)["pageToken"], "p2")
        let lines = all.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.first?.hasPrefix("6 settings of 5 kinds.") == true, all.text)
        XCTAssertEqual(lines.dropFirst().first, "Settings an audit checks first:")
        let enforcement = "2-step verification enforcement (security.two_step_verification_enforcement), "
        XCTAssertEqual(Array(lines[2...6]), [
            enforcement + "group groups/contractors: not enforced yet: enforced from 2099-01-01T00:00:00Z",
            enforcement + "org unit orgUnits/root1: enforced since 2025-01-01T00:00:00Z",
            "Less secure apps (security.less_secure_apps), org unit orgUnits/root1 (Google's default): allowed: apps may sign in with a password alone, without 2-step verification",
            "Drive sharing outside the organisation (drive_and_docs.external_sharing), org unit orgUnits/root1: files may be shared outside the organisation; "
                + "files may be published on the web; no warning before sharing outside",
            "Drive default link sharing (drive_and_docs.general_access_default), org unit orgUnits/root1: new files open to the organisation to anyone with the link",
        ], all.text)
        XCTAssertEqual(lines[7], "Other settings:")
        XCTAssertEqual(lines[8], "gmail.mail_delegation, org unit orgUnits/root1: {enableMailDelegation=false}")
        XCTAssertTrue(lines.last?.hasPrefix("Not listed, so at Google's default or not in this edition: 2-step verification enrollment,") == true
                      && lines.last?.contains("Web session length") == true && lines.last?.contains("Less secure apps") == false, all.text)
        XCTAssertEqual(all.structured?["matched"] as? Int, 6)
        XCTAssertEqual(all.structured?["incomplete"] as? Bool, false)
        let settings = try XCTUnwrap(all.structured?["settings"] as? [[String: Any]])
        XCTAssertEqual(settings.first?["group"] as? String, "groups/contractors")
        XCTAssertEqual((settings.first?["value"] as? [String: Any])?["enforcedFrom"] as? String, "2099-01-01T00:00:00Z")

        // A type is asked of Google by its start, and an organisational unit kept here, by its ID however it is given.
        service.sequences[path] = [(200, first), (200, second)]
        let twoStep = try await callTool(GoogleWorkspace.adapter, "policy-settings", #"{"settingType":"settings/security.two_step","orgUnit":"orgUnits/root1"}"#,
                                         on: service, in: workspace)
        XCTAssertEqual(queryItems(service.requests.last)["filter"], #"setting.type.matches('^settings/security\\.two_step')"#)
        let twoStepLines = twoStep.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(twoStepLines.first?.hasPrefix("1 setting of 1 kind for type security.two_step and org unit root1.") == true, twoStep.text)
        XCTAssertFalse(twoStep.text.contains("drive_and_docs"), "a setting Google let through anyway is not listed")
        XCTAssertFalse(twoStep.text.contains("groups/contractors"), twoStep.text)
        XCTAssertTrue(twoStepLines.last?.contains("2-step verification methods") == true && twoStepLines.last?.contains("Web session length") == false, twoStep.text)

        service.answers[path] = (200, #"{"policies":[{"name":"policies/a","type":"ADMIN","policyQuery":{"orgUnit":"orgUnits/root1"},"setting":{"type":"settings/drive_and_docs.external_sharing","value":{}}}],"nextPageToken":"more"}"#)
        let cut = try await callTool(GoogleWorkspace.adapter, "policy-settings", #"{"limit":1}"#, on: service, in: workspace)
        XCTAssertTrue(cut.text.contains("incomplete") && cut.text.contains("more matched than are listed"), cut.text)
        XCTAssertEqual(cut.structured?["incomplete"] as? Bool, true)

        service.answers[path] = (200, "{}")
        let none = try await callTool(GoogleWorkspace.adapter, "policy-settings", "{}", on: service, in: workspace)
        XCTAssertFalse(none.isError, none.text)
        XCTAssertTrue(none.text.hasPrefix("Google's Policy API gave no settings.") && none.text.contains("Admin console"), none.text)

        let wrong = try await callTool(GoogleWorkspace.adapter, "policy-settings", #"{"settingType":"x') || true || ('"}"#, on: service, in: workspace)
        XCTAssertTrue(wrong.isError && wrong.text.contains("letters, digits"), wrong.text)
    }

    /// Google lets only a super admin read the settings, so a refusal says that rather than a privilege to add; a plan
    /// without the Policy API says it may not be in the edition.
    func testPolicySettingsSayWhyTheyCouldNotBeRead() async throws {
        let service = FakeService()
        service.answers["/v1/policies"] = (403, Self.notAuthorized)
        let refused = try await callTool(GoogleWorkspace.adapter, "policy-settings", "{}", on: service, in: workspace)
        XCTAssertTrue(refused.isError && refused.text.contains("only a super admin") && refused.text.contains("Admin console pages"), refused.text)
        service.answers["/v1/policies"] = (403, Self.scopeMissing)
        let scope = try await callTool(GoogleWorkspace.adapter, "policy-settings", "{}", on: service, in: workspace)
        XCTAssertTrue(scope.isError && scope.text.contains("cloud-identity.policies.readonly"), scope.text)
        service.answers["/v1/policies"] = (400, #"{"error":{"code":400,"message":"Request contains an invalid argument.","status":"FAILED_PRECONDITION"}}"#)
        let unavailable = try await callTool(GoogleWorkspace.adapter, "policy-settings", "{}", on: service, in: workspace)
        XCTAssertTrue(unavailable.isError && unavailable.text.contains("edition") && unavailable.text.contains("invalid argument"), unavailable.text)
    }

    // MARK: Investigation

    /// An account's 2-step verification enforcement, and recovery details an attacker would change, flagged when they
    /// lead outside the domain.
    func testUsersShowEnforcementRecoveryAliasesAndGuests() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/users"] = (200, #"{"users":[{"primaryEmail":"ivana@kestrel.example","isEnrolledIn2Sv":true,"isEnforcedIn2Sv":false,"recoveryEmail":"ivana.p@gmail.com","recoveryPhone":"+447700900123","aliases":["accounts@kestrel.example"],"isGuestUser":false,"creationTime":"2024-01-02T00:00:00.000Z"},{"primaryEmail":"nick@kestrel.example","isEnrolledIn2Sv":true,"isEnforcedIn2Sv":true,"recoveryEmail":"nick@kestrel.example","isGuestUser":true,"archived":true}]}"#)
        let users = try await callTool(GoogleWorkspace.adapter, "users", "{}", on: service, in: workspace)
        let lines = users.text.split(separator: "\n").map(String.init)
        let ivana = try XCTUnwrap(lines.first { $0.hasPrefix("ivana@") })
        XCTAssertTrue(ivana.contains("2-step verification not enforced") && ivana.contains("recovery email outside the domain: ivana.p@gmail.com")
                      && ivana.contains("recovery phone set") && ivana.contains("aliases accounts@kestrel.example"), ivana)
        let nick = try XCTUnwrap(lines.first { $0.hasPrefix("nick@") })
        XCTAssertTrue(nick.contains("guest") && nick.contains("archived") && !nick.contains("outside the domain"), nick)
    }

    /// Who is in a group, so who reads what it receives, with members outside the domain flagged.
    func testGroupMembersFlagThoseOutsideTheDomain() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/groups/accounting@kestrel.example/members"] = (200, #"{"members":[{"email":"ivana@kestrel.example","role":"MEMBER","type":"USER","status":"ACTIVE"},{"email":"bookkeeper@agency.example","role":"MEMBER","type":"USER"},{"email":"finance@kestrel.example","role":"OWNER","type":"GROUP"},{"id":"C01","role":"MEMBER","type":"CUSTOMER"}]}"#)
        let members = try await callTool(GoogleWorkspace.adapter, "group-members", #"{"group":"accounting@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertFalse(members.isError, members.text)
        XCTAssertTrue(members.text.contains("bookkeeper@agency.example (outside the domain)"), members.text)
        XCTAssertTrue(members.text.contains("finance@kestrel.example (group, owner)"), members.text)
        XCTAssertTrue(members.text.contains("everyone in the domain"), members.text)
        XCTAssertFalse(members.text.contains("ivana@kestrel.example (outside"), members.text)
    }

    /// Every app people let into their accounts in the window, by its client ID, with its scopes and who granted or
    /// revoked it, those that can read mail or files or administer first.
    func testOAuthAppsAreBuiltFromAuthorizationsAndRevocations() async throws {
        let service = FakeService()
        let token = "/admin/reports/v1/activity/users/all/applications/token"
        service.answers[token + "?eventName=authorize&maxResults=1000&startTime=2026-06-01T00:00:00Z"] = (200, #"{"items":[{"id":{"time":"2026-11-10T09:00:00.000Z","uniqueQualifier":"1"},"actor":{"email":"pdp@kestrel.example"},"events":[{"name":"authorize","parameters":[{"name":"app_name","value":"Reclaim.ai"},{"name":"client_id","value":"111.apps.googleusercontent.com"},{"name":"client_type","value":"WEB"},{"name":"scope","multiValue":["https://www.googleapis.com/auth/calendar"]}]}]},{"id":{"time":"2026-11-11T09:00:00.000Z","uniqueQualifier":"2"},"actor":{"email":"ivana@kestrel.example"},"events":[{"name":"authorize","parameters":[{"name":"app_name","value":"Reclaim.ai"},{"name":"client_id","value":"111.apps.googleusercontent.com"},{"name":"scope","multiValue":["https://www.googleapis.com/auth/calendar"]}]}]},{"id":{"time":"2026-11-12T09:00:00.000Z","uniqueQualifier":"3"},"actor":{"email":"nick@kestrel.example"},"events":[{"name":"authorize","parameters":[{"name":"app_name","value":"Mail Helper"},{"name":"client_id","value":"222.apps.googleusercontent.com"},{"name":"scope","multiValue":["https://mail.google.com/"]}]}]}]}"#)
        service.answers[token + "?eventName=revoke&maxResults=1000&startTime=2026-06-01T00:00:00Z"] = (200, #"{"items":[{"id":{"time":"2026-11-13T09:00:00.000Z","uniqueQualifier":"4"},"actor":{"email":"ivana@kestrel.example"},"events":[{"name":"revoke","parameters":[{"name":"app_name","value":"Reclaim.ai"},{"name":"client_id","value":"111.apps.googleusercontent.com"}]}]}]}"#)
        service.answers["/admin/reports/v1/activity/users/all/applications/admin"] = (200, #"{"items":[]}"#)
        let apps = try await callTool(GoogleWorkspace.adapter, "oauth-apps", #"{"since":"2026-06-01T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(apps.isError, apps.text)
        let lines = apps.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("Mail Helper") && lines[0].contains("222.apps.googleusercontent.com") && lines[0].contains("reads and sends mail"), apps.text)
        let reclaim = try XCTUnwrap(lines.first { $0.contains("Reclaim.ai") })
        XCTAssertTrue(reclaim.contains("granted by pdp@kestrel.example") && reclaim.contains("revoked by ivana@kestrel.example")
                      && reclaim.contains("https://www.googleapis.com/auth/calendar"), reclaim)
    }

    /// What an app did with the access it was given: its API calls and how much data it pulled, by client ID or user.
    func testAppActivitySumsCallsAndBytesPerAppAndMethod() async throws {
        let service = FakeService()
        let token = "/admin/reports/v1/activity/users/all/applications/token"
        service.answers[token] = (200, #"{"items":[{"id":{"time":"2026-11-14T09:00:00.000Z","uniqueQualifier":"1"},"actor":{"email":"nick@kestrel.example"},"events":[{"name":"activity","parameters":[{"name":"app_name","value":"Mail Helper"},{"name":"client_id","value":"222"},{"name":"api_name","value":"gmail"},{"name":"method_name","value":"gmail.users.messages.get"},{"name":"num_response_bytes","intValue":"5000000"}]}]},{"id":{"time":"2026-11-14T09:01:00.000Z","uniqueQualifier":"2"},"actor":{"email":"nick@kestrel.example"},"events":[{"name":"activity","parameters":[{"name":"app_name","value":"Mail Helper"},{"name":"client_id","value":"222"},{"name":"api_name","value":"gmail"},{"name":"method_name","value":"gmail.users.messages.get"},{"name":"num_response_bytes","intValue":"3000000"}]}]}]}"#)
        let activity = try await callTool(GoogleWorkspace.adapter, "app-activity", #"{"clientId":"222","since":"2026-11-13T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(activity.isError, activity.text)
        XCTAssertTrue(activity.text.contains("Mail Helper (222) as nick@kestrel.example: gmail.users.messages.get 2 calls, 8.0 MB"), activity.text)
        let sent = queryItems(service.requests.last)
        XCTAssertEqual(sent["eventName"], "activity")
        XCTAssertEqual(sent["filters"], "client_id==222")
    }

    /// One account's sign-ins, account changes, app grants, files and admin actions, and what admins did to it, in one
    /// list, newest first.
    func testAUserTimelineMergesTheirActivityAcrossReports() async throws {
        let service = FakeService()
        let user = "/admin/reports/v1/activity/users/ivana@kestrel.example/applications/"
        for application in ["user_accounts", "drive", "saml", "mobile", "groups", "admin"] { service.answers[user + application] = (200, "{}") }
        service.answers[user + "login"] = (200, #"{"items":[{"id":{"time":"2026-11-14T09:00:00.000Z","uniqueQualifier":"1"},"actor":{"email":"ivana@kestrel.example"},"ipAddress":"203.0.113.77","events":[{"name":"login_success"}]}]}"#)
        service.answers[user + "token"] = (200, #"{"items":[{"id":{"time":"2026-11-14T09:05:00.000Z","uniqueQualifier":"2"},"actor":{"email":"ivana@kestrel.example"},"events":[{"name":"authorize","parameters":[{"name":"app_name","value":"Mail Helper"}]}]}]}"#)
        service.answers["/admin/reports/v1/activity/users/all/applications/admin"] = (200, #"{"items":[{"id":{"time":"2026-11-14T09:10:00.000Z","uniqueQualifier":"3"},"actor":{"email":"pdp@kestrel.example"},"events":[{"name":"CHANGE_PASSWORD","parameters":[{"name":"USER_EMAIL","value":"ivana@kestrel.example"}]}]}]}"#)
        let timeline = try await callTool(GoogleWorkspace.adapter, "user-timeline", #"{"user":"ivana@kestrel.example","since":"2026-11-13T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(timeline.isError, timeline.text)
        let lines = timeline.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("admin") && lines[0].contains("CHANGE_PASSWORD") && lines[0].contains("by pdp@kestrel.example"), timeline.text)
        XCTAssertTrue(lines[1].contains("token") && lines[1].contains("authorize"), timeline.text)
        XCTAssertTrue(lines[2].contains("login") && lines[2].contains("203.0.113.77"), timeline.text)
        let aboutThem = service.requests.first { $0.url?.path.hasSuffix("/users/all/applications/admin") == true }
        XCTAssertEqual(queryItems(aboutThem)["filters"], "USER_EMAIL==ivana@kestrel.example")
    }

    /// The signs of an account being taken over wake the agents: 2-step verification turned off, recovery changed,
    /// mail forwarded out or monitored, backup codes made for someone, a mailbox dumped.
    func testTheTriggerWatchesForAccountTakeover() {
        let watched = Set(GoogleWorkspace.watched.map { "\($0.application)/\($0.event)" })
        for event in ["user_accounts/2sv_disable", "user_accounts/recovery_email_edit", "user_accounts/recovery_phone_edit",
                      "user_accounts/email_forwarding_out_of_domain", "admin/CREATE_EMAIL_MONITOR", "admin/MAIL_ROUTING_DESTINATION_ADDED",
                      "admin/GENERATE_2SV_SCRATCH_CODES", "admin/REQUEST_MAILBOX_DUMP", "admin/CHANGE_RECOVERY_EMAIL"] {
            XCTAssertTrue(watched.contains(event), event)
        }
    }

    /// The apps that hold access to accounts now, across everyone, by client ID, those that can read mail or files or
    /// administer first: what is still open after a breach.
    func testContainmentAppsListEveryAppHoldingAccessNow() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/users"] = (200, #"{"users":[{"primaryEmail":"pdp@kestrel.example"},{"primaryEmail":"nick@kestrel.example"}]}"#)
        service.answers["/admin/directory/v1/users/pdp@kestrel.example/tokens"] = (200, #"{"items":[{"clientId":"111","displayText":"Reclaim.ai","scopes":["https://www.googleapis.com/auth/calendar"]}]}"#)
        service.answers["/admin/directory/v1/users/nick@kestrel.example/tokens"] = (200, #"{"items":[{"clientId":"111","displayText":"Reclaim.ai","scopes":["https://www.googleapis.com/auth/calendar"]},{"clientId":"222","displayText":"Mail Helper","scopes":["https://mail.google.com/"]}]}"#)
        let apps = try await callTool(GoogleWorkspace.containmentAdapter, "apps", "{}", on: service, in: containment)
        XCTAssertFalse(apps.isError, apps.text)
        let lines = apps.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("Mail Helper (222)") && lines[0].contains("reads and sends mail") && lines[0].contains("nick@kestrel.example"), apps.text)
        XCTAssertTrue(lines.contains { $0.contains("Reclaim.ai (111)") && $0.contains("2 users") }, apps.text)
        XCTAssertEqual(GoogleWorkspace.containmentAdapter.simultaneousRequests, 8)
    }

    // MARK: Troubleshooting

    static let scopeMissing = #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED","details":[{"reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#
    static let notAuthorized = #"{"error":{"code":403,"message":"Not Authorized to access this resource/api","errors":[{"reason":"forbidden"}]}}"#
    static let apiDisabled = #"{"error":{"code":403,"message":"Cloud Identity API has not been used in project 123456 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/cloudidentity.googleapis.com/overview?project=123456 then retry.","status":"PERMISSION_DENIED"}}"#

    /// Each thing the tool reads is tried once, and what fails says exactly what to change: a scope the sign-in lacks,
    /// an API turned off in the project, or a privilege the admin's role lacks.
    func testCheckAccessSaysWhatWorksAndHowToFixWhatDoesNot() async throws {
        let service = FakeService()
        service.answers["/admin/reports/v1/activity/users/all/applications/login"] = (200, "{}")
        service.answers["/admin/directory/v1/users"] = (200, #"{"users":[]}"#)
        service.answers["/admin/directory/v1/customer/my_customer/roles"] = (403, Self.scopeMissing)
        service.answers["/admin/directory/v1/groups"] = (403, Self.notAuthorized)
        service.answers["/admin/directory/v1/customer/my_customer/devices/mobile"] = (403, Self.apiDisabled)
        service.answers["/v1/policies"] = (403, Self.notAuthorized)
        let check = try await callTool(GoogleWorkspace.adapter, "check-access", "{}", on: service, in: workspace)
        XCTAssertFalse(check.isError, check.text)
        let lines = check.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("✓ Audit reports"), check.text)
        XCTAssertTrue(lines.contains("✓ Users"), check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("✗ Admin roles") && $0.contains("admin.directory.rolemanagement.readonly") && $0.contains("sign the tool in again") }, check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("✗ Groups") && $0.contains("Groups › Read") && $0.contains("role") }, check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("✗ Mobile devices") && $0.contains("is turned off")
            && $0.contains("https://console.developers.google.com/apis/api/cloudidentity.googleapis.com/overview?project=123456") }, check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("✗ Organisation settings") && $0.contains("only a super admin") && !$0.contains("add super admin") }, check.text)
        XCTAssertEqual(Set(service.requests.filter { $0.url?.host == "cloudidentity.googleapis.com" }.map { $0.url?.path ?? "" }), ["/v1/policies"])
    }

    /// A tool call that fails says the same, so an agent can tell the champion what to change without guessing.
    func testARefusedCallSaysWhatToChange() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/customer/my_customer/devices/mobile"] = (403, Self.apiDisabled)
        let devices = try await callTool(GoogleWorkspace.adapter, "user-devices", #"{"user":"ivana@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertTrue(devices.isError)
        XCTAssertTrue(devices.text.contains("is turned off") && devices.text.contains("project=123456"), devices.text)
        service.answers["/admin/directory/v1/users"] = (401, #"{"error":{"code":401,"message":"Request had invalid authentication credentials."}}"#)
        let users = try await callTool(GoogleWorkspace.adapter, "users", "{}", on: service, in: workspace)
        XCTAssertTrue(users.isError && users.text.contains("sign the tool in again"), users.text)
        service.answers["/admin/reports/v1/activity/users/all/applications/login"] = (403, Self.scopeMissing)
        let activity = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"login"}"#, on: service, in: workspace)
        XCTAssertTrue(activity.isError && activity.text.contains("admin.reports.audit.readonly"), activity.text)
        // Cloud Identity's settings take a scope and an API of their own, which the setup names. Its device scope is not
        // on Google's list of scopes a sign-in may request, so the sign-in does not ask for it.
        let setup = GoogleWorkspace.setup.joined()
        XCTAssertTrue(setup.contains("cloud-identity.policies.readonly") && setup.contains("only a super admin") && !setup.contains("cloud-identity.devices"))
        service.answers["/v1/policies"] = (403, Self.apiDisabled)
        let disabled = try await callTool(GoogleWorkspace.adapter, "policy-settings", "{}", on: service, in: workspace)
        XCTAssertTrue(disabled.isError && disabled.text.contains("Cloud Identity API is turned off"), disabled.text)
    }

    /// Containment's check tries reading users and one user's tokens; suspending can only be confirmed by suspending.
    func testContainmentCheckAccessTriesWhatItSafelyCan() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/users"] = (200, #"{"users":[{"primaryEmail":"pdp@kestrel.example"}]}"#)
        service.answers["/admin/directory/v1/users/pdp@kestrel.example/tokens"] = (403, Self.notAuthorized)
        let check = try await callTool(GoogleWorkspace.containmentAdapter, "check-access", "{}", on: service, in: containment)
        let lines = check.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("✓ Users"), check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("✗ Sessions, apps and app passwords") && $0.contains("User Security Management") }, check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("· Suspending") && $0.contains("Suspend users") }, check.text)
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" }, "a check never changes anything")
        XCTAssertEqual(queryItems(service.requests.first)["query"], "isAdmin=false isDelegatedAdmin=false",
                       "User Security Management never covers admins, so an admin's tokens would fail a healthy setup")
        let none = FakeService()
        none.answers["/admin/directory/v1/users"] = (200, #"{"users":[]}"#)
        let unchecked = try await callTool(GoogleWorkspace.containmentAdapter, "check-access", "{}", on: none, in: containment)
        XCTAssertTrue(unchecked.text.contains("not tried, as no account that is not an admin could be read"), unchecked.text)
    }

    /// Every page and API the Setup Steps name is a link to it, so nobody has to search Google's consoles.
    func testSetupStepsLinkEveryPageAndAPITheyName() {
        let links: [(String, [String], [String])] = [
            ("Google Workspace Detection", GoogleWorkspace.setup, ["console.cloud.google.com/apis/library/admin.googleapis.com",
                                                              "console.cloud.google.com/apis/library/cloudidentity.googleapis.com",
                                                              "console.cloud.google.com/auth/overview", "console.cloud.google.com/auth/scopes",
                                                              "console.cloud.google.com/auth/clients", "admin.google.com/ac/roles"]),
            ("Google Workspace Containment", GoogleWorkspace.containmentSetup, ["admin.google.com/ac/roles", "console.cloud.google.com/apis/library/admin.googleapis.com",
                                                                               "console.cloud.google.com/auth/scopes", "console.cloud.google.com/auth/clients",
                                                                               "admin.google.com/ac/owl"]),
            ("Google Cloud", GoogleCloud.setup, ["console.cloud.google.com/apis/library/logging.googleapis.com", "console.cloud.google.com/apis/library/securitycenter.googleapis.com",
                                                 "console.cloud.google.com/apis/library/cloudasset.googleapis.com", "console.cloud.google.com/auth/overview",
                                                 "console.cloud.google.com/auth/scopes", "console.cloud.google.com/auth/clients",
                                                 "console.cloud.google.com/iam-admin/iam", "console.cloud.google.com/iam-admin/audit",
                                                 "admin.google.com/ac/roles"]),
        ]
        for (tool, steps, wanted) in links {
            let text = steps.joined(separator: "\n")
            for link in wanted { XCTAssertTrue(text.contains("https://" + link), "\(tool) does not link \(link)") }
        }
    }

    // MARK: Completeness

    private static func item(_ n: Int, _ event: String = "login_success", parameters: String = "") -> String {
        #"{"id":{"time":"2026-11-14T09:\#(String(format: "%02d", n % 60)):00.000Z","uniqueQualifier":"\#(n)"},"actor":{"email":"u\#(n)@kestrel.example"},"events":[{"name":"\#(event)","parameters":[\#(parameters)]}]}"#
    }

    /// An audit query reads every page up to what was asked, and says when there was more, so an agent never takes a
    /// cut-short answer for the whole.
    func testAuditQueriesReadEveryPageAndSayWhenCutShort() async throws {
        let service = FakeService()
        let login = "/admin/reports/v1/activity/users/all/applications/login"
        service.sequences[login] = [
            (200, #"{"items":[\#((0..<3).map { Self.item($0) }.joined(separator: ","))],"nextPageToken":"p2"}"#),
            (200, #"{"items":[\#((3..<5).map { Self.item($0) }.joined(separator: ","))]}"#),
        ]
        let all = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"login","limit":500}"#, on: service, in: workspace)
        XCTAssertEqual((all.structured?["events"] as? [Any])?.count, 5, all.text)
        XCTAssertEqual(queryItems(service.requests.last)["pageToken"], "p2")
        XCTAssertFalse(all.text.contains("more"), all.text)
        service.sequences[login] = [(200, #"{"items":[\#((0..<3).map { Self.item($0) }.joined(separator: ","))],"nextPageToken":"p2"}"#)]
        let cut = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"login","limit":3}"#, on: service, in: workspace)
        XCTAssertTrue(cut.text.contains("There are more"), cut.text)
    }

    /// The details that matter for each kind of event come first, nested ones included, with where the address is.
    func testEventsShowTheirKeyDetailsNestedOnesAndTheNetwork() async throws {
        let service = FakeService()
        service.answers["/admin/reports/v1/activity/users/all/applications/drive"] = (200, #"{"items":[{"id":{"time":"2026-11-14T09:00:00.000Z","uniqueQualifier":"1"},"actor":{"email":"ivana@kestrel.example"},"ipAddress":"203.0.113.77","networkInfo":{"ipAsn":[16509],"regionCode":"NL","subdivisionCode":"NL-NH"},"events":[{"name":"change_user_access","parameters":[{"name":"actor_is_collaborator_account","boolValue":false},{"name":"billable","boolValue":true},{"name":"doc_id","value":"1AbC"},{"name":"doc_type","value":"spreadsheet"},{"name":"primary_event","boolValue":true},{"name":"doc_title","value":"Payroll 2026"},{"name":"target_user","value":"drop@mailbox.example"},{"name":"new_value","multiValue":["can_view"]}]}]}]}"#)
        let drive = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"drive"}"#, on: service, in: workspace)
        XCTAssertTrue(drive.text.contains("doc_title=Payroll 2026") && drive.text.contains("target_user=drop@mailbox.example")
                      && drive.text.contains("new_value=can_view"), drive.text)
        XCTAssertTrue(drive.text.contains("from 203.0.113.77 (AS16509, NL-NH)"), drive.text)
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
        service.answers["/admin/reports/v1/activity/users/all/applications/gmail"] = (200, #"{"items":[{"id":{"time":"2026-11-14T09:00:00.000Z","uniqueQualifier":"2"},"actor":{"email":"ivana@kestrel.example"},"events":[{"name":"delivery","parameters":[{"name":"message_info","messageValue":{"parameter":[{"name":"subject","value":"Invoice overdue"},{"name":"source","messageValue":{"parameter":[{"name":"address","value":"billing@evil.example"}]}}]}}]}]}]}"#)
        let mail = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"gmail","since":"\#(since)"}"#, on: service, in: workspace)
        XCTAssertFalse(mail.isError, mail.text)
        XCTAssertTrue(mail.text.contains("message_info.subject=Invoice overdue") && mail.text.contains("message_info.source.address=billing@evil.example"), mail.text)
    }

    /// Google takes Gmail events only for a window of 30 days at most, with an end.
    func testGmailEventsAreAskedForInAWindowGoogleTakes() async throws {
        let service = FakeService()
        service.answers["/admin/reports/v1/activity/users/all/applications/gmail"] = (200, "{}")
        _ = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"gmail"}"#, on: service, in: workspace)
        XCTAssertNotNil(queryItems(service.requests.last)["endTime"])
        let wide = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"gmail","since":"2026-01-01T00:00:00Z","until":"2026-03-01T00:00:00Z"}"#,
                                      on: service, in: workspace)
        XCTAssertTrue(wide.isError && wide.text.contains("30 days"), wide.text)
    }

    /// Directory lists read every page, so a large org's admins, members or users are not left out.
    func testDirectoryListsReadEveryPage() async throws {
        let service = FakeService()
        service.sequences["/admin/directory/v1/users"] = [
            (200, #"{"users":[{"primaryEmail":"a@kestrel.example"}],"nextPageToken":"n2"}"#),
            (200, #"{"users":[{"primaryEmail":"b@kestrel.example"}]}"#),
        ]
        let users = try await callTool(GoogleWorkspace.adapter, "users", "{}", on: service, in: workspace)
        XCTAssertTrue(users.text.contains("a@kestrel.example") && users.text.contains("b@kestrel.example"), users.text)
        XCTAssertEqual(queryItems(service.requests.last)["pageToken"], "n2")
        service.answers["/admin/directory/v1/groups/all@kestrel.example/members"] = (200, #"{"members":[]}"#)
        _ = try await callTool(GoogleWorkspace.adapter, "group-members", #"{"group":"all@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertEqual(queryItems(service.requests.last)["includeDerivedMembership"], "true")
    }

    /// Everything one address did, in every report: how an attacker's IP is followed.
    func testIPActivityFollowsAnAddressAcrossEveryReport() async throws {
        let service = FakeService()
        for application in GoogleWorkspace.IPActivity.applications { service.answers["/admin/reports/v1/activity/users/all/applications/" + application] = (200, "{}") }
        service.answers["/admin/reports/v1/activity/users/all/applications/token"] = (200, ##"{"items":[\##(Self.item(1, "authorize", parameters: #"{"name":"app_name","value":"Mail Helper"}"#))]}"##)
        service.answers["/admin/reports/v1/activity/users/all/applications/login"] = (200, #"{"items":[\#(Self.item(2))]}"#)
        let found = try await callTool(GoogleWorkspace.adapter, "ip-activity", #"{"ip":"203.0.113.77"}"#, on: service, in: workspace)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("token") && found.text.contains("app_name=Mail Helper") && found.text.contains("login"), found.text)
        XCTAssertTrue(service.requests.allSatisfy { queryItems($0)["actorIpAddress"] == "203.0.113.77" })
        XCTAssertTrue(Set(GoogleWorkspace.IPActivity.applications).isSuperset(of: ["login", "token", "drive", "admin", "takeout"]))
        let bad = try await callTool(GoogleWorkspace.adapter, "ip-activity", #"{"ip":"not an ip"}"#, on: service, in: workspace)
        XCTAssertTrue(bad.isError)
    }

    /// Events found by a detail: who opened one file, everyone who used one app.
    func testActivityFiltersOnAnEventsDetails() async throws {
        let service = FakeService()
        service.answers["/admin/reports/v1/activity/users/all/applications/drive"] = (200, "{}")
        _ = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"drive","filters":"doc_id==1AbC"}"#, on: service, in: workspace)
        XCTAssertEqual(queryItems(service.requests.last)["filters"], "doc_id==1AbC")
    }

    /// A user's own exports, calendar sharing and chats are part of their timeline.
    func testATimelineCoversExportsCalendarAndChat() {
        XCTAssertTrue(Set(GoogleWorkspace.UserTimeline.applications).isSuperset(of: ["takeout", "calendar", "chat", "meet"]))
    }

    /// Agents are told what silence does not mean, and what this tool cannot see.
    func testInstructionsSayWhatSilenceDoesNotMeanAndWhereTheBlindSpotsAre() {
        let audit = GoogleWorkspace.preset.defaultInstructions
        XCTAssertTrue(audit.contains("hours late") && audit.contains("180 days") && audit.contains("forwarding"), audit)
        XCTAssertTrue(GoogleWorkspace.containment.defaultInstructions.contains("never covers admins"))
    }

    // MARK: Review findings

    /// One report refused leaves the rest of an account's history, and says which report could not be read.
    func testOneRefusedReportLeavesTheRestOfTheTimeline() async throws {
        let service = FakeService()
        let user = "/admin/reports/v1/activity/users/ivana@kestrel.example/applications/"
        for application in GoogleWorkspace.UserTimeline.applications { service.answers[user + application] = (200, "{}") }
        service.answers["/admin/reports/v1/activity/users/all/applications/admin"] = (200, "{}")
        service.answers[user + "login"] = (200, #"{"items":[\#(Self.item(1))]}"#)
        service.answers[user + "drive"] = (403, Self.notAuthorized)
        let timeline = try await callTool(GoogleWorkspace.adapter, "user-timeline", #"{"user":"ivana@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertFalse(timeline.isError, timeline.text)
        XCTAssertTrue(timeline.text.contains("login_success"), timeline.text)
        XCTAssertTrue(timeline.text.contains("Could not read: drive"), timeline.text)
        XCTAssertTrue(timeline.text.contains("Searched:") && timeline.text.contains("takeout"), timeline.text)
    }

    /// Two events with the same qualifier at different times are two events.
    func testEventsAtDifferentTimesAreNotMerged() async throws {
        let service = FakeService()
        let user = "/admin/reports/v1/activity/users/ivana@kestrel.example/applications/"
        for application in GoogleWorkspace.UserTimeline.applications { service.answers[user + application] = (200, "{}") }
        service.answers["/admin/reports/v1/activity/users/all/applications/admin"] = (200, "{}")
        service.answers[user + "login"] = (200, #"{"items":[{"id":{"time":"2026-11-14T09:00:00.000Z","uniqueQualifier":"7"},"events":[{"name":"login_success"}]},{"id":{"time":"2026-11-14T10:00:00.000Z","uniqueQualifier":"7"},"events":[{"name":"login_success"}]}]}"#)
        let timeline = try await callTool(GoogleWorkspace.adapter, "user-timeline", #"{"user":"ivana@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertEqual((timeline.structured?["events"] as? [Any])?.count, 2, timeline.text)
    }

    /// A deleted account is found with its profile ID, and its history is read by that ID.
    func testDeletedAccountsAreFoundAndReadByProfileID() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/users"] = (200, #"{"users":[{"id":"104857600123456789012","primaryEmail":"leaver@kestrel.example"}]}"#)
        let deleted = try await callTool(GoogleWorkspace.adapter, "users", #"{"deleted":true}"#, on: service, in: workspace)
        XCTAssertTrue(deleted.text.contains("leaver@kestrel.example") && deleted.text.contains("104857600123456789012"), deleted.text)
        XCTAssertEqual(queryItems(service.requests.last)["showDeleted"], "true")
        let byID = "/admin/reports/v1/activity/users/104857600123456789012/applications/login"
        service.answers[byID] = (200, #"{"items":[\#(Self.item(3))]}"#)
        let history = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"login","user":"104857600123456789012"}"#, on: service, in: workspace)
        XCTAssertFalse(history.isError, history.text)
        XCTAssertEqual(service.requests.last?.url?.path, byID)
    }

    /// The app inventory pages through every account, keeps what it found when one account is refused, and says how
    /// many accounts it checked even when it found nothing.
    func testTheAppInventoryCoversEveryAccountAndKeepsWhatItFound() async throws {
        let service = FakeService()
        service.sequences["/admin/directory/v1/users"] = [
            (200, #"{"users":[{"primaryEmail":"admin@kestrel.example"}],"nextPageToken":"n2"}"#),
            (200, #"{"users":[{"primaryEmail":"nick@kestrel.example"}]}"#),
        ]
        service.answers["/admin/directory/v1/users/admin@kestrel.example/tokens"] = (403, Self.notAuthorized)
        service.answers["/admin/directory/v1/users/nick@kestrel.example/tokens"] = (200, #"{"items":[{"clientId":"222","displayText":"Mail Helper","scopes":["https://mail.google.com/"]}]}"#)
        let apps = try await callTool(GoogleWorkspace.containmentAdapter, "apps", "{}", on: service, in: containment)
        XCTAssertFalse(apps.isError, apps.text)
        XCTAssertTrue(apps.text.contains("Mail Helper (222)"), apps.text)
        XCTAssertTrue(apps.text.contains("Checked 1 of 2 accounts") && apps.text.contains("could not read admin@kestrel.example"), apps.text)
        XCTAssertEqual(apps.structured?["accountsChecked"] as? Int, 1, "an account that could not be read was not checked")
        XCTAssertEqual(apps.structured?["accountsTried"] as? Int, 2)
        service.sequences["/admin/directory/v1/users"] = [(200, #"{"users":[{"primaryEmail":"a@kestrel.example"}]}"#)]
        service.answers["/admin/directory/v1/users/a@kestrel.example/tokens"] = (200, "{}")
        let none = try await callTool(GoogleWorkspace.containmentAdapter, "apps", "{}", on: service, in: containment)
        XCTAssertTrue(none.text.contains("No app holds access to any of the 1 account checked"), none.text)
    }

    /// Gmail's nested event type, which tells receipt from forwarding, comes through with what it means.
    func testGmailEventTypesSayWhatHappened() async throws {
        let service = FakeService()
        service.answers["/admin/reports/v1/activity/users/all/applications/gmail"] = (200, #"{"items":[{"id":{"time":"2026-11-14T09:00:00.000Z","uniqueQualifier":"1"},"actor":{"email":"ivana@kestrel.example"},"events":[{"name":"delivery","parameters":[{"name":"event_info","messageValue":{"parameter":[{"name":"mail_event_type","intValue":"11"}]}}]}]}]}"#)
        let mail = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"gmail"}"#, on: service, in: workspace)
        XCTAssertTrue(mail.text.contains("event_info.mail_event_type=11 (autoforwarded by a forwarding setting)"), mail.text)
    }

    /// The access check tries the Gmail and Takeout reports too, as a working sign-in report does not prove them.
    func testCheckAccessTriesGmailAndTakeoutReports() async throws {
        let service = FakeService()
        for path in ["/admin/reports/v1/activity/users/all/applications/login", "/admin/directory/v1/users", "/admin/directory/v1/customer/my_customer/roles",
                     "/admin/directory/v1/groups", "/admin/directory/v1/customer/my_customer/devices/mobile",
                     "/admin/reports/v1/activity/users/all/applications/takeout"] { service.answers[path] = (200, "{}") }
        service.answers["/admin/reports/v1/activity/users/all/applications/gmail"] = (400, #"{"error":{"code":400,"message":"Gmail logs are not available"}}"#)
        let check = try await callTool(GoogleWorkspace.adapter, "check-access", "{}", on: service, in: workspace)
        XCTAssertTrue(check.text.contains("✓ Takeout report") && check.text.contains("✗ Gmail report"), check.text)
        let gmail = service.requests.first { $0.url?.path.hasSuffix("/gmail") == true }
        XCTAssertNotNil(queryItems(gmail)["endTime"])
    }

    // MARK: Scope guard

    /// Every Google scope Pion asks for, with where it was checked. A scope can be accepted by an API's method and still
    /// be refused at sign-in, and an invalid one fails the whole sign-in. So a scope is added here only once it is on Google's list of scopes a sign-in can
    /// request (developers.google.com/identity/protocols/oauth2/scopes) and the API's own guide allows an admin's
    /// sign-in, or a live sign-in has taken it.
    static let checkedScopes: [String: String] = [
        "https://www.googleapis.com/auth/admin.reports.audit.readonly": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/admin.directory.user.readonly": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/admin.directory.group.readonly": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/admin.directory.device.mobile.readonly": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/admin.directory.domain.readonly": "on Google's scope list; Directory API, which takes an admin's own sign-in; domains.list accepts it",
        "https://www.googleapis.com/auth/cloud-identity.policies.readonly": "on Google's scope list; policies.list accepts it; Google lets only a super admin use the Policy API",
        "https://www.googleapis.com/auth/admin.directory.user": "on Google's scope list",
        "https://www.googleapis.com/auth/admin.directory.user.security": "on Google's scope list",
        "https://www.googleapis.com/auth/admin.directory.device.mobile.action": "on Google's scope list; mobiledevices.list, get and action each accept it",
        "https://www.googleapis.com/auth/logging.read": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/cloudasset": "not on Google's scope list, which gives only cloud-platform for Cloud Asset; taken by the champion's live sign-in",
        "https://www.googleapis.com/auth/securitycenter": "not on Google's scope list, which gives only cloud-platform for Security Command Center; taken by the champion's live sign-in",
        "https://www.googleapis.com/auth/cloud-platform": "on Google's scope list for IAM, Resource Manager, Compute Engine and Cloud Storage; Google Cloud Containment's alone",
        "https://www.googleapis.com/auth/userinfo.email": "on Google's scope list for Google's OpenID Connect user info; Google Cloud Containment checks who signed in with it",
    ]

    func testEveryGoogleScopeAskedForHasBeenChecked() throws {
        var tools = 0
        defer { XCTAssertEqual(tools, 4, "Google Workspace Detection, Google Workspace Containment, Google Cloud Detection and Google Cloud Containment") }
        for preset in PionCatalogue.entries where preset.adapter?.hasPrefix("google-") == true {
            guard case .connection(let configuration) = preset.configuration, let oauth = configuration.oauth else { continue }
            tools += 1
            for scope in oauth.scopes {
                XCTAssertNotNil(Self.checkedScopes[scope], "\(preset.name) asks for \(scope), which nobody has checked a sign-in can request")
            }
        }
    }

    /// The alert check reads every watched report at once, and they answer out of order; it must come back with what
    /// they found every time. Pion crashed at launch when a report finished after its group was gone.
    func testReadingManyReportsThatAnswerOutOfOrderIsSafe() async throws {
        let service = FakeService()
        service.answerDelay = 0.02
        for application in Set(GoogleWorkspace.watched.map(\.application)) {
            service.answers["/admin/reports/v1/activity/users/all/applications/" + application] = (200, #"{"items":[\#(Self.item(1, "suspicious_login"))]}"#)
        }
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
        for _ in 0..<40 {
            let found = try await GoogleWorkspace.adapter.alerts(since: since, connection: workspace, access: service)
            XCTAssertFalse(found.isEmpty)
        }
    }

    /// The app inventory asks every account at once, and they answer out of order.
    func testTheAppInventoryIsSafeWhenAccountsAnswerOutOfOrder() async throws {
        let service = FakeService()
        service.answerDelay = 0.02
        let emails = (0..<30).map { "u\($0)@kestrel.example" }
        service.answers["/admin/directory/v1/users"] = (200, #"{"users":[\#(emails.map { #"{"primaryEmail":"\#($0)"}"# }.joined(separator: ","))]}"#)
        for email in emails { service.answers["/admin/directory/v1/users/\(email)/tokens"] = (200, #"{"items":[{"clientId":"1","displayText":"App"}]}"#) }
        for _ in 0..<20 {
            let apps = try await callTool(GoogleWorkspace.containmentAdapter, "apps", "{}", on: service, in: containment)
            XCTAssertTrue(apps.text.contains("held by 30 users"), apps.text)
        }
    }

    func testDomainsListEachDomainAndAliasWithWhatIsUnverified() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/customer/my_customer/domains"] = (200, #"""
        {"domains":[
          {"domainName":"kestrel.example","isPrimary":true,"verified":true,"creationTime":"1577934000000",
           "domainAliases":[{"domainAliasName":"kestrel-mail.example","parentDomainName":"kestrel.example","verified":false,"creationTime":"1763164800000"}]},
          {"domainName":"kestrel-labs.example","isPrimary":false,"verified":true,"creationTime":1700000000000}
        ]}
        """#)
        let result = try await callTool(GoogleWorkspace.adapter, "domains", "{}", on: service, in: workspace)
        XCTAssertFalse(result.isError, result.text)
        for expected in ["3 domains", "kestrel.example: primary, verified, added 2020-01-02",
                         "kestrel-labs.example: secondary, verified, added 2023-11-14",
                         "kestrel-mail.example: alias of kestrel.example, NOT verified, added 2025-11-15"] {
            XCTAssertTrue(result.text.contains(expected), "\(expected) missing from:\n\(result.text)")
        }
        service.answers["/admin/directory/v1/customer/my_customer/domains"] = (403, #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED"}}"#)
        let refused = try await callTool(GoogleWorkspace.adapter, "domains", "{}", on: service, in: workspace)
        XCTAssertTrue(refused.text.contains("admin.directory.domain.readonly"), refused.text)
    }

    /// Who clicked a link in mail, from Gmail's events of type 15 (a link in the body) and 16 (a link in an attachment
    /// preview). Google does not say which detail holds the address, so a link is matched against all of them.
    func testLinkClicksSayWhoClickedALinkInMail() async throws {
        let service = FakeService()
        // The sender's domain and Message-ID name the same domain as the bad link, as phishing mail's often do.
        func click(_ id: String, _ time: String, _ user: String, _ code: String, _ urls: String...) -> String {
            let links = urls.map { #"{"parameter":[{"name":"url","value":"\#($0)"}]}"# }.joined(separator: ",")
            return #"{"id":{"time":"\#(time)","uniqueQualifier":"\#(id)"},"actor":{"email":"\#(user)"},"events":[{"name":"delivery","type":"delivery_type","parameters":[{"name":"event_info","messageValue":{"parameter":[{"name":"mail_event_type","intValue":"\#(code)"}]}},{"name":"message_info","messageValue":{"parameter":[{"name":"subject","value":"Invoice overdue"},{"name":"rfc2822_message_id","value":"<abc@evil.example>"},{"name":"source","messageValue":{"parameter":[{"name":"domain","value":"evil.example"}]}},{"name":"link_click_info","multiMessageValue":[\#(links)]}]}}]}]}"#
        }
        let path = "/admin/reports/v1/activity/users/all/applications/gmail"
        let pages: [(Int, String)] = [
            (200, #"{"items":[\#(click("1", "2026-11-20T09:00:00.000Z", "ivana@kestrel.example", "15", "https://login.evil.example/x")),\#(click("2", "2026-11-20T10:00:00.000Z", "nick@kestrel.example", "15", "https://news.example/a"))]}"#),
            (200, #"{"items":[\#(click("3", "2026-11-21T08:00:00.000Z", "pdp@kestrel.example", "16", "https://login.evil.example/y")),\#(click("4", "2026-11-21T07:00:00.000Z", "maria@kestrel.example", "15", "https://news.example/b", "https://login.evil.example/z"))]}"#),
        ]
        service.sequences[path] = pages
        let clicks = try await callTool(GoogleWorkspace.adapter, "link-clicks",
                                        #"{"link":"evil.example","since":"2026-11-01T00:00:00Z","until":"2026-11-21T12:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(clicks.isError, clicks.text)
        let filters = service.requests.map { queryItems($0)["filters"] }
        XCTAssertEqual(filters, ["event_info.mail_event_type==15", "event_info.mail_event_type==16"])
        XCTAssertEqual(queryItems(service.requests.first)["endTime"], "2026-11-21T12:00:00Z")
        for expected in ["2 clicks on links matching evil.example by 2 people: ivana@kestrel.example, pdp@kestrel.example",
                         "2026-11-21T08:00:00.000Z", "16 (link in an attachment preview clicked)", "15 (link in the body clicked)",
                         "https://login.evil.example/y", "Invoice overdue"] {
            XCTAssertTrue(clicks.text.contains(expected), "\(expected) missing from:\n\(clicks.text)")
        }
        XCTAssertFalse(clicks.text.contains("nick@kestrel.example"), "a click on another link in the same mail, from the same sender, was listed")
        XCTAssertTrue(clicks.text.contains("1 more click in a message that also links to evil.example, where Google's event lists several links and not which was clicked: maria@kestrel.example"), clicks.text)
        XCTAssertTrue(clicks.text.contains("https://news.example/b | https://login.evil.example/z"), "every link an event lists is kept:\n\(clicks.text)")
        service.sequences[path] = pages
        let bySubject = try await callTool(GoogleWorkspace.adapter, "link-clicks",
                                           #"{"message":"invoice overdue","since":"2026-11-01T00:00:00Z","until":"2026-11-21T12:00:00Z"}"#, on: service, in: workspace)
        XCTAssertTrue(bySubject.text.contains("4 clicks in messages matching invoice overdue by 4 people"), bySubject.text)
        let newest = try XCTUnwrap(clicks.text.range(of: "08:00:00.000Z pdp@")), older = try XCTUnwrap(clicks.text.range(of: "09:00:00.000Z ivana@"))
        XCTAssertLessThan(newest.lowerBound, older.lowerBound, "not newest first")

        let window = try await callTool(GoogleWorkspace.adapter, "link-clicks", #"{"since":"2026-09-01T00:00:00Z","until":"2026-11-21T00:00:00Z"}"#,
                                        on: service, in: workspace)
        XCTAssertTrue(window.isError && window.text.contains("30 days"), window.text)
    }

    /// Roles a user holds directly or through a group, from Google's own indirect listing.
    func testAdminRolesForOneUserIncludeThoseHeldThroughAGroup() async throws {
        let service = FakeService()
        let directory = "/admin/directory/v1"
        service.answers[directory + "/users"] = (200, #"{"users":[]}"#)
        service.answers[directory + "/customer/my_customer/roles"] = (200, #"{"items":[{"roleId":"r-help","roleName":"Help Desk Admin","rolePrivileges":[{"privilegeName":"USERS_RESET_PASSWORD"}]}]}"#)
        service.answers[directory + "/customer/my_customer/roleassignments"] = (200, #"{"items":[{"roleId":"r-help","assignedTo":"g-1","assigneeType":"GROUP","scopeType":"CUSTOMER"}]}"#)
        service.answers[directory + "/groups/g-1"] = (200, #"{"email":"helpdesk@kestrel.example"}"#)
        service.answers[directory + "/groups/g-1/members"] = (200, #"{"members":[{"email":"sam@kestrel.example"}]}"#)
        let roles = try await callTool(GoogleWorkspace.adapter, "admin-roles", #"{"user":"sam@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertFalse(roles.isError, roles.text)
        let asked = queryItems(service.requests.first { $0.url?.path.hasSuffix("/roleassignments") == true })
        XCTAssertEqual(asked["userKey"], "sam@kestrel.example")
        XCTAssertEqual(asked["includeIndirectRoleAssignments"], "true")
        XCTAssertTrue(roles.text.contains("Help Desk Admin") && roles.text.contains("group helpdesk@kestrel.example"), roles.text)
    }

    /// A Directory list longer than was read says so, in its text and its structured result, so a large group or a
    /// busy user is never taken for fully listed.
    func testDirectoryListsThatWereCutShortSaySo() async throws {
        let directory = "/admin/directory/v1"
        let cases: [(String, String, String, (Int, String))] = [
            ("group-members", #"{"group":"all@kestrel.example"}"#, directory + "/groups/all@kestrel.example/members",
             (200, #"{"members":[{"email":"a@kestrel.example"}],"nextPageToken":"more"}"#)),
            ("user-groups", #"{"user":"a@kestrel.example"}"#, directory + "/groups",
             (200, #"{"groups":[{"email":"g@kestrel.example"}],"nextPageToken":"more"}"#)),
            ("user-devices", #"{"user":"a@kestrel.example"}"#, directory + "/customer/my_customer/devices/mobile",
             (200, #"{"mobiledevices":[{"email":["a@kestrel.example"],"model":"Pixel"}],"nextPageToken":"more"}"#)),
            ("all-devices", "{}", directory + "/customer/my_customer/devices/mobile",
             (200, #"{"mobiledevices":[{"email":["a@kestrel.example"],"model":"Pixel"}],"nextPageToken":"more"}"#)),
            ("admin-roles", "{}", directory + "/customer/my_customer/roleassignments",
             (200, #"{"items":[{"roleId":"r","assignedTo":"u","assigneeType":"USER"}],"nextPageToken":"more"}"#)),
        ]
        for (tool, arguments, path, endless) in cases {
            let service = FakeService()
            service.answers[path] = endless
            service.answers[directory + "/users"] = (200, #"{"users":[]}"#)
            service.answers[directory + "/customer/my_customer/roles"] = (200, #"{"items":[{"roleId":"r","roleName":"Reader"}]}"#)
            let result = try await callTool(GoogleWorkspace.adapter, tool, arguments, on: service, in: workspace)
            XCTAssertFalse(result.isError, "\(tool): \(result.text)")
            XCTAssertTrue(result.text.contains("incomplete"), "\(tool) did not say it was cut short:\n\(result.text)")
            XCTAssertEqual(result.structured?["incomplete"] as? Bool, true, tool)
        }
    }

    /// Domain-wide delegation lets a client act as anyone without their consent, so no user's tokens show it: the
    /// admin log's grants and removals do (Google's Domain Settings events), and the alert watch wakes agents for a grant
    /// and for apps trusted or unblocked.
    func testDomainWideDelegationIsWatchedAndListedWithTheApps() async throws {
        let watched = Set(GoogleWorkspace.watched.filter { $0.application == "admin" }.map(\.event))
        for event in ["AUTHORIZE_API_CLIENT_ACCESS", "ADD_TO_TRUSTED_OAUTH2_APPS", "REMOVE_FROM_BLOCKED_OAUTH2_APPS",
                      "UNBLOCK_ALL_THIRD_PARTY_API_ACCESS", "ADD_TO_CAA_EXEMPT_OAUTH2_APPS"] {
            XCTAssertTrue(watched.contains(event), "\(event) is not watched")
        }
        let service = FakeService()
        let since = "maxResults=1000&startTime=2026-06-01T00:00:00Z"
        let token = "/admin/reports/v1/activity/users/all/applications/token", admin = "/admin/reports/v1/activity/users/all/applications/admin"
        service.answers[token + "?eventName=authorize&" + since] = (200, #"{"items":[]}"#)
        service.answers[token + "?eventName=revoke&" + since] = (200, #"{"items":[]}"#)
        service.answers[admin + "?eventName=AUTHORIZE_API_CLIENT_ACCESS&" + since] = (200, #"{"items":[{"id":{"time":"2026-11-15T03:00:00.000Z","uniqueQualifier":"9"},"actor":{"email":"it@kestrel.example"},"events":[{"type":"DOMAIN_SETTINGS","name":"AUTHORIZE_API_CLIENT_ACCESS","parameters":[{"name":"API_CLIENT_NAME","value":"104857600000000000001"},{"name":"API_SCOPES","value":"https://mail.google.com/"},{"name":"DOMAIN_NAME","value":"kestrel.example"}]}]}]}"#)
        service.answers[admin + "?eventName=REMOVE_API_CLIENT_ACCESS&" + since] = (200, #"{"items":[]}"#)
        let apps = try await callTool(GoogleWorkspace.adapter, "oauth-apps", #"{"since":"2026-06-01T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(apps.isError, apps.text)
        for expected in ["Domain-wide delegation", "client 104857600000000000001", "reads and sends mail", "authorized by it@kestrel.example at 2026-11-15T03:00:00.000Z",
                         "not removed since", "admin.google.com/ac/owl/domainwidedelegation"] {
            XCTAssertTrue(apps.text.contains(expected), "\(expected) missing from:\n\(apps.text)")
        }
        XCTAssertFalse(apps.text.contains("No app was granted access"), "a delegation grant is an app granted access:\n\(apps.text)")
        let delegated = try XCTUnwrap(apps.structured?["delegated"] as? [[String: Any]])
        XCTAssertEqual(delegated.first?["client"] as? String, "104857600000000000001")
    }

    /// A report that fails for a passing reason fails the whole check, so the watch does not move past what that report
    /// would have found and the next check reads the same window again. A report refused for good, such as one the
    /// edition lacks, does not hold the rest back, and is told as an alert of its own rather than dropped unsaid.
    func testAReportFailingForNowFailsTheAlertCheckSoNothingIsSkipped() async throws {
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
        func service(login: (Int, String)) -> FakeService {
            let service = FakeService()
            for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
            service.answers[reports + "admin"] = (200, #"{"items":[\#(Self.item(5, "GRANT_ADMIN_PRIVILEGE"))]}"#)
            service.answers[reports + "login"] = login
            return service
        }
        do {
            _ = try await GoogleWorkspace.adapter.alerts(since: since, connection: workspace, access: service(login: (503, #"{"error":{"code":503,"message":"Backend Error"}}"#)))
            XCTFail("a check that could not read the sign-in report succeeded, and the watch would move past it")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("login"), error.localizedDescription)
        }
        let refused = try await GoogleWorkspace.adapter.alerts(since: since, connection: workspace, access: service(login: (403, Self.notAuthorized)))
        XCTAssertEqual(refused.map(\.id).filter { $0.hasPrefix("admin/") }.count, 1, "a report refused for good held back what the others found")
        let told = refused.filter { $0.id.hasPrefix("unreadable/") }
        XCTAssertEqual(told.count, 1, "the refused report is told once, not per event")
        XCTAssertTrue(told.first?.id.hasPrefix("unreadable/login/") == true, "\(told)")
        XCTAssertEqual(told.first?.time, since, "told at the window's start, so it moves the watch past nothing")
        // What the wake's window reads back names the report and why, rather than saying nothing happened.
        let read = try await callTool(GoogleWorkspace.adapter, "security-events", #"{"since":"2026-11-14T00:00:00Z"}"#,
                                      on: service(login: (403, Self.notAuthorized)), in: workspace)
        XCTAssertTrue(read.text.contains("Could not read: login/"), read.text)
        XCTAssertTrue((read.structured?["couldNotRead"] as? [String])?.contains("login/suspicious_login") == true, read.text)
    }

    /// A report that keeps failing for a passing reason holds the watch back for a few checks only; then the rest is
    /// read and it is told as unreadable, and once it answers again a new failure holds the watch back afresh.
    func testAReportThatKeepsFailingForNowStopsHoldingTheWatchBack() async throws {
        let account = try GoogleWorkspace.preset.makeConnection(name: "Workspace — failing", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
        let service = FakeService()
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        service.answers[reports + "admin"] = (200, #"{"items":[\#(Self.item(5, "GRANT_ADMIN_PRIVILEGE"))]}"#)
        let unavailable = (503, #"{"error":{"code":503,"message":"Backend Error"}}"#)
        service.answers[reports + "rules"] = unavailable
        for check in 1...GoogleWorkspace.NewSecurityEvents.holdChecks {
            do {
                _ = try await GoogleWorkspace.adapter.alerts(since: since, connection: account, access: service)
                XCTFail("check \(check) moved past a report failing for now")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("rules/rule_trigger"), error.localizedDescription)
            }
        }
        let given = try await GoogleWorkspace.adapter.alerts(since: since, connection: account, access: service)
        XCTAssertEqual(given.map(\.id).filter { !$0.hasPrefix("unreadable/rules/") }, ["admin/2026-11-14T09:05:00.000Z/5/GRANT_ADMIN_PRIVILEGE/0"])
        XCTAssertEqual(given.filter { $0.id.hasPrefix("unreadable/rules/") }.count, 1, "\(given)")
        let still = try await GoogleWorkspace.adapter.alerts(since: since, connection: account, access: service)
        XCTAssertEqual(still.map(\.id), ["admin/2026-11-14T09:05:00.000Z/5/GRANT_ADMIN_PRIVILEGE/0"], "told again while it still fails")
        service.answers[reports + "rules"] = (200, #"{"items":[]}"#)
        let back = try await GoogleWorkspace.adapter.alerts(since: since, connection: account, access: service)
        XCTAssertEqual(back.map(\.id), ["admin/2026-11-14T09:05:00.000Z/5/GRANT_ADMIN_PRIVILEGE/0"])
        service.answers[reports + "rules"] = unavailable
        do {
            _ = try await GoogleWorkspace.adapter.alerts(since: since, connection: account, access: service)
            XCTFail("a report failing anew did not hold the watch back")
        } catch {}
    }

    /// A report that answers again on a check another report holds back has its outage forgotten there, so when it
    /// stops answering again the new outage is told.
    func testAReportThatAnswersOnAHeldCheckIsToldAgainWhenItStopsAgain() async throws {
        let account = try GoogleWorkspace.preset.makeConnection(name: "Workspace — flapping", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
        let service = FakeService()
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        service.answers[reports + "rules"] = (403, Self.notAuthorized)
        let first = try await GoogleWorkspace.adapter.alerts(since: since, connection: account, access: service)
        XCTAssertEqual(first.filter { $0.id.hasPrefix("unreadable/rules/") }.count, 1, "\(first)")
        service.answers[reports + "rules"] = (200, #"{"items":[]}"#)
        service.answers[reports + "login"] = (503, #"{"error":{"code":503,"message":"Backend Error"}}"#)
        do {
            _ = try await GoogleWorkspace.adapter.alerts(since: since, connection: account, access: service)
            XCTFail("a check that could not read the sign-in report for now moved on")
        } catch {}
        service.answers[reports + "rules"] = (403, Self.notAuthorized)
        service.answers[reports + "login"] = (200, #"{"items":[]}"#)
        let again = try await GoogleWorkspace.adapter.alerts(since: since, connection: account, access: service)
        let told = again.filter { $0.id.hasPrefix("unreadable/rules/") }
        XCTAssertEqual(told.count, 1, "the second outage was not told: \(again)")
        XCTAssertNotEqual(told.first?.id, first.first { $0.id.hasPrefix("unreadable/rules/") }?.id, "told with the first outage's ID")
    }

    /// A burst of one watched event, such as a rule firing hundreds of times, cannot push an older suspicious sign-in
    /// out of what one check takes in: each watched event takes its turn.
    func testABurstOfOneWatchedEventCannotCrowdOutTheRest() async throws {
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        let service = FakeService()
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        let rules = (0..<600).map { Self.item(1_000 + $0, "rule_trigger", parameters: #"{"name":"severity","value":"HIGH"}"#) }
        service.answers[reports + "rules"] = (200, #"{"items":[\#(rules.joined(separator: ","))]}"#)
        service.answers[reports + "login"] = (200, #"{"items":[{"id":{"time":"2026-11-14T08:00:00.000Z","uniqueQualifier":"1"},"actor":{"email":"m.okafor@kestrel.example"},"events":[{"name":"suspicious_login"}]}]}"#)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
        let found = try await GoogleWorkspace.adapter.alerts(since: since, connection: workspace, access: service)
        XCTAssertEqual(found.count, ServiceAlert.most)
        XCTAssertTrue(found.contains { $0.id == "login/2026-11-14T08:00:00.000Z/1/suspicious_login/0" }, "the rule's burst crowded out the sign-in")
        XCTAssertEqual(found.map(\.time), found.map(\.time).sorted(by: >), "newest first")
        let read = try await callTool(GoogleWorkspace.adapter, "security-events", #"{"since":"2026-11-14T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertTrue(read.text.contains("suspicious_login"), "the first lines a burst fills still show the sign-in")
    }

    /// A report whose later page fails keeps the pages read before it and says it was read only in part, and why; a
    /// first page that fails is still a failure.
    func testALaterPageThatFailsKeepsWhatWasReadAndSaysSo() async throws {
        let service = FakeService()
        let user = "/admin/reports/v1/activity/users/ivana@kestrel.example/applications/"
        for application in GoogleWorkspace.UserTimeline.applications { service.answers[user + application] = (200, "{}") }
        service.answers["/admin/reports/v1/activity/users/all/applications/admin"] = (200, "{}")
        let unavailable = (503, #"{"error":{"code":503,"message":"Backend Error"}}"#)
        service.sequences[user + "drive"] = [(200, #"{"items":[\#(Self.item(1, "download"))],"nextPageToken":"p2"}"#), unavailable]
        let timeline = try await callTool(GoogleWorkspace.adapter, "user-timeline", #"{"user":"ivana@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertFalse(timeline.isError, timeline.text)
        XCTAssertTrue(timeline.text.contains("drive") && timeline.text.contains("download"), "the page read was lost:\n\(timeline.text)")
        XCTAssertTrue(timeline.text.contains("Read only in part: drive (a later page could not be read"), timeline.text)
        XCTAssertNotNil((timeline.structured?["partlyRead"] as? [String: String])?["drive"], timeline.text)
        XCTAssertFalse((timeline.structured?["couldNotRead"] as? [String])?.contains("drive") == true)

        let login = "/admin/reports/v1/activity/users/all/applications/login"
        service.sequences[login] = [(200, #"{"items":[\#(Self.item(2))],"nextPageToken":"p2"}"#), unavailable]
        let activity = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"login"}"#, on: service, in: workspace)
        XCTAssertFalse(activity.isError, activity.text)
        XCTAssertTrue(activity.text.contains("login_success") && activity.text.contains("Read only in part"), activity.text)
        XCTAssertEqual(activity.structured?["more"] as? Bool, true)
        XCTAssertNotNil(activity.structured?["partlyRead"] as? String)
        service.sequences[login] = [unavailable]
        let first = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"login"}"#, on: service, in: workspace)
        XCTAssertTrue(first.isError, first.text)
    }

    /// A report Google answers in short pages that still carry a next page says there was more once its pages run out.
    func testAReportThatRunsOutOfPagesSaysThereWasMore() async throws {
        let service = FakeService()
        let user = "/admin/reports/v1/activity/users/ivana@kestrel.example/applications/"
        for application in GoogleWorkspace.UserTimeline.applications { service.answers[user + application] = (200, "{}") }
        service.answers["/admin/reports/v1/activity/users/all/applications/admin"] = (200, "{}")
        service.sequences[user + "login"] = (0..<GoogleWorkspace.mostPages).map { (200, #"{"items":[\#(Self.item($0))],"nextPageToken":"p\#($0 + 1)"}"#) }
        let timeline = try await callTool(GoogleWorkspace.adapter, "user-timeline", #"{"user":"ivana@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertEqual(service.requests.filter { $0.url?.path == user + "login" }.count, GoogleWorkspace.mostPages)
        XCTAssertEqual(timeline.structured?["cutShort"] as? [String], ["login"], timeline.text)
        XCTAssertTrue(timeline.text.contains("Cut short, with more not read: login"), timeline.text)
    }

    /// A timeline that found nothing says so only when every report was read; otherwise it names what could not be
    /// checked, including what admins did to a deleted account, which its profile ID cannot be asked for by.
    func testATimelineThatFoundNothingSaysWhatItCouldNotCheck() async throws {
        let service = FakeService()
        let user = "/admin/reports/v1/activity/users/ivana@kestrel.example/applications/"
        for application in GoogleWorkspace.UserTimeline.applications { service.answers[user + application] = (200, "{}") }
        service.answers["/admin/reports/v1/activity/users/all/applications/admin"] = (200, "{}")
        let quiet = try await callTool(GoogleWorkspace.adapter, "user-timeline", #"{"user":"ivana@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertTrue(quiet.text.hasPrefix("Nothing for ivana@kestrel.example in this window."), quiet.text)
        service.answers[user + "drive"] = (403, Self.notAuthorized)
        let gap = try await callTool(GoogleWorkspace.adapter, "user-timeline", #"{"user":"ivana@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertTrue(gap.text.hasPrefix("Nothing for ivana@kestrel.example in the reports that could be read; drive could not be checked."), gap.text)

        let deleted = "/admin/reports/v1/activity/users/104857600123456789012/applications/"
        for application in GoogleWorkspace.UserTimeline.applications { service.answers[deleted + application] = (200, "{}") }
        let leaver = try await callTool(GoogleWorkspace.adapter, "user-timeline", #"{"user":"104857600123456789012"}"#, on: service, in: workspace)
        XCTAssertFalse(leaver.isError, leaver.text)
        XCTAssertTrue(leaver.text.hasPrefix("Nothing for 104857600123456789012 in the reports that could be read; admin, about them could not be checked."), leaver.text)
        XCTAssertTrue(leaver.text.contains("Not read: admin, about them (admin events name an account by email"), leaver.text)
        XCTAssertEqual(leaver.structured?["skipped"] as? [String], ["admin, about them"])
    }

    /// A timeline over more than 30 days reads Gmail for the window's last 30 days, which Google takes, and says so,
    /// rather than losing Gmail entirely.
    func testATimelineOverThirtyDaysReadsGmailForItsLastThirty() async throws {
        let service = FakeService()
        let user = "/admin/reports/v1/activity/users/ivana@kestrel.example/applications/"
        for application in GoogleWorkspace.UserTimeline.applications { service.answers[user + application] = (200, "{}") }
        service.answers["/admin/reports/v1/activity/users/all/applications/admin"] = (200, "{}")
        let timeline = try await callTool(GoogleWorkspace.adapter, "user-timeline",
            #"{"user":"ivana@kestrel.example","since":"2026-06-01T00:00:00Z","until":"2026-09-01T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(timeline.isError, timeline.text)
        let gmail = try XCTUnwrap(service.requests.first { $0.url?.path == user + "gmail" })
        XCTAssertEqual(queryItems(gmail)["startTime"], "2026-08-02T00:00:00Z")
        XCTAssertEqual(queryItems(gmail)["endTime"], "2026-09-01T00:00:00Z")
        XCTAssertEqual(queryItems(service.requests.first { $0.url?.path == user + "login" })["startTime"], "2026-06-01T00:00:00Z")
        XCTAssertTrue(timeline.text.contains("Searched:") && timeline.text.contains("gmail"), timeline.text)
        XCTAssertTrue(timeline.text.contains("Read only in part: gmail (only the window's last 30 days, from 2026-08-02T00:00:00Z"), timeline.text)
        XCTAssertTrue(timeline.text.hasPrefix("Nothing for ivana@kestrel.example in the reports that could be read; gmail was read only in part."), timeline.text)
        XCTAssertNotNil((timeline.structured?["partlyRead"] as? [String: String])?["gmail"])
    }

    /// An action an app took for a user names the app's client ID and whether it impersonated them, so it can be tied to
    /// the grant or delegation that let it.
    func testAnEventKeepsTheAppThatActedAndWhetherItImpersonated() async throws {
        let service = FakeService()
        service.answers["/admin/reports/v1/activity/users/all/applications/drive"] = (200, #"{"items":[{"id":{"time":"2026-11-15T03:00:00.000Z","uniqueQualifier":"1"},"actor":{"email":"ivana@kestrel.example","applicationInfo":{"applicationName":"Backup Tool","oauthClientId":"104857600000000000001","impersonation":true}},"events":[{"name":"download","parameters":[{"name":"doc_title","value":"Payroll"}]}]},{"id":{"time":"2026-11-15T02:00:00.000Z","uniqueQualifier":"2"},"actor":{"email":"nick@kestrel.example","applicationInfo":{"applicationName":"Backup Tool","oauthClientId":"222"}},"events":[{"name":"download","parameters":[]}]}]}"#)
        let activity = try await callTool(GoogleWorkspace.adapter, "activity", #"{"application":"drive"}"#, on: service, in: workspace)
        XCTAssertFalse(activity.isError, activity.text)
        XCTAssertTrue(activity.text.contains("via Backup Tool (client 104857600000000000001, impersonating the user)"), activity.text)
        XCTAssertTrue(activity.text.contains("via Backup Tool (client 222)"), activity.text)
        let events = try XCTUnwrap(activity.structured?["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["viaClient"] as? String, "104857600000000000001")
        XCTAssertEqual(events.first?["impersonated"] as? Bool, true)
    }

    /// Google calls suspicious_login a blocked sign-in; one that succeeded is a login_success marked suspicious. Role
    /// changes that widen an admin role, and the Groups Enterprise report's member changes, are read too.
    func testTheWatchCoversSuspiciousSignInsThatSucceededAndRolesWidened() async throws {
        let admin = Set(GoogleWorkspace.watched.filter { $0.application == "admin" }.map(\.event))
        XCTAssertTrue(admin.isSuperset(of: ["ASSIGN_ROLE", "ADD_PRIVILEGE"]), "\(admin)")
        XCTAssertTrue(GoogleWorkspace.applications.contains("groups_enterprise"))
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        let service = FakeService()
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
        _ = try await GoogleWorkspace.adapter.alerts(since: since, connection: workspace, access: service)
        let success = try XCTUnwrap(service.requests.first { queryItems($0)["eventName"] == "login_success" })
        XCTAssertEqual(queryItems(success)["filters"], "is_suspicious==true")
        for request in service.requests {
            let label = "\(request.url!.lastPathComponent)/\(queryItems(request)["eventName"] ?? "")"
            XCTAssertEqual(queryItems(request)["filters"], GoogleWorkspace.watchedFilters[label], "only the reads that need a filter are filtered: \(label)")
        }
    }

    /// Containment's agents are told what the least-access role cannot do to an admin, to keep the evidence before
    /// suspending, and what restoring an account needs; Detection's, what to hand the champion to remediate.
    func testInstructionsCoverAdminsEvidenceRestoringAndRemediation() {
        let containment = GoogleWorkspace.containment.defaultInstructions
        for expected in ["super admin", "before suspend", "invalidate-backup-codes", "before unsuspend"] {
            XCTAssertTrue(containment.contains(expected), "Containment instructions lack \(expected)")
        }
        XCTAssertFalse(containment.contains("contain one with suspend"), "the least-access role cannot suspend an admin")
        let audit = GoogleWorkspace.preset.defaultInstructions
        for expected in ["file IDs", "Message-ID"] { XCTAssertTrue(audit.contains(expected), "Detection instructions lack \(expected)") }
    }

    // MARK: Second review

    /// oauth-apps says it is incomplete before anything else when a list was not read in full, never says a delegation
    /// was not removed when removals were read only in part, and names as revoking an app only those who revoked it
    /// after they last granted it.
    func testOAuthAppsSayWhatWasReadOnlyInPartAndWhoStillRevoked() async throws {
        let service = FakeService()
        let since = "maxResults=1000&startTime=2026-06-01T00:00:00Z"
        let token = "/admin/reports/v1/activity/users/all/applications/token", admin = "/admin/reports/v1/activity/users/all/applications/admin"
        func event(_ n: Int, _ time: String, _ user: String, _ name: String) -> String {
            #"{"id":{"time":"\#(time)","uniqueQualifier":"\#(n)"},"actor":{"email":"\#(user)"},"events":[{"name":"\#(name)","parameters":[{"name":"client_id","value":"333"},{"name":"app_name","value":"Inbox Sorter"},{"name":"scope","value":"https://www.googleapis.com/auth/gmail.send"}]}]}"#
        }
        service.answers[token + "?eventName=authorize&" + since] = (200, #"{"items":[\#(event(1, "2026-11-15T10:00:00.000Z", "a@kestrel.example", "authorize")),\#(event(2, "2026-11-15T08:00:00.000Z", "b@kestrel.example", "authorize"))]}"#)
        // a revoked it and granted it again later; b revoked it after granting it. A second page is not found.
        service.answers[token + "?eventName=revoke&" + since] = (200, #"{"items":[\#(event(3, "2026-11-15T11:00:00.000Z", "b@kestrel.example", "revoke")),\#(event(4, "2026-11-15T09:00:00.000Z", "a@kestrel.example", "revoke"))],"nextPageToken":"p2"}"#)
        service.answers[admin + "?eventName=AUTHORIZE_API_CLIENT_ACCESS&" + since] = (200, #"{"items":[{"id":{"time":"2026-11-15T03:00:00.000Z","uniqueQualifier":"9"},"actor":{"email":"it@kestrel.example"},"events":[{"name":"AUTHORIZE_API_CLIENT_ACCESS","parameters":[{"name":"API_CLIENT_NAME","value":"104857600000000000001"},{"name":"API_SCOPES","value":"https://mail.google.com/"}]}]}]}"#)
        service.answers[admin + "?eventName=REMOVE_API_CLIENT_ACCESS&" + since] = (200, #"{"items":[],"nextPageToken":"p2"}"#)
        let apps = try await callTool(GoogleWorkspace.adapter, "oauth-apps", #"{"since":"2026-06-01T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(apps.isError, apps.text)
        XCTAssertTrue(apps.text.hasPrefix("This result is incomplete: not all the revocations and delegation removals in this window were read"), apps.text)
        XCTAssertEqual(apps.structured?["incomplete"] as? [String], ["revocations", "delegation removals"])
        XCTAssertTrue(apps.text.contains("revoked by b@kestrel.example since they last granted it; revocations read only in part"), apps.text)
        XCTAssertFalse(apps.text.contains("revoked by a@kestrel.example") || apps.text.contains("b@kestrel.example, a@kestrel.example;"), apps.text)
        XCTAssertEqual((apps.structured?["apps"] as? [[String: Any]])?.first?["revokedBy"] as? [String], ["b@kestrel.example"])
        XCTAssertTrue(apps.text.contains("whether it was removed since is not known"), apps.text)
        XCTAssertFalse(apps.text.contains("not removed since"), apps.text)
    }

    /// app-activity and link-clicks lead with saying they are incomplete when they read only part of the window.
    func testActivityAndClickSummariesSayFirstWhenTheyAreIncomplete() async throws {
        let service = FakeService()
        let token = "/admin/reports/v1/activity/users/all/applications/token"
        service.answers[token] = (200, ##"{"items":[\##(Self.item(1, "activity", parameters: #"{"name":"app_name","value":"Backup Tool"},{"name":"client_id","value":"222"},{"name":"method_name","value":"gmail.users.messages.get"}"#))],"nextPageToken":"p2"}"##)
        service.sequences[token] = [(200, ##"{"items":[\##(Self.item(1, "activity", parameters: #"{"name":"app_name","value":"Backup Tool"},{"name":"client_id","value":"222"}"#))],"nextPageToken":"p2"}"##),
                                    (503, #"{"error":{"code":503,"message":"Backend Error"}}"#)]
        let calls = try await callTool(GoogleWorkspace.adapter, "app-activity", "{}", on: service, in: workspace)
        XCTAssertTrue(calls.text.hasPrefix("This result is incomplete"), calls.text)
        XCTAssertTrue(calls.text.contains("Read only in part: a later page could not be read"), calls.text)
        XCTAssertEqual(calls.structured?["incomplete"] as? Bool, true)
        let gmail = "/admin/reports/v1/activity/users/all/applications/gmail"
        service.sequences[gmail] = [(200, #"{"items":[],"nextPageToken":"p2"}"#), (503, #"{"error":{"code":503,"message":"Backend Error"}}"#)]
        service.answers[gmail] = (200, "{}")
        let clicks = try await callTool(GoogleWorkspace.adapter, "link-clicks", #"{"link":"evil.example"}"#, on: service, in: workspace)
        XCTAssertTrue(clicks.text.hasPrefix("This result is incomplete: not every click"), clicks.text)
    }

    /// Scopes a consent-phishing app asks for, such as sending mail and changing forwarding, rank with reading mail,
    /// well above a calendar; Vault, Cloud Identity, documents, Apps Script and group settings are named too.
    func testAppRiskNamesTheScopesAConsentPhishingAppAsksFor() throws {
        let auth = "https://www.googleapis.com/auth/"
        let phishing = try XCTUnwrap(GoogleWorkspace.risk([auth + "gmail.send", auth + "gmail.settings.sharing"]))
        let calendar = try XCTUnwrap(GoogleWorkspace.risk([auth + "calendar"]))
        XCTAssertLessThan(phishing.rank, calendar.rank)
        XCTAssertTrue(phishing.said.contains("sends mail as the user") && phishing.said.contains("forwarding"), phishing.said)
        let expected: [(String, Int, String)] = [
            ("ediscovery", 0, "Vault"), ("cloud-identity.groups", 0, "Cloud Identity"), ("cloud-identity.groups.readonly", 4, "directory"),
            ("gmail.settings.basic", 1, "filters"), ("gmail.insert", 1, "puts messages"), ("documents", 2, "changes documents"),
            ("spreadsheets.readonly", 2, "reads documents, spreadsheets"), ("script.projects", 2, "Apps Script"),
            ("apps.groups.settings", 3, "group settings"), ("directory.readonly", 4, "directory"), ("ediscovery.readonly", 4, "Vault matters"),
        ]
        for (scope, rank, said) in expected {
            let risk = try XCTUnwrap(GoogleWorkspace.risk([auth + scope]), scope)
            XCTAssertEqual(risk.rank, rank, scope)
            XCTAssertTrue(risk.said.contains(said), "\(scope): \(risk.said)")
        }
        XCTAssertNil(GoogleWorkspace.risk([auth + "drive.file"]), "a file the user picked is not every file")
    }

    /// The app inventory says why each account could not be read, putting down to the role only what the role was
    /// refused, never Google being busy.
    func testTheAppInventorySaysWhyEachAccountCouldNotBeRead() async throws {
        let service = FakeService()
        let users = "/admin/directory/v1/users"
        service.answers[users] = (200, #"{"users":[{"primaryEmail":"admin@kestrel.example"},{"primaryEmail":"busy@kestrel.example"},{"primaryEmail":"nick@kestrel.example"}]}"#)
        service.answers[users + "/admin@kestrel.example/tokens"] = (403, Self.notAuthorized)
        service.answers[users + "/busy@kestrel.example/tokens"] = (503, #"{"error":{"code":503,"message":"Backend Error"}}"#)
        service.answers[users + "/nick@kestrel.example/tokens"] = (200, "{}")
        let apps = try await callTool(GoogleWorkspace.containmentAdapter, "apps", "{}", on: service, in: containment)
        XCTAssertFalse(apps.isError, apps.text)
        XCTAssertTrue(apps.text.contains("admin@kestrel.example, as User Security Management never covers admins"), apps.text)
        XCTAssertTrue(apps.text.contains("busy@kestrel.example, as Google was busy"), apps.text)
        XCTAssertFalse(apps.text.contains("busy@kestrel.example, as User Security"), apps.text)
        let reasons = try XCTUnwrap(apps.structured?["reasons"] as? [String: [String]])
        XCTAssertEqual(reasons.values.flatMap { $0 }.sorted(), ["admin@kestrel.example", "busy@kestrel.example"])
        XCTAssertEqual(apps.structured?["accountsChecked"] as? Int, 1)
    }

    /// An address in another of the organisation's verified domains or aliases is not flagged as outside; one in a
    /// subdomain the organisation does not list, or in a domain or alias not yet verified, is. When the domains cannot
    /// be read, the flag falls back to the group's own domain and says so.
    func testOutsideFlagsKnowTheOrganisationsVerifiedDomains() async throws {
        let service = FakeService()
        let directory = "/admin/directory/v1"
        service.answers[directory + "/groups/accounting@kestrel.example/members"] = (200, #"{"members":[{"email":"ivana@kestrel.co.uk","type":"USER"},{"email":"desk@kestrel-mail.example","type":"USER"},{"email":"bookkeeper@agency.example","type":"USER"},{"email":"bob@contractor.dept.kestrel.example","type":"USER"},{"email":"ops@mail.kestrel.example","type":"USER"},{"email":"old@kestrel-old.example","type":"USER"},{"email":"new@kestrel-new.example","type":"USER"}]}"#)
        let unread = try await callTool(GoogleWorkspace.adapter, "group-members", #"{"group":"accounting@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertTrue(unread.text.contains("ivana@kestrel.co.uk (outside the domain)") && unread.text.contains("could not be read"), unread.text)
        XCTAssertTrue(unread.text.contains("compare with the group's own domain"), unread.text)
        service.answers[directory + "/customer/my_customer/domains"] = (200, #"""
        {"domains":[{"domainName":"kestrel.example","isPrimary":true,"verified":true},
                    {"domainName":"mail.kestrel.example","verified":true},
                    {"domainName":"kestrel-old.example","verified":false},
                    {"domainName":"kestrel.co.uk","verified":true,"domainAliases":[{"domainAliasName":"kestrel-mail.example","verified":true},
                                                                                  {"domainAliasName":"kestrel-new.example","verified":false}]}]}
        """#)
        let members = try await callTool(GoogleWorkspace.adapter, "group-members", #"{"group":"accounting@kestrel.example"}"#, on: service, in: workspace)
        for outside in ["bookkeeper@agency.example", "bob@contractor.dept.kestrel.example", "old@kestrel-old.example", "new@kestrel-new.example"] {
            XCTAssertTrue(members.text.contains(outside + " (outside the domain)"), "\(outside) not flagged:\n\(members.text)")
        }
        for inside in ["ivana@kestrel.co.uk", "desk@kestrel-mail.example", "ops@mail.kestrel.example"] {
            XCTAssertFalse(members.text.contains(inside + " (outside"), "\(inside) flagged:\n\(members.text)")
        }
        XCTAssertFalse(members.text.contains("could not be read"), members.text)
        service.answers[directory + "/users"] = (200, #"{"users":[{"primaryEmail":"ivana@kestrel.example","isEnrolledIn2Sv":true,"recoveryEmail":"ivana@kestrel.co.uk"},{"primaryEmail":"nick@kestrel.example","isEnrolledIn2Sv":true,"recoveryEmail":"nick@sub.kestrel.example"}]}"#)
        let users = try await callTool(GoogleWorkspace.adapter, "users", "{}", on: service, in: workspace)
        XCTAssertFalse(users.text.contains("recovery email outside the domain: ivana@kestrel.co.uk"), users.text)
        XCTAssertTrue(users.text.contains("recovery email outside the domain: nick@sub.kestrel.example"), users.text)
    }

    /// The app inventory reads accounts a few at a time across several batches, and still says why each one that
    /// failed could not be read, grouped by reason.
    func testTheAppInventoryAcrossSeveralBatchesGroupsEachFailureByReason() async throws {
        XCTAssertLessThan(GoogleWorkspace.Apps.atOnce * 2, 20, "fewer than two full batches")
        let service = FakeService()
        service.answerDelay = 0.01
        let users = "/admin/directory/v1/users"
        let emails = (0..<20).map { "u\($0)@kestrel.example" }
        service.answers[users] = (200, #"{"users":[\#(emails.map { #"{"primaryEmail":"\#($0)"}"# }.joined(separator: ","))]}"#)
        let denied = ["u3@kestrel.example", "u11@kestrel.example"], busy = ["u9@kestrel.example", "u17@kestrel.example"]
        for email in emails {
            service.answers[users + "/\(email)/tokens"] = denied.contains(email) ? (403, Self.notAuthorized)
                : busy.contains(email) ? (503, #"{"error":{"code":503,"message":"Backend Error"}}"#)
                : (200, #"{"items":[{"clientId":"222","displayText":"Mail Helper","scopes":["https://mail.google.com/"]}]}"#)
        }
        let apps = try await callTool(GoogleWorkspace.containmentAdapter, "apps", "{}", on: service, in: containment)
        XCTAssertFalse(apps.isError, apps.text)
        XCTAssertEqual(apps.structured?["accountsChecked"] as? Int, 16)
        XCTAssertEqual(apps.structured?["accountsTried"] as? Int, 20)
        let reasons = try XCTUnwrap(apps.structured?["reasons"] as? [String: [String]])
        XCTAssertEqual(reasons.count, 2, "\(reasons)")
        XCTAssertEqual(reasons.first { $0.key.hasPrefix("User Security Management") }?.value, denied.sorted())
        XCTAssertEqual(reasons.first { $0.key.hasPrefix("Google was busy") }?.value, busy.sorted())
        XCTAssertTrue(apps.text.contains("Mail Helper (222)") && apps.text.contains("held by 16 users"), apps.text)
        XCTAssertEqual(service.requests.filter { $0.url?.path.hasSuffix("/tokens") == true }.count, 20, "an account was read twice or not at all")
    }

    /// A device's suspicious activity wakes the agents only when its integrity or Google's management of it changed,
    /// not for a new model or Wi-Fi address.
    func testTheWatchTakesADevicesSuspiciousActivityOnlyForItsIntegrity() async throws {
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        let service = FakeService()
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        service.answers[reports + "mobile"] = (200, ##"{"items":[\##(Self.item(1, "SUSPICIOUS_ACTIVITY_EVENT", parameters: #"{"name":"DEVICE_PROPERTY","value":"DEVICE_MODEL"}"#)),\##(Self.item(2, "SUSPICIOUS_ACTIVITY_EVENT", parameters: #"{"name":"DEVICE_PROPERTY","value":"DEVICE_BOOTLOADER"}"#))]}"##)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
        let found = try await GoogleWorkspace.adapter.alerts(since: since, connection: workspace, access: service)
        XCTAssertEqual(found.map(\.id), ["mobile/2026-11-14T09:02:00.000Z/2/SUSPICIOUS_ACTIVITY_EVENT/0"])
    }

    /// A role holder the users do not know is labelled as no person's account, as a service account given a role shows
    /// only its ID.
    func testAdminRolesLabelAHolderThatIsNotAUser() async throws {
        let service = FakeService()
        let directory = "/admin/directory/v1"
        service.answers[directory + "/users"] = (200, #"{"users":[]}"#)
        service.answers[directory + "/customer/my_customer/roles"] = (200, #"{"items":[{"roleId":"r-1","roleName":"User Management","rolePrivileges":[]}]}"#)
        service.answers[directory + "/customer/my_customer/roleassignments"] = (200, #"{"items":[{"roleId":"r-1","assignedTo":"112233445566778899","assigneeType":"USER","scopeType":"CUSTOMER"}]}"#)
        let roles = try await callTool(GoogleWorkspace.adapter, "admin-roles", "{}", on: service, in: workspace)
        XCTAssertTrue(roles.text.contains("112233445566778899 (not a user: possibly a service account"), roles.text)
    }

    /// Agents are told the mobile report's events include laptops and desktops enrolled through endpoint verification.
    func testInstructionsSayTheMobileReportCoversEnrolledLaptops() {
        let audit = GoogleWorkspace.preset.defaultInstructions
        XCTAssertTrue(audit.contains("endpoint verification") && audit.contains("DESKTOP_CHROME"), audit)
    }

    /// The watch over every watched report, each answering nothing but what `answers` gives it, from 2026-11-14.
    private func watch(_ answers: [String: (Int, String)], service: FakeService = FakeService()) async throws -> [ServiceAlert] {
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        for (report, answer) in answers { service.answers[reports + report] = answer }
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T00:00:00Z"))
        return try await GoogleWorkspace.adapter.alerts(since: since, connection: workspace, access: service)
    }

    /// An admin taking over someone else's account wakes the agents: a recovery phone set, a security key added or
    /// taken away, Advanced Protection or security-key-only sign-in turned off, a blocked session let through, a
    /// password reset or its temporary password viewed. An admin changing a name does not.
    func testTheWatchWakesForAnAdminTakingOverAnAccount() async throws {
        let watched = Set(GoogleWorkspace.watched.filter { $0.application == "admin" }.map(\.event))
        for event in ["CHANGE_RECOVERY_PHONE", "ADD_RECOVERY_PHONE", "SECURITY_KEY_REGISTERED_FOR_USER", "REVOKE_SECURITY_KEY", "UNENROLL_USER_FROM_TITANIUM",
                      "UNENROLL_USER_FROM_STRONG_AUTH", "UNBLOCK_USER_SESSION", "CHANGE_PASSWORD", "VIEW_TEMP_PASSWORD"] {
            XCTAssertTrue(watched.contains(event), event)
        }
        let user = #"{"name":"USER_EMAIL","value":"cfo@kestrel.example"}"#
        let admin = [Self.item(1, "CHANGE_RECOVERY_PHONE", parameters: user), Self.item(2, "SECURITY_KEY_REGISTERED_FOR_USER", parameters: user),
                     Self.item(3, "CHANGE_PASSWORD", parameters: user), Self.item(4, "CHANGE_FIRST_NAME", parameters: user)]
        let found = try await watch(["admin": (200, #"{"items":[\#(admin.joined(separator: ","))]}"#)])
        XCTAssertEqual(found.map(\.id), ["admin/2026-11-14T09:03:00.000Z/3/CHANGE_PASSWORD/0", "admin/2026-11-14T09:02:00.000Z/2/SECURITY_KEY_REGISTERED_FOR_USER/0",
                                         "admin/2026-11-14T09:01:00.000Z/1/CHANGE_RECOVERY_PHONE/0"])
    }

    /// When a check holds more than it keeps, an admin resetting a password, which some organisations do every day, takes
    /// its turn after the sign-ins and the takeovers, and before devices and rules; exports and apps come after the
    /// admin changes.
    func testAPasswordResetTakesItsTurnAfterSignInsAndTakeovers() {
        func event(_ application: String, _ name: String, _ minute: Int) -> GoogleWorkspace.Event {
            GoogleWorkspace.Event(id: "\(application)/\(name)/\(minute)", time: String(format: "2026-11-14T09:%02d:00Z", minute), application: application,
                                  user: nil, ip: nil, event: name, parameters: [:])
        }
        let events = [event("admin", "CHANGE_PASSWORD", 9), event("rules", "rule_trigger", 8), event("token", "authorize", 7), event("mobile", "APPLICATION_EVENT", 6),
                      event("admin", "CREATE_DATA_TRANSFER_REQUEST", 5), event("admin", "CHANGE_RECOVERY_PHONE", 4), event("login", "suspicious_login", 3)]
        XCTAssertEqual(GoogleWorkspace.inTurn(events, most: 2).map(\.event), ["CHANGE_RECOVERY_PHONE", "suspicious_login"])
        XCTAssertEqual(GoogleWorkspace.inTurn(events, most: 3).map(\.event), ["CHANGE_PASSWORD", "CHANGE_RECOVERY_PHONE", "suspicious_login"])
        XCTAssertEqual(GoogleWorkspace.inTurn(events, most: 5).map(\.event),
                       ["CHANGE_PASSWORD", "authorize", "CREATE_DATA_TRANSFER_REQUEST", "CHANGE_RECOVERY_PHONE", "suspicious_login"])
        let six = GoogleWorkspace.inTurn(events, most: 6).map(\.event)
        XCTAssertTrue(six.contains("APPLICATION_EVENT") && !six.contains("rule_trigger"), "devices before rules: \(six)")
    }

    /// A domain mail routing, compliance or other mail setting added or changed wakes the agents, as it can send or copy
    /// mail out without any user's settings showing it.
    func testTheWatchWakesForDomainMailRules() async throws {
        let rule = #"{"name":"SETTING_NAME","value":"MESSAGE_SECURITY_RULE"},{"name":"USER_DEFINED_SETTING_NAME","value":"Copy finance"}"#
        let admin = [Self.item(1, "CREATE_GMAIL_SETTING", parameters: rule), Self.item(2, "CHANGE_GMAIL_SETTING", parameters: rule),
                     Self.item(3, "CHANGE_EMAIL_SETTING", parameters: #"{"name":"SETTING_NAME","value":"AUTO_FORWARDING"}"#),
                     Self.item(4, "RELEASE_FROM_QUARANTINE")]
        let found = try await watch(["admin": (200, #"{"items":[\#(admin.joined(separator: ","))]}"#)])
        XCTAssertEqual(found.map(\.id), ["admin/2026-11-14T09:03:00.000Z/3/CHANGE_EMAIL_SETTING/0", "admin/2026-11-14T09:02:00.000Z/2/CHANGE_GMAIL_SETTING/0",
                                         "admin/2026-11-14T09:01:00.000Z/1/CREATE_GMAIL_SETTING/0"])
    }

    /// An app granted access to read or send mail, read files or administer the domain wakes the agents, as consent
    /// phishing asks for; a calendar app or a sign-in with Google does not. The grants are read further than other
    /// events, as most are left out.
    func testTheWatchWakesForAnAppGrantedMailOrFilesButNotForALowRiskOne() async throws {
        let mail = #"{"name":"app_name","value":"Mail Helper"},{"name":"scope","multiValue":["openid","https://mail.google.com/"]}"#
        let drive = #"{"name":"app_name","value":"PDF Tools"},{"name":"scope","multiValue":["https://www.googleapis.com/auth/drive.readonly"]}"#
        let calendar = #"{"name":"app_name","value":"Reclaim.ai"},{"name":"scope","multiValue":["https://www.googleapis.com/auth/calendar"]}"#
        let signIn = #"{"name":"app_name","value":"Zoom"},{"name":"scope","multiValue":["openid","https://www.googleapis.com/auth/userinfo.email","https://www.googleapis.com/auth/userinfo.profile"]}"#
        let service = FakeService()
        let grants = [Self.item(1, "authorize", parameters: mail), Self.item(2, "authorize", parameters: drive), Self.item(3, "authorize", parameters: calendar),
                      Self.item(4, "authorize", parameters: signIn)]
        let found = try await watch(["token": (200, #"{"items":[\#(grants.joined(separator: ","))]}"#)], service: service)
        XCTAssertEqual(found.map(\.id), ["token/2026-11-14T09:02:00.000Z/2/authorize/0", "token/2026-11-14T09:01:00.000Z/1/authorize/0"])
        let read = try XCTUnwrap(service.requests.first { $0.url?.lastPathComponent == "token" })
        XCTAssertEqual(queryItems(read)["eventName"], "authorize")
        XCTAssertEqual(queryItems(read)["maxResults"], "1000")
        let quiet = try await watch(["token": (200, #"{"items":[\#(Self.item(3, "authorize", parameters: calendar)),\#(Self.item(4, "authorize", parameters: signIn))]}"#)])
        XCTAssertEqual(quiet, [])
    }

    /// A Takeout started or scheduled, a Vault export made or a retention rule changed or deleted, and an admin moving an
    /// account's data to someone else wake the agents; a Takeout completing or downloaded, and a Vault search, do not.
    /// The Takeout and Vault reports are read whole.
    func testTheWatchWakesForExportsAndRetentionChanges() async throws {
        let service = FakeService()
        let takeout = [Self.item(1, "STARTED_USER_TAKEOUT", parameters: #"{"name":"INITIATED_BY","value":"admin"}"#), Self.item(2, "SCHEDULED_USER_TAKEOUT"),
                       Self.item(3, "COMPLETED_USER_TAKEOUT"), Self.item(4, "DOWNLOADED_USER_TAKEOUT")]
        let vault = [Self.item(5, "create_export_begin"), Self.item(6, "delete_retention_rule_begin"), Self.item(7, "update_retention_rule_begin"),
                     Self.item(8, "modify_default_retention_period_begin"), Self.item(9, "search"), Self.item(10, "view_document")]
        let found = try await watch(["takeout": (200, #"{"items":[\#(takeout.joined(separator: ","))]}"#),
                                     "vault": (200, #"{"items":[\#(vault.joined(separator: ","))]}"#),
                                     "admin": (200, #"{"items":[\#(Self.item(11, "CREATE_DATA_TRANSFER_REQUEST", parameters: #"{"name":"DESTINATION_USER_EMAIL","value":"x@kestrel.example"}"#))]}"#)],
                                    service: service)
        XCTAssertEqual(Set(found.map { String($0.id.split(separator: "/")[3]) }),
                       ["STARTED_USER_TAKEOUT", "SCHEDULED_USER_TAKEOUT", "create_export_begin", "delete_retention_rule_begin", "update_retention_rule_begin",
                        "modify_default_retention_period_begin", "CREATE_DATA_TRANSFER_REQUEST"])
        for report in ["takeout", "vault"] {
            XCTAssertEqual(service.requests.filter { $0.url?.lastPathComponent == report }.map { queryItems($0)["eventName"] }, [nil], report)
        }
    }

    /// The domain's defences loosened wake the agents: 2-step verification's enforcement or methods, less secure apps,
    /// API access, apps trusted, context-aware access, sessions, password recovery, a new domain or alias, and a role made
    /// or changed. Methods narrowed to security keys only tighten them, and do not.
    func testTheWatchWakesForDefencesLoosened() async throws {
        let watched = Set(GoogleWorkspace.watched.filter { $0.application == "admin" }.map(\.event))
        for event in ["ENFORCE_STRONG_AUTHENTICATION", "ALLOW_STRONG_AUTHENTICATION", "CHANGE_ALLOWED_TWO_STEP_VERIFICATION_METHODS",
                      "WEAK_PROGRAMMATIC_LOGIN_SETTINGS_CHANGED", "TOGGLE_OAUTH_ACCESS_TO_ALL_APIS", "ENABLE_API_ACCESS", "ALLOW_SERVICE_FOR_OAUTH2_ACCESS",
                      "ADD_TO_TRUSTED_BY_OAUTH_SCOPE_OAUTH2_APPS", "MULTIPLE_ADD_TO_TRUSTED_OAUTH2_APPS", "MULTIPLE_ADD_TO_TRUSTED_BY_OAUTH_SCOPE_OAUTH2_APPS",
                      "TRUST_DOMAIN_OWNED_OAUTH2_APPS", "TOGGLE_CAA_ENABLEMENT", "CHANGE_CAA_APP_ASSIGNMENTS", "SESSION_CONTROL_SETTINGS_CHANGE",
                      "CHANGE_SESSION_LENGTH", "ENABLE_NON_ADMIN_USER_PASSWORD_RECOVERY", "TOGGLE_ALLOW_ADMIN_PASSWORD_RESET", "ADD_SECONDARY_DOMAIN",
                      "ADD_DOMAIN_ALIAS", "CREATE_ROLE", "UPDATE_ROLE"] {
            XCTAssertTrue(watched.contains(event), event)
        }
        let method = { (value: String) in #"{"name":"ALLOWED_TWO_STEP_VERIFICATION_METHOD","value":"\#(value)"}"# }
        let admin = [Self.item(1, "CHANGE_ALLOWED_TWO_STEP_VERIFICATION_METHODS", parameters: method("ANY")),
                     Self.item(2, "CHANGE_ALLOWED_TWO_STEP_VERIFICATION_METHODS", parameters: method("ONLY_SECURITY_KEY")),
                     Self.item(3, "WEAK_PROGRAMMATIC_LOGIN_SETTINGS_CHANGED"), Self.item(4, "ADD_SECONDARY_DOMAIN"), Self.item(5, "CREATE_ROLE"),
                     Self.item(6, "BLOCK_ALL_THIRD_PARTY_API_ACCESS")]
        let found = try await watch(["admin": (200, #"{"items":[\#(admin.joined(separator: ","))]}"#)])
        XCTAssertEqual(found.map(\.id), ["admin/2026-11-14T09:05:00.000Z/5/CREATE_ROLE/0", "admin/2026-11-14T09:04:00.000Z/4/ADD_SECONDARY_DOMAIN/0",
                                         "admin/2026-11-14T09:03:00.000Z/3/WEAK_PROGRAMMATIC_LOGIN_SETTINGS_CHANGED/0",
                                         "admin/2026-11-14T09:01:00.000Z/1/CHANGE_ALLOWED_TWO_STEP_VERIFICATION_METHODS/0"])
    }

    /// A sensitive action let through for a session Google found suspicious, and a passkey removed, wake the agents; a
    /// sensitive action in an ordinary session does not, even when Google sends it despite the filter.
    func testTheWatchWakesForASuspiciousSessionsSensitiveActionAndARemovedPasskey() async throws {
        let service = FakeService()
        let login = [Self.item(1, "risky_sensitive_action_allowed", parameters: #"{"name":"is_suspicious","boolValue":true},{"name":"sensitive_action_name","value":"CHANGE_RECOVERY"}"#),
                     Self.item(2, "risky_sensitive_action_allowed", parameters: #"{"name":"is_suspicious","boolValue":false}"#),
                     Self.item(3, "passkey_removed")]
        let found = try await watch(["login": (200, #"{"items":[\#(login.joined(separator: ","))]}"#)], service: service)
        XCTAssertEqual(found.map(\.id), ["login/2026-11-14T09:03:00.000Z/3/passkey_removed/0", "login/2026-11-14T09:01:00.000Z/1/risky_sensitive_action_allowed/0"])
        let allowed = try XCTUnwrap(service.requests.first { queryItems($0)["eventName"] == "risky_sensitive_action_allowed" })
        XCTAssertEqual(queryItems(allowed)["filters"], "is_suspicious==true")
        XCTAssertFalse(GoogleWorkspace.watched.contains { ["CREATE_USER", "UNDELETE_USER", "UNSUSPEND_USER"].contains($0.event) },
                       "accounts made or brought back are routine, and would wake the agents every day")
    }

    /// A harmful app found on a phone wakes the agents; an app installed or updated does not.
    func testTheWatchWakesForAHarmfulAppOnAPhone() async throws {
        let service = FakeService()
        let mobile = [Self.item(1, "APPLICATION_EVENT", parameters: #"{"name":"APPLICATION_STATE","value":"PHA"},{"name":"APPLICATION_ID","value":"com.example.flashlight"}"#),
                      Self.item(2, "APPLICATION_EVENT", parameters: #"{"name":"APPLICATION_STATE","value":"INSTALLED"}"#)]
        let found = try await watch(["mobile": (200, #"{"items":[\#(mobile.joined(separator: ","))]}"#)], service: service)
        XCTAssertEqual(found.map(\.id), ["mobile/2026-11-14T09:01:00.000Z/1/APPLICATION_EVENT/0"])
        let read = try XCTUnwrap(service.requests.first { queryItems($0)["eventName"] == "APPLICATION_EVENT" })
        XCTAssertEqual(queryItems(read)["filters"], "APPLICATION_STATE==PHA")
    }

    /// A report read whole that holds more than the watch reads in one go, as a busy domain's admin report may, is read
    /// event by event too, so a privilege granted among thousands of ordinary changes still wakes the agents, and the
    /// report is not said to be cut short. Google takes a filter only with an event's name, so no report read whole
    /// needs one.
    func testABusyReportReadWholeIsReadEventByEventSoNothingIsCutOff() async throws {
        XCTAssertTrue(GoogleWorkspace.watchedFilters.keys.allSatisfy { !GoogleWorkspace.readWhole.contains(String($0.prefix { $0 != "/" })) })
        let admin = "/admin/reports/v1/activity/users/all/applications/admin"
        let noise = (0..<1000).map { Self.item(10_000 + $0, "CHANGE_USER_ORGANIZATION") }.joined(separator: ",")
        let service = FakeService()
        service.sequences[admin] = Array(repeating: (200, #"{"items":[\#(noise)],"nextPageToken":"more"}"#), count: GoogleWorkspace.mostRead / 1000)
        service.answers[admin + "?eventName=GRANT_ADMIN_PRIVILEGE&maxResults=500&startTime=2026-11-14T00:00:00Z"] = (200, #"{"items":[\#(Self.item(1, "GRANT_ADMIN_PRIVILEGE"))]}"#)
        let found = try await watch(["admin": (200, #"{"items":[]}"#)], service: service)
        XCTAssertEqual(found.map(\.id), ["admin/2026-11-14T09:01:00.000Z/1/GRANT_ADMIN_PRIVILEGE/0"])
        let named = Set(service.requests.filter { $0.url?.path == admin }.compactMap { queryItems($0)["eventName"] })
        XCTAssertEqual(named, Set(GoogleWorkspace.watched.filter { $0.application == "admin" }.map(\.event)))
        let quiet = FakeService()
        _ = try await watch([:], service: quiet)
        XCTAssertEqual(quiet.requests.filter { $0.url?.path == admin }.count, 1, "a quiet admin report is read once")
    }

    // MARK: Batch 4: containing an account further

    /// Resetting a password replaces it with a random one that is sent only to Google, never shown: not in the result's
    /// text or its structured part. It is set to be changed at the next sign-in, and the result recommends signing out.
    func testResetPasswordNeverShowsThePasswordAndForcesAChange() async throws {
        let service = FakeService()
        let user = "/admin/directory/v1/users/m.okafor@kestrel.example"
        service.answers[user] = (200, "{}")
        var passwords: [String] = []
        for _ in 0..<2 {
            let result = try await callTool(GoogleWorkspace.containmentAdapter, "reset-password", #"{"user":"m.okafor@kestrel.example"}"#, on: service, in: containment)
            XCTAssertFalse(result.isError, result.text)
            let sent = service.requests.last
            XCTAssertEqual(sent?.httpMethod, "PATCH")
            XCTAssertEqual(sent?.url?.path, user)
            let body = try json(sent)
            XCTAssertEqual(body["changePasswordAtNextLogin"] as? Bool, true)
            XCTAssertNil(body["hashFunction"])
            let password = try XCTUnwrap(body["password"] as? String)
            XCTAssertEqual(password.count, 32)
            XCTAssertTrue(password.allSatisfy { $0.isASCII && !$0.isWhitespace })
            XCTAssertFalse(result.text.contains(password), "the password is never shown")
            let structured = String(data: try JSONSerialization.data(withJSONObject: result.structured ?? [:]), encoding: .utf8) ?? ""
            XCTAssertFalse(structured.contains(password), "the password is never in the structured result")
            XCTAssertTrue(result.text.contains("nobody knows") && result.text.contains("sign-out") && result.text.contains("https://admin.google.com/ac/users"),
                          result.text)
            passwords.append(password)
        }
        XCTAssertNotEqual(passwords[0], passwords[1], "each reset makes a new random password")
        // Only a super admin can reset another admin's password, which the refusal says.
        service.answers["/admin/directory/v1/users/cfo@kestrel.example"] = (403, Self.notAuthorized)
        let refused = try await callTool(GoogleWorkspace.containmentAdapter, "reset-password", #"{"user":"cfo@kestrel.example"}"#, on: service, in: containment)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("Reset password") && refused.text.contains("super admin"), refused.text)
        XCTAssertFalse(refused.text.contains(passwords[1]))
    }

    /// The new actions are held for the champion's approval like the others; listing devices only reads.
    func testTheNewContainmentActionsAreDestructive() async throws {
        let listed = try JSONSerialization.jsonObject(with: try await GoogleWorkspace.containmentAdapter.tools(for: containment)) as! [String: Any]
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        for name in ["reset-password", "remove-recovery", "device-block"] {
            let hints = try XCTUnwrap(tools.first { $0["name"] as? String == name }?["annotations"] as? [String: Any], name)
            XCTAssertEqual(hints["readOnlyHint"] as? Bool, false, name)
            XCTAssertEqual(hints["destructiveHint"] as? Bool, true, name)
        }
        let devices = try XCTUnwrap(tools.first { $0["name"] as? String == "devices" }?["annotations"] as? [String: Any])
        XCTAssertEqual(devices["readOnlyHint"] as? Bool, true)
        XCTAssertNil(devices["destructiveHint"])
        let instructions = GoogleWorkspace.containment.defaultInstructions
        for name in ["reset-password", "remove-recovery", "device-block", "devices"] {
            XCTAssertTrue(instructions.contains(name), name)
        }
    }

    /// Removing recovery details says what they were, clears only what was asked through Google's update method, which
    /// clears a field set to null, and changes nothing when there was nothing to remove.
    func testRemoveRecoverySaysWhatWasThereAndClearsIt() async throws {
        let service = FakeService()
        let user = "/admin/directory/v1/users/m.okafor@kestrel.example"
        service.answers[user] = (200, #"{"primaryEmail":"m.okafor@kestrel.example","recoveryEmail":"helpdesk@attacker.example","recoveryPhone":"+15550100"}"#)
        let email = try await callTool(GoogleWorkspace.containmentAdapter, "remove-recovery", #"{"user":"m.okafor@kestrel.example","email":true}"#, on: service, in: containment)
        XCTAssertFalse(email.isError, email.text)
        XCTAssertEqual(service.requests.map(\.httpMethod), ["GET", "PUT"])
        var body = try json(service.requests.last)
        XCTAssertEqual(Array(body.keys), ["recoveryEmail"])
        XCTAssertTrue(body["recoveryEmail"] is NSNull)
        XCTAssertTrue(email.text.contains("recovery email (was helpdesk@attacker.example)"), email.text)
        XCTAssertFalse(email.text.contains("+15550100"))
        XCTAssertEqual((email.structured?["removed"] as? [String: String])?["recoveryEmail"], "helpdesk@attacker.example")
        let both = try await callTool(GoogleWorkspace.containmentAdapter, "remove-recovery", #"{"user":"m.okafor@kestrel.example"}"#, on: service, in: containment)
        body = try json(service.requests.last)
        XCTAssertEqual(Set(body.keys), ["recoveryEmail", "recoveryPhone"])
        XCTAssertTrue(both.text.contains("recovery phone (was +15550100)"), both.text)
        let none = FakeService()
        none.answers[user] = (200, #"{"primaryEmail":"m.okafor@kestrel.example","recoveryEmail":""}"#)
        let nothing = try await callTool(GoogleWorkspace.containmentAdapter, "remove-recovery", #"{"user":"m.okafor@kestrel.example"}"#, on: none, in: containment)
        XCTAssertTrue(nothing.text.contains("nothing was changed"), nothing.text)
        XCTAssertTrue(none.requests.allSatisfy { $0.httpMethod == "GET" })
        let neither = try await callTool(GoogleWorkspace.containmentAdapter, "remove-recovery", #"{"user":"m.okafor@kestrel.example","email":false,"phone":false}"#, on: none, in: containment)
        XCTAssertTrue(neither.isError)
        // A role without Users › Update is told what to add.
        service.answers[user] = (200, #"{"recoveryPhone":"+15550100"}"#)
        service.sequences[user] = [(200, #"{"recoveryPhone":"+15550100"}"#), (403, Self.notAuthorized)]
        let refused = try await callTool(GoogleWorkspace.containmentAdapter, "remove-recovery", #"{"user":"m.okafor@kestrel.example"}"#, on: service, in: containment)
        XCTAssertTrue(refused.isError && refused.text.contains("Users › Update"), refused.text)
    }

    /// Devices lists a user's phones with the resource ID the actions take; each action asks Google for its documented
    /// action, only on a device that syncs that user's account, and a missing scope is said as such.
    func testDeviceActionsActOnlyOnTheUsersOwnDevice() async throws {
        let service = FakeService()
        let devices = "/admin/directory/v1/customer/my_customer/devices/mobile"
        service.answers[devices] = (200, #"{"mobiledevices":[{"resourceId":"R1","email":["m.okafor@kestrel.example"],"model":"Pixel 8","os":"Android 15","status":"APPROVED"},{"resourceId":"R2","email":["m.okafor@kestrel.example.evil"],"model":"iPhone"}]}"#)
        service.answers[devices + "/R1"] = (200, #"{"resourceId":"R1","email":["M.Okafor@kestrel.example"],"model":"Pixel 8","type":"ANDROID","managedAccountIsOnOwnerProfile":false,"supportsWorkProfile":true}"#)
        service.answers[devices + "/R1/action"] = (200, "")
        service.answers[devices + "/R2"] = (200, #"{"resourceId":"R2","email":["someone@kestrel.example"],"model":"iPhone"}"#)
        let listed = try await callTool(GoogleWorkspace.containmentAdapter, "devices", #"{"user":"m.okafor@kestrel.example"}"#, on: service, in: containment)
        XCTAssertTrue(listed.text.contains("Pixel 8") && listed.text.contains("resource ID R1"), listed.text)
        XCTAssertFalse(listed.text.contains("R2"), listed.text)
        XCTAssertEqual(queryItems(service.requests.last)["query"], "email:m.okafor@kestrel.example")
        for (tool, action) in [("device-block", "block")] {
            let result = try await callTool(GoogleWorkspace.containmentAdapter, tool, #"{"user":"m.okafor@kestrel.example","resourceId":"R1"}"#, on: service, in: containment)
            XCTAssertFalse(result.isError, "\(tool): \(result.text)")
            XCTAssertEqual(service.requests.last?.httpMethod, "POST", tool)
            XCTAssertEqual(service.requests.last?.url?.path, devices + "/R1/action", tool)
            XCTAssertEqual(try json(service.requests.last)["action"] as? String, action, tool)
        }
        let before = service.requests.count
        let other = try await callTool(GoogleWorkspace.containmentAdapter, "device-block", #"{"user":"m.okafor@kestrel.example","resourceId":"R2"}"#, on: service, in: containment)
        XCTAssertTrue(other.isError && other.text.contains("does not sync"), other.text)
        XCTAssertEqual(service.requests.count, before + 1)
        XCTAssertEqual(service.requests.last?.httpMethod, "GET", "nothing is done to someone else's device")
        let bad = try await callTool(GoogleWorkspace.containmentAdapter, "device-block", #"{"user":"m.okafor@kestrel.example","resourceId":"../R1"}"#, on: service, in: containment)
        XCTAssertTrue(bad.isError)
        // A connection signed in before the device scope was asked for is told to sign in again with it.
        service.answers[devices + "/R1"] = (403, Self.scopeMissing)
        let unscoped = try await callTool(GoogleWorkspace.containmentAdapter, "device-block", #"{"user":"m.okafor@kestrel.example","resourceId":"R1"}"#, on: service, in: containment)
        XCTAssertTrue(unscoped.isError && unscoped.text.contains("admin.directory.device.mobile.action") && unscoped.text.contains("sign the tool in again"), unscoped.text)
    }

    /// Containment's check tries the mobile devices too, never changing anything, and describes what only acting can
    /// confirm: resetting a password, removing recovery details and acting on a device.
    func testContainmentCheckAccessCoversTheNewActionsWithoutChangingAnything() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/users"] = (200, #"{"users":[{"primaryEmail":"pdp@kestrel.example"}]}"#)
        service.answers["/admin/directory/v1/users/pdp@kestrel.example/tokens"] = (200, "{}")
        service.answers["/admin/directory/v1/customer/my_customer/devices/mobile"] = (403, Self.scopeMissing)
        let check = try await callTool(GoogleWorkspace.containmentAdapter, "check-access", "{}", on: service, in: containment)
        let lines = check.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.hasPrefix("✗ Mobile devices") && $0.contains("admin.directory.device.mobile.action") }, check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("· Resetting passwords") && $0.contains("Reset password") && $0.contains("Force password change") }, check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("· Recovery details") && $0.contains("Users › Update") }, check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("· Device actions") && $0.contains("Mobile Device Management") }, check.text)
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" }, "a check never changes anything")
        let setup = GoogleWorkspace.containmentSetup.joined(separator: "\n")
        for privilege in ["Reset password", "Force password change", "Mobile Device Management", "Users › Update** itself"] {
            XCTAssertTrue(setup.contains(privilege), privilege)
        }
    }

    // MARK: Batch 4: investigating further

    /// The timeline reads every report Google keeps that an account acts in, and the IP search Gmail too, for the
    /// window's last 30 days, with Chrome, rules and Groups Enterprise.
    func testTheTimelineAndIPSearchReadTheReportsTheyMissed() async throws {
        let service = FakeService()
        service.answers["/admin/reports/v1/activity/users/ivana@kestrel.example/applications/login"] = (200, "{}")
        let timeline = try await callTool(GoogleWorkspace.adapter, "user-timeline", #"{"user":"ivana@kestrel.example"}"#, on: service, in: workspace)
        let asked = Set(service.requests.compactMap { $0.url?.lastPathComponent })
        for report in ["chrome", "rules", "keep", "data_studio", "gcp", "gemini_in_workspace_apps", "admin_data_action", "access_transparency"] {
            XCTAssertTrue(asked.contains(report), report)
            XCTAssertTrue(GoogleWorkspace.applications.contains(report), "activity reads \(report) too")
        }
        XCTAssertTrue(timeline.text.contains("Could not read"), "each report it could not read is named: \(timeline.text)")
        let ip = FakeService()
        for application in GoogleWorkspace.IPActivity.applications { ip.answers["/admin/reports/v1/activity/users/all/applications/" + application] = (200, "{}") }
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60 * 86_400))
        let result = try await callTool(GoogleWorkspace.adapter, "ip-activity", #"{"ip":"203.0.113.77","since":"\#(since)"}"#, on: ip, in: workspace)
        XCTAssertFalse(result.isError, result.text)
        for report in ["gmail", "chrome", "rules", "groups_enterprise"] {
            XCTAssertTrue(ip.requests.contains { $0.url?.lastPathComponent == report && queryItems($0)["actorIpAddress"] == "203.0.113.77" }, report)
        }
        let gmail = queryItems(ip.requests.first { $0.url?.lastPathComponent == "gmail" })
        let start = try XCTUnwrap(gmail["startTime"].flatMap(ServiceAlert.time)), end = try XCTUnwrap(gmail["endTime"].flatMap(ServiceAlert.time))
        XCTAssertLessThanOrEqual(end.timeIntervalSince(start), 30 * 86_400)
        XCTAssertTrue(result.text.contains("gmail (only the window's last 30 days"), result.text)
        XCTAssertTrue(result.text.contains("Nothing from 203.0.113.77 in the reports that could be read"), result.text)
    }

    /// What left through Drive: downloads, copies and prints by person and file; shares outside the organisation by
    /// domain, not a share inside one of its verified domains or access taken away; files made public or open to anyone
    /// with the link, not those open only inside; and ownership handed over, flagged when it left.
    func testDriveExposureGroupsWhatLeftByPersonFileAndOutsideDomain() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/customer/my_customer/domains"] = (200, #"{"domains":[{"domainName":"kestrel.example","verified":true,"domainAliases":[{"domainAliasName":"kestrel-labs.example","verified":true}]}]}"#)
        func drive(_ n: Int, _ user: String, _ event: String, _ doc: String, _ title: String, _ more: String = "") -> String {
            let extra = more.isEmpty ? "" : "," + more
            return #"{"id":{"time":"2026-11-14T09:\#(String(format: "%02d", n)):00.000Z","uniqueQualifier":"\#(n)"},"actor":{"email":"\#(user)"},"events":[{"name":"\#(event)","parameters":[{"name":"doc_id","value":"\#(doc)"},{"name":"doc_title","value":"\#(title)"}\#(extra)]}]}"#
        }
        let access = { (target: String, value: String) in #"{"name":"target_user","value":"\#(target)"},{"name":"new_value","value":"\#(value)"},{"name":"old_value","value":"none"}"# }
        let events = [
            drive(1, "nick@kestrel.example", "download", "A", "Budget"), drive(2, "nick@kestrel.example", "download", "A", "Budget"),
            drive(3, "nick@kestrel.example", "print", "A", "Budget"), drive(4, "ivana@kestrel.example", "copy", "B", "Copy of Plan"),
            drive(5, "nick@kestrel.example", "change_user_access", "A", "Budget", access("friend@gmail.com", "can_edit")),
            drive(6, "nick@kestrel.example", "change_user_access", "C", "Payroll", access("bob@partner.example", "can_view")),
            drive(7, "nick@kestrel.example", "change_user_access", "A", "Budget", access("sam@kestrel-labs.example", "can_view")),
            drive(8, "nick@kestrel.example", "change_user_access", "B", "Copy of Plan", access("gone@gmail.com", "none")),
            drive(9, "nick@kestrel.example", "change_document_visibility", "D", "Roadmap", #"{"name":"new_value","value":"people_with_link"},{"name":"old_value","value":"private"}"#),
            drive(10, "nick@kestrel.example", "change_document_visibility", "E", "Lunch menu", #"{"name":"new_value","value":"public_in_the_domain"}"#),
            drive(11, "nick@kestrel.example", "change_owner", "F", "Keys", #"{"name":"owner","value":"nick@kestrel.example"},{"name":"new_owner","value":"thief@gmail.com"}"#),
        ]
        service.answers["/admin/reports/v1/activity/users/nick@kestrel.example/applications/drive"] = (200, #"{"items":[\#(events.reversed().joined(separator: ","))]}"#)
        let result = try await callTool(GoogleWorkspace.adapter, "drive-exposure", #"{"user":"nick@kestrel.example","since":"2026-11-13T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(result.isError, result.text)
        let lines = result.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains(#"nick@kestrel.example: "Budget" (A), 2 downloads, 1 print"#), result.text)
        XCTAssertTrue(lines.contains(#"ivana@kestrel.example: "Copy of Plan" (B), 1 copy"#), result.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("gmail.com (1): \"Budget\" (A) to friend@gmail.com (can_edit) by nick@kestrel.example") }, result.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("partner.example (1): \"Payroll\" (C) to bob@partner.example") }, result.text)
        XCTAssertFalse(result.text.contains("sam@kestrel-labs.example") || result.text.contains("gone@gmail.com"), "an inside share or access taken away is not exposure")
        XCTAssertTrue(lines.contains { $0.hasPrefix("\"Roadmap\" (D) made anyone with the link by nick@kestrel.example") && $0.hasSuffix("was private") }, result.text)
        XCTAssertFalse(result.text.contains("Lunch menu"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("\"Keys\" (F) from nick@kestrel.example to thief@gmail.com (outside the organisation)") }, result.text)
        XCTAssertEqual(Set((result.structured?["sharedOutside"] as? [String: Any])?.keys.map { $0 } ?? []), ["gmail.com", "partner.example"])
        let asked = Set(service.requests.compactMap { queryItems($0)["eventName"] })
        XCTAssertEqual(asked, Set(GoogleWorkspace.DriveExposure.events))
        XCTAssertTrue(result.text.contains("Searched: drive/"), result.text)
        // A read cut short says so, so silence is never taken for nothing having left.
        service.answers["/admin/reports/v1/activity/users/nick@kestrel.example/applications/drive"] = (200, #"{"items":[\#(events[0])],"nextPageToken":"more"}"#)
        let cut = try await callTool(GoogleWorkspace.adapter, "drive-exposure", #"{"user":"nick@kestrel.example","limit":1}"#, on: service, in: workspace)
        XCTAssertTrue(cut.text.contains("Cut short, with more not read: ") && cut.text.contains("drive/download"), cut.text)
    }

    /// A phishing message traced through every mailbox: who received it, opened it, forwarded it, downloaded its
    /// attachment and deleted it, and who likely still holds it; a type Google names but not in a group is shown by name.
    func testMailTraceGroupsWhatHappenedToAMessage() async throws {
        let service = FakeService()
        func mail(_ n: Int, _ user: String, _ type: String, id: String = "<abc@evil.example>", subject: String = "Invoice overdue",
                  from: String = "billing@evil.example") -> String {
            #"{"id":{"time":"2026-11-14T09:\#(String(format: "%02d", n)):00.000Z","uniqueQualifier":"\#(n)"},"actor":{"email":"\#(user)"},"events":[{"name":"delivery","parameters":[{"name":"event_info","messageValue":{"parameter":[{"name":"mail_event_type","intValue":"\#(type)"}]}},{"name":"message_info","messageValue":{"parameter":[{"name":"subject","value":"\#(subject)"},{"name":"rfc2822_message_id","value":"\#(id)"},{"name":"source","messageValue":{"parameter":[{"name":"address","value":"\#(from)"}]}}]}}]}]}"#
        }
        let events = [mail(1, "a@kestrel.example", "2"), mail(2, "b@kestrel.example", "2"), mail(3, "c@kestrel.example", "2"), mail(4, "a@kestrel.example", "7"),
                      mail(5, "b@kestrel.example", "10"), mail(6, "a@kestrel.example", "17"), mail(7, "c@kestrel.example", "13"), mail(8, "b@kestrel.example", "21"),
                      mail(9, "d@kestrel.example", "2", id: "<lunch@kestrel.example>", subject: "Lunch", from: "chef@kestrel.example")]
        service.answers["/admin/reports/v1/activity/users/all/applications/gmail"] = (200, #"{"items":[\#(events.reversed().joined(separator: ","))]}"#)
        let trace = try await callTool(GoogleWorkspace.adapter, "mail-trace", #"{"messageId":"<ABC@evil.example>","since":"2026-11-13T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(trace.isError, trace.text)
        let lines = trace.text.split(separator: "\n").map(String.init)
        for expected in ["received (3): a@kestrel.example, b@kestrel.example, c@kestrel.example", "opened or viewed (1): a@kestrel.example",
                         "forwarded (1): b@kestrel.example", "attachments downloaded, previewed or saved (1): a@kestrel.example",
                         "moved, archived or deleted (1): c@kestrel.example", "classification label changed (1): b@kestrel.example",
                         "Received and not seen deleted in what was read, so likely still in the mailbox: a@kestrel.example, b@kestrel.example"] {
            XCTAssertTrue(lines.contains(expected), "\(expected) missing from:\n\(trace.text)")
        }
        XCTAssertFalse(trace.text.contains("d@kestrel.example"))
        let sent = queryItems(service.requests.last)
        XCTAssertEqual(sent["eventName"], "delivery")
        XCTAssertNotNil(sent["endTime"], "Google takes Gmail events only with an end")
        XCTAssertNil(sent["filters"], "the message's details are matched here, as Google has not named them")
        let bySender = try await callTool(GoogleWorkspace.adapter, "mail-trace", #"{"sender":"evil.example","since":"2026-11-13T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertTrue(bySender.text.hasPrefix("8 Gmail events"), bySender.text)
        let byRecipient = try await callTool(GoogleWorkspace.adapter, "mail-trace", #"{"recipient":"c@kestrel.example","subject":"invoice","since":"2026-11-13T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertTrue(byRecipient.text.hasPrefix("2 Gmail events") && !byRecipient.text.contains("a@kestrel.example"), byRecipient.text)
        let nothing = try await callTool(GoogleWorkspace.adapter, "mail-trace", #"{"user":"a@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertTrue(nothing.isError)
        let tooLong = try await callTool(GoogleWorkspace.adapter, "mail-trace", #"{"subject":"x","since":"2026-09-01T00:00:00Z","until":"2026-11-01T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertTrue(tooLong.isError && tooLong.text.contains("30 days"), tooLong.text)
        XCTAssertEqual(GoogleWorkspace.mailEvent("27"), "27 (deleted for good)")
        XCTAssertEqual(GoogleWorkspace.mailEvent("99"), "99")
    }

    /// Everything one client ID did: the events whose actor names it, in Drive, Gmail, Calendar and admin actions, read
    /// whole, and its token events, asked for by client ID; grouped by the account it acted as.
    func testClientActivityKeepsOnlyWhatOneClientDidByAccount() async throws {
        let service = FakeService()
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        func acted(_ n: Int, _ user: String, _ event: String, client: String?, impersonating: Bool = true) -> String {
            let via = client.map { #","applicationInfo":{"applicationName":"Sync Pro","oauthClientId":"\#($0)","impersonation":\#(impersonating)}"# } ?? ""
            return #"{"id":{"time":"2026-11-14T09:\#(String(format: "%02d", n)):00.000Z","uniqueQualifier":"\#(n)"},"actor":{"email":"\#(user)"\#(via)},"events":[{"name":"\#(event)"}]}"#
        }
        service.answers[reports + "drive"] = (200, #"{"items":[\#([acted(5, "a@kestrel.example", "download", client: "123"), acted(4, "a@kestrel.example", "download", client: "123"), acted(3, "b@kestrel.example", "view", client: "999"), acted(2, "c@kestrel.example", "edit", client: nil)].joined(separator: ","))]}"#)
        service.answers[reports + "admin"] = (200, #"{"items":[\#(acted(6, "it@kestrel.example", "CREATE_USER", client: "123", impersonating: false))]}"#)
        for report in ["gmail", "calendar"] { service.answers[reports + report] = (200, "{}") }
        service.answers[reports + "token"] = (200, #"{"items":[{"id":{"time":"2026-11-14T09:01:00.000Z","uniqueQualifier":"1"},"actor":{"email":"b@kestrel.example"},"events":[{"name":"authorize","parameters":[{"name":"client_id","value":"123"},{"name":"app_name","value":"Sync Pro"}]}]}]}"#)
        let result = try await callTool(GoogleWorkspace.adapter, "client-activity", #"{"clientId":"123","since":"2026-11-13T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(result.isError, result.text)
        let lines = result.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Client 123 acted as 3 accounts in 4 events, the busiest first:")
        XCTAssertTrue(lines.contains("a@kestrel.example (impersonating them): 2, drive download 2"), result.text)
        XCTAssertTrue(lines.contains("it@kestrel.example: 1, admin CREATE_USER 1"), result.text)
        XCTAssertTrue(lines.contains("b@kestrel.example: 1, token authorize 1"), result.text)
        XCTAssertFalse(result.text.contains("view") || result.text.contains("c@kestrel.example"), "another client's or a person's own events are left out")
        let token = service.requests.filter { $0.url?.lastPathComponent == "token" }
        XCTAssertEqual(Set(token.compactMap { queryItems($0)["eventName"] }), ["authorize", "activity", "revoke"])
        XCTAssertTrue(token.allSatisfy { queryItems($0)["filters"] == "client_id==123" })
        XCTAssertTrue(service.requests.filter { $0.url?.lastPathComponent == "drive" }.allSatisfy { queryItems($0)["filters"] == nil && queryItems($0)["eventName"] == nil })
        XCTAssertEqual((result.structured?["accounts"] as? [Any])?.count, 3)
        // A report read whole that was cut short is said to may hold more of what the client did.
        service.answers[reports + "drive"] = (200, #"{"items":[\#(acted(5, "a@kestrel.example", "download", client: "123"))],"nextPageToken":"more"}"#)
        let cut = try await callTool(GoogleWorkspace.adapter, "client-activity", #"{"clientId":"123","limit":1}"#, on: service, in: workspace)
        XCTAssertTrue(cut.text.contains("drive was read whole up to 1 events and kept only for this client"), cut.text)
    }

    // MARK: Batch 4: the watch

    /// A file a user made public on the web or open to anyone with the link wakes the agents, in the tier of exports
    /// and apps; one opened only inside the organisation, or made private, does not.
    func testTheWatchWakesForAFileMadePublic() async throws {
        let visibility = { (value: String) in #"{"name":"new_value","value":"\#(value)"},{"name":"doc_id","value":"D"}"# }
        let drive = [Self.item(1, "change_document_visibility", parameters: visibility("public_on_the_web")),
                     Self.item(2, "change_document_visibility", parameters: visibility("people_with_link")),
                     Self.item(3, "change_document_visibility", parameters: visibility("public_in_the_domain")),
                     Self.item(4, "change_document_visibility", parameters: visibility("private"))]
        let service = FakeService()
        let found = try await watch(["drive": (200, #"{"items":[\#(drive.joined(separator: ","))]}"#)], service: service)
        XCTAssertEqual(found.map(\.id), ["drive/2026-11-14T09:02:00.000Z/2/change_document_visibility/0", "drive/2026-11-14T09:01:00.000Z/1/change_document_visibility/0"])
        let reads = service.requests.filter { $0.url?.lastPathComponent == "drive" }
        XCTAssertEqual(reads.compactMap { queryItems($0)["eventName"] }, ["change_document_visibility"], "only link sharing changes are read, not every share")
        let event = GoogleWorkspace.Event(id: "x", time: nil, application: "drive", user: nil, ip: nil, event: "change_document_visibility", parameters: [:])
        XCTAssertEqual(GoogleWorkspace.tier(event), 2)
    }

    /// The watched events kept only in part, by their details, their scopes' risk or an exception, are those a read cut
    /// short could hide the one that counts in; those Google filters are not.
    func testTheWatchKnowsWhichEventsItKeepsOnlyInPart() {
        for label in ["token/authorize", "mobile/SUSPICIOUS_ACTIVITY_EVENT", "mobile/DEVICE_COMPROMISED_EVENT", "rules/rule_trigger",
                      "drive/change_document_visibility", "admin/CHANGE_ALLOWED_TWO_STEP_VERIFICATION_METHODS"] {
            XCTAssertTrue(GoogleWorkspace.keptInPart(label), label)
        }
        for label in ["login/login_success", "login/suspicious_login", "mobile/APPLICATION_EVENT", "admin/CHANGE_PASSWORD"] {
            XCTAssertFalse(GoogleWorkspace.keptInPart(label), label)
        }
    }

    /// The newest grants read are all routine and there are more than the watch can read even reading on: it says so,
    /// once, dated at the window's start so it moves nothing on, and again only once the grants were read in full and
    /// then were too many again.
    func testTheWatchTellsOnceOfRoutineGrantsItCouldNotReadToTheEnd() async throws {
        let connection = try GoogleWorkspace.preset.makeConnection(name: "Workspace — grants", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let service = FakeService()
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        let calendar = #"{"name":"scope","multiValue":["https://www.googleapis.com/auth/calendar"]}"#
        let routine = (200, #"{"items":[\#(Self.item(30, "authorize", parameters: calendar))],"nextPageToken":"more"}"#)
        service.answers[reports + "token"] = routine
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        var found = try await GoogleWorkspace.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(found.count, 1, "\(found.map(\.id))")
        XCTAssertTrue(found.first?.id.hasPrefix("unchecked/token/authorize/") == true, "\(found.map(\.id))")
        XCTAssertEqual(found.first?.time, since, "dated at the window's start, so it moves nothing on")
        let grants = service.requests.filter { $0.url?.lastPathComponent == "token" && queryItems($0)["eventName"] == "authorize" }
        XCTAssertTrue(grants.contains { queryItems($0)["endTime"] == "2026-11-14T09:30:00.000Z" }, "read on from the oldest grant read")
        XCTAssertLessThanOrEqual(grants.filter { queryItems($0)["endTime"] != nil }.count, GoogleWorkspace.readOnPages, "a bounded number of requests")
        found = try await GoogleWorkspace.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(found.map(\.id), [], "told once, not at every check")
        service.answers[reports + "token"] = (200, #"{"items":[]}"#)
        found = try await GoogleWorkspace.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(found.map(\.id), [])
        service.answers[reports + "token"] = routine
        found = try await GoogleWorkspace.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(found.count, 1, "a new episode is told again: \(found.map(\.id))")
        // security-events, which the wake names, says the grants were cut short.
        let events = try await callTool(GoogleWorkspace.adapter, "security-events", #"{"since":"2026-11-19T09:00:00Z"}"#, on: service, in: workspace)
        XCTAssertTrue(events.text.contains("Cut short, with more not read: token/authorize"), events.text)
    }

    /// Google answering in short pages, each with an older routine grant, spends the check's pages for reading on: no more
    /// are asked for than it allows, and the watch says once that the grants were not all checked.
    func testShortPagesSpendTheReadOnBudgetAndAreToldOnce() async throws {
        let connection = try GoogleWorkspace.preset.makeConnection(name: "Workspace — short pages", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let service = FakeService()
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        let calendar = #"{"name":"scope","multiValue":["https://www.googleapis.com/auth/calendar"]}"#
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:59:59Z"))
        // A page of one grant each, every one older than the last, far more than one check reads.
        service.sequences[reports + "token"] = (0..<(GoogleWorkspace.mostPages + 3 * GoogleWorkspace.readOnPages)).map { n in
            let time = ISO8601DateFormatter().string(from: base.addingTimeInterval(-Double(n)))
            return (200, #"{"items":[{"id":{"time":"\#(time)","uniqueQualifier":"\#(n)"},"actor":{"email":"u@kestrel.example"},"events":[{"name":"authorize","parameters":[\#(calendar)]}]}],"nextPageToken":"p\#(n)"}"#)
        }
        service.answers[reports + "token"] = (200, #"{"items":[\#(Self.item(30, "authorize", parameters: calendar))],"nextPageToken":"more"}"#)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let readOn = { service.requests.filter { $0.url?.lastPathComponent == "token" && queryItems($0)["endTime"] != nil }.count }
        var found = try await GoogleWorkspace.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(readOn(), GoogleWorkspace.readOnPages, "read on until the budget ran out, and no further")
        XCTAssertEqual(found.map { String($0.id.split(separator: "/").prefix(3).joined(separator: "/")) }, ["unchecked/token/authorize"])
        let first = readOn()
        found = try await GoogleWorkspace.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(found.map(\.id), [], "told once, not at every check")
        XCTAssertLessThanOrEqual(readOn() - first, GoogleWorkspace.readOnPages)
    }

    /// Thousands of routine grants after a risky one: the watch reads on, earlier in the window, and finds it.
    func testTheWatchReadsOnPastRoutineGrantsToARiskyOne() async throws {
        let connection = try GoogleWorkspace.preset.makeConnection(name: "Workspace — read on", values: ["clientID": "1234-abc.apps.googleusercontent.com"])
        let service = FakeService()
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        let calendar = #"{"name":"scope","multiValue":["https://www.googleapis.com/auth/calendar"]}"#
        service.sequences[reports + "token"] = (0..<5).map { page in
            let items = (0..<1000).map { n in
                #"{"id":{"time":"2026-11-19T09:30:00.000Z","uniqueQualifier":"\#(page * 1000 + n)"},"actor":{"email":"u@kestrel.example"},"events":[{"name":"authorize","parameters":[\#(calendar)]}]}"#
            }
            return (200, #"{"items":[\#(items.joined(separator: ","))],"nextPageToken":"p\#(page)"}"#)
        }
        service.answers[reports + "token"] = (200, #"{"items":[{"id":{"time":"2026-11-19T09:10:00.000Z","uniqueQualifier":"risky"},"actor":{"email":"cfo@kestrel.example"},"events":[{"name":"authorize","parameters":[{"name":"app_name","value":"Mail Helper"},{"name":"scope","multiValue":["https://mail.google.com/"]}]}]}]}"#)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let found = try await GoogleWorkspace.adapter.alerts(since: since, connection: connection, access: service)
        XCTAssertEqual(found.map(\.id), ["token/2026-11-19T09:10:00.000Z/risky/authorize/0"])
    }

    /// An admin's password reset or a loosened policy shows, on its security-events line, who did it and what changed:
    /// the user, the setting, its old and new values and where it applies, even for an event with many details.
    func testSecurityEventsShowWhoChangedWhatForAdminEvents() async throws {
        let service = FakeService()
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        for application in Set(GoogleWorkspace.watched.map(\.application)) { service.answers[reports + application] = (200, #"{"items":[]}"#) }
        func parameters(_ pairs: [(String, String)]) -> String { pairs.map { #"{"name":"\#($0.0)","value":"\#($0.1)"}"# }.joined(separator: ",") }
        let caa = parameters([("APPLICATION_NAME", "Gmail"), ("CAA_ACCESS_ASSIGNMENTS_NEW", "a"), ("CAA_ACCESS_ASSIGNMENTS_OLD", "b"), ("CAA_ACCESS_LEVELS_NEW", "none"),
                              ("CAA_ACCESS_LEVELS_OLD", "corp-only"), ("CAA_ASSIGNMENTS_NEW", "c"), ("CAA_ASSIGNMENTS_OLD", "d"), ("CAA_ENFORCEMENT_ENDPOINTS_NEW", "e"),
                              ("CAA_ENFORCEMENT_ENDPOINTS_OLD", "f"), ("GROUP_NAME", "g"), ("MODE", "h"), ("ORG_UNIT_NAME", "/Finance"), ("TARGET_ENTITY_NAME", "Gmail"),
                              ("TARGET_ENTITY_TYPE", "APP")])
        let admin = [Self.item(3, "CHANGE_PASSWORD", parameters: parameters([("USER_EMAIL", "ivana@kestrel.example")])),
                     Self.item(2, "SESSION_CONTROL_SETTINGS_CHANGE", parameters: parameters([("ORG_UNIT_NAME", "/"), ("REAUTH_APPLICATION", "Admin console"),
                                                                                              ("REAUTH_SETTING_NEW", "never"), ("REAUTH_SETTING_OLD", "1 hour")])),
                     Self.item(1, "CHANGE_CAA_APP_ASSIGNMENTS", parameters: caa)]
        service.answers[reports + "admin"] = (200, #"{"items":[\#(admin.joined(separator: ","))]}"#)
        let events = try await callTool(GoogleWorkspace.adapter, "security-events", #"{"since":"2026-11-14T00:00:00Z"}"#, on: service, in: workspace)
        let lines = events.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.contains("CHANGE_PASSWORD by u3@kestrel.example") && $0.contains("USER_EMAIL=ivana@kestrel.example") }, events.text)
        XCTAssertTrue(lines.contains { $0.contains("SESSION_CONTROL_SETTINGS_CHANGE by u2@kestrel.example") && $0.contains("REAUTH_SETTING_NEW=never")
            && $0.contains("REAUTH_SETTING_OLD=1 hour") && $0.contains("ORG_UNIT_NAME=/") }, events.text)
        XCTAssertTrue(lines.contains { $0.contains("CHANGE_CAA_APP_ASSIGNMENTS by u1@kestrel.example") && $0.contains("CAA_ACCESS_LEVELS_NEW=none")
            && $0.contains("CAA_ACCESS_LEVELS_OLD=corp-only") && $0.contains("TARGET_ENTITY_NAME=Gmail") && $0.contains("ORG_UNIT_NAME=/Finance") }, events.text)
    }

    /// Both tools' instructions name the new operations, and the detection tool's the file made public it wakes for.
    func testInstructionsNameTheInvestigationAndContainmentOperations() {
        let audit = GoogleWorkspace.preset.defaultInstructions
        for name in ["drive-exposure", "mail-trace", "client-activity", "anyone with the link", "read only in part"] { XCTAssertTrue(audit.contains(name), name) }
    }

    // MARK: Batch 4 review

    /// Pion never sends Google's account wipe: Google resets company-owned and work-only Android phones and supervised
    /// iPhones to factory settings, and the Directory cannot say how a phone is owned. No Containment operation wipes,
    /// blocking sends only block, and the agents and the champion are told to wipe in the Admin console after checking.
    func testContainmentCannotWipeAPhone() async throws {
        let listed = try JSONSerialization.jsonObject(with: try await GoogleWorkspace.containmentAdapter.tools(for: containment)) as! [String: Any]
        let names = try XCTUnwrap(listed["tools"] as? [[String: Any]]).compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("device-block") && names.contains("devices"), "\(names)")
        XCTAssertFalse(names.contains { $0.contains("wipe") }, "\(names)")
        let service = FakeService()
        let devices = "/admin/directory/v1/customer/my_customer/devices/mobile"
        service.answers[devices + "/R1"] = (200, #"{"resourceId":"R1","email":["m.okafor@kestrel.example"],"model":"Pixel 8","type":"ANDROID","managedAccountIsOnOwnerProfile":false}"#)
        service.answers[devices + "/R1/action"] = (200, "")
        // Whatever a call adds, blocking asks Google to block and nothing else.
        let blocked = try await callTool(GoogleWorkspace.containmentAdapter, "device-block",
                                         #"{"user":"m.okafor@kestrel.example","resourceId":"R1","action":"admin_account_wipe","personallyOwned":true}"#, on: service, in: containment)
        XCTAssertFalse(blocked.isError, blocked.text)
        let posts = service.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(try json(posts.first) as NSDictionary, ["action": "block"] as NSDictionary)
        XCTAssertTrue(blocked.text.contains("https://admin.google.com/ac/devices") && blocked.text.contains("factory settings"), blocked.text)
        do {
            let wipe = try await callTool(GoogleWorkspace.containmentAdapter, "device-account-wipe", #"{"user":"m.okafor@kestrel.example","resourceId":"R1"}"#, on: service, in: containment)
            XCTAssertTrue(wipe.isError, wipe.text)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("does not offer device-account-wipe"), error.localizedDescription)
        }
        XCTAssertEqual(service.requests.filter { $0.httpMethod == "POST" }.count, 1, "no wipe is ever sent")
        let instructions = GoogleWorkspace.containment.defaultInstructions
        XCTAssertTrue(instructions.contains("cannot wipe") && instructions.contains("https://admin.google.com/ac/devices") && instructions.contains("factory"), instructions)
        // The access check never mentions a wipe.
        let check = FakeService()
        check.answers["/admin/directory/v1/users"] = (200, #"{"users":[]}"#)
        let access = try await callTool(GoogleWorkspace.containmentAdapter, "check-access", "{}", on: check, in: containment)
        XCTAssertFalse(access.text.lowercased().contains("wipe"), access.text)
    }

    /// Without the organisation's verified domains, an outside collaborator who acted does not make their domain look
    /// inside: every share and new owner is listed, said not known to be inside or outside.
    func testDriveExposureWithoutTheDomainsListsEveryShareAsNotKnown() async throws {
        let service = FakeService()
        service.answers["/admin/directory/v1/customer/my_customer/domains"] = (403, Self.notAuthorized)
        func drive(_ n: Int, _ user: String, _ event: String, _ more: String = "") -> String {
            #"{"id":{"time":"2026-11-14T09:\#(String(format: "%02d", n)):00.000Z","uniqueQualifier":"\#(n)"},"actor":{"email":"\#(user)"},"events":[{"name":"\#(event)","parameters":[{"name":"doc_id","value":"A"},{"name":"doc_title","value":"Budget"}\#(more)]}]}"#
        }
        let events = [drive(1, "x@partner.example", "download"),
                      drive(2, "nick@kestrel.example", "change_user_access", #",{"name":"target_user","value":"bob@partner.example"},{"name":"new_value","value":"can_edit"}"#),
                      drive(3, "nick@kestrel.example", "change_owner", #",{"name":"owner","value":"nick@kestrel.example"},{"name":"new_owner","value":"bob@partner.example"}"#)]
        service.answers["/admin/reports/v1/activity/users/all/applications/drive"] = (200, #"{"items":[\#(events.reversed().joined(separator: ","))]}"#)
        let result = try await callTool(GoogleWorkspace.adapter, "drive-exposure", #"{"since":"2026-11-13T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("whether each is inside the organisation is not known"), result.text)
        XCTAssertTrue(result.text.contains("partner.example (1): \"Budget\" (A) to bob@partner.example"), result.text)
        XCTAssertTrue(result.text.contains("to bob@partner.example (inside or outside not known)"), result.text)
        XCTAssertTrue(result.text.contains("verified domains could not be read"), result.text)
        XCTAssertEqual((result.structured?["sharedOutside"] as? [String: Any])?.count, 0)
        XCTAssertEqual((result.structured?["sharedInsideOrOutsideNotKnown"] as? [String: Any])?.keys.first, "partner.example")
    }

    /// A Message-ID matches only the message's own ID detail, whole, never the same text in a subject or a link; which
    /// mailboxes still hold mail is worked out by mailbox and message; and an ID no event carries is said unmatchable.
    func testMailTraceMatchesTheMessageIDExactlyAndKeepsEachMessageApart() async throws {
        let service = FakeService()
        func mail(_ n: Int, _ user: String, _ type: String, id: String?, subject: String = "Invoice", link: String = "") -> String {
            let idDetail = id.map { #",{"name":"rfc2822_message_id","value":"\#($0)"}"# } ?? ""
            let linkDetail = link.isEmpty ? "" : #",{"name":"link_click_info","multiMessageValue":[{"parameter":[{"name":"url","value":"\#(link)"}]}]}"#
            return #"{"id":{"time":"2026-11-14T09:\#(String(format: "%02d", n)):00.000Z","uniqueQualifier":"\#(n)"},"actor":{"email":"\#(user)"},"events":[{"name":"delivery","parameters":[{"name":"event_info","messageValue":{"parameter":[{"name":"mail_event_type","intValue":"\#(type)"}]}},{"name":"message_info","messageValue":{"parameter":[{"name":"subject","value":"\#(subject)"}\#(idDetail),{"name":"source","messageValue":{"parameter":[{"name":"address","value":"billing@evil.example"}]}}\#(linkDetail)]}}]}]}"#
        }
        let events = [mail(1, "e@kestrel.example", "2", id: "<one@evil.example>"), mail(2, "e@kestrel.example", "2", id: "<two@evil.example>"),
                      mail(3, "e@kestrel.example", "13", id: "<one@evil.example>"),
                      mail(4, "f@kestrel.example", "2", id: "<other@kestrel.example>", subject: "Re: <one@evil.example> looks fake"),
                      mail(5, "g@kestrel.example", "15", id: "<other2@kestrel.example>", link: "https://mail.example/?q=one@evil.example"),
                      mail(6, "h@kestrel.example", "2", id: "<one@evil.example.org>")]
        service.answers["/admin/reports/v1/activity/users/all/applications/gmail"] = (200, #"{"items":[\#(events.reversed().joined(separator: ","))]}"#)
        let byID = try await callTool(GoogleWorkspace.adapter, "mail-trace", #"{"messageId":" <ONE@evil.example> ","since":"2026-11-13T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertTrue(byID.text.hasPrefix("2 Gmail events"), byID.text)
        for other in ["f@kestrel.example", "g@kestrel.example", "h@kestrel.example"] { XCTAssertFalse(byID.text.contains(other), "\(other): \(byID.text)") }
        XCTAssertFalse(byID.text.contains("likely still in the mailbox"), "its one recipient deleted it: \(byID.text)")
        // By sender, one mailbox deleted one of two messages and still holds the other.
        let bySender = try await callTool(GoogleWorkspace.adapter, "mail-trace", #"{"sender":"evil.example","since":"2026-11-13T00:00:00Z"}"#, on: service, in: workspace)
        XCTAssertTrue(bySender.text.contains("so likely still in the mailbox: e@kestrel.example, f@kestrel.example, h@kestrel.example"), bySender.text)
        // Events that carry no ID detail: an ID cannot be matched, and nothing is said of what mailboxes still hold.
        let bare = FakeService()
        bare.answers["/admin/reports/v1/activity/users/all/applications/gmail"] = (200, #"{"items":[\#(mail(1, "e@kestrel.example", "2", id: nil, subject: "<one@evil.example>"))]}"#)
        let unmatched = try await callTool(GoogleWorkspace.adapter, "mail-trace", #"{"messageId":"one@evil.example","since":"2026-11-13T00:00:00Z"}"#, on: bare, in: workspace)
        XCTAssertTrue(unmatched.text.hasPrefix("0 Gmail events") && unmatched.text.contains("could not be matched reliably"), unmatched.text)
        let unsaid = try await callTool(GoogleWorkspace.adapter, "mail-trace", #"{"sender":"evil.example","since":"2026-11-13T00:00:00Z"}"#, on: bare, in: workspace)
        XCTAssertTrue(unsaid.text.contains("Which mailboxes still hold it is not said"), unsaid.text)
        XCTAssertTrue(unsaid.structured?["likelyStillHeldBy"] == nil || unsaid.structured?["likelyStillHeldBy"] is NSNull)
    }
}
