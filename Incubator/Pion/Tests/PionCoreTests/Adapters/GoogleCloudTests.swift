import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

/// Google Cloud Detection says what it searched and what it could not, keeps what it found when a later read fails, and
/// says exactly what to change when Google refuses it.
final class GoogleCloudTests: XCTestCase {
    private let cloud = try! GoogleCloud.preset.makeConnection(name: "Google Cloud — Kestrel", values: [
        "level": "organizations", "id": "123456789", "clientID": "1234-abc.apps.googleusercontent.com"])
    private let project = try! GoogleCloud.preset.makeConnection(name: "Google Cloud — Prod", values: [
        "level": "projects", "id": "kestrel-prod", "clientID": "1234-abc.apps.googleusercontent.com"])

    private let assets = "/v1/organizations/123456789/assets"
    private let entries = "/v2/entries:list"

    private func json(_ request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
    }

    private func searches(_ service: FakeService) -> [URLRequest] { service.requests.filter { $0.url?.host == "logging.googleapis.com" } }

    private static func project(_ id: String, number: Int, state: String = "ACTIVE") -> String {
        #"{"name":"//cloudresourcemanager.googleapis.com/projects/\#(number)","assetType":"cloudresourcemanager.googleapis.com/Project","resource":{"data":{"projectId":"\#(id)","lifecycleState":"\#(state)"}}}"#
    }

    private static func folder(_ number: Int, state: String = "ACTIVE") -> String {
        #"{"name":"//cloudresourcemanager.googleapis.com/folders/\#(number)","assetType":"cloudresourcemanager.googleapis.com/Folder","resource":{"data":{"name":"folders/\#(number)","displayName":"Folder \#(number)","lifecycleState":"\#(state)"}}}"#
    }

    private static func listing(_ assets: [String], next: String? = nil) -> String {
        #"{"assets":[\#(assets.joined(separator: ","))]\#(next.map { #","nextPageToken":"\#($0)""# } ?? "")}"#
    }

    private static func entry(_ time: String, _ method: String, by principal: String, key: String? = nil, delegatedBy: String? = nil, on resource: String,
                              target: String? = nil, in log: String, id: String, status: String = "{}") -> String {
        let keyName = key.map { #","serviceAccountKeyName":"//iam.googleapis.com/projects/kestrel-prod/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com/keys/\#($0)""# } ?? ""
        let delegation = delegatedBy.map { #","serviceAccountDelegationInfo":[{"firstPartyPrincipal":{"principalEmail":"\#($0)"}}]"# } ?? ""
        let request = target.map { #","request":{"@type":"type.googleapis.com/google.iam.admin.v1.CreateServiceAccountKeyRequest","name":"\#($0)"}"# } ?? ""
        return #"{"insertId":"\#(id)","timestamp":"\#(time)","logName":"\#(log)/logs/cloudaudit.googleapis.com%2Factivity","resource":{"type":"audited_resource","labels":{"project_id":"kestrel-prod"}},"protoPayload":{"methodName":"\#(method)","resourceName":"\#(resource)","authenticationInfo":{"principalEmail":"\#(principal)"\#(keyName)\#(delegation)},"requestMetadata":{"callerIp":"203.0.113.77"}\#(request),"status":\#(status)}}"#
    }

    private static func page(_ entries: [String], next: String? = nil) -> String {
        #"{"entries":[\#(entries.joined(separator: ","))]\#(next.map { #","nextPageToken":"\#($0)""# } ?? "")}"#
    }

    // MARK: Finn's case: a stolen token, a key made, a bucket read

    func testABucketReadInAnotherProjectThanTheIAMChangeIsFoundAndSaysWhereEachWasLogged() async throws {
        let service = FakeService()
        service.answers[assets] = (200, Self.listing([Self.project("kestrel-prod", number: 1001), Self.project("kestrel-data", number: 1003)]))
        service.answers[entries] = (200, Self.page([
            Self.entry("2026-11-14T10:00:00Z", "storage.objects.get", by: "ci@kestrel-prod.iam.gserviceaccount.com", key: "k1",
                       on: "projects/_/buckets/payroll/objects/2026.csv", in: "projects/kestrel-data", id: "read-1"),
            Self.entry("2026-11-14T09:00:00Z", "SetIamPolicy", by: "mallory@kestrel.example", on: "projects/kestrel-prod", in: "projects/kestrel-prod", id: "grant-1"),
        ]))
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"since":"2026-11-13T00:00:00Z"}"#, on: service, in: cloud)
        XCTAssertFalse(logs.isError, logs.text)
        XCTAssertEqual(try json(searches(service).first)["resourceNames"] as? [String], ["organizations/123456789", "projects/kestrel-prod", "projects/kestrel-data"])
        XCTAssertTrue(logs.text.contains("storage.objects.get by ci@kestrel-prod.iam.gserviceaccount.com with key k1 from 203.0.113.77 on projects/_/buckets/payroll/objects/2026.csv in projects/kestrel-data"), logs.text)
        XCTAssertTrue(logs.text.contains("SetIamPolicy by mallory@kestrel.example from 203.0.113.77 on projects/kestrel-prod in projects/kestrel-prod"), logs.text)
        XCTAssertTrue(logs.text.contains("[insertId read-1]"), logs.text)
        XCTAssertTrue(logs.text.contains("Searched: organizations/123456789, projects/kestrel-prod and projects/kestrel-data, from 2026-11-13T00:00:00Z to now."), logs.text)
    }

    func testEachEntrySaysWhichKeyAndDelegationActedAndAMissingKeyIsUnknown() async throws {
        let service = FakeService()
        let sa = "ci@kestrel-prod.iam.gserviceaccount.com"
        service.answers[entries] = (200, Self.page([
            Self.entry("2026-11-14T12:00:00Z", "storage.objects.get", by: sa, key: "k2", on: "projects/_/buckets/payroll", in: "projects/kestrel-prod", id: "e4"),
            Self.entry("2026-11-14T11:00:00Z", "storage.objects.get", by: sa, on: "projects/_/buckets/payroll", in: "projects/kestrel-prod", id: "e3"),
            Self.entry("2026-11-14T10:30:00Z", "storage.objects.list", by: sa, delegatedBy: "mallory@kestrel.example", on: "projects/_/buckets/payroll", in: "projects/kestrel-prod", id: "e5"),
            Self.entry("2026-11-14T10:00:00Z", "storage.objects.get", by: sa, key: "k1", on: "projects/_/buckets/payroll", in: "projects/kestrel-prod", id: "e2"),
            Self.entry("2026-11-14T09:00:00Z", "google.iam.admin.v1.CreateServiceAccountKey", by: "mallory@kestrel.example", on: "projects/-/serviceAccounts/1234567890",
                       target: "projects/-/serviceAccounts/\(sa)", in: "projects/kestrel-prod", id: "e1"),
        ]))
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: service, in: project)
        XCTAssertFalse(logs.isError, logs.text)
        let lines = logs.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("by \(sa) with key k2"), lines[0])
        XCTAssertTrue(lines[1].contains("by \(sa) with key unknown"), lines[1])
        XCTAssertTrue(lines[2].contains("by \(sa) (delegated by mallory@kestrel.example)") && !lines[2].contains("key unknown"), lines[2])
        XCTAssertTrue(lines[3].contains("by \(sa) with key k1"), lines[3])
        // The key was made for the account the request names, as the resource is only its number.
        XCTAssertTrue(lines[4].contains("on projects/-/serviceAccounts/1234567890 (target projects/-/serviceAccounts/\(sa))"), lines[4])
        XCTAssertFalse(lines[4].contains(" in projects/kestrel-prod"), "a project's own account repeated its project: \(lines[4])")
        XCTAssertTrue(logs.text.contains("not proof of who held it"), logs.text)
        let kept = try XCTUnwrap(logs.structured?["entries"] as? [[String: Any]])
        let auth = (kept[0]["protoPayload"] as? [String: Any])?["authenticationInfo"] as? [String: Any]
        XCTAssertEqual(auth?["serviceAccountKeyName"] as? String, "//iam.googleapis.com/projects/kestrel-prod/serviceAccounts/\(sa)/keys/k2")
        XCTAssertEqual(kept[4]["insertId"] as? String, "e1")
        XCTAssertEqual((kept[4]["resource"] as? [String: Any])?["type"] as? String, "audited_resource")
        XCTAssertEqual(((kept[4]["protoPayload"] as? [String: Any])?["request"] as? [String: Any])?["name"] as? String, "projects/-/serviceAccounts/\(sa)")
    }

    func testAnEmptySearchSaysWhatWasSearchedAndThatDataReadsAreUnknownWhileARefusalSaysWhatToChange() async throws {
        let empty = FakeService()
        empty.answers[entries] = (200, "{}")
        let none = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"since":"2026-11-01T00:00:00Z","until":"2026-11-02T00:00:00Z"}"#, on: empty, in: project)
        XCTAssertFalse(none.isError, none.text)
        XCTAssertTrue(none.text.contains("No audit log entries match in projects/kestrel-prod, from 2026-11-01T00:00:00Z to 2026-11-02T00:00:00Z."), none.text)
        XCTAssertTrue(none.text.contains("off by default") && none.text.contains("Private Logs Viewer") && none.text.contains("unknown, not none"), none.text)

        let denied = FakeService()
        denied.answers[entries] = (403, #"{"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}"#)
        let refused = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: denied, in: project)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("Logs Viewer (roles/logging.viewer)") && refused.text.contains("on projects/kestrel-prod") && refused.text.contains("check-access"), refused.text)

        let scope = FakeService()
        scope.answers[entries] = (403, #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]}}"#)
        let scopeless = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: scope, in: project)
        XCTAssertTrue(scopeless.text.contains("lacks the scope https://www.googleapis.com/auth/logging.read"), scopeless.text)

        let off = FakeService()
        off.answers[entries] = (403, #"{"error":{"code":403,"message":"Cloud Logging API has not been used in project 604757830675 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/logging.googleapis.com/overview?project=604757830675 then retry.","status":"PERMISSION_DENIED"}}"#)
        let disabled = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: off, in: project)
        XCTAssertTrue(disabled.text.contains("enable it at https://console.developers.google.com/apis/api/logging.googleapis.com/overview?project=604757830675"), disabled.text)

        let expired = FakeService()
        expired.answers[entries] = (401, #"{"error":{"code":401,"message":"Request had invalid authentication credentials.","status":"UNAUTHENTICATED"}}"#)
        let signIn = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: expired, in: project)
        XCTAssertTrue(signIn.text.contains("sign the tool in again"), signIn.text)
    }

    func testALaterPageRefusedOrRateLimitedKeepsTheEvidenceAlreadyRead() async throws {
        let first = Self.page([Self.entry("2026-11-14T09:00:00Z", "google.iam.admin.v1.CreateServiceAccountKey", by: "mallory@kestrel.example",
                                          on: "projects/-/serviceAccounts/1", in: "projects/kestrel-prod", id: "key-made")], next: "page-2")
        for failure in [(429, #"{"error":{"code":429,"message":"Quota exceeded for quota metric 'Read requests' and limit 'Read requests per minute'","status":"RESOURCE_EXHAUSTED"}}"#),
                        (403, #"{"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}"#)] {
            let service = FakeService()
            service.sequences[entries] = [(200, first), failure]
            let logs = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: service, in: project)
            XCTAssertFalse(logs.isError, logs.text)
            XCTAssertTrue(logs.text.contains("CreateServiceAccountKey by mallory@kestrel.example"), logs.text)
            XCTAssertTrue(logs.text.contains("Read only in part: projects/kestrel-prod") && logs.text.contains("at or before 2026-11-14T09:00:00Z may be missing")
                          && logs.text.contains("until 2026-11-14T09:00:00Z, which includes that moment"), logs.text)
            XCTAssertEqual(service.requests.count, 2, "a refusal was asked again")
            let coverage = try XCTUnwrap(logs.structured?["coverage"] as? [String: Any])
            XCTAssertEqual((coverage["partial"] as? [Any])?.count, 1)
            XCTAssertEqual(((coverage["continuations"] as? [[String: Any]])?.first)?["pageToken"] as? String, "page-2")
        }
    }

    // MARK: Coverage

    func testEveryProjectIsListedPageByPageAndSearchedInSearchesOfAHundred() async throws {
        let service = FakeService()
        let firstPage = (0..<600).map { Self.project("p\($0)", number: 10_000 + $0) }
        let secondPage = (600..<750).map { Self.project("p\($0)", number: 10_000 + $0) } + [Self.folder(42), Self.folder(43)]
        service.sequences[assets] = [(200, Self.listing(firstPage, next: "more")), (200, Self.listing(secondPage))]
        service.answers[entries] = (200, "{}")
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: service, in: cloud)
        XCTAssertFalse(logs.isError, logs.text)
        let listings = service.requests.filter { $0.url?.host == "cloudasset.googleapis.com" }
        XCTAssertEqual(listings.count, 2)
        XCTAssertEqual(queryItems(listings[0])["pageSize"], "1000")
        XCTAssertEqual(queryItems(listings[1])["pageToken"], "more")
        XCTAssertTrue(listings[0].url?.query?.contains("assetTypes=cloudresourcemanager.googleapis.com/Folder") == true, "folders were not listed")
        let sent = try searches(service).map { try XCTUnwrap(json($0)["resourceNames"] as? [String]) }
        XCTAssertEqual(sent.count, 8)
        XCTAssertTrue(sent.allSatisfy { $0.count <= 100 }, "a search named more resources than Logging takes")
        XCTAssertEqual(Set(sent.joined()), Set(["organizations/123456789", "folders/42", "folders/43"] + (0..<750).map { "projects/p\($0)" }))
        XCTAssertEqual(Array(sent[0].prefix(3)), ["organizations/123456789", "folders/42", "folders/43"], "folders were not searched first")
        XCTAssertTrue(logs.text.contains("Searched: organizations/123456789, 2 folders and 750 projects"), logs.text)

        // More than the searches one call sends reach: those past it are named, not silently dropped.
        let huge = FakeService()
        huge.answers[assets] = (200, Self.listing((0..<2500).map { Self.project("p\($0)", number: 10_000 + $0) }))
        huge.answers[entries] = (200, "{}")
        let capped = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: huge, in: cloud)
        XCTAssertFalse(capped.isError, capped.text)
        XCTAssertEqual(searches(huge).count, GoogleCloud.searchRequests)
        XCTAssertTrue(capped.text.contains("Not searched, over the 20 Logging requests one search sends: 501 projects"), capped.text)
        XCTAssertFalse(capped.text.contains("No audit log entries match"), "a search that left projects out said nothing matched: \(capped.text)")
        let notSearched = try XCTUnwrap((capped.structured?["coverage"] as? [String: Any])?["notSearched"] as? [[String: Any]])
        XCTAssertEqual(notSearched.flatMap { $0["resources"] as? [String] ?? [] }.count, 501)
    }

    func testAFoldersOwnLogsAreSearchedAndSaidWhereAnEntryWasLogged() async throws {
        let service = FakeService()
        service.answers[assets] = (200, Self.listing([Self.folder(42), Self.project("kestrel-prod", number: 1001)]))
        service.answers[entries] = (200, #"{"entries":[\#(Self.entry("2026-11-14T09:00:00Z", "SetIamPolicy", by: "mallory@kestrel.example", on: "folders/42", in: "folders/42", id: "f1"))]}"#)
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: service, in: cloud)
        XCTAssertEqual(try json(searches(service).first)["resourceNames"] as? [String], ["organizations/123456789", "folders/42", "projects/kestrel-prod"])
        XCTAssertTrue(logs.text.contains("SetIamPolicy by mallory@kestrel.example from 203.0.113.77 on folders/42 in folders/42"), logs.text)
    }

    func testAProjectListingThatFailsStillSearchesTheScopesOwnLogs() async throws {
        let service = FakeService()
        service.answers[assets] = (403, #"{"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}"#)
        service.answers[entries] = (200, #"{"entries":[\#(Self.entry("2026-11-14T09:00:00Z", "SetIamPolicy", by: "mallory@kestrel.example", on: "organizations/123456789", in: "organizations/123456789", id: "o1"))]}"#)
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: service, in: cloud)
        XCTAssertFalse(logs.isError, logs.text)
        XCTAssertEqual(try json(searches(service).first)["resourceNames"] as? [String], ["organizations/123456789"])
        XCTAssertTrue(logs.text.contains("SetIamPolicy by mallory@kestrel.example"), logs.text)
        XCTAssertTrue(logs.text.contains("could not be listed, so only its own logs were searched") && logs.text.contains("Cloud Asset Viewer"), logs.text)
    }

    func testMoreEntriesThanTheLimitAreSaidToExist() async throws {
        let service = FakeService()
        service.answers[entries] = (200, #"{"entries":[\#(Self.entry("2026-11-14T09:00:00Z", "SetIamPolicy", by: "mallory@kestrel.example", on: "projects/kestrel-prod", in: "projects/kestrel-prod", id: "a"))],"nextPageToken":"more"}"#)
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"limit":1}"#, on: service, in: project)
        XCTAssertTrue(logs.text.contains("More entries match than the 1 kept: some at or before 2026-11-14T09:00:00Z") && logs.text.contains("which includes that moment"), logs.text)
        XCTAssertEqual((logs.structured?["coverage"] as? [String: Any])?["more"] as? Bool, true)
        XCTAssertEqual(service.requests.count, 1)
    }

    func testAWindowGivenOnlyItsEndReachesThirtyDaysBackFromItAndNeverEndsBeforeItStarts() async throws {
        let service = FakeService()
        service.answers[entries] = (200, "{}")
        _ = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"principal":"Mallory@Kestrel.Example","until":"2026-09-01T00:00:00Z"}"#, on: service, in: project)
        let filter = try XCTUnwrap(json(service.requests.first)["filter"] as? String)
        XCTAssertTrue(filter.hasSuffix(#"serviceAccountDelegationInfo.firstPartyPrincipal.principalEmail="mallory@kestrel.example") AND timestamp>="2026-08-02T00:00:00Z" AND timestamp<="2026-09-01T00:00:00Z""#), filter)

        let backwards = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"since":"2026-10-01T00:00:00Z","until":"2026-09-01T00:00:00Z"}"#, on: service, in: project)
        XCTAssertTrue(backwards.isError)
        XCTAssertTrue(backwards.text.contains("after until"), backwards.text)
        XCTAssertEqual(service.requests.count, 1)
    }

    func testFailedAndSuccessfulEntriesAreToldApart() async throws {
        let service = FakeService()
        let denied = #"{"code":7,"message":"PERMISSION_DENIED"}"#
        service.answers[entries] = (200, Self.page([
            Self.entry("2026-11-14T09:01:00Z", "SetIamPolicy", by: "mallory@kestrel.example", on: "projects/kestrel-prod", in: "projects/kestrel-prod", id: "b", status: denied),
            Self.entry("2026-11-14T09:00:00Z", "SetIamPolicy", by: "mallory@kestrel.example", on: "projects/kestrel-prod", in: "projects/kestrel-prod", id: "a"),
        ]))
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: service, in: project)
        XCTAssertTrue(logs.text.contains("— failed (PERMISSION_DENIED)"), logs.text)
        XCTAssertTrue(logs.text.contains("1 succeeded and 1 failed"), logs.text)
        XCTAssertEqual(logs.structured?["failed"] as? Int, 1)
    }

    // MARK: Findings

    func testMutedFindingsAreLeftOutUnlessAskedForAndEachSaysItsClassWhoActedAndHowManyMatched() async throws {
        let service = FakeService()
        let path = "/v2/organizations/123456789/sources/-/findings"
        let threat = #"{"finding":{"name":"organizations/123456789/sources/9/findings/t1","category":"Persistence: IAM Anomalous Grant","severity":"HIGH","state":"ACTIVE","findingClass":"THREAT","mute":"UNDEFINED","eventTime":"2026-11-14T09:00:00Z","externalUri":"https://console.cloud.google.com/security/command-center/findings?x=t1","access":{"principalEmail":"mallory@kestrel.example","callerIp":"203.0.113.77","methodName":"SetIamPolicy"}},"resource":{"displayName":"kestrel-prod"}}"#
        let muted = #"{"finding":{"name":"organizations/123456789/sources/1/findings/m1","category":"PUBLIC_IP_ADDRESS","severity":"HIGH","state":"ACTIVE","findingClass":"MISCONFIGURATION","mute":"MUTED","eventTime":"2026-11-14T08:00:00Z"},"resource":{"displayName":"web-01"}}"#
        service.sequences[path] = [(200, #"{"listFindingsResults":[\#(threat)],"nextPageToken":"p2","totalSize":400}"#),
                                   (200, #"{"listFindingsResults":[\#(threat)],"nextPageToken":"p3","totalSize":400}"#)]
        let findings = try await callTool(GoogleCloud.adapter, "scc-findings", #"{"limit":2}"#, on: service, in: cloud)
        XCTAssertFalse(findings.isError, findings.text)
        XCTAssertEqual(queryItems(service.requests.first)["filter"], #"state="ACTIVE" AND NOT mute="MUTED" AND (severity="CRITICAL" OR severity="HIGH")"#)
        XCTAssertEqual(queryItems(service.requests.last)["pageToken"], "p2", "the next page was not read")
        XCTAssertTrue(findings.text.contains("2026-11-14T09:00:00Z HIGH THREAT Persistence: IAM Anomalous Grant — kestrel-prod; by mallory@kestrel.example from 203.0.113.77 calling SetIamPolicy (https://console.cloud.google.com/security/command-center/findings?x=t1) [organizations/123456789/sources/9/findings/t1]"), findings.text)
        XCTAssertTrue(findings.text.contains("Showing 2 of the 400 matching findings; more exist"), findings.text)
        XCTAssertTrue(findings.text.contains("Muted findings are left out"), findings.text)
        XCTAssertEqual(findings.structured?["totalSize"] as? Int, 400)
        XCTAssertEqual(findings.structured?["nextPageToken"] as? String, "p3")

        let all = FakeService()
        all.answers[path] = (200, #"{"listFindingsResults":[\#(muted)],"totalSize":1}"#)
        let withMuted = try await callTool(GoogleCloud.adapter, "scc-findings", #"{"includeMuted":true}"#, on: all, in: cloud)
        XCTAssertEqual(queryItems(all.requests.first)["filter"], #"state="ACTIVE" AND (severity="CRITICAL" OR severity="HIGH")"#)
        XCTAssertTrue(withMuted.text.contains("PUBLIC_IP_ADDRESS — web-01, muted"), withMuted.text)
        XCTAssertFalse(withMuted.text.contains("Muted findings are left out"), withMuted.text)

        let none = FakeService()
        none.answers[path] = (200, "{}")
        let empty = try await callTool(GoogleCloud.adapter, "scc-findings", "{}", on: none, in: cloud)
        XCTAssertTrue(empty.text.contains("No active critical and high findings at organizations/123456789, leaving out muted ones.") && empty.text.contains("Premium and Enterprise"), empty.text)
    }

    // MARK: IAM

    func testABareEmailThatIsAGroupIsCheckedAsAGroupWhenNoUserHasIt() async throws {
        let service = FakeService()
        let path = "/v1/organizations/123456789:analyzeIamPolicy"
        service.sequences[path] = [(200, #"{"mainAnalysis":{"fullyExplored":true}}"#), (200, #"""
        {"mainAnalysis":{"fullyExplored":true,"analysisResults":[{"attachedResourceFullName":"//cloudresourcemanager.googleapis.com/organizations/123456789",
          "iamBinding":{"role":"roles/owner","members":["group:admins@kestrel.example"]},"identityList":{"identities":[{"name":"group:admins@kestrel.example"}]}}]}}
        """#)]
        service.answers[assets] = (200, Self.listing([]))
        let access = try await callTool(GoogleCloud.adapter, "iam-policies", #"{"member":"Admins@kestrel.example"}"#, on: service, in: cloud)
        XCTAssertFalse(access.isError, access.text)
        let asked = service.requests.filter { $0.url?.path == path }.map { queryItems($0)["analysisQuery.identitySelector.identity"] }
        XCTAssertEqual(asked, ["user:admins@kestrel.example", "group:admins@kestrel.example"])
        XCTAssertTrue(access.text.contains("organizations/123456789: roles/owner to group:admins@kestrel.example"), access.text)
        XCTAssertTrue(access.text.contains("user:admins@kestrel.example has no access, so this is group:admins@kestrel.example."), access.text)
        XCTAssertEqual(access.structured?["checkedAs"] as? [String], ["user:admins@kestrel.example", "group:admins@kestrel.example"])

        let nobody = FakeService()
        nobody.answers[path] = (200, #"{"mainAnalysis":{"fullyExplored":true}}"#)
        let none = try await callTool(GoogleCloud.adapter, "iam-policies", #"{"member":"nobody@kestrel.example"}"#, on: nobody, in: cloud)
        XCTAssertTrue(none.text.contains("No access matches for user:nobody@kestrel.example or group:nobody@kestrel.example across organizations/123456789."), none.text)
        XCTAssertTrue(none.text.contains("deny policies") , none.text)
    }

    func testAnAnalysisSaysWhatItCouldNotCoverConditionsAndATimeout() async throws {
        let service = FakeService()
        service.answers["/v1/organizations/123456789:analyzeIamPolicy"] = (200, #"""
        {"fullyExplored":false,"mainAnalysis":{"fullyExplored":false,"nonCriticalErrors":[{"code":"PERMISSION_DENIED","cause":"Failed to expand group admins@kestrel.example: groups.read is missing"}],
          "analysisResults":[{"attachedResourceFullName":"//cloudresourcemanager.googleapis.com/projects/kestrel-prod",
            "iamBinding":{"role":"roles/editor","members":["user:mallory@kestrel.example"],"condition":{"title":"Until Friday","expression":"request.time < timestamp('2026-11-21T00:00:00Z')"}},
            "accessControlLists":[{"conditionEvaluation":{"evaluationValue":"CONDITIONAL"}}]}]}}
        """#)
        // The projects pending deletion cannot be listed for now: what was analysed is kept.
        service.answers[assets] = (429, #"{"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#)
        let access = try await callTool(GoogleCloud.adapter, "iam-policies", #"{"member":"mallory@kestrel.example"}"#, on: service, in: cloud)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("roles/editor to user:mallory@kestrel.example — only when Until Friday (conditional)"), access.text)
        XCTAssertTrue(access.text.contains("Google could not analyse all of it: PERMISSION_DENIED: Failed to expand group") && access.text.contains("Groups Reader"), access.text)
        XCTAssertTrue(access.text.contains("The analysis was not complete"), access.text)
        XCTAssertTrue(access.text.contains("pending deletion could not be checked"), access.text)
        XCTAssertEqual((access.structured?["nonCriticalErrors"] as? [Any])?.count, 1)
        XCTAssertEqual(access.structured?["fullyExplored"] as? Bool, false)

        let slow = FakeService()
        slow.answers["/v1/organizations/123456789:analyzeIamPolicy"] = (504, #"{"error":{"code":504,"message":"Deadline expired before operation could complete.","status":"DEADLINE_EXCEEDED"}}"#)
        let timedOut = try await callTool(GoogleCloud.adapter, "iam-policies", #"{"member":"serviceAccount:ci@kestrel-prod.iam.gserviceaccount.com"}"#, on: slow, in: cloud)
        XCTAssertTrue(timedOut.isError)
        XCTAssertTrue(timedOut.text.contains("narrow it with a role or a resource"), timedOut.text)
        XCTAssertEqual(slow.requests.count, 1, "a service account was asked about as a group too")
    }

    func testFindResourcesReadsOnBeforeSayingNothingMatches() async throws {
        let service = FakeService()
        let instance = { (name: String) in #"{"name":"//compute.googleapis.com/projects/kestrel-prod/zones/us-central1-a/instances/\#(name)","assetType":"compute.googleapis.com/Instance","resource":{"location":"us-central1-a","data":{"status":"RUNNING"}}}"# }
        service.sequences["/v1/projects/kestrel-prod/assets"] = [(200, Self.listing((0..<5).map { instance("web-\($0)") }, next: "p2")),
                                                                 (200, Self.listing([instance("miner-01")]))]
        let found = try await callTool(GoogleCloud.adapter, "find-resources", #"{"assetTypes":["compute.googleapis.com/Instance"],"name":"miner"}"#, on: service, in: project)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("miner-01 (compute.googleapis.com/Instance) in us-central1-a, RUNNING"), found.text)
        XCTAssertEqual(queryItems(service.requests.first)["pageSize"], "1000")
        XCTAssertEqual(queryItems(service.requests.last)["pageToken"], "p2")
        XCTAssertEqual(found.structured?["read"] as? Int, 6)
    }

    // MARK: check-access

    func testCheckAccessSaysWhatWorksWhatToFixAndWhetherTheSignInCouldChangeFindingsWithoutChangingAnything() async throws {
        let service = FakeService()
        // Logging answers, though no Data Access entry comes back; Cloud Asset is turned off; findings are readable.
        service.sequences[entries] = [(200, "{}"), (200, "{}")]
        service.answers[assets] = (403, #"{"error":{"code":403,"message":"Cloud Asset API has not been used in project 604757830675 before or it is disabled. Enable it by visiting https://console.developers.google.com/apis/api/cloudasset.googleapis.com/overview?project=604757830675 then retry.","status":"PERMISSION_DENIED"}}"#)
        service.answers["/v1/organizations/123456789:analyzeIamPolicy"] = (403, #"{"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}"#)
        service.answers["/v2/organizations/123456789/sources/-/findings"] = (200, "{}")
        service.answers["/v2/organizations/123456789/sources"] = (200, #"{"sources":[{"name":"organizations/123456789/sources/1","displayName":"Security Health Analytics"}]}"#)
        service.answers["/v2/organizations/123456789/sources/1:testIamPermissions"] = (200, #"{"permissions":["securitycenter.findings.setMute"]}"#)
        let check = try await callTool(GoogleCloud.adapter, "check-access", "{}", on: service, in: cloud)
        XCTAssertFalse(check.isError, check.text)
        XCTAssertTrue(check.text.contains("✓ Audit logs"), check.text)
        XCTAssertTrue(check.text.contains("· Data Access audit logs: none came back") && check.text.contains("not established"), check.text)
        XCTAssertTrue(check.text.contains("✗ Cloud Asset listing: the Cloud Asset API is turned off") && check.text.contains("https://console.developers.google.com/apis/api/cloudasset.googleapis.com/overview?project=604757830675"), check.text)
        XCTAssertTrue(check.text.contains("✗ IAM analysis: the account signed in may not do this on organizations/123456789: grant it Cloud Asset Viewer"), check.text)
        XCTAssertTrue(check.text.contains("✓ Security Command Center findings"), check.text)
        XCTAssertTrue(check.text.contains("services reporting here: Security Health Analytics") && check.text.contains("Event Threat Detection is not among them"), check.text)
        XCTAssertTrue(check.text.contains("⚠ The account signed in can change findings: on organizations/123456789/sources/1 it holds securitycenter.findings.setMute"), check.text)
        XCTAssertEqual(try json(service.requests.last)["permissions"] as? [String], GoogleCloud.CheckAccess.writes)
        // Only reads: GETs, Logging's search, and asking which permissions the sign-in holds.
        for request in service.requests where request.httpMethod != "GET" {
            let path = request.url?.path ?? ""
            XCTAssertTrue(path == entries || path.hasSuffix(":testIamPermissions"), "check-access sent \(request.httpMethod ?? "?") \(path)")
        }
        XCTAssertNil(service.requests.first { $0.url?.path.contains("setMute") == true || $0.url?.path.contains("setState") == true })

        let healthy = FakeService()
        healthy.sequences[entries] = [(200, "{}"), (200, #"{"entries":[{"timestamp":"2026-11-20T09:00:00Z"}]}"#)]
        healthy.answers[assets] = (200, "{}")
        healthy.answers["/v1/organizations/123456789:analyzeIamPolicy"] = (200, "{}")
        healthy.answers["/v2/organizations/123456789/sources/-/findings"] = (400, #"{"error":{"code":400,"message":"Security Command Center is not activated for organization 123456789.","status":"FAILED_PRECONDITION"}}"#)
        healthy.answers["/v2/organizations/123456789/sources"] = (200, #"{"sources":[{"name":"organizations/123456789/sources/9","displayName":"Event Threat Detection"}]}"#)
        healthy.answers["/v2/organizations/123456789/sources/9:testIamPermissions"] = (200, "{}")
        let good = try await callTool(GoogleCloud.adapter, "check-access", "{}", on: healthy, in: cloud)
        XCTAssertTrue(good.text.contains("✓ Data Access audit logs: readable"), good.text)
        XCTAssertTrue(good.text.contains("✓ Cloud Asset listing") && good.text.contains("✓ IAM analysis"), good.text)
        XCTAssertTrue(good.text.contains("✗ Security Command Center findings: Security Command Center is not activated where this account looks"), good.text)
        XCTAssertTrue(good.text.contains("✓ The account signed in cannot mute or change findings"), good.text)
        XCTAssertFalse(good.text.contains("Event Threat Detection is not among them"), good.text)
    }

    // MARK: Audit log filters

    private static let denied403 = #"{"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}"#

    func testNoInputCanBreakOutOfTheLoggingFilterAndNothingIsSentWhenOneTries() async throws {
        let service = FakeService()
        service.answers[entries] = (200, "{}")
        for arguments in [#"{"principal":"mallory@kestrel.example\" OR \"1\"=\"1"}"#, #"{"principal":"mallory@kestrel.example\\"}"#,
                          #"{"method":"SetIamPolicy\" OR log_id(\"x\")"}"#, #"{"resource":"projects/a\nprojects/b"}"#,
                          #"{"ip":"203.0.113.77\" OR \"1"}"#, #"{"ip":"not-an-address"}"#, #"{"service":"storage.googleapis.com\" OR \"x"}"#,
                          #"{"status":"maybe"}"#, #"{"logType":"activity\") OR (\"x"}"#,
                          #"{"logViews":["projects/siem/locations/global/buckets/audit/views/v\" OR \"x"]}"#, #"{"logViews":["projects/siem"]}"#] {
            let refused = try await callTool(GoogleCloud.adapter, "audit-logs", arguments, on: service, in: project)
            XCTAssertTrue(refused.isError, "\(arguments) was taken: \(refused.text)")
        }
        XCTAssertTrue(service.requests.isEmpty, "a request was sent for an input that could break the filter")
    }

    func testIPStatusServiceAndLogTypeNarrowTheFilterAsLoggingTakesThem() async throws {
        let service = FakeService()
        service.answers[entries] = (200, "{}")
        let since = #""since":"2026-11-13T00:00:00Z""#
        let none = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"ip":"203.0.113.77","status":"denied","service":"Storage.googleapis.com","logType":"data_access",\#(since)}"#, on: service, in: project)
        XCTAssertFalse(none.isError, none.text)
        XCTAssertEqual(try json(searches(service).last)["filter"] as? String,
            #"log_id("cloudaudit.googleapis.com/data_access") AND protoPayload.requestMetadata.callerIp="203.0.113.77" AND protoPayload.status.code=7 AND protoPayload.serviceName="storage.googleapis.com" AND timestamp>="2026-11-13T00:00:00Z""#)
        XCTAssertEqual(none.structured?["filter"] as? String, try json(searches(service).last)["filter"] as? String)
        // A Data Access search that finds nothing points to where enablement can be established.
        XCTAssertTrue(none.text.contains("unknown, not none") && none.text.contains("logging-coverage"), none.text)

        _ = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"ip":"2001:db8::1","status":"failed","logType":"activity",\#(since)}"#, on: service, in: project)
        XCTAssertEqual(try json(searches(service).last)["filter"] as? String,
            #"log_id("cloudaudit.googleapis.com/activity") AND protoPayload.requestMetadata.callerIp="2001:db8::1" AND protoPayload.status.code!=0 AND timestamp>="2026-11-13T00:00:00Z""#)
        let activity = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"status":"succeeded","logType":"policy",\#(since)}"#, on: service, in: project)
        XCTAssertEqual(try json(searches(service).last)["filter"] as? String,
            #"log_id("cloudaudit.googleapis.com/policy") AND (NOT protoPayload.status.code:* OR protoPayload.status.code=0) AND timestamp>="2026-11-13T00:00:00Z""#)
        XCTAssertFalse(activity.text.contains("Data Access audit logs, which record reads"), "a search of Policy Denied logs warned about Data Access logs: \(activity.text)")
    }

    func testAPersonsTimelineIncludesWhatTheyDidWhileImpersonatingAServiceAccount() async throws {
        let service = FakeService()
        let sa = "ci@kestrel-prod.iam.gserviceaccount.com"
        service.answers[entries] = (200, Self.page([
            Self.entry("2026-11-14T10:00:00Z", "storage.objects.list", by: sa, delegatedBy: "mallory@kestrel.example", on: "projects/_/buckets/payroll", in: "projects/kestrel-prod", id: "as-sa"),
            Self.entry("2026-11-14T09:00:00Z", "GenerateAccessToken", by: "mallory@kestrel.example", on: "projects/-/serviceAccounts/\(sa)", in: "projects/kestrel-prod", id: "token"),
        ]))
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"principal":"user:Mallory@Kestrel.example"}"#, on: service, in: project)
        XCTAssertFalse(logs.isError, logs.text)
        let filter = try XCTUnwrap(json(service.requests.first)["filter"] as? String)
        XCTAssertTrue(filter.contains(#"(protoPayload.authenticationInfo.principalEmail="mallory@kestrel.example" OR protoPayload.authenticationInfo.serviceAccountDelegationInfo.firstPartyPrincipal.principalEmail="mallory@kestrel.example")"#), filter)
        XCTAssertTrue(logs.text.contains("storage.objects.list by \(sa) (delegated by mallory@kestrel.example)"), logs.text)

        // A federated identity is matched by its subject.
        let federated = "principal://iam.googleapis.com/locations/global/workforcePools/contractors/subject/mallory"
        _ = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"principal":"\#(federated)"}"#, on: service, in: project)
        XCTAssertTrue(try XCTUnwrap(json(service.requests.last)["filter"] as? String).contains(
            #"(protoPayload.authenticationInfo.principalSubject="\#(federated)" OR protoPayload.authenticationInfo.serviceAccountDelegationInfo.principalSubject="\#(federated)")"#))
    }

    func testAnEntrySaysWhatAnIAMChangeGrantedTheKeyAKeyRequestMadeAndAFirewallsRangesWithoutKeepingKeyMaterial() async throws {
        let service = FakeService()
        let grant = #"{"insertId":"grant","timestamp":"2026-11-14T12:00:00Z","logName":"projects/kestrel-prod/logs/cloudaudit.googleapis.com%2Factivity","protoPayload":{"methodName":"SetIamPolicy","serviceName":"cloudresourcemanager.googleapis.com","resourceName":"projects/kestrel-prod","authenticationInfo":{"principalEmail":"mallory@kestrel.example"},"authorizationInfo":[{"resource":"projects/kestrel-prod","permission":"resourcemanager.projects.setIamPolicy","granted":true}],"request":{"@type":"type.googleapis.com/google.iam.v1.SetIamPolicyRequest","resource":"projects/kestrel-prod","policy":{"bindings":[{"role":"roles/owner","members":["user:mallory@kestrel.example"]}]}},"serviceData":{"@type":"type.googleapis.com/google.iam.v1.logging.AuditData","policyDelta":{"bindingDeltas":[{"action":"ADD","role":"roles/owner","member":"user:mallory@evil.example"},{"action":"REMOVE","role":"roles/viewer","member":"user:bob@kestrel.example"}],"auditConfigDeltas":[{"action":"REMOVE","service":"storage.googleapis.com","logType":"DATA_READ"}]}},"status":{}}}"#
        let key = #"{"insertId":"key","timestamp":"2026-11-14T11:00:00Z","logName":"projects/kestrel-prod/logs/cloudaudit.googleapis.com%2Factivity","protoPayload":{"methodName":"google.iam.admin.v1.CreateServiceAccountKey","resourceName":"projects/-/serviceAccounts/1234567890","authenticationInfo":{"principalEmail":"mallory@kestrel.example"},"request":{"name":"projects/-/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com","private_key_type":2},"response":{"name":"projects/kestrel-prod/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com/keys/abc123","privateKeyData":"U0VDUkVU","validAfterTime":"2026-11-14T11:00:00Z","keyType":"USER_MANAGED"},"status":{}}}"#
        let firewall = #"{"insertId":"fw","timestamp":"2026-11-14T10:00:00Z","logName":"projects/kestrel-prod/logs/cloudaudit.googleapis.com%2Factivity","protoPayload":{"methodName":"v1.compute.firewalls.insert","resourceName":"projects/kestrel-prod/global/firewalls/allow-ssh","authenticationInfo":{"principalEmail":"mallory@kestrel.example"},"requestMetadata":{"callerIp":"203.0.113.77","callerSuppliedUserAgent":"google-cloud-sdk gcloud/450.0.0"},"request":{"name":"allow-ssh","direction":"INGRESS","sourceRanges":["0.0.0.0/0"],"alloweds":[{"IPProtocol":"tcp","ports":["22"]}],"metadata":{"items":[{"key":"ssh-keys","value":"mallory:ssh-rsa AAAA"}]}},"status":{}}}"#
        let denied = #"{"insertId":"no","timestamp":"2026-11-14T09:00:00Z","logName":"projects/kestrel-prod/logs/cloudaudit.googleapis.com%2Factivity","protoPayload":{"methodName":"google.cloud.secretmanager.v1.SecretManagerService.AccessSecretVersion","resourceName":"projects/1001/secrets/db/versions/latest","authenticationInfo":{"principalEmail":"mallory@kestrel.example"},"authorizationInfo":[{"permission":"secretmanager.versions.access","granted":false}],"status":{"code":7,"message":"Permission denied"}}}"#
        let dataset = #"{"insertId":"bq","timestamp":"2026-11-14T08:00:00Z","logName":"projects/kestrel-prod/logs/cloudaudit.googleapis.com%2Factivity","protoPayload":{"methodName":"google.iam.v1.IAMPolicy.SetIamPolicy","resourceName":"projects/kestrel-prod/datasets/payroll","authenticationInfo":{"principalEmail":"mallory@kestrel.example"},"metadata":{"@type":"type.googleapis.com/google.cloud.audit.BigQueryAuditMetadata","datasetChange":{"bindingDeltas":[{"action":"ADD","role":"roles/bigquery.dataViewer","member":"allAuthenticatedUsers"}]}}}}"#
        service.answers[entries] = (200, Self.page([grant, key, firewall, denied, dataset]))
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", "{}", on: service, in: project)
        XCTAssertFalse(logs.isError, logs.text)
        let lines = logs.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("— granted roles/owner to user:mallory@evil.example; revoked roles/viewer from user:bob@kestrel.example — audit logging turned off DATA_READ for storage.googleapis.com"), lines[0])
        XCTAssertFalse(lines[0].contains("policy="), "a whole policy was put in the line: \(lines[0])")
        XCTAssertTrue(lines[1].contains("(target projects/-/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com)")
                      && lines[1].contains("response name=projects/kestrel-prod/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com/keys/abc123, keyType=USER_MANAGED, validAfterTime=2026-11-14T11:00:00Z"), lines[1])
        XCTAssertTrue(lines[2].contains("request direction=INGRESS, sourceRanges=0.0.0.0/0, alloweds={IPProtocol=tcp ports=22}") && lines[2].contains("agent google-cloud-sdk gcloud/450.0.0"), lines[2])
        XCTAssertFalse(lines[2].contains("ssh-rsa"), "instance metadata was kept: \(lines[2])")
        XCTAssertTrue(lines[3].contains("— failed (Permission denied) — denied secretmanager.versions.access"), lines[3])
        XCTAssertTrue(lines[4].contains("granted roles/bigquery.dataViewer to allAuthenticatedUsers"), lines[4])
        XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: logs.structured ?? [:]), encoding: .utf8)!.contains("U0VDUkVU"), "key material was kept")
        let kept = try XCTUnwrap(logs.structured?["entries"] as? [[String: Any]])
        let payload = try XCTUnwrap(kept[0]["protoPayload"] as? [String: Any])
        let deltas = ((payload["serviceData"] as? [String: Any])?["policyDelta"] as? [String: Any])?["bindingDeltas"] as? [[String: Any]]
        XCTAssertEqual(deltas?.first?["member"] as? String, "user:mallory@evil.example")
        XCTAssertEqual((payload["authorizationInfo"] as? [[String: Any]])?.first?["permission"] as? String, "resourcemanager.projects.setIamPolicy")
        XCTAssertEqual(((kept[1]["protoPayload"] as? [String: Any])?["response"] as? [String: Any])?["name"] as? String,
                       "projects/kestrel-prod/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com/keys/abc123")
    }

    func testLogViewsAreSearchedApartAndAnEntryBothReturnIsShownOnce() async throws {
        let view = "projects/kestrel-siem/locations/global/buckets/audit/views/_AllLogs"
        let shared = Self.entry("2026-11-14T10:00:00Z", "SetIamPolicy", by: "mallory@kestrel.example", on: "projects/kestrel-prod", in: "projects/kestrel-prod", id: "same")
        let routed = Self.entry("2026-11-14T09:00:00Z", "DeleteSink", by: "mallory@kestrel.example", on: "projects/kestrel-prod/sinks/siem", in: "projects/kestrel-prod", id: "only-in-view")
        let service = FakeService()
        // The view's project is under the organisation, so it is inside the account's scope.
        service.answers[assets] = (200, Self.listing([Self.project("kestrel-prod", number: 1001), Self.project("kestrel-siem", number: 1009)]))
        service.sequences[entries] = [(200, Self.page([shared])), (200, Self.page([shared, routed]))]
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"logViews":["\#(view)"]}"#, on: service, in: cloud)
        XCTAssertFalse(logs.isError, logs.text)
        XCTAssertEqual(try searches(service).map { try XCTUnwrap(json($0)["resourceNames"] as? [String]) }, [["organizations/123456789", "projects/kestrel-prod", "projects/kestrel-siem"], [view]])
        XCTAssertEqual(logs.text.components(separatedBy: "[insertId same]").count, 2, "an entry two searches returned was shown twice: \(logs.text)")
        XCTAssertTrue(logs.text.contains("[insertId only-in-view]"), logs.text)
        XCTAssertTrue(logs.text.contains("Searched these log views too: \(view)."), logs.text)
        XCTAssertTrue(logs.text.contains("1 entries came back from more than one of them"), logs.text)
        XCTAssertEqual((logs.structured?["coverage"] as? [String: Any])?["duplicates"] as? Int, 1)

        // Two projects' entries sharing an insertId and a time are both kept; each one's copy in a view is taken once.
        let other = Self.entry("2026-11-14T10:00:00Z", "SetIamPolicy", by: "mallory@kestrel.example", on: "projects/kestrel-data", in: "projects/kestrel-data", id: "same")
        let twins = FakeService()
        twins.answers[assets] = (200, Self.listing([Self.project("kestrel-prod", number: 1001), Self.project("kestrel-data", number: 1003), Self.project("kestrel-siem", number: 1009)]))
        twins.sequences[entries] = [(200, Self.page([shared, other])), (200, Self.page([shared, other]))]
        let both = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"logViews":["\#(view)"]}"#, on: twins, in: cloud)
        XCTAssertEqual(both.text.components(separatedBy: "[insertId same]").count, 3, "two projects' entries were taken for one, or a view's copy kept: \(both.text)")
        XCTAssertTrue(both.text.contains("on projects/kestrel-prod in projects/kestrel-prod") && both.text.contains("on projects/kestrel-data in projects/kestrel-data"), both.text)
        XCTAssertEqual((both.structured?["coverage"] as? [String: Any])?["duplicates"] as? Int, 2)

        // A view the account may not read says which role to grant, and keeps what the scope's own logs gave.
        let refused = FakeService()
        refused.answers[assets] = (200, Self.listing([Self.project("kestrel-prod", number: 1001), Self.project("kestrel-siem", number: 1009)]))
        refused.sequences[entries] = [(200, Self.page([shared])), (403, Self.denied403)]
        let partial = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"logViews":["\#(view)"]}"#, on: refused, in: cloud)
        XCTAssertFalse(partial.isError, partial.text)
        XCTAssertTrue(partial.text.contains("[insertId same]"), partial.text)
        XCTAssertTrue(partial.text.contains("Could not read: \(view)") && partial.text.contains("Logs View Accessor (roles/logging.viewAccessor)"), partial.text)
    }

    // MARK: Batch 1 review: where to search again after a partial read

    func testAnEmptyPageThenARateLimitSaysNothingWasReadAndToSearchTheSameWindowAgain() async throws {
        let service = FakeService()
        service.sequences[entries] = [(200, #"{"entries":[],"nextPageToken":"p2"}"#),
                                      (429, #"{"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#)]
        let logs = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"since":"2026-11-01T00:00:00Z","until":"2026-11-02T00:00:00Z"}"#, on: service, in: project)
        XCTAssertFalse(logs.isError, logs.text)
        XCTAssertTrue(logs.text.contains("before any entry came back, so nothing of the window was read; search the same window again"), logs.text)
        XCTAssertFalse(logs.text.contains("search again with until 2026-11-01T00:00:00Z"), "the advice skipped the whole window: \(logs.text)")
        XCTAssertFalse(logs.text.contains("No audit log entries match"), logs.text)
    }

    func testEntriesSharingTheBoundaryTimeAreReadAgainOnTheFollowUp() async throws {
        let boundary = "2026-11-14T09:00:00Z"
        let service = FakeService()
        service.sequences[entries] = [
            (200, Self.page([Self.entry("2026-11-14T10:00:00Z", "SetIamPolicy", by: "mallory@kestrel.example", on: "projects/kestrel-prod", in: "projects/kestrel-prod", id: "a"),
                             Self.entry(boundary, "SetIamPolicy", by: "mallory@kestrel.example", on: "projects/kestrel-prod", in: "projects/kestrel-prod", id: "b")], next: "p2")),
            (429, #"{"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#),
            // The follow-up the advice asks for: until the boundary, which includes it.
            (200, Self.page([Self.entry(boundary, "SetIamPolicy", by: "mallory@kestrel.example", on: "projects/kestrel-prod", in: "projects/kestrel-prod", id: "b"),
                             Self.entry(boundary, "google.iam.admin.v1.CreateServiceAccountKey", by: "mallory@kestrel.example", on: "projects/-/serviceAccounts/1", in: "projects/kestrel-prod", id: "c")])),
        ]
        let first = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"since":"2026-11-13T00:00:00Z"}"#, on: service, in: project)
        XCTAssertTrue(first.text.contains("search again with until \(boundary), which includes that moment, and drop entries repeated by insertId"), first.text)
        let followUp = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"since":"2026-11-13T00:00:00Z","until":"\#(boundary)"}"#, on: service, in: project)
        XCTAssertTrue(try XCTUnwrap(json(service.requests.last)["filter"] as? String).hasSuffix(#"timestamp<="\#(boundary)""#))
        XCTAssertTrue(followUp.text.contains("[insertId b]") && followUp.text.contains("[insertId c]"), "an entry at the boundary was lost: \(followUp.text)")
    }

    // MARK: Public resources

    private static func policy(_ name: String, type: String, _ bindings: String, ancestors: [String] = [], audit: String? = nil) -> String {
        let ancestry = ancestors.isEmpty ? "" : #","ancestors":[\#(ancestors.map { "\"\($0)\"" }.joined(separator: ","))]"#
        return #"{"name":"\#(name)","assetType":"\#(type)","iamPolicy":{"bindings":[\#(bindings)]\#(audit.map { #","auditConfigs":\#($0)"# } ?? "")}\#(ancestry)}"#
    }

    func testPublicResourcesFindsAllUsersAcrossPagesGroupedByTypeAndSaysWhatItDidNotRead() async throws {
        let service = FakeService()
        let bucket = "storage.googleapis.com/Bucket", run = "run.googleapis.com/Service"
        service.sequences[assets] = [
            (200, Self.listing([Self.policy("//storage.googleapis.com/payroll", type: bucket, #"{"role":"roles/storage.objectViewer","members":["allUsers","user:alice@kestrel.example"]}"#),
                                Self.policy("//storage.googleapis.com/private", type: bucket, #"{"role":"roles/storage.admin","members":["user:alice@kestrel.example"]}"#)], next: "p2")),
            (200, Self.listing([Self.policy("//run.googleapis.com/projects/kestrel-prod/locations/us-central1/services/api", type: run,
                                            #"{"role":"roles/run.invoker","members":["allAuthenticatedUsers"],"condition":{"title":"Office hours"}}"#)])),
        ]
        let found = try await callTool(GoogleCloud.adapter, "public-resources", "{}", on: service, in: cloud)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertEqual(queryItems(service.requests.first)["contentType"], "IAM_POLICY")
        XCTAssertEqual(queryItems(service.requests.last)["pageToken"], "p2")
        XCTAssertTrue(found.text.contains("2 resources grant a role to allUsers or allAuthenticatedUsers: 1 run.googleapis.com/Service, 1 storage.googleapis.com/Bucket."), found.text)
        XCTAssertTrue(found.text.contains("storage.googleapis.com/Bucket:\n  //storage.googleapis.com/payroll: roles/storage.objectViewer to allUsers"), found.text)
        XCTAssertTrue(found.text.contains("roles/run.invoker to allAuthenticatedUsers only when Office hours"), found.text)
        XCTAssertFalse(found.text.contains("//storage.googleapis.com/private"), found.text)
        XCTAssertTrue(found.text.contains("Read 3 IAM policies in organizations/123456789.") && found.text.contains("legacy access control lists"), found.text)
        XCTAssertEqual((found.structured?["resources"] as? [Any])?.count, 2)

        // More policies than one call reads: it says so, and stops at its budget.
        let huge = FakeService()
        huge.answers[assets] = (200, Self.listing([Self.policy("//storage.googleapis.com/b", type: bucket, #"{"role":"roles/storage.admin","members":["user:a@kestrel.example"]}"#)], next: "more"))
        let capped = try await callTool(GoogleCloud.adapter, "public-resources", #"{"assetTypes":["storage.googleapis.com/Bucket"]}"#, on: huge, in: cloud)
        XCTAssertEqual(huge.requests.count, GoogleCloud.policyPages)
        XCTAssertTrue(capped.text.contains("No IAM allow policy among the 10 read") && capped.text.contains("Not read: more IAM policies than the 10 one call reads"), capped.text)
        XCTAssertEqual(capped.structured?["more"] as? Bool, true)

        let scopeless = FakeService()
        scopeless.answers[assets] = (403, #"{"error":{"code":403,"message":"Request had insufficient authentication scopes.","status":"PERMISSION_DENIED"}}"#)
        let refused = try await callTool(GoogleCloud.adapter, "public-resources", "{}", on: scopeless, in: cloud)
        XCTAssertTrue(refused.isError && refused.text.contains("lacks the scope https://www.googleapis.com/auth/cloudasset"), refused.text)
    }

    // MARK: Service account keys

    func testServiceAccountKeysFlagUserManagedAndNewKeysAndCountTheRest() async throws {
        let service = FakeService()
        let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 86_400))
        func key(_ id: String, account: String = "ci@kestrel-prod.iam.gserviceaccount.com", type: String, made: String, ends: String = "9999-12-31T23:59:59Z", origin: String = "GOOGLE_PROVIDED", extra: String = "") -> String {
            #"{"name":"//iam.googleapis.com/projects/kestrel-prod/serviceAccounts/111/keys/\#(id)","assetType":"iam.googleapis.com/ServiceAccountKey","resource":{"data":{"name":"projects/kestrel-prod/serviceAccounts/\#(account)/keys/\#(id)","keyType":"\#(type)","keyOrigin":"\#(origin)","validAfterTime":"\#(made)","validBeforeTime":"\#(ends)"\#(extra)}}}"#
        }
        service.answers["/v1/projects/kestrel-prod/assets"] = (200, Self.listing([
            key("old", type: "USER_MANAGED", made: "2025-01-01T00:00:00Z", extra: #","disabled":true,"disableReason":"SERVICE_ACCOUNT_KEY_DISABLE_REASON_EXPOSED""#),
            key("new", type: "USER_MANAGED", made: recent, origin: "USER_PROVIDED"),
            key("sys", type: "SYSTEM_MANAGED", made: recent, ends: "2026-12-01T00:00:00Z"),
            key("web", account: "web@kestrel-prod.iam.gserviceaccount.com", type: "USER_MANAGED", made: "2026-01-01T00:00:00Z"),
        ]))
        let keys = try await callTool(GoogleCloud.adapter, "sa-keys", "{}", on: service, in: project)
        XCTAssertFalse(keys.isError, keys.text)
        XCTAssertTrue(service.requests.first?.url?.query?.contains("assetTypes=iam.googleapis.com/ServiceAccountKey") == true)
        let lines = keys.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("⚠ user-managed key new of ci@kestrel-prod.iam.gserviceaccount.com") && lines[0].contains("never expires, enabled — uploaded, made in the last 30 days"), lines[0])
        XCTAssertTrue(keys.text.contains("user-managed key old of ci@kestrel-prod.iam.gserviceaccount.com, made 2025-01-01T00:00:00Z, never expires, disabled (exposed)"), keys.text)
        XCTAssertFalse(keys.text.contains("⚠ user-managed key old"), "a disabled key was flagged as live: \(keys.text)")
        XCTAssertFalse(keys.text.contains("key sys"), "a system-managed key was listed: \(keys.text)")
        XCTAssertTrue(keys.text.contains("3 user-managed, 1 made in the last 30 days and 1 disabled; 1 system-managed") && keys.text.contains("set includeSystemManaged"), keys.text)
        XCTAssertTrue(keys.text.contains("up to 7 days") && keys.text.contains("CreateServiceAccountKey"), keys.text)
        XCTAssertEqual(keys.structured?["userManaged"] as? Int, 3)

        let one = try await callTool(GoogleCloud.adapter, "sa-keys", #"{"serviceAccount":"web@kestrel-prod.iam.gserviceaccount.com","includeSystemManaged":true}"#, on: service, in: project)
        XCTAssertEqual((one.structured?["keys"] as? [[String: Any]])?.map { $0["keyID"] as? String }, ["web"])
    }

    // MARK: Asset history

    func testAssetHistoryComparesThenWithNowAndSaysWhenAddedAndRemovedCannotBeEstablished() async throws {
        let service = FakeService()
        let bucket = "storage.googleapis.com/Bucket", path = "/v1/projects/kestrel-prod/assets"
        let viewer = #"{"role":"roles/storage.objectViewer","members":["user:alice@kestrel.example"]}"#
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86_400))
        service.sequences[path] = [
            (200, Self.listing([Self.policy("//storage.googleapis.com/payroll", type: bucket, viewer), Self.policy("//storage.googleapis.com/old", type: bucket, viewer)])),
            (200, Self.listing([Self.policy("//storage.googleapis.com/payroll", type: bucket, #"{"role":"roles/storage.objectViewer","members":["user:alice@kestrel.example","allUsers"]}"#),
                                Self.policy("//storage.googleapis.com/new", type: bucket, viewer)])),
        ]
        let history = try await callTool(GoogleCloud.adapter, "asset-history", #"{"assetType":"\#(bucket)","since":"\#(since)"}"#, on: service, in: project)
        XCTAssertFalse(history.isError, history.text)
        XCTAssertEqual(queryItems(service.requests.first)["readTime"], since)
        XCTAssertNil(queryItems(service.requests.last)["readTime"])
        XCTAssertEqual(queryItems(service.requests.first)["contentType"], "IAM_POLICY")
        XCTAssertTrue(history.text.contains("1 added, 1 removed and 1 changed"), history.text)
        XCTAssertTrue(history.text.contains("~ //storage.googleapis.com/payroll: granted roles/storage.objectViewer to allUsers"), history.text)
        XCTAssertTrue(history.text.contains("+ //storage.googleapis.com/new: granted roles/storage.objectViewer to user:alice@kestrel.example"), history.text)
        XCTAssertTrue(history.text.contains("− //storage.googleapis.com/old"), history.text)
        XCTAssertEqual((history.structured?["changes"] as? [Any])?.count, 3)

        // A snapshot read only in part cannot say what was added or removed.
        let partial = FakeService()
        partial.sequences[path] = [
            (200, Self.listing([Self.policy("//storage.googleapis.com/payroll", type: bucket, viewer)], next: "p2")), (403, Self.denied403),
            (200, Self.listing([Self.policy("//storage.googleapis.com/new", type: bucket, viewer)])),
        ]
        let unsure = try await callTool(GoogleCloud.adapter, "asset-history", #"{"assetType":"\#(bucket)","since":"\#(since)"}"#, on: partial, in: project)
        XCTAssertFalse(unsure.isError, unsure.text)
        XCTAssertTrue(unsure.text.contains("What was added or removed is not established") && unsure.text.contains("Read only in part"), unsure.text)
        XCTAssertFalse(unsure.text.contains("+ //storage.googleapis.com/new"), unsure.text)

        let tooOld = try await callTool(GoogleCloud.adapter, "asset-history", #"{"assetType":"\#(bucket)","since":"2026-01-01T00:00:00Z"}"#, on: FakeService(), in: project)
        XCTAssertTrue(tooOld.isError && tooOld.text.contains("35 days"), tooOld.text)
    }

    // MARK: Organisation policies

    func testOrgPoliciesFlagSecurityConstraintsLoosened() async throws {
        let service = FakeService()
        let org = #"{"name":"//cloudresourcemanager.googleapis.com/organizations/123456789","assetType":"cloudresourcemanager.googleapis.com/Organization","orgPolicy":[{"constraint":"constraints/iam.disableServiceAccountKeyCreation","booleanPolicy":{"enforced":true},"updateTime":"2025-01-01T00:00:00Z"},{"constraint":"constraints/iam.allowedPolicyMemberDomains","listPolicy":{"allValues":"ALLOW"},"updateTime":"2026-11-14T09:30:00Z"},{"constraint":"constraints/compute.disableSerialPortAccess","booleanPolicy":{"enforced":true}}]}"#
        let prod = #"{"name":"//cloudresourcemanager.googleapis.com/projects/1001","assetType":"cloudresourcemanager.googleapis.com/Project","orgPolicy":[{"constraint":"constraints/iam.disableServiceAccountKeyCreation","booleanPolicy":{},"updateTime":"2026-11-14T09:00:00Z"},{"constraint":"constraints/storage.publicAccessPrevention","restoreDefault":{}},{"constraint":"constraints/compute.vmExternalIpAccess","listPolicy":{"allowedValues":["projects/kestrel-prod/zones/us-central1-a/instances/bastion"]}},{"constraint":"constraints/compute.requireOsLogin","updateTime":"2026-11-14T08:00:00Z"}]}"#
        service.answers[assets] = (200, Self.listing([org, prod]))
        let policies = try await callTool(GoogleCloud.adapter, "org-policies", "{}", on: service, in: cloud)
        XCTAssertFalse(policies.isError, policies.text)
        XCTAssertEqual(queryItems(service.requests.first)["contentType"], "ORG_POLICY")
        XCTAssertTrue(policies.text.contains("6 set a security constraint, 2 leave one loosened, 1 reset one to Google's default, 1 set one in a form not read here."), policies.text)
        XCTAssertTrue(policies.text.contains("⚠ iam.disableServiceAccountKeyCreation on projects/1001: not enforced, loosened — it stops service account keys being made (set 2026-11-14T09:00:00Z)"), policies.text)
        XCTAssertTrue(policies.text.contains("⚠ iam.allowedPolicyMemberDomains on organizations/123456789: allows every value, loosened"), policies.text)
        // Reset to Google's default is not an explicit loosening, and a rule in no form read here is unknown, not off.
        XCTAssertTrue(policies.text.contains("? storage.publicAccessPrevention on projects/1001: reset to Google's default, so whether it is enforced depends on Google's default for this organisation"), policies.text)
        XCTAssertTrue(policies.text.contains("? compute.requireOsLogin on projects/1001: set in a form not read here, so whether it is enforced is unknown"), policies.text)
        XCTAssertFalse(policies.text.contains("publicAccessPrevention on projects/1001: reset to Google's default, loosened"), policies.text)
        XCTAssertTrue(policies.text.contains("· iam.disableServiceAccountKeyCreation on organizations/123456789: enforced"), policies.text)
        XCTAssertTrue(policies.text.contains("· compute.vmExternalIpAccess on projects/1001: allows only projects/kestrel-prod/zones/us-central1-a/instances/bastion"), policies.text)
        XCTAssertFalse(policies.text.contains("disableSerialPortAccess"), policies.text)
        XCTAssertTrue(policies.text.contains("1 other constraints are set; set all to list them.") && policies.text.contains("not the effective one"), policies.text)
        let lines = policies.text.split(separator: "\n")
        XCTAssertTrue(lines[1].hasPrefix("⚠"), "a loosened constraint was not listed first: \(policies.text)")
        XCTAssertEqual(policies.structured?["loosened"] as? Int, 2)
        XCTAssertEqual(policies.structured?["resetToDefault"] as? Int, 1)
        XCTAssertEqual(policies.structured?["unknown"] as? Int, 1)
        let judged = try XCTUnwrap(policies.structured?["policies"] as? [[String: Any]])
        XCTAssertEqual(judged.first { $0["constraint"] as? String == "compute.requireOsLogin" }?["loosened"] as? Bool, false)

        let all = try await callTool(GoogleCloud.adapter, "org-policies", #"{"all":true}"#, on: service, in: cloud)
        XCTAssertTrue(all.text.contains("· compute.disableSerialPortAccess on organizations/123456789: enforced"), all.text)
    }

    // MARK: Logging coverage

    func testLoggingCoverageSaysWhereDataAccessLoggingIsOnOffOrUnknown() async throws {
        let service = FakeService()
        let owner = #"{"role":"roles/owner","members":["user:admin@kestrel.example"]}"#
        let crm = "//cloudresourcemanager.googleapis.com/"
        service.sequences[assets] = [
            (200, Self.listing([
                Self.policy(crm + "organizations/123456789", type: GoogleCloud.organizationType, owner, ancestors: ["organizations/123456789"],
                            audit: #"[{"service":"allServices","auditLogConfigs":[{"logType":"ADMIN_READ"}]}]"#),
                Self.policy(crm + "folders/42", type: GoogleCloud.folderType, owner, ancestors: ["folders/42", "organizations/123456789"],
                            audit: #"[{"service":"storage.googleapis.com","auditLogConfigs":[{"logType":"DATA_READ","exemptedMembers":["serviceAccount:etl@kestrel-data.iam.gserviceaccount.com"]},{"logType":"DATA_WRITE"}]}]"#),
                Self.policy(crm + "projects/1001", type: GoogleCloud.projectType, owner, ancestors: ["projects/1001", "folders/42", "organizations/123456789"]),
                Self.policy(crm + "projects/1003", type: GoogleCloud.projectType, owner, ancestors: ["projects/1003", "organizations/123456789"]),
                Self.policy(crm + "projects/1005", type: GoogleCloud.projectType, owner, ancestors: ["projects/1005", "folders/77", "organizations/123456789"]),
                // Writes logged but not reads.
                Self.policy(crm + "projects/1007", type: GoogleCloud.projectType, owner, ancestors: ["projects/1007", "organizations/123456789"],
                            audit: #"[{"service":"storage.googleapis.com","auditLogConfigs":[{"logType":"DATA_WRITE"}]}]"#),
                // A policy that did not come back, beside configured siblings.
                #"{"name":"\#(crm)projects/1009","assetType":"\#(GoogleCloud.projectType)","ancestors":["projects/1009","organizations/123456789"]}"#,
            ])),
            // The projects by ID.
            (200, Self.listing([Self.project("kestrel-prod", number: 1001), Self.project("kestrel-data", number: 1003), Self.project("kestrel-lab", number: 1005),
                                Self.project("kestrel-etl", number: 1007), Self.project("kestrel-new", number: 1009)])),
        ]
        let coverage = try await callTool(GoogleCloud.adapter, "logging-coverage", #"{"service":"storage.googleapis.com"}"#, on: service, in: cloud)
        XCTAssertFalse(coverage.isError, coverage.text)
        let first = service.requests.first.flatMap { $0.url?.query } ?? ""
        XCTAssertTrue(first.contains("contentType=IAM_POLICY") && first.contains("assetTypes=cloudresourcemanager.googleapis.com/Organization"), first)
        XCTAssertTrue(coverage.text.contains("for storage.googleapis.com in the 5 projects read in organizations/123456789: data reads and writes both logged in 1, only one of them in 1, neither in 1, unknown in 2."), coverage.text)
        XCTAssertTrue(coverage.text.contains("on in projects/kestrel-prod: DATA_READ on, DATA_WRITE on, ADMIN_READ on; set on folders/42 and organizations/123456789; not logged for serviceAccount:etl@kestrel-data.iam.gserviceaccount.com (DATA_READ)"), coverage.text)
        XCTAssertTrue(coverage.text.contains("⚠ off in projects/kestrel-data: DATA_READ off, DATA_WRITE off, ADMIN_READ on; set on organizations/123456789"), coverage.text)
        // Writes alone are not reads logged.
        XCTAssertTrue(coverage.text.contains("⚠ partly on in projects/kestrel-etl: DATA_READ off, DATA_WRITE on, ADMIN_READ on"), coverage.text)
        XCTAssertTrue(coverage.text.contains("unknown in projects/kestrel-lab: DATA_READ unknown, DATA_WRITE unknown, ADMIN_READ on; set on organizations/123456789; folders/77 above it could not be read"), coverage.text)
        // A policy that did not come back is unknown, never off, whatever its siblings set.
        XCTAssertTrue(coverage.text.contains("unknown in projects/kestrel-new: DATA_READ unknown, DATA_WRITE unknown, ADMIN_READ on; set on organizations/123456789; its own IAM policy did not come back"), coverage.text)
        let projects = try XCTUnwrap(coverage.structured?["projects"] as? [[String: Any]])
        XCTAssertEqual(Set(projects.compactMap { $0["status"] as? String }), ["on", "partly on", "off", "unknown"])
        XCTAssertEqual((projects.first { $0["project"] as? String == "projects/kestrel-etl" }?["types"] as? [String: String])?["DATA_READ"], "off")

        // BigQuery writes its Data Access logs with nothing set.
        let bigQuery = FakeService()
        bigQuery.sequences[assets] = [
            (200, Self.listing([
                Self.policy(crm + "organizations/123456789", type: GoogleCloud.organizationType, owner, ancestors: ["organizations/123456789"]),
                Self.policy(crm + "projects/1001", type: GoogleCloud.projectType, owner, ancestors: ["projects/1001", "organizations/123456789"]),
            ])),
            (200, Self.listing([Self.project("kestrel-prod", number: 1001)])),
        ]
        let warehouse = try await callTool(GoogleCloud.adapter, "logging-coverage", #"{"service":"bigquery.googleapis.com"}"#, on: bigQuery, in: cloud)
        XCTAssertTrue(warehouse.text.contains("on in projects/kestrel-prod: DATA_READ on by default, DATA_WRITE on by default, ADMIN_READ unknown"), warehouse.text)
        XCTAssertTrue(warehouse.text.contains("BigQuery writes its Data Access logs whether or not they are set here, and they cannot be turned off."), warehouse.text)

        // Nothing configured anywhere: off cannot be told from left out.
        let bare = FakeService()
        bare.sequences["/v1/projects/kestrel-prod/assets"] = [(200, Self.listing([Self.policy(crm + "projects/1001", type: GoogleCloud.projectType, owner, ancestors: ["projects/1001", "organizations/123456789"])]))]
        let unknown = try await callTool(GoogleCloud.adapter, "logging-coverage", #"{"service":"storage.googleapis.com"}"#, on: bare, in: project)
        XCTAssertTrue(unknown.text.contains("both logged in 0, only one of them in 0, neither in 0, unknown in 1") && unknown.text.contains("unknown in projects/kestrel-prod"), unknown.text)
        XCTAssertTrue(unknown.text.contains("No audit configuration came back on any policy read") && unknown.text.contains("cannot be read from an account set to it"), unknown.text)
    }

    // MARK: Findings in depth

    func testSCCSummaryCountsFindingsByCategoryAndSeverityMostFirst() async throws {
        let service = FakeService()
        let path = "/v2/organizations/123456789/sources/-/findings:group"
        service.sequences[path] = [
            (200, #"{"groupByResults":[{"properties":{"category":"OPEN_FIREWALL","severity":"HIGH"},"count":"3"},{"properties":{"category":"PUBLIC_IP_ADDRESS","severity":"HIGH"},"count":"12"}],"nextPageToken":"g2"}"#),
            (200, #"{"groupByResults":[{"properties":{"category":"Persistence: IAM Anomalous Grant","severity":"CRITICAL"},"count":"1"}]}"#),
        ]
        let summary = try await callTool(GoogleCloud.adapter, "scc-summary", #"{"severities":["CRITICAL","HIGH"]}"#, on: service, in: cloud)
        XCTAssertFalse(summary.isError, summary.text)
        let body = try json(service.requests.first)
        XCTAssertEqual(body["groupBy"] as? String, "category,severity")
        XCTAssertEqual(body["filter"] as? String, #"state="ACTIVE" AND NOT mute="MUTED" AND (severity="CRITICAL" OR severity="HIGH")"#)
        XCTAssertEqual(try json(service.requests.last)["pageToken"] as? String, "g2")
        let lines = summary.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "16 active findings in 3 groups by category and severity at organizations/123456789, most first:")
        XCTAssertEqual(lines[1], "12 — PUBLIC_IP_ADDRESS · HIGH")
        XCTAssertEqual(lines[3], "1 — Persistence: IAM Anomalous Grant · CRITICAL")
        XCTAssertEqual(summary.structured?["total"] as? Int, 16)

        _ = try await callTool(GoogleCloud.adapter, "scc-summary", #"{"groupBy":["project"],"includeMuted":true}"#, on: service, in: cloud)
        XCTAssertEqual(try json(service.requests.last)["groupBy"] as? String, "resource.project_display_name")

        let inactive = FakeService()
        inactive.answers[path] = (400, #"{"error":{"code":400,"message":"Security Command Center is not activated for organization 123456789.","status":"FAILED_PRECONDITION"}}"#)
        let refused = try await callTool(GoogleCloud.adapter, "scc-summary", "{}", on: inactive, in: cloud)
        XCTAssertTrue(refused.isError && refused.text.contains("Security Command Center is not activated where this account looks"), refused.text)
    }

    func testOneFindingIsReadInFullByItsName() async throws {
        let service = FakeService()
        let name = "organizations/123456789/sources/9/findings/t1"
        service.answers["/v2/organizations/123456789/sources/9/findings"] = (200, #"""
        {"listFindingsResults":[{"finding":{"name":"organizations/123456789/sources/9/findings/t1","category":"Persistence: IAM Anomalous Grant","severity":"HIGH","state":"ACTIVE","findingClass":"THREAT","mute":"UNMUTED",
          "eventTime":"2026-11-14T09:00:00Z","createTime":"2026-11-14T09:05:00Z","description":"A principal outside the organisation was granted a sensitive role.","nextSteps":"Review the grant.",
          "mitreAttack":{"primaryTactic":"PERSISTENCE","primaryTechniques":["MODIFY_AUTHENTICATION_PROCESS"],"additionalTactics":["PRIVILEGE_ESCALATION"]},
          "access":{"principalEmail":"ci@kestrel-prod.iam.gserviceaccount.com","callerIp":"203.0.113.77","callerIpGeo":{"regionCode":"NL"},"methodName":"SetIamPolicy","serviceName":"cloudresourcemanager.googleapis.com",
            "serviceAccountKeyName":"//iam.googleapis.com/projects/kestrel-prod/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com/keys/k1","serviceAccountDelegationInfo":[{"principalEmail":"mallory@kestrel.example"}]},
          "sourceProperties":{"sensitiveRoleGrant":{"principalEmails":["mallory@evil.example"]},"detectionCategory":{"ruleName":"iam_anomalous_grant"},"evidence":[{"sourceLogId":{"insertId":"grant-1"}}]},
          "externalUri":"https://console.cloud.google.com/security/command-center/findings?x=t1"},
         "resource":{"name":"//cloudresourcemanager.googleapis.com/projects/1001","displayName":"kestrel-prod","type":"google.cloud.resourcemanager.Project","gcpMetadata":{"project":"//cloudresourcemanager.googleapis.com/projects/1001","projectDisplayName":"kestrel-prod"}}}]}
        """#)
        let detail = try await callTool(GoogleCloud.adapter, "scc-finding", #"{"name":"\#(name)"}"#, on: service, in: cloud)
        XCTAssertFalse(detail.isError, detail.text)
        XCTAssertEqual(queryItems(service.requests.first)["filter"], #"name="\#(name)""#)
        XCTAssertTrue(detail.text.contains("Persistence: IAM Anomalous Grant — HIGH THREAT, ACTIVE"), detail.text)
        XCTAssertTrue(detail.text.contains("Last seen 2026-11-14T09:00:00Z; created 2026-11-14T09:05:00Z."), detail.text)
        XCTAssertTrue(detail.text.contains("Resource: kestrel-prod, //cloudresourcemanager.googleapis.com/projects/1001 (google.cloud.resourcemanager.Project) in project kestrel-prod."), detail.text)
        XCTAssertTrue(detail.text.contains("MITRE ATT&CK: PERSISTENCE, PRIVILEGE_ESCALATION; techniques MODIFY_AUTHENTICATION_PROCESS."), detail.text)
        XCTAssertTrue(detail.text.contains("Who acted: ci@kestrel-prod.iam.gserviceaccount.com (delegated by mallory@kestrel.example) with key k1 from 203.0.113.77 (NL) calling SetIamPolicy of cloudresourcemanager.googleapis.com"), detail.text)
        XCTAssertTrue(detail.text.contains("Source properties: detectionCategory={ruleName=iam_anomalous_grant}; evidence={sourceLogId={insertId=grant-1}}; sensitiveRoleGrant={principalEmails=mallory@evil.example}"), detail.text)
        XCTAssertTrue(detail.text.hasSuffix("[\(name)]"), detail.text)
        XCTAssertEqual(((detail.structured?["finding"] as? [String: Any])?["mitreAttack"] as? [String: Any])?["primaryTactic"] as? String, "PERSISTENCE")

        let none = FakeService()
        none.answers["/v2/organizations/123456789/sources/9/findings"] = (200, "{}")
        let missing = try await callTool(GoogleCloud.adapter, "scc-finding", #"{"name":"\#(name)"}"#, on: none, in: cloud)
        XCTAssertFalse(missing.isError)
        XCTAssertTrue(missing.text.contains("No finding named \(name) could be read"), missing.text)

        let bad = try await callTool(GoogleCloud.adapter, "scc-finding", #"{"name":"organizations/123456789/sources/9/findings/t1\" OR name=\"x"}"#, on: none, in: cloud)
        let path = try await callTool(GoogleCloud.adapter, "scc-finding", #"{"name":"organizations/123456789/../findings/t1"}"#, on: none, in: cloud)
        XCTAssertTrue(bad.isError && path.isError)
        XCTAssertEqual(none.requests.count, 1)
    }

    // MARK: Impersonation

    func testWhoCanImpersonateAServiceAccountAndWhatAMemberCanActAs() async throws {
        let service = FakeService()
        let path = "/v1/organizations/123456789:analyzeIamPolicy", sa = "ci@kestrel-prod.iam.gserviceaccount.com"
        service.sequences[path] = [(200, #"""
        {"fullyExplored":true,"mainAnalysis":{"fullyExplored":true,"analysisResults":[{"attachedResourceFullName":"//cloudresourcemanager.googleapis.com/projects/kestrel-prod",
          "iamBinding":{"role":"roles/iam.serviceAccountTokenCreator","members":["group:devs@kestrel.example"]},"identityList":{"identities":[{"name":"group:devs@kestrel.example"},{"name":"user:mallory@kestrel.example"}]},
          "accessControlLists":[{"accesses":[{"permission":"iam.serviceAccounts.getAccessToken"},{"permission":"iam.serviceAccounts.signBlob"}]}]},
          {"attachedResourceFullName":"//iam.googleapis.com/projects/kestrel-prod/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com","iamBinding":{"role":"roles/iam.serviceAccountKeyAdmin","members":["user:bob@kestrel.example"]},
          "accessControlLists":[{"accesses":[{"permission":"iam.serviceAccountKeys.create"}]}]}]}}
        """#), (200, #"""
        {"fullyExplored":true,"mainAnalysis":{"fullyExplored":true,"analysisResults":[{"attachedResourceFullName":"//cloudresourcemanager.googleapis.com/projects/kestrel-prod",
          "iamBinding":{"role":"roles/iam.serviceAccountUser","members":["user:mallory@kestrel.example"]},
          "accessControlLists":[{"accesses":[{"permission":"iam.serviceAccounts.actAs"}],"resources":[{"fullResourceName":"//cloudresourcemanager.googleapis.com/projects/kestrel-prod"},
            {"fullResourceName":"//iam.googleapis.com/projects/kestrel-prod/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com"},{"fullResourceName":"//iam.googleapis.com/projects/kestrel-prod/serviceAccounts/web@kestrel-prod.iam.gserviceaccount.com"}]}]}]}}
        """#)]
        let who = try await callTool(GoogleCloud.adapter, "who-can-impersonate", #"{"serviceAccount":"\#(sa)"}"#, on: service, in: cloud)
        XCTAssertFalse(who.isError, who.text)
        let asked = try XCTUnwrap(service.requests.first?.url)
        XCTAssertEqual(queryItems(service.requests.first)["analysisQuery.resourceSelector.fullResourceName"], "//iam.googleapis.com/projects/kestrel-prod/serviceAccounts/\(sa)")
        let permissions = URLComponents(url: asked, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "analysisQuery.accessSelector.permissions" }.compactMap(\.value)
        XCTAssertEqual(permissions, GoogleCloud.Impersonation.permissions)
        XCTAssertTrue(who.text.contains("//cloudresourcemanager.googleapis.com/projects/kestrel-prod: roles/iam.serviceAccountTokenCreator to group:devs@kestrel.example (reaching group:devs@kestrel.example, user:mallory@kestrel.example) — can getAccessToken, signBlob"), who.text)
        XCTAssertTrue(who.text.contains("roles/iam.serviceAccountKeyAdmin to user:bob@kestrel.example — can keys.create") && who.text.contains("for as long as the key lives"), who.text)
        XCTAssertTrue(who.text.contains("20 IAM analyses a day") && who.text.contains("deny policies"), who.text)

        let reach = try await callTool(GoogleCloud.adapter, "who-can-impersonate", #"{"member":"mallory@kestrel.example"}"#, on: service, in: cloud)
        XCTAssertEqual(queryItems(service.requests.last)["analysisQuery.identitySelector.identity"], "user:mallory@kestrel.example")
        XCTAssertEqual(queryItems(service.requests.last)["analysisQuery.options.expandResources"], "true")
        XCTAssertTrue(reach.text.contains("roles/iam.serviceAccountUser on //cloudresourcemanager.googleapis.com/projects/kestrel-prod, reaching 2 service accounts: //iam.googleapis.com/projects/kestrel-prod/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com, //iam.googleapis.com/projects/kestrel-prod/serviceAccounts/web@kestrel-prod.iam.gserviceaccount.com — can actAs"), reach.text)

        // A default account's project comes from its email; a service agent's must be given.
        service.answers[path] = (200, #"{"mainAnalysis":{"fullyExplored":true}}"#)
        _ = try await callTool(GoogleCloud.adapter, "who-can-impersonate", #"{"serviceAccount":"1001-compute@developer.gserviceaccount.com"}"#, on: service, in: cloud)
        XCTAssertEqual(queryItems(service.requests.last)["analysisQuery.resourceSelector.fullResourceName"], "//iam.googleapis.com/projects/1001/serviceAccounts/1001-compute@developer.gserviceaccount.com")
        let count = service.requests.count
        let agent = try await callTool(GoogleCloud.adapter, "who-can-impersonate", #"{"serviceAccount":"service-1001@gcp-sa-pubsub.iam.gserviceaccount.com"}"#, on: service, in: cloud)
        let both = try await callTool(GoogleCloud.adapter, "who-can-impersonate", #"{"serviceAccount":"\#(sa)","member":"mallory@kestrel.example"}"#, on: service, in: cloud)
        XCTAssertTrue(agent.isError && agent.text.contains("Give project too"), agent.text)
        XCTAssertTrue(both.isError)
        XCTAssertEqual(service.requests.count, count)

        let denied = FakeService()
        denied.answers[path] = (403, Self.denied403)
        let refused = try await callTool(GoogleCloud.adapter, "who-can-impersonate", #"{"serviceAccount":"\#(sa)"}"#, on: denied, in: cloud)
        XCTAssertTrue(refused.isError && refused.text.contains("Cloud Asset Viewer (roles/cloudasset.viewer)"), refused.text)
    }

    // MARK: Resources by creation time and location

    func testFindResourcesNarrowsByCreationTimeAndLocationWhileReadingAndCountsWhatHasNoTime() async throws {
        let service = FakeService()
        let instance = { (name: String, zone: String, made: String) in
            #"{"name":"//compute.googleapis.com/projects/kestrel-prod/zones/\#(zone)/instances/\#(name)","assetType":"compute.googleapis.com/Instance","resource":{"location":"\#(zone)","data":{"status":"RUNNING","creationTimestamp":"\#(made)"}}}"#
        }
        let undated = #"{"name":"//compute.googleapis.com/projects/kestrel-prod/zones/asia-east1-a/instances/legacy","assetType":"compute.googleapis.com/Instance","resource":{"location":"asia-east1-a","data":{"status":"RUNNING"}}}"#
        service.sequences["/v1/projects/kestrel-prod/assets"] = [
            (200, Self.listing([instance("web-01", "us-central1-a", "2025-03-01T10:00:00.000-07:00"), instance("miner-01", "asia-east1-b", "2026-11-14T03:00:00.000-08:00")], next: "p2")),
            (200, Self.listing([instance("miner-02", "europe-west4-a", "2026-11-14T04:00:00.000-08:00"), instance("miner-03", "asia-east1-a", "2026-11-14T05:00:00.000-08:00"), undated])),
        ]
        let found = try await callTool(GoogleCloud.adapter, "find-resources", #"{"assetTypes":["compute.googleapis.com/Instance"],"createdSince":"2026-11-14T00:00:00Z","location":"asia-east1"}"#, on: service, in: project)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("miner-01 (compute.googleapis.com/Instance) in asia-east1-b, RUNNING, made 2026-11-14T03:00:00.000-08:00"), found.text)
        XCTAssertTrue(found.text.contains("miner-03"), found.text)
        XCTAssertFalse(found.text.contains("web-01") || found.text.contains("miner-02"), found.text)
        XCTAssertTrue(found.text.contains("1 of the resources read record no creation time"), found.text)
        XCTAssertEqual(found.structured?["undated"] as? Int, 1)
        XCTAssertEqual((found.structured?["resources"] as? [Any])?.count, 2)
    }

    // MARK: Batch 1 review: which sources check-access asked

    func testCheckAccessAsksEverySourceAndReadsSourcesPastTheFirstPage() async throws {
        let service = FakeService()
        service.sequences[entries] = [(200, "{}"), (200, "{}")]
        service.answers[assets] = (200, "{}")
        service.answers["/v1/organizations/123456789:analyzeIamPolicy"] = (200, "{}")
        service.answers["/v2/organizations/123456789/sources/-/findings"] = (200, "{}")
        service.sequences["/v2/organizations/123456789/sources"] = [
            (200, #"{"sources":[{"name":"organizations/123456789/sources/1","displayName":"Security Health Analytics"}],"nextPageToken":"s2"}"#),
            (200, #"{"sources":[{"name":"organizations/123456789/sources/2","displayName":"Event Threat Detection"}]}"#),
        ]
        service.answers["/v2/organizations/123456789/sources/1:testIamPermissions"] = (200, "{}")
        service.answers["/v2/organizations/123456789/sources/2:testIamPermissions"] = (200, #"{"permissions":["securitycenter.findings.setMute"]}"#)
        let check = try await callTool(GoogleCloud.adapter, "check-access", "{}", on: service, in: cloud)
        XCTAssertFalse(check.isError, check.text)
        XCTAssertTrue(check.text.contains("services reporting here: Security Health Analytics, Event Threat Detection."), check.text)
        XCTAssertFalse(check.text.contains("Event Threat Detection is not among them") || check.text.contains("was not seen"), check.text)
        XCTAssertTrue(check.text.contains("⚠ The account signed in can change findings: on organizations/123456789/sources/2 it holds securitycenter.findings.setMute"), check.text)
        XCTAssertFalse(check.text.contains("✓ The account signed in cannot"), check.text)

        // A later page of sources that cannot be read leaves both conclusions unknown.
        let cut = FakeService()
        cut.sequences[entries] = [(200, "{}"), (200, "{}")]
        cut.answers[assets] = (200, "{}")
        cut.answers["/v1/organizations/123456789:analyzeIamPolicy"] = (200, "{}")
        cut.answers["/v2/organizations/123456789/sources/-/findings"] = (200, "{}")
        cut.sequences["/v2/organizations/123456789/sources"] = [
            (200, #"{"sources":[{"name":"organizations/123456789/sources/1","displayName":"Security Health Analytics"}],"nextPageToken":"s2"}"#), (403, Self.denied403),
        ]
        cut.answers["/v2/organizations/123456789/sources/1:testIamPermissions"] = (200, "{}")
        let unsure = try await callTool(GoogleCloud.adapter, "check-access", "{}", on: cut, in: cloud)
        XCTAssertTrue(unsure.text.contains("Event Threat Detection was not seen among the 1 sources read, as a later page could not be read"), unsure.text)
        XCTAssertFalse(unsure.text.contains("Event Threat Detection is not among them"), unsure.text)
        XCTAssertTrue(unsure.text.contains("is unknown for some sources: none of the 1 asked grants it (asked of organizations/123456789/sources/1 for securitycenter.findings.setMute"), unsure.text)
        XCTAssertFalse(unsure.text.contains("✓ The account signed in cannot"), unsure.text)
    }

    // MARK: The watch: Security Command Center and the Admin Activity audit logs

    private let findings = "/v2/projects/kestrel-prod/sources/-/findings"
    private let watchSince = ISO8601DateFormatter().date(from: "2026-11-21T04:00:00Z")!

    /// An Admin Activity entry of kestrel-prod, as Logging gives it.
    private static func activity(_ id: String, _ method: String, service: String = "cloudresourcemanager.googleapis.com", by principal: String = "mallory@kestrel.example",
                                 at time: String = "2026-11-21T10:00:00Z", resource: String = "projects/kestrel-prod", request: String? = nil,
                                 serviceData: String? = nil, metadata: String? = nil, response: String? = nil, operation: String? = nil,
                                 in log: String = "projects/kestrel-prod", status: String = "{}") -> String {
        let parts = [request.map { #""request":\#($0)"# }, serviceData.map { #""serviceData":\#($0)"# }, metadata.map { #""metadata":\#($0)"# },
                     response.map { #""response":\#($0)"# }].compactMap { $0 }
        return #"{"insertId":"\#(id)","timestamp":"\#(time)","logName":"\#(log)/logs/cloudaudit.googleapis.com%2Factivity"\#(operation.map { #","operation":\#($0)"# } ?? ""),"protoPayload":{"serviceName":"\#(service)","methodName":"\#(method)","resourceName":"\#(resource)","authenticationInfo":{"principalEmail":"\#(principal)"}\#(parts.isEmpty ? "" : "," + parts.joined(separator: ",")),"status":\#(status)}}"#
    }

    private static func grant(_ role: String, to member: String, action: String = "ADD") -> String {
        #"{"@type":"type.googleapis.com/google.iam.v1.logging.AuditData","policyDelta":{"bindingDeltas":[{"action":"\#(action)","role":"\#(role)","member":"\#(member)"}]}}"#
    }

    private static func finding(_ name: String, severity: String = "HIGH", findingClass: String = "MISCONFIGURATION", category: String = "PUBLIC_IP_ADDRESS",
                                event: String = "2026-11-21T10:00:00Z", created: String? = nil, mute: String = "UNMUTED") -> String {
        #"{"finding":{"name":"projects/kestrel-prod/sources/1/findings/\#(name)","category":"\#(category)","severity":"\#(severity)","findingClass":"\#(findingClass)","state":"ACTIVE","mute":"\#(mute)","eventTime":"\#(event)","createTime":"\#(created ?? event)","resourceName":"//compute.googleapis.com/projects/kestrel-prod/zones/us-central1-a/instances/web"},"resource":{"displayName":"web"}}"#
    }

    private static func findingsPage(_ results: [String], next: String? = nil) -> String {
        #"{"listFindingsResults":[\#(results.joined(separator: ","))]\#(next.map { #","nextPageToken":"\#($0)""# } ?? "")}"#
    }

    /// A service whose findings and audit logs are empty unless set.
    private func watched(_ entries: [String] = [], critical: [String] = [], high: [String] = []) -> FakeService {
        let service = FakeService()
        service.answers[self.entries] = (200, Self.page(entries))
        service.answers[findings] = (200, "{}")
        service.sequences[findings] = [(200, Self.findingsPage(critical)), (200, Self.findingsPage(high))]
        return service
    }

    private func alerts(_ service: FakeService, in connection: ToolConnection? = nil) async throws -> [ServiceAlert] {
        try await GoogleCloud.adapter.alerts(since: watchSince, connection: connection ?? project, access: service)
    }

    /// The insertIds of the audit entries among what a check found.
    private func woke(_ alerts: [ServiceAlert]) -> Set<String> {
        Set(alerts.compactMap { alert in alert.id.hasPrefix("audit/") ? alert.id.split(separator: "|").dropFirst().first.map(String.init) : nil })
    }

    func testEachTakeoverAndEvasionSignalWakesAndABenignGrantDoesNot() async throws {
        let sa = "projects/kestrel-prod/serviceAccounts/ci@kestrel-prod.iam.gserviceaccount.com"
        let entries = [
            Self.activity("key", "google.iam.admin.v1.CreateServiceAccountKey", service: "iam.googleapis.com", resource: sa),
            Self.activity("upload", "google.iam.admin.v1.UploadServiceAccountKey", service: "iam.googleapis.com", resource: sa),
            Self.activity("owner", "SetIamPolicy", serviceData: Self.grant("roles/owner", to: "user:mallory@evil.example")),
            Self.activity("editor", "SetIamPolicy", serviceData: Self.grant("roles/editor", to: "user:mallory@evil.example")),
            Self.activity("token", "SetIamPolicy", serviceData: Self.grant("roles/iam.serviceAccountTokenCreator", to: "user:mallory@evil.example")),
            Self.activity("keyadmin", "SetIamPolicy", serviceData: Self.grant("roles/iam.serviceAccountKeyAdmin", to: "user:mallory@evil.example")),
            Self.activity("orgadmin", "SetIamPolicy", resource: "organizations/123456789", serviceData: Self.grant("roles/resourcemanager.organizationAdmin", to: "user:mallory@evil.example")),
            Self.activity("secadmin", "SetIamPolicy", serviceData: Self.grant("roles/iam.securityAdmin", to: "user:mallory@evil.example")),
            Self.activity("public", "SetIamPolicy", serviceData: Self.grant("roles/viewer", to: "allAuthenticatedUsers")),
            // IAM logs a service account's policy whole.
            Self.activity("sa-policy", "google.iam.admin.v1.SetIAMPolicy", service: "iam.googleapis.com", resource: sa,
                          response: #"{"bindings":[{"role":"roles/iam.serviceAccountTokenCreator","members":["user:mallory@evil.example"]}]}"#),
            Self.activity("audit-off", "SetIamPolicy", serviceData: #"{"policyDelta":{"auditConfigDeltas":[{"action":"REMOVE","service":"storage.googleapis.com","logType":"DATA_READ"}]}}"#),
            Self.activity("exempt", "SetIamPolicy", serviceData: #"{"policyDelta":{"auditConfigDeltas":[{"action":"ADD","service":"allServices","logType":"DATA_WRITE","exemptedMember":"user:mallory@evil.example"}]}}"#),
            Self.activity("sink-del", "google.logging.v2.ConfigServiceV2.DeleteSink", service: "logging.googleapis.com", resource: "projects/kestrel-prod/sinks/siem"),
            Self.activity("sink-upd", "google.logging.v2.ConfigServiceV2.UpdateSink", service: "logging.googleapis.com", resource: "projects/kestrel-prod/sinks/siem"),
            Self.activity("excl-new", "google.logging.v2.ConfigServiceV2.CreateExclusion", service: "logging.googleapis.com", resource: "projects/kestrel-prod/exclusions/x"),
            Self.activity("excl-upd", "google.logging.v2.ConfigServiceV2.UpdateExclusion", service: "logging.googleapis.com", resource: "projects/kestrel-prod/exclusions/x"),
            Self.activity("pool", "google.iam.v1.WorkloadIdentityPools.CreateWorkloadIdentityPool", service: "iam.googleapis.com",
                          resource: "projects/1001/locations/global/workloadIdentityPools/gh", operation: #"{"id":"op1","first":true}"#),
            Self.activity("provider", "google.iam.v1.WorkloadIdentityPools.UpdateWorkloadIdentityPoolProvider", service: "iam.googleapis.com",
                          resource: "projects/1001/locations/global/workloadIdentityPools/gh/providers/p"),
            // Benign: a viewer grant, a role taken away and a powerful grant that failed.
            Self.activity("viewer", "SetIamPolicy", serviceData: Self.grant("roles/viewer", to: "user:bob@kestrel.example")),
            Self.activity("revoked", "SetIamPolicy", serviceData: Self.grant("roles/owner", to: "user:bob@kestrel.example", action: "REMOVE")),
            Self.activity("failed", "SetIamPolicy", serviceData: Self.grant("roles/owner", to: "user:mallory@evil.example"), status: #"{"code":7,"message":"denied"}"#),
            // The pool's operation logged last: one change, told once.
            Self.activity("pool", "google.iam.v1.WorkloadIdentityPools.CreateWorkloadIdentityPool", service: "iam.googleapis.com", at: "2026-11-21T10:00:05Z",
                          resource: "projects/1001/locations/global/workloadIdentityPools/gh", operation: #"{"id":"op1","last":true}"#),
        ]
        let service = watched(entries)
        let found = try await alerts(service)
        XCTAssertEqual(woke(found), ["key", "upload", "owner", "editor", "token", "keyadmin", "orgadmin", "secadmin", "public", "sa-policy", "audit-off", "exempt",
                                     "sink-del", "sink-upd", "excl-new", "excl-upd", "pool", "provider"])
        XCTAssertEqual(found.filter { $0.id.contains("|pool|") }.count, 1, "an operation's two entries were told twice")
        XCTAssertTrue(found.allSatisfy { !$0.id.hasPrefix("unreadable/") && !$0.id.hasPrefix("unchecked/") }, "\(found.map(\.id))")

        // One Logging request, filtered by Google to the Admin Activity log, the watched methods and what succeeded.
        let filter = try XCTUnwrap(json(searches(service).first)["filter"] as? String)
        XCTAssertTrue(filter.hasPrefix(#"log_id("cloudaudit.googleapis.com/activity") AND timestamp>="2026-11-21T04:00:00Z" AND (NOT protoPayload.status.code:* OR protoPayload.status.code=0) AND (protoPayload.methodName=("#), filter)
        for method in ["google.iam.admin.v1.CreateServiceAccountKey", "google.iam.admin.v1.UploadServiceAccountKey", "google.logging.v2.ConfigServiceV2.DeleteSink",
                       "google.cloud.orgpolicy.v2.OrgPolicy.UpdatePolicy", "v1.compute.firewalls.insert", "v1.compute.projects.setCommonInstanceMetadata",
                       "google.iam.v1.WorkloadIdentityPools.CreateWorkloadIdentityPoolProvider", "DestroyCryptoKeyVersion"] {
            XCTAssertTrue(filter.contains("\"\(method)\""), "\(method) is not watched: \(filter)")
        }
        XCTAssertTrue(filter.contains(#"protoPayload.methodName:"SetIamPolicy" OR protoPayload.methodName:"DeleteProject" OR protoPayload.methodName:"SetOrgPolicy" OR protoPayload.methodName:"ClearOrgPolicy" OR protoPayload.methodName="storage.setIamPermissions""#), filter)
        XCTAssertTrue(filter.contains(#"protoPayload.request.guestAccelerators:* OR NOT protoPayload.authenticationInfo.principalEmail:"cloudservices.gserviceaccount.com""#), filter)
        XCTAssertEqual(try json(searches(service).first)["resourceNames"] as? [String], ["projects/kestrel-prod"])
        XCTAssertEqual(searches(service).count, 1)
    }

    func testPoliciesFirewallsSSHKeysDeletionsAndMiningWakeAndTheirOrdinaryKindsDoNot() async throws {
        let compute = "compute.googleapis.com", first = #"{"id":"op","first":true}"#
        func firewall(_ id: String, _ request: String) -> String {
            Self.activity(id, "v1.compute.firewalls.insert", service: compute, resource: "projects/kestrel-prod/global/firewalls/\(id)", request: request, operation: first)
        }
        var entries = [
            Self.activity("org-v2", "google.cloud.orgpolicy.v2.OrgPolicy.UpdatePolicy", service: "orgpolicy.googleapis.com", resource: "projects/1001/policies/iam.disableServiceAccountKeyCreation",
                          request: #"{"policy":{"name":"projects/1001/policies/iam.disableServiceAccountKeyCreation","spec":{"rules":[{"enforce":false}]}}}"#),
            Self.activity("org-v2-tight", "google.cloud.orgpolicy.v2.OrgPolicy.UpdatePolicy", service: "orgpolicy.googleapis.com", resource: "projects/1001/policies/iam.disableServiceAccountKeyCreation",
                          request: #"{"policy":{"name":"projects/1001/policies/iam.disableServiceAccountKeyCreation","spec":{"rules":[{"enforce":true}]}}}"#),
            Self.activity("org-v2-other", "google.cloud.orgpolicy.v2.OrgPolicy.UpdatePolicy", service: "orgpolicy.googleapis.com", resource: "projects/1001/policies/compute.disableSerialPortAccess",
                          request: #"{"policy":{"name":"projects/1001/policies/compute.disableSerialPortAccess","spec":{"rules":[{"enforce":false}]}}}"#),
            Self.activity("org-del", "google.cloud.orgpolicy.v2.OrgPolicy.DeletePolicy", service: "orgpolicy.googleapis.com", resource: "projects/1001/policies/storage.publicAccessPrevention",
                          request: #"{"name":"projects/1001/policies/storage.publicAccessPrevention"}"#),
            Self.activity("org-v1", "SetOrgPolicy", resource: "projects/kestrel-prod",
                          request: #"{"resource":"projects/kestrel-prod","policy":{"constraint":"constraints/iam.allowedPolicyMemberDomains","listPolicy":{"allValues":"ALLOW"}}}"#),
            Self.activity("org-clear", "ClearOrgPolicy", resource: "projects/kestrel-prod", request: #"{"name":"projects/kestrel-prod","constraint":"constraints/compute.requireOsLogin"}"#),
            firewall("open", #"{"name":"open","direction":"INGRESS","sourceRanges":["0.0.0.0/0"],"alloweds":[{"IPProtocol":"tcp","ports":["22"]}]}"#),
            firewall("open6", #"{"name":"open6","sourceRanges":["::/0"],"alloweds":[{"IPProtocol":"all"}]}"#),
            firewall("internal", #"{"name":"internal","direction":"INGRESS","sourceRanges":["10.0.0.0/8"],"alloweds":[{"IPProtocol":"tcp"}]}"#),
            firewall("deny", #"{"name":"deny","direction":"INGRESS","sourceRanges":["0.0.0.0/0"],"denieds":[{"IPProtocol":"all"}]}"#),
            firewall("egress", #"{"name":"egress","direction":"EGRESS","destinationRanges":["0.0.0.0/0"],"sourceRanges":["0.0.0.0/0"],"alloweds":[{"IPProtocol":"all"}]}"#),
            // Compute Engine leaves the metadata out of the request: project-wide, any change counts unless its keys show.
            Self.activity("project-ssh", "v1.compute.projects.setCommonInstanceMetadata", service: compute, request: #"{"@type":"type.googleapis.com/compute.projects.setCommonInstanceMetadata"}"#, operation: first),
            Self.activity("vm-ssh", "v1.compute.instances.setMetadata", service: compute, resource: "projects/kestrel-prod/zones/us-central1-a/instances/web",
                          metadata: #"{"instanceMetadataDelta":{"modifiedMetadataKeys":["ssh-keys"]}}"#, operation: first),
            Self.activity("vm-startup", "v1.compute.instances.setMetadata", service: compute, resource: "projects/kestrel-prod/zones/us-central1-a/instances/web",
                          metadata: #"{"instanceMetadataDelta":{"addedMetadataKeys":["startup-script"]}}"#, operation: first),
            Self.activity("vm-unknown", "v1.compute.instances.setMetadata", service: compute, resource: "projects/kestrel-prod/zones/us-central1-a/instances/web", operation: first),
            Self.activity("deleted", "DeleteProject", resource: "projects/kestrel-old", in: "organizations/123456789"),
            Self.activity("bucket", "storage.setIamPermissions", service: "storage.googleapis.com", resource: "projects/_/buckets/payroll",
                          serviceData: Self.grant("roles/storage.objectViewer", to: "allUsers")),
            Self.activity("new-sa", "google.iam.admin.v1.CreateServiceAccount", service: "iam.googleapis.com", resource: "projects/kestrel-prod",
                          request: #"{"account_id":"backup","name":"projects/kestrel-prod"}"#, response: #"{"email":"backup@kestrel-prod.iam.gserviceaccount.com"}"#),
            Self.activity("new-sa-granted", "SetIamPolicy", serviceData: Self.grant("roles/storage.admin", to: "serviceAccount:backup@kestrel-prod.iam.gserviceaccount.com")),
            Self.activity("old-sa-granted", "SetIamPolicy", serviceData: Self.grant("roles/storage.admin", to: "serviceAccount:etl@kestrel-prod.iam.gserviceaccount.com")),
            Self.activity("gpu", "v1.compute.instances.insert", service: compute, resource: "projects/kestrel-prod/zones/us-central1-a/instances/miner",
                          request: #"{"name":"miner","guestAccelerators":[{"acceleratorType":"nvidia-tesla-t4","acceleratorCount":4}]}"#, operation: first),
            Self.activity("kms-destroy", "DestroyCryptoKeyVersion", service: "cloudkms.googleapis.com", resource: "projects/kestrel-prod/locations/global/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1"),
            Self.activity("kms-disable", "UpdateCryptoKeyVersion", service: "cloudkms.googleapis.com", resource: "projects/kestrel-prod/locations/global/keyRings/r/cryptoKeys/k/cryptoKeyVersions/2",
                          request: #"{"cryptoKeyVersion":{"name":"v2","state":"DISABLED"},"updateMask":"state"}"#),
            Self.activity("kms-enable", "UpdateCryptoKeyVersion", service: "cloudkms.googleapis.com", resource: "projects/kestrel-prod/locations/global/keyRings/r/cryptoKeys/k/cryptoKeyVersions/3",
                          request: #"{"cryptoKeyVersion":{"name":"v3","state":"ENABLED"},"updateMask":"state"}"#),
        ]
        // Many VMs by one account are mining; a few by another, or Google's own agent making a group's, are not.
        for index in 0..<GoogleCloud.manyVMs {
            entries.append(Self.activity("spree-\(index)", "v1.compute.instances.insert", service: compute, by: "ci@kestrel-prod.iam.gserviceaccount.com",
                                         resource: "projects/kestrel-prod/zones/europe-west4-a/instances/w\(index)", request: #"{"name":"w\#(index)"}"#, operation: first))
        }
        for index in 0..<3 {
            entries.append(Self.activity("few-\(index)", "v1.compute.instances.insert", service: compute, by: "bob@kestrel.example",
                                         resource: "projects/kestrel-prod/zones/us-central1-a/instances/b\(index)", request: #"{"name":"b\#(index)"}"#, operation: first))
        }
        let service = watched(entries)
        let found = woke(try await alerts(service))
        let expected: Set<String> = ["org-v2", "org-del", "org-v1", "org-clear", "open", "open6", "project-ssh", "vm-ssh", "deleted", "bucket", "new-sa", "new-sa-granted",
                                     "gpu", "kms-destroy", "kms-disable"]
        XCTAssertEqual(found.subtracting((0..<GoogleCloud.manyVMs).map { "spree-\($0)" }), expected)
        XCTAssertTrue((0..<GoogleCloud.manyVMs).allSatisfy { found.contains("spree-\($0)") }, "a spree of VMs did not wake")

        // security-events, which the wake names, reads the same: each with what it did, in turn by tier.
        let read = try await callTool(GoogleCloud.adapter, "security-events", #"{"since":"2026-11-21T04:00:00Z"}"#, on: watched(entries), in: project)
        XCTAssertFalse(read.isError, read.text)
        let events = try XCTUnwrap(read.structured?["events"] as? [[String: Any]])
        XCTAssertEqual(Set(events.compactMap { ($0["id"] as? String)?.split(separator: "|").dropFirst().first.map(String.init) }), found)
        XCTAssertTrue(read.text.contains("firewall rule lets in 0.0.0.0/0: "), read.text)
        XCTAssertTrue(read.text.contains("iam.disableServiceAccountKeyCreation loosened: "), read.text)
        XCTAssertTrue(read.text.contains("storage.publicAccessPrevention handed back to its parent's or Google's default"), read.text)
        XCTAssertTrue(read.text.contains("roles/storage.admin granted to serviceAccount:backup@kestrel-prod.iam.gserviceaccount.com, made in this window"), read.text)
        XCTAssertTrue(read.text.contains("project-wide metadata changed; the entry does not show which keys"), read.text)
        XCTAssertTrue(read.text.contains("one of 20 VMs ci@kestrel-prod.iam.gserviceaccount.com made in this window"), read.text)
        XCTAssertEqual(events.first { ($0["id"] as? String)?.contains("|bucket|") == true }?["tier"] as? Int, 1, "a bucket made public is exposure, after takeover")
        XCTAssertTrue(read.text.contains("Data Access audit logs, off by default for every service but BigQuery, are not read here"), read.text)
    }

    func testFindingsAreUnmutedReadByCreationOrLastSeenTimeCriticalFirstAndALateOneIsFound() async throws {
        // Seen at 08:00 but written to Security Command Center at 10:30, after a watch that read from 09:00.
        let late = Self.finding("late", findingClass: "THREAT", category: "Persistence: IAM Anomalous Grant", event: "2026-11-21T08:00:00Z", created: "2026-11-21T10:30:00Z")
        let muted = Self.finding("muted", mute: "MUTED")
        let service = watched(critical: [Self.finding("crit", severity: "CRITICAL")], high: [late, muted])
        let since = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T09:00:00Z"))
        let found = try await GoogleCloud.adapter.alerts(since: since, connection: project, access: service)
        XCTAssertEqual(Set(found.map(\.id)), ["projects/kestrel-prod/sources/1/findings/crit", "projects/kestrel-prod/sources/1/findings/late"])
        XCTAssertEqual(found.first { $0.id.hasSuffix("/late") }?.time, ISO8601DateFormatter().date(from: "2026-11-21T10:30:00Z"), "dated before what it is found by, so seen again and again")
        let asked = service.requests.filter { $0.url?.host == "securitycenter.googleapis.com" }.map { queryItems($0) }
        XCTAssertEqual(asked.map { $0["filter"] }, [
            #"state="ACTIVE" AND NOT mute="MUTED" AND (create_time>="2026-11-21T09:00:00Z" OR event_time>="2026-11-21T09:00:00Z") AND severity="CRITICAL""#,
            #"state="ACTIVE" AND NOT mute="MUTED" AND (create_time>="2026-11-21T09:00:00Z" OR event_time>="2026-11-21T09:00:00Z") AND severity="HIGH""#,
        ])
        XCTAssertEqual(asked.first?["pageSize"], String(ServiceAlert.most))
        XCTAssertEqual(GoogleCloud.adapter.watchedTool, "security-events")
        XCTAssertEqual(GoogleCloud.adapter.alertLookBack, 6 * 3_600)

        let read = try await callTool(GoogleCloud.adapter, "security-events", #"{"since":"2026-11-21T09:00:00Z","until":"2026-11-21T11:00:00Z"}"#,
                                      on: watched(critical: [Self.finding("crit", severity: "CRITICAL")], high: [late, muted]), in: project)
        XCTAssertTrue(read.text.contains("2026-11-21T10:30:00Z HIGH THREAT finding Persistence: IAM Anomalous Grant — web (first seen 2026-11-21T08:00:00Z, reached Security Command Center 2026-11-21T10:30:00Z)"), read.text)
        XCTAssertFalse(read.text.contains("findings/muted"), read.text)
    }

    func testABurstCannotCrowdOutACriticalFindingAThreatOrAKeyMade() async throws {
        let burst = (0..<600).map { Self.finding("noise-\($0)", event: String(format: "2026-11-21T10:%02d:%02dZ", $0 / 60, $0 % 60)) }
        let threat = Self.finding("threat", findingClass: "THREAT", category: "Execution: Cryptocurrency Mining Hash Match", event: "2026-11-21T05:00:00Z")
        let accounts = (0..<300).map { Self.activity("sa-\($0)", "google.iam.admin.v1.CreateServiceAccount", service: "iam.googleapis.com",
                                                     at: String(format: "2026-11-21T11:%02d:%02dZ", $0 / 60, $0 % 60)) }
        let key = Self.activity("key", "google.iam.admin.v1.CreateServiceAccountKey", service: "iam.googleapis.com", at: "2026-11-21T04:30:00Z")
        let service = watched(accounts + [key], critical: [Self.finding("crit", severity: "CRITICAL", event: "2026-11-21T04:10:00Z")], high: burst + [threat])
        let found = try await alerts(service)
        XCTAssertEqual(found.count, ServiceAlert.most)
        XCTAssertTrue(found.contains { $0.id.hasSuffix("/crit") }, "the burst crowded out the critical finding")
        XCTAssertTrue(found.contains { $0.id.hasSuffix("/threat") }, "the burst crowded out the threat")
        XCTAssertTrue(woke(found).contains("key"), "service accounts made crowded out a key made")
        XCTAssertEqual(found.map(\.time), found.map(\.time).sorted(by: >), "newest first")
    }

    func testSecurityCommandCenterNotActivatedIsToldOnceEachOutageAndTheAuditLogsStillWake() async throws {
        let inactive = (400, #"{"error":{"code":400,"message":"Security Command Center is not activated for this resource.","status":"FAILED_PRECONDITION"}}"#)
        let account = try GoogleCloud.preset.makeConnection(name: "Google Cloud — no SCC", values: ["level": "projects", "id": "kestrel-prod", "clientID": "1234-abc.apps.googleusercontent.com"])
        let key = Self.activity("key", "google.iam.admin.v1.CreateServiceAccountKey", service: "iam.googleapis.com")
        let service = watched([key])
        service.sequences[findings] = nil
        service.answers[findings] = inactive
        let first = try await alerts(service, in: account)
        let told = first.filter { $0.id.hasPrefix("unreadable/scc/") }
        XCTAssertEqual(told.count, 1, "\(first.map(\.id))")
        XCTAssertEqual(told.first?.time, watchSince, "told at the window's start, so it moves the watch past nothing")
        XCTAssertEqual(woke(first), ["key"], "the audit logs did not wake beside it")
        let second = try await alerts(service, in: account)
        XCTAssertFalse(second.contains { $0.id.hasPrefix("unreadable/") }, "told at every check: \(second.map(\.id))")
        // What the wake's window reads back says why and what to change.
        let read = try await callTool(GoogleCloud.adapter, "security-events", #"{"since":"2026-11-21T04:00:00Z"}"#, on: service, in: account)
        XCTAssertTrue(read.text.contains("Could not read Security Command Center findings") && read.text.contains("not activated where this account looks"), read.text)
        XCTAssertTrue(read.text.contains("service account key made: "), read.text)
        // Recovered, then down again: the new outage is told afresh.
        service.answers[findings] = (200, "{}")
        let back = try await alerts(service, in: account)
        XCTAssertFalse(back.contains { $0.id.hasPrefix("unreadable/") })
        service.answers[findings] = (403, Self.denied403)
        let again = try await alerts(service, in: account).filter { $0.id.hasPrefix("unreadable/scc/") }
        XCTAssertEqual(again.count, 1)
        XCTAssertNotEqual(again.first?.id, told.first?.id, "told with the first outage's ID")
    }

    func testASignInThatExpiredIsToldOnceThenEveryCheckFails() async throws {
        let account = try GoogleCloud.preset.makeConnection(name: "Google Cloud — expired", values: ["level": "projects", "id": "kestrel-prod", "clientID": "1234-abc.apps.googleusercontent.com"])
        let service = FakeService()
        let expired = (401, #"{"error":{"code":401,"message":"Request had invalid authentication credentials.","status":"UNAUTHENTICATED"}}"#)
        service.answers[entries] = expired
        service.answers[findings] = expired
        let first = try await alerts(service, in: account)
        XCTAssertEqual(Set(first.map { $0.id.split(separator: "/").prefix(2).joined(separator: "/") }), ["unreadable/scc", "unreadable/audit-logs"])
        do {
            _ = try await alerts(service, in: account)
            XCTFail("a watch that can read nothing said nothing was new")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sign the tool in again"), error.localizedDescription)
        }
    }

    func testAFeedFailingForNowHoldsTheWatchBackThenIsTold() async throws {
        let account = try GoogleCloud.preset.makeConnection(name: "Google Cloud — busy", values: ["level": "projects", "id": "kestrel-prod", "clientID": "1234-abc.apps.googleusercontent.com"])
        let service = watched([Self.activity("key", "google.iam.admin.v1.CreateServiceAccountKey", service: "iam.googleapis.com")])
        service.sequences[findings] = nil
        service.answers[findings] = (503, #"{"error":{"code":503,"message":"Backend Error"}}"#)
        for check in 1...GoogleCloud.NewSecurityEvents.holdChecks {
            do {
                _ = try await alerts(service, in: account)
                XCTFail("check \(check) moved past findings failing for now")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Could not read Security Command Center findings for now"), error.localizedDescription)
            }
        }
        let given = try await alerts(service, in: account)
        XCTAssertEqual(woke(given), ["key"])
        XCTAssertEqual(given.filter { $0.id.hasPrefix("unreadable/scc/") }.count, 1, "\(given.map(\.id))")
    }

    func testAnAuditReadCutShortReadsOnWithinTheBudgetThenTellsOnceWhatItLeftUnchecked() async throws {
        // Read on: the key made is on the second page.
        let paged = watched()
        paged.sequences[entries] = [(200, Self.page([Self.activity("viewer", "SetIamPolicy", serviceData: Self.grant("roles/viewer", to: "user:bob@kestrel.example"))], next: "p2")),
                                    (200, Self.page([Self.activity("key", "google.iam.admin.v1.CreateServiceAccountKey", service: "iam.googleapis.com", at: "2026-11-21T05:00:00Z")]))]
        let found = try await alerts(paged)
        XCTAssertEqual(woke(found), ["key"])
        XCTAssertFalse(found.contains { $0.id.hasPrefix("unchecked/") })
        XCTAssertEqual(try json(searches(paged).last)["pageToken"] as? String, "p2")

        // More than the budget reads: told once, not at every check, and never more requests than the budget.
        let account = try GoogleCloud.preset.makeConnection(name: "Google Cloud — busy logs", values: ["level": "projects", "id": "kestrel-prod", "clientID": "1234-abc.apps.googleusercontent.com"])
        let endless = watched()
        endless.answers[entries] = (200, Self.page([Self.activity("viewer", "SetIamPolicy", serviceData: Self.grant("roles/viewer", to: "user:bob@kestrel.example"))], next: "more"))
        let cut = try await alerts(endless, in: account)
        XCTAssertEqual(searches(endless).count, GoogleCloud.watchRequests)
        XCTAssertEqual(cut.map { $0.id.split(separator: "/").prefix(2).joined(separator: "/") }, ["unchecked/audit-logs"])
        let again = try await alerts(endless, in: account)
        XCTAssertTrue(again.isEmpty, "told at every check: \(again.map(\.id))")
        XCTAssertEqual(searches(endless).count, 2 * GoogleCloud.watchRequests)
        let read = try await callTool(GoogleCloud.adapter, "security-events", #"{"since":"2026-11-21T04:00:00Z"}"#, on: endless, in: account)
        XCTAssertTrue(read.text.contains("Cut short, with older entries not read: the audit logs of projects/kestrel-prod"), read.text)
        XCTAssertTrue(read.text.contains("No watched events from 2026-11-21T04:00:00Z to now in what could be read"), read.text)
    }

    func testAnOrganisationsProjectsAreWatchedInTurnWithinTheLoggingBudget() async throws {
        let projects = (0..<1500).map { Self.project("p\($0)", number: 10_000 + $0) }
        let service = FakeService()
        service.sequences[assets] = [(200, Self.listing(Array(projects[0..<1000]), next: "a2")), (200, Self.listing(Array(projects[1000...])))]
        service.answers[entries] = (200, "{}")
        service.answers["/v2/organizations/123456789/sources/-/findings"] = (200, "{}")
        let organisation = try GoogleCloud.preset.makeConnection(name: "Google Cloud — big", values: ["level": "organizations", "id": "123456789", "clientID": "1234-abc.apps.googleusercontent.com"])
        var read = Set<String>(), requests = 0
        for check in 1...3 {
            let found = try await alerts(service, in: organisation)
            XCTAssertTrue(found.isEmpty, "\(found.map(\.id))")
            let sent = searches(service).dropFirst(requests)
            XCTAssertLessThanOrEqual(sent.count, GoogleCloud.watchRequests, "check \(check)")
            requests += sent.count
            let names = try sent.map { try XCTUnwrap(json($0)["resourceNames"] as? [String]) }
            XCTAssertEqual(names.first?.first, "organizations/123456789", "the organisation's own logs were not read first at check \(check)")
            XCTAssertTrue(names.allSatisfy { $0.count <= GoogleCloud.namesPerSearch })
            read.formUnion(names.joined())
        }
        XCTAssertEqual(read.count, 1501, "a project was never watched")
        XCTAssertEqual(service.requests.filter { $0.url?.host == "cloudasset.googleapis.com" }.count, 2, "the projects were listed again at every check")

        // security-events reads them all at once within its own budget, and says what it could not.
        let bigger = FakeService()
        bigger.sequences[assets] = [(200, Self.listing(Array(projects[0..<1000]), next: "a2")),
                                   (200, Self.listing(Array(projects[1000...]) + (1500..<2500).map { Self.project("p\($0)", number: 10_000 + $0) }))]
        bigger.answers[entries] = (200, "{}")
        bigger.answers["/v2/organizations/123456789/sources/-/findings"] = (200, "{}")
        let events = try await callTool(GoogleCloud.adapter, "security-events", #"{"since":"2026-11-21T04:00:00Z"}"#, on: bigger, in: cloud)
        XCTAssertEqual(searches(bigger).count, GoogleCloud.searchRequests)
        XCTAssertTrue(events.text.contains("Not searched, over the 20 Logging requests one read sends: 501 projects"), events.text)
    }

    // MARK: Batch 3 review: a listing cut short, and what woke the agents read back in a large organisation

    func testAListingCutShortIsToldOnceKeptWithWhatItListedAndToldAgainAfterItRecovers() async throws {
        let organisation = try GoogleCloud.preset.makeConnection(name: "Google Cloud — listing", values: ["level": "organizations", "id": "123456789", "clientID": "1234-abc.apps.googleusercontent.com"])
        let service = FakeService()
        service.answers[entries] = (200, "{}")
        service.answers["/v2/organizations/123456789/sources/-/findings"] = (200, "{}")
        service.answers[assets] = (200, Self.listing([Self.project("p1", number: 1001), Self.project("p2", number: 1002)]))
        let partial = [(200, Self.listing([Self.project("p1", number: 1001)], next: "a2")), (403, Self.denied403)]
        service.sequences[assets] = partial
        let client = ServiceClient(base: organisation.endpoint, access: service, settings: organisation.settings ?? [:], account: organisation.id)
        let watch = GoogleCloud.NewSecurityEvents(), start = Date()
        func check(after minutes: Double) async throws -> [ServiceAlert] {
            try await watch.alerts(since: watchSince, on: client, account: organisation.id, now: start.addingTimeInterval(minutes * 60))
        }
        func kind(_ alerts: [ServiceAlert]) -> [String] { alerts.map { $0.id.split(separator: "/").prefix(2).joined(separator: "/") } }
        func listings() -> Int { service.requests.filter { $0.url?.host == "cloudasset.googleapis.com" }.count }
        let kept = { GoogleCloud.NewSecurityEvents.kept.withLock { $0[organisation.id] } }

        let first = try await check(after: 0)
        XCTAssertEqual(kind(first), ["unreadable/listing"])
        XCTAssertEqual(first.first?.time, watchSince, "told at the window's start, so it moves the watch past nothing")
        XCTAssertEqual(try json(searches(service).first)["resourceNames"] as? [String], ["organizations/123456789", "projects/p1"])
        // Reused within half an hour, still incomplete and still said to be, but not told again.
        let cached = try await check(after: 5)
        XCTAssertTrue(cached.isEmpty, "\(cached.map(\.id))")
        XCTAssertEqual(listings(), 2, "listed again within half an hour")
        XCTAssertNotNil(kept()?.rotation.incomplete)
        XCTAssertEqual(kept()?.told["listing"], first.first?.id, "the episode was forgotten while the listing reused was still incomplete")
        // security-events says so too.
        service.sequences[assets] = partial
        let read = try await callTool(GoogleCloud.adapter, "security-events", #"{"since":"2026-11-21T04:00:00Z"}"#, on: service, in: organisation)
        XCTAssertTrue(read.text.contains("Could not read the folders and projects under the scope: only some were listed, as a later page of the listing could not be read"), read.text)
        XCTAssertTrue(read.text.contains("Only some folders and projects under organizations/123456789 were listed"), read.text)
        XCTAssertTrue(read.text.contains("No watched events from 2026-11-21T04:00:00Z to now in what could be read"), read.text)
        // Listed whole again: the episode is over, and the next listing cut short is told afresh.
        let back = try await check(after: 31)
        XCTAssertTrue(back.isEmpty, "\(back.map(\.id))")
        XCTAssertNil(kept()?.rotation.incomplete)
        XCTAssertNil(kept()?.told["listing"])
        service.sequences[assets] = partial
        let again = try await check(after: 62)
        XCTAssertEqual(kind(again), ["unreadable/listing"])
        XCTAssertNotEqual(again.first?.id, first.first?.id, "told with the first episode's ID")
    }

    /// Answers each Logging search with an entry only when it names the project the entry was logged in, as Logging
    /// does, and anything else as `fake` does.
    private final class ByResource: ServiceAccess, @unchecked Sendable {
        let fake: FakeService, target: String, entry: String
        let lock = NSLock()
        var searched: [[String]] = []
        init(_ fake: FakeService, target: String, entry: String) { self.fake = fake; self.target = target; self.entry = entry }
        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard request.url?.host == "logging.googleapis.com" else { return try await fake.data(for: request) }
            let names = ((try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any])?["resourceNames"] as? [String] ?? []
            lock.withLock { searched.append(names) }
            let page = names.contains(target) ? #"{"entries":[\#(entry)]}"# : "{}"
            return (Data(page.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @MainActor func testWhatWokeTheAgentsFarDownALargeOrganisationIsReadBackWithinTheBudget() async throws {
        let organisation = try GoogleCloud.preset.makeConnection(name: "Google Cloud — large", values: ["level": "organizations", "id": "123456789", "clientID": "1234-abc.apps.googleusercontent.com"])
        let projects = (0..<2500).map { Self.project("p\($0)", number: 10_000 + $0) }
        let fake = FakeService()
        fake.sequences[assets] = [(200, Self.listing(Array(projects[0..<1000]), next: "a2")), (200, Self.listing(Array(projects[1000..<2000]), next: "a3")),
                                  (200, Self.listing(Array(projects[2000...])))]
        fake.answers[assets] = (200, Self.listing(projects))
        fake.answers["/v2/organizations/123456789/sources/-/findings"] = (200, "{}")
        let entry = Self.activity("late-key", "google.iam.admin.v1.CreateServiceAccountKey", service: "iam.googleapis.com", at: "2026-11-21T00:10:00Z",
                                  resource: "projects/-/serviceAccounts/1", in: "projects/p2400")
        let access = ByResource(fake, target: "projects/p2400", entry: entry)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let watcher = AlertWatcher(file: file, alerts: { connection, since in
            try await GoogleCloud.adapter.alerts(since: since, connection: connection, access: access)
        })
        watcher.adapters = PionAdapters.all
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T00:00:00Z"))
        var woken: [String] = [], results: [AlertWatcher.Checked] = []
        for check in 0..<6 {
            let checked = await watcher.check([(organisation, [UUID()])], keeping: [], at: start.addingTimeInterval(Double(check) * 300)) { woken.append($1) }
            results.append(try XCTUnwrap(checked[organisation.id]))
        }
        // Project p2400 is in the 25th search of up to 100, read on the fourth check of the watch's turns.
        XCTAssertEqual(results, [.started, .nothingNew, .nothingNew, .nothingNew, .found("1 new alert"), .nothingNew])
        XCTAssertTrue(access.searched.allSatisfy { $0.count <= GoogleCloud.namesPerSearch })
        let note = try XCTUnwrap(woken.first)
        func attribute(_ name: String) throws -> String {
            let range = try XCTUnwrap(note.range(of: #"\#(name)="([^"]+)""#, options: .regularExpression))
            return String(note[range].dropFirst(name.count + 2).dropLast())
        }
        XCTAssertEqual(try attribute("tool"), "security-events")
        let arguments = #"{"since":"\#(try attribute("since"))","until":"\#(try attribute("until"))"}"#

        // The wake's call reads first where the watch found it, so it comes back within one call's budget.
        let before = access.searched.count
        let data = try await GoogleCloud.adapter.run("security-events", arguments: Data(arguments.utf8), connection: organisation, access: access)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertNotEqual(result["isError"] as? Bool, true, text)
        XCTAssertTrue(text.contains("service account key made: 2026-11-21T00:10:00Z google.iam.admin.v1.CreateServiceAccountKey by mallory@kestrel.example") && text.contains("[insertId late-key]"), text)
        let sent = access.searched.dropFirst(before)
        XCTAssertEqual(sent.first?.first, "projects/p2400", "where the watch found it was not searched first")
        XCTAssertLessThanOrEqual(sent.count, GoogleCloud.searchRequests)
        XCTAssertFalse(text.contains("as the watch found"), "it was not read again: \(text)")

        // Without what the watch found, as after a relaunch, the scope is searched in order and says what it could not
        // reach; naming the project reads it alone.
        let relaunched = try GoogleCloud.preset.makeConnection(name: "Google Cloud — large", values: ["level": "organizations", "id": "123456789", "clientID": "1234-abc.apps.googleusercontent.com"])
        let fresh = try await GoogleCloud.adapter.run("security-events", arguments: Data(arguments.utf8), connection: relaunched, access: access)
        let freshText = (((try JSONSerialization.jsonObject(with: fresh) as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertFalse(freshText.contains("late-key"), freshText)
        XCTAssertTrue(freshText.contains("Not searched, over the 20 Logging requests one read sends: 501 projects") && freshText.contains("kept only while Pion runs"), freshText)
        let named = access.searched.count
        let narrow = try await GoogleCloud.adapter.run("security-events", arguments: Data(#"{"since":"2026-11-21T00:00:00Z","project":"p2400"}"#.utf8), connection: relaunched, access: access)
        let narrowText = (((try JSONSerialization.jsonObject(with: narrow) as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(narrowText.contains("[insertId late-key]"), narrowText)
        XCTAssertEqual(Array(access.searched.dropFirst(named)), [["projects/p2400"]])
        let bad = try await GoogleCloud.adapter.run("security-events", arguments: Data(#"{"resourceNames":["projects/x\" OR \"y"]}"#.utf8), connection: relaunched, access: access)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: bad) as? [String: Any])?["isError"] as? Bool, true)
    }

    // MARK: Batch 3 review: naming resources never widens the account's scope

    func testNamedResourcesAndLogViewsOutsideTheAccountsScopeAreRefusedBeforeAnythingIsRead() async throws {
        // A project's account reads that project alone.
        let single = FakeService()
        let other = try await callTool(GoogleCloud.adapter, "security-events", #"{"project":"kestrel-other"}"#, on: single, in: project)
        XCTAssertTrue(other.isError)
        XCTAssertTrue(other.text.contains("projects/kestrel-other (the account reads projects/kestrel-prod alone)") && other.text.contains("Set the account's Scope"), other.text)
        let view = "projects/kestrel-siem/locations/global/buckets/audit/views/_AllLogs"
        let viewed = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"logViews":["\#(view)"]}"#, on: single, in: project)
        XCTAssertTrue(viewed.isError && viewed.text.contains("\(view) (held by projects/kestrel-siem: the account reads projects/kestrel-prod alone)"), viewed.text)
        XCTAssertTrue(single.requests.isEmpty, "something was read: \(single.requests.compactMap(\.url))")

        // An organisation's reads only what its listing holds; one that came back in part leaves the rest unknown.
        let organisation = FakeService()
        organisation.answers[assets] = (200, Self.listing([Self.folder(42), Self.project("kestrel-prod", number: 1001)]))
        let foreign = try await callTool(GoogleCloud.adapter, "security-events", #"{"resourceNames":["folders/999","folders/42"]}"#, on: organisation, in: cloud)
        XCTAssertTrue(foreign.isError && foreign.text.contains("folders/999 (it is not under organizations/123456789)") && !foreign.text.contains("folders/42 ("), foreign.text)
        XCTAssertTrue(searches(organisation).isEmpty)
        let partly = FakeService()
        partly.sequences[assets] = [(200, Self.listing([Self.folder(42)], next: "a2")), (403, Self.denied403)]
        let unknown = try await callTool(GoogleCloud.adapter, "security-events", #"{"project":"kestrel-prod"}"#, on: partly, in: cloud)
        XCTAssertTrue(unknown.isError && unknown.text.contains("projects/kestrel-prod (it is not among the folders and projects listed under organizations/123456789, which came back only in part"), unknown.text)
        let unlisted = FakeService()
        unlisted.answers[assets] = (403, Self.denied403)
        let unlistedView = try await callTool(GoogleCloud.adapter, "audit-logs", #"{"logViews":["\#(view)"]}"#, on: unlisted, in: cloud)
        XCTAssertTrue(unlistedView.isError && unlistedView.text.contains("whether it is under organizations/123456789 is unknown, as its folders and projects could not be listed"), unlistedView.text)
        XCTAssertTrue(searches(partly).isEmpty && searches(unlisted).isEmpty)
    }

    func testANarrowedReadSearchesThoseResourcesAloneAndListsTheScopesFindingsApart() async throws {
        let service = FakeService()
        service.answers[assets] = (200, Self.listing([Self.folder(42), Self.project("kestrel-prod", number: 1001), Self.project("kestrel-data", number: 1003)]))
        service.answers[entries] = (200, Self.page([Self.activity("key", "google.iam.admin.v1.CreateServiceAccountKey", service: "iam.googleapis.com")]))
        service.answers["/v2/organizations/123456789/sources/-/findings"] = (200, Self.findingsPage([
            #"{"finding":{"name":"organizations/123456789/sources/1/findings/elsewhere","category":"OPEN_FIREWALL","severity":"HIGH","findingClass":"MISCONFIGURATION","state":"ACTIVE","eventTime":"2026-11-21T09:00:00Z","resourceName":"//compute.googleapis.com/projects/kestrel-data/global/firewalls/open"},"resource":{"displayName":"open"}}"#,
        ]))
        // A project given by its number is taken by its ID, as Logging names it.
        let read = try await callTool(GoogleCloud.adapter, "security-events", #"{"since":"2026-11-21T04:00:00Z","resourceNames":["folders/42","projects/1001"]}"#, on: service, in: cloud)
        XCTAssertFalse(read.isError, read.text)
        XCTAssertEqual(try searches(service).map { try XCTUnwrap(json($0)["resourceNames"] as? [String]) }, [["folders/42", "projects/kestrel-prod"]])
        let events = try XCTUnwrap(read.structured?["events"] as? [[String: Any]])
        XCTAssertEqual(events.compactMap { $0["feed"] as? String }, ["audit-logs"], "a finding of the whole scope was taken for the resources'")
        XCTAssertEqual((read.structured?["scopeFindings"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["organizations/123456789/sources/1/findings/elsewhere"])
        let lines = read.text.components(separatedBy: "\n")
        let apart = try XCTUnwrap(lines.firstIndex(of: "Security Command Center findings across the whole of organizations/123456789, not narrowed to folders/42 and projects/kestrel-prod:"), read.text)
        XCTAssertTrue(lines[apart + 1].contains("OPEN_FIREWALL"), read.text)
        XCTAssertTrue(lines[..<apart].contains { $0.hasPrefix("service account key made: ") } && !lines[..<apart].contains { $0.contains("OPEN_FIREWALL") }, read.text)
    }
}
