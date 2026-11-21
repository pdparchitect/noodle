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
                                                   "https://www.googleapis.com/auth/admin.directory.domain.readonly"]),
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
        ]
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"principal":"mallory@kestrel.example","since":"2026-11-13T00:00:00Z","limit":20}"#, on: service, in: cloud)
        XCTAssertFalse(logs.isError, logs.text)
        XCTAssertTrue(logs.text.contains("SetIamPolicy by mallory@kestrel.example from 203.0.113.77"), logs.text)
        XCTAssertTrue(logs.text.contains("CreateServiceAccountKey by mallory@kestrel.example from 203.0.113.77 on projects/-/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com in projects/kestrel-prod"), logs.text)
        let searches = service.requests.filter { $0.url?.host == "logging.googleapis.com" }
        XCTAssertEqual(searches.count, 2, "the second page was not read")
        let body = try json(searches.first)
        XCTAssertEqual(body["resourceNames"] as? [String], ["organizations/123456789", "projects/kestrel-prod"], "a live project's logs were left out, or a deleted one's put in")
        // Named logs, which Logging finds by index, rather than a search through every log's name.
        XCTAssertEqual(body["filter"] as? String,
            #"(log_id("cloudaudit.googleapis.com/activity") OR log_id("cloudaudit.googleapis.com/data_access") OR log_id("cloudaudit.googleapis.com/system_event") OR log_id("cloudaudit.googleapis.com/policy") OR log_id("cloudaudit.googleapis.com/access_transparency")) AND protoPayload.authenticationInfo.principalEmail="mallory@kestrel.example" AND timestamp>="2026-11-13T00:00:00Z""#)
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
        XCTAssertEqual(queryItems(service.requests.first)["filter"], #"state="ACTIVE" AND (severity="HIGH" OR severity="CRITICAL")"#)
        XCTAssertEqual(service.requests.first?.url?.host, "securitycenter.googleapis.com")
    }

    func testCloudsTriggerFindsHighAndCriticalFindingsSinceATime() async throws {
        let service = FakeService()
        service.answers["/v2/organizations/123456789/sources/-/findings"] = (200, #"{"listFindingsResults":[{"finding":{"name":"organizations/123456789/sources/1/findings/f2","eventTime":"2026-11-19T09:14:22.500Z"}},{"finding":{"name":"organizations/123456789/sources/1/findings/f1","eventTime":"2026-11-19T09:11:00Z"}}]}"#)
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z"))
        let findings = try await GoogleCloud.adapter.alerts(since: since, connection: cloud, access: service)
        XCTAssertEqual(findings.map(\.id), ["organizations/123456789/sources/1/findings/f2", "organizations/123456789/sources/1/findings/f1"])
        let query = queryItems(service.requests.last)
        XCTAssertEqual(query["filter"], #"state="ACTIVE" AND (severity="HIGH" OR severity="CRITICAL") AND event_time>="2026-11-19T09:00:00Z""#)
        XCTAssertEqual(query["pageSize"], String(ServiceAlert.most))
        XCTAssertEqual(GoogleCloud.adapter.watchedTool, "scc-findings")

        // The window a wake names can be read back with the findings operation.
        _ = try await callTool(GoogleCloud.adapter, "scc-findings", #"{"since":"2026-11-19T09:00:00Z"}"#, on: service, in: cloud)
        XCTAssertEqual(queryItems(service.requests.last)["filter"], #"state="ACTIVE" AND (severity="CRITICAL" OR severity="HIGH") AND event_time>="2026-11-19T09:00:00Z""#)
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

    func testWhatSitsInAProjectPendingDeletionIsMarkedSoItIsNotTakenForLive() async throws {
        let service = FakeService()
        service.answers["/v1/organizations/123456789/assets?assetTypes=cloudresourcemanager.googleapis.com/Project&contentType=RESOURCE&pageSize=500"] = (200, #"""
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
    /// fired above low. Each event is asked for by name, and only that event of an answer counts.
    func testWorkspacesTriggerFindsTheAuditEventsThatMeanAnAttack() async throws {
        let service = FakeService()
        let reports = "/admin/reports/v1/activity/users/all/applications/"
        service.answers[reports + "login"] = (200, #"{"items":[{"id":{"time":"2026-11-19T09:20:00.000Z","uniqueQualifier":"101","applicationName":"login"},"actor":{"email":"m.okafor@kestrel.example"},"ipAddress":"203.0.113.77","events":[{"type":"account_warning","name":"suspicious_login","parameters":[{"name":"affected_email_address","value":"m.okafor@kestrel.example"}]}]},{"id":{"time":"2026-11-19T09:19:00.000Z","uniqueQualifier":"102","applicationName":"login"},"actor":{"email":"j.lee@kestrel.example"},"events":[{"type":"login","name":"login_success"}]}]}"#)
        service.answers[reports + "admin"] = (200, #"{"items":[{"id":{"time":"2026-11-19T09:18:00.000Z","uniqueQualifier":"201","applicationName":"admin"},"actor":{"email":"it@kestrel.example"},"events":[{"type":"USER_SETTINGS","name":"GRANT_ADMIN_PRIVILEGE","parameters":[{"name":"USER_EMAIL","value":"intern@kestrel.example"}]}]},{"id":{"time":"2026-11-19T09:17:00.000Z","uniqueQualifier":"202","applicationName":"admin"},"events":[{"type":"USER_SETTINGS","name":"CHANGE_PASSWORD"}]}]}"#)
        service.answers[reports + "mobile"] = (200, #"{"items":[{"id":{"time":"2026-11-19T09:16:00.000Z","uniqueQualifier":"301","applicationName":"mobile"},"events":[{"type":"suspicious_activity","name":"DEVICE_COMPROMISED_EVENT","parameters":[{"name":"DEVICE_COMPROMISED_STATE","value":"COMPROMISED"}]}]},{"id":{"time":"2026-11-19T09:15:00.000Z","uniqueQualifier":"302","applicationName":"mobile"},"events":[{"type":"suspicious_activity","name":"DEVICE_COMPROMISED_EVENT","parameters":[{"name":"DEVICE_COMPROMISED_STATE","value":"NOT_COMPROMISED"}]}]}]}"#)
        service.answers[reports + "user_accounts"] = (200, "{}")
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
                      "admin/GRANT_ADMIN_PRIVILEGE", "admin/UPDATE_DOMAIN_PRIMARY_ADMIN_EMAIL", "admin/TURN_OFF_2_STEP_VERIFICATION",
                      "mobile/DEVICE_COMPROMISED_EVENT", "rules/rule_trigger"] {
            XCTAssertTrue(asked.contains(event), event)
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

    /// The containment tool signs in on its own, through the same client, asking only for the two Directory scopes
    /// suspending and ending sessions take; the audit tool keeps its one read-only scope.
    func testContainmentSignsInSeparatelyWithOnlyTheScopesItsActionsTake() throws {
        XCTAssertNotNil(PionAdapters.all["google-workspace-containment"])
        XCTAssertEqual(containment.endpoint.absoluteString, "https://admin.googleapis.com")
        guard case .connection(let configuration) = GoogleWorkspace.containment.configuration, let oauth = configuration.oauth else {
            return XCTFail("no sign-in")
        }
        XCTAssertEqual(oauth.scopes, ["https://www.googleapis.com/auth/admin.directory.user",
                                      "https://www.googleapis.com/auth/admin.directory.user.security"])
        XCTAssertEqual(configuration.oauthClientField, "clientID")
        XCTAssertNotEqual(GoogleWorkspace.containment.id, GoogleWorkspace.preset.id)
        XCTAssertEqual(GoogleWorkspace.preset.name, "Google Workspace Audit")
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
        for name in ["sign-out", "revoke-token", "delete-app-password", "suspend", "unsuspend"] {
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
        for path in [user, user + "/signOut", user + "/tokens/999-evil.apps.googleusercontent.com", user + "/asps/42"] {
            service.answers[path] = (200, "{}")
        }
        let runs: [(String, String, String, String)] = [
            ("sign-out", #"{"user":"m.okafor@kestrel.example"}"#, "POST", user + "/signOut"),
            ("revoke-token", #"{"user":"m.okafor@kestrel.example","clientId":"999-evil.apps.googleusercontent.com"}"#, "DELETE", user + "/tokens/999-evil.apps.googleusercontent.com"),
            ("delete-app-password", #"{"user":"m.okafor@kestrel.example","codeId":42}"#, "DELETE", user + "/asps/42"),
            ("suspend", #"{"user":"m.okafor@kestrel.example"}"#, "PATCH", user),
            ("unsuspend", #"{"user":"m.okafor@kestrel.example"}"#, "PATCH", user),
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

    /// A refusal says what the Audit admin's role lacks, as Google answers 403 for anything outside it.
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
        let check = try await callTool(GoogleWorkspace.adapter, "check-access", "{}", on: service, in: workspace)
        XCTAssertFalse(check.isError, check.text)
        let lines = check.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("✓ Audit reports"), check.text)
        XCTAssertTrue(lines.contains("✓ Users"), check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("✗ Admin roles") && $0.contains("admin.directory.rolemanagement.readonly") && $0.contains("sign the tool in again") }, check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("✗ Groups") && $0.contains("Groups › Read") && $0.contains("role") }, check.text)
        XCTAssertTrue(lines.contains { $0.hasPrefix("✗ Mobile devices") && $0.contains("is turned off")
            && $0.contains("https://console.developers.google.com/apis/api/cloudidentity.googleapis.com/overview?project=123456") }, check.text)
        XCTAssertFalse(service.requests.contains { $0.url?.host == "cloudidentity.googleapis.com" }, "Cloud Identity needs a service account")
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
        // Cloud Identity's device API takes only a service account, so the admin's sign-in never asks for it.
        XCTAssertFalse(GoogleWorkspace.setup.joined().contains("cloud-identity"))
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
        XCTAssertEqual(queryItems(service.requests.first)["query"], "isAdmin=false",
                       "User Security Management never covers admins, so an admin's tokens would fail a healthy setup")
        let none = FakeService()
        none.answers["/admin/directory/v1/users"] = (200, #"{"users":[]}"#)
        let unchecked = try await callTool(GoogleWorkspace.containmentAdapter, "check-access", "{}", on: none, in: containment)
        XCTAssertTrue(unchecked.text.contains("not tried, as no account that is not an admin could be read"), unchecked.text)
    }

    /// Every page and API the Setup Steps name is a link to it, so nobody has to search Google's consoles.
    func testSetupStepsLinkEveryPageAndAPITheyName() {
        let links: [(String, [String], [String])] = [
            ("Google Workspace Audit", GoogleWorkspace.setup, ["console.cloud.google.com/apis/library/admin.googleapis.com",
                                                              "console.cloud.google.com/auth/overview", "console.cloud.google.com/auth/scopes",
                                                              "console.cloud.google.com/auth/clients", "admin.google.com/ac/roles"]),
            ("Google Workspace Containment", GoogleWorkspace.containmentSetup, ["admin.google.com/ac/roles", "console.cloud.google.com/apis/library/admin.googleapis.com",
                                                                               "console.cloud.google.com/auth/scopes", "console.cloud.google.com/auth/clients",
                                                                               "admin.google.com/ac/owl"]),
            ("Google Cloud", GoogleCloud.setup, ["console.cloud.google.com/apis/library/logging.googleapis.com", "console.cloud.google.com/apis/library/securitycenter.googleapis.com",
                                                 "console.cloud.google.com/apis/library/cloudasset.googleapis.com", "console.cloud.google.com/auth/overview",
                                                 "console.cloud.google.com/auth/scopes", "console.cloud.google.com/auth/clients",
                                                 "console.cloud.google.com/iam-admin/iam"]),
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
    /// be refused at sign-in, as Cloud Identity's device scopes are, which take only a service account, and an invalid
    /// one fails the whole sign-in. So a scope is added here only once it is on Google's list of scopes a sign-in can
    /// request (developers.google.com/identity/protocols/oauth2/scopes) and the API's own guide allows an admin's
    /// sign-in, or a live sign-in has taken it.
    static let checkedScopes: [String: String] = [
        "https://www.googleapis.com/auth/admin.reports.audit.readonly": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/admin.directory.user.readonly": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/admin.directory.group.readonly": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/admin.directory.device.mobile.readonly": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/admin.directory.domain.readonly": "on Google's scope list; Directory API, which takes an admin's own sign-in; domains.list accepts it",
        "https://www.googleapis.com/auth/admin.directory.user": "on Google's scope list",
        "https://www.googleapis.com/auth/admin.directory.user.security": "on Google's scope list",
        "https://www.googleapis.com/auth/logging.read": "on Google's scope list; live on the champion's tenant",
        "https://www.googleapis.com/auth/cloudasset": "not on Google's scope list, which gives only cloud-platform for Cloud Asset; taken by the champion's live sign-in",
        "https://www.googleapis.com/auth/securitycenter": "not on Google's scope list, which gives only cloud-platform for Security Command Center; taken by the champion's live sign-in",
    ]

    func testEveryGoogleScopeAskedForHasBeenChecked() throws {
        var tools = 0
        defer { XCTAssertEqual(tools, 3, "Google Workspace Audit, Google Workspace Containment and Google Cloud") }
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
    /// edition lacks, does not hold the rest back.
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
        XCTAssertEqual(refused.count, 1, "a report refused for good held back what the others found")
    }
}

