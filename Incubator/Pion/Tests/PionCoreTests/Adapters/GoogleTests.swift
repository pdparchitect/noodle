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
                                                           "https://www.googleapis.com/auth/cloud-identity.devices.readonly"]),
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
        XCTAssertEqual(found.map(\.id), ["login/101/suspicious_login", "admin/201/GRANT_ADMIN_PRIVILEGE", "mobile/301/DEVICE_COMPROMISED_EVENT",
                                         "rules/401/rule_trigger"])
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
        service.answers[directory + "/customer/my_customer/roleassignments"] = (200, #"{"items":[{"roleAssignmentId":"a1","roleId":"r-super","assignedTo":"u-1","assigneeType":"user","scopeType":"CUSTOMER"},{"roleAssignmentId":"a2","roleId":"r-super","assignedTo":"u-2","assigneeType":"user","scopeType":"CUSTOMER"},{"roleAssignmentId":"a3","roleId":"r-pion","assignedTo":"u-3","assigneeType":"user","scopeType":"ORG_UNIT","orgUnitId":"ou-1"},{"roleAssignmentId":"a4","roleId":"r-pion","assignedTo":"g-1","assigneeType":"group","scopeType":"CUSTOMER"}]}"#)
        service.answers[directory + "/users/u-3"] = (200, #"{"id":"u-3","primaryEmail":"pion@kestrel.example","isDelegatedAdmin":true}"#)
        let roles = try await callTool(GoogleWorkspace.adapter, "admin-roles", "{}", on: service, in: workspace)
        XCTAssertFalse(roles.isError, roles.text)
        let lines = roles.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("Super admins (2):") && lines[0].contains("ceo@kestrel.example (2-step verification off)"), roles.text)
        XCTAssertTrue(lines.contains { $0.contains("Pion Containment") && $0.contains("USERS_SUSPEND") && $0.contains("pion@kestrel.example (in one organisational unit)")
            && $0.contains("group g-1") }, roles.text)
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

    /// Laptops, desktops and phones the organisation knows, with who uses each and whether it is compromised,
    /// unencrypted or unmanaged.
    func testDevicesListEveryDeviceWithItsUsersAndRisks() async throws {
        let service = FakeService()
        service.answers["/v1/devices"] = (200, #"{"devices":[{"name":"devices/d1","deviceType":"MAC_OS","model":"MacBook Pro","osVersion":"MacOS 15.1","ownerType":"COMPANY","encryptionState":"NOT_ENCRYPTED","managementState":"APPROVED","compromisedState":"UNCOMPROMISED","lastSyncTime":"2026-11-20T09:00:00Z","serialNumber":"C02X"},{"name":"devices/d2","deviceType":"ANDROID","model":"Pixel 8","compromisedState":"COMPROMISED","lastSyncTime":"2026-11-19T09:00:00Z"}]}"#)
        service.answers["/v1/devices/-/deviceUsers"] = (200, #"{"deviceUsers":[{"name":"devices/d1/deviceUsers/u1","userEmail":"ivana@kestrel.example","managementState":"APPROVED"},{"name":"devices/d2/deviceUsers/u2","userEmail":"nick@kestrel.example"}]}"#)
        let all = try await callTool(GoogleWorkspace.adapter, "devices", "{}", on: service, in: workspace)
        XCTAssertFalse(all.isError, all.text)
        let lines = all.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("Pixel 8") && lines[0].contains("compromised") && lines[0].contains("nick@kestrel.example"), all.text)
        XCTAssertTrue(lines.contains { $0.contains("MacBook Pro") && $0.contains("not encrypted") && $0.contains("ivana@kestrel.example") }, all.text)
        XCTAssertEqual(service.requests.first?.url?.host, "cloudidentity.googleapis.com")
        XCTAssertEqual(queryItems(service.requests.first)["customer"], "customers/my_customer")
        let hers = try await callTool(GoogleWorkspace.adapter, "devices", #"{"user":"ivana@kestrel.example"}"#, on: service, in: workspace)
        XCTAssertTrue(hers.text.contains("MacBook Pro") && !hers.text.contains("Pixel 8"), hers.text)
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
}

