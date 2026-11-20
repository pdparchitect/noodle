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
        XCTAssertTrue(access.text.contains("HTTP 429") && access.text.contains("for consumer 'project_number:604757830675'"), access.text)
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
        for report in ["admin", "mobile", "rules"] { service.answers["/admin/reports/v1/activity/users/all/applications/" + report] = (200, "{}") }
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
}
