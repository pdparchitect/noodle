import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class DefenderTests: XCTestCase {
    private let contoso = try! Defender.preset.makeConnection(name: "Defender — Contoso", values: ["tenant": "contoso.onmicrosoft.com", "clientID": EntraTests.client])
    private let device = "1e5bc9d7e413ddd7902c2932e418702b84d0cc07"

    private func call(_ tool: String, _ arguments: String, _ service: FakeService) async throws -> AdapterResult {
        try await callTool(Defender.adapter, tool, arguments, on: service, in: contoso)
    }

    /// The KQL each hunting request sent, in turn.
    private func queries(_ service: FakeService) -> [String] {
        service.requests.filter { $0.url?.path.hasSuffix("runHuntingQuery") == true }.compactMap { request in
            (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["Query"] as? String
        }
    }

    func testEachTenantSignsInAsAnAdminAtItsOwnTenantWithReadingPermissionsOnly() throws {
        XCTAssertEqual(Defender.preset.name, "Microsoft Defender XDR Audit")
        XCTAssertEqual(Defender.preset.id, "eef1f5bd-b131-448f-9f37-0a3ba0beb217", "the same entry, renamed")
        XCTAssertEqual(contoso.endpoint.absoluteString, "https://graph.microsoft.com/v1.0")
        XCTAssertEqual(contoso.adapter, "defender")
        XCTAssertNil(contoso.clientCredentials, "no client secret: an admin signs in")
        XCTAssertFalse(contoso.keepsSecret)
        guard case .connection(let configuration) = Defender.preset.configuration else { return XCTFail() }
        XCTAssertEqual(configuration.oauthClientField, "clientID")
        XCTAssertEqual(configuration.oauthPathField, "tenant")
        let oauth = try XCTUnwrap(configuration.oauth(for: contoso.settings))
        XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token")
        XCTAssertEqual(oauth.authorizationParameters, ["prompt": "login"])
        XCTAssertFalse(oauth.usesResourceIndicator)
        XCTAssertEqual(oauth.unlistedScopes, ["offline_access"])
        XCTAssertEqual(Set(oauth.scopes), Set(Defender.auditScopes))
        XCTAssertTrue(oauth.scopes.allSatisfy { $0.contains(".Read") }, "Audit only reads: \(oauth.scopes)")
        XCTAssertFalse(oauth.scopes.contains { $0.contains("securitycenter") }, "Graph alone: one sign-in gets tokens for one API")
        XCTAssertTrue(Defender.auditScopes.allSatisfy { scope in Defender.setup.contains { $0.contains("`\(scope)`") } }, "the setup grants every permission asked for")
        XCTAssertTrue(Defender.setup.contains { $0.contains("com.pdparchitect.pion:/oauth2callback") && $0.contains("Public client") })
        XCTAssertTrue(Defender.setup.contains { $0.contains("**Security Reader**") })
        XCTAssertFalse(Defender.setup.contains { $0.lowercased().contains("client secret and copy") }, "no secret to keep")
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        ToolCatalog.use(PionCatalogue.entries)
        XCTAssertTrue(ToolConnectionService.signsInThroughBrowser(contoso))
        XCTAssertEqual(Defender.adapter.watchedTool, "security-events")
        XCTAssertNotNil(PionAdapters.all["defender"])
    }

    /// Microsoft's addresses that stand for any tenant would sign in wherever the admin belongs: neither tool can be
    /// set up with one, and one saved under an account reads nothing.
    func testATenantThatIsNoOneTenantIsRefusedAtSetupAndReadsNothing() async throws {
        let service = FakeService()
        for tool in [Defender.preset, Defender.containment] {
            guard case .connection(let configuration) = tool.configuration else { return XCTFail() }
            for generic in ["common", "Organizations", "consumers", "...", "contoso/../x"] {
                XCTAssertThrowsError(try tool.makeConnection(name: "Any", values: ["tenant": generic, "clientID": EntraTests.client]), generic)
                XCTAssertNil(configuration.oauth(for: ["tenant": generic, "clientID": EntraTests.client]), generic)
            }
        }
        var connection = contoso
        connection.settings?["tenant"] = "common"
        let alerts = try await callTool(Defender.adapter, "alerts", "{}", on: service, in: connection)
        XCTAssertTrue(alerts.isError && alerts.text.contains("no one tenant"), alerts.text)
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testAlertsFilterOnTheServiceWithinTheirWindowAndSayWhenMoreMatched() async throws {
        let service = FakeService()
        service.sequences["/v1.0/security/alerts_v2"] = [
            (200, ##"{"value":[{"id":"a1","title":"Suspicious execution of hidden file","severity":"high","status":"new","serviceSource":"microsoftDefenderForEndpoint","createdDateTime":"2026-11-14T08:00:00Z","incidentId":"28282","mitreTechniques":["T1564.001"],"evidence":[{"@odata.type":"#microsoft.graph.security.deviceEvidence","deviceDnsName":"lt-0423","mdeDeviceId":"1e5bc9d7e413ddd7902c2932e418702b84d0cc07"}]}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/security/alerts_v2?$top=1&$skip=1"}"##),
            (200, #"{"value":[{"id":"a2","title":"Second","severity":"high","createdDateTime":"2026-11-14T09:00:00Z"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/security/alerts_v2?$top=1&$skip=2"}"#),
        ]
        let since = Defender.iso(Date().addingTimeInterval(-2 * 86_400))
        let alerts = try await call("alerts", #"{"severity":"high","status":"new","source":"microsoftDefenderForEndpoint","since":"\#(since)","limit":1}"#, service)
        XCTAssertFalse(alerts.isError, alerts.text)
        XCTAssertTrue(alerts.text.contains("Suspicious execution of hidden file") && alerts.text.contains("lt-0423"), alerts.text)
        XCTAssertTrue(alerts.text.contains("Defender for Endpoint ID 1e5bc9d7e413ddd7902c2932e418702b84d0cc07"), alerts.text)
        XCTAssertTrue(alerts.text.contains("More alerts match than the 1 kept"), alerts.text)
        XCTAssertEqual(alerts.structured?["complete"] as? Bool, false)
        let filter = queryItems(service.requests.first)["$filter"] ?? ""
        XCTAssertTrue(filter.hasPrefix("severity eq 'high' and status eq 'new' and serviceSource eq 'microsoftDefenderForEndpoint' and createdDateTime ge \(since) and createdDateTime le "), filter)
        XCTAssertEqual(service.requests.count, 1, "it stops once it has as many as asked for")
        for bad in [#"{"severity":"catastrophic"}"#, #"{"status":"open"}"#, #"{"incident":"1' or '1"}"#, #"{"since":"yesterday"}"#,
                    #"{"since":"2020-01-01T00:00:00Z"}"#, #"{"limit":0}"#] {
            let refused = try await call("alerts", bad, service)
            XCTAssertTrue(refused.isError, bad)
        }
        XCTAssertEqual(service.requests.count, 1, "refused before anything is sent")
    }

    /// A listing follows only Graph's own next link at the same path, takes only its $skiptoken or $skip, asks again
    /// with its own query, and says where it stopped.
    func testListingsFollowOnlyGraphsOwnNextLinkAndSayWhereTheyStopped() async throws {
        let service = FakeService()
        service.sequences["/v1.0/security/incidents"] = [
            (200, #"{"value":[{"id":"1","displayName":"First","severity":"high","status":"active","createdDateTime":"2026-11-20T08:00:00Z"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/security/incidents?$skiptoken=T2&$filter=evil"}"#),
            (200, #"{"value":[{"id":"2","displayName":"Second","severity":"high","status":"active","createdDateTime":"2026-11-20T09:00:00Z"}],"@odata.nextLink":"https://evil.example/v1.0/security/incidents?$skiptoken=T3"}"#),
        ]
        let incidents = try await call("incidents", #"{"severity":"high"}"#, service)
        XCTAssertTrue(incidents.text.contains("First") && incidents.text.contains("Second"), incidents.text)
        XCTAssertTrue(incidents.text.contains("Incomplete: stopped at page 3 reading incidents") && incidents.text.contains("does not follow"), incidents.text)
        XCTAssertEqual(service.requests.count, 2)
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "graph.microsoft.com" })
        let second = queryItems(service.requests[1])
        XCTAssertEqual(second["$skiptoken"], "T2")
        XCTAssertEqual(second["$filter"], queryItems(service.requests[0])["$filter"], "its own query, never the link's")
        XCTAssertEqual(incidents.structured?["complete"] as? Bool, false)
        for link in ["http://graph.microsoft.com/v1.0/security/incidents?$skip=2", "https://graph.microsoft.com/v1.0/users?$skip=2",
                     "https://graph.microsoft.com:8443/v1.0/security/incidents?$skip=2", "https://graph.microsoft.com/v1.0/security/incidents?$skip=-5",
                     "https://user@graph.microsoft.com/v1.0/security/incidents?$skip=2"] {
            let client = ServiceClient(base: contoso.endpoint, access: service)
            XCTAssertEqual(Defender.next(link, service: client, path: ["security", "incidents"]), .unfollowable, link)
        }
    }

    func testAlertShowsEveryEntityWithTheIDsContainmentTakes() async throws {
        let service = FakeService()
        service.answers["/v1.0/security/alerts_v2/da637-1_2"] = (200, ##"{"id":"da637-1_2","title":"Ransomware behaviour","severity":"high","status":"inProgress","serviceSource":"microsoftDefenderForEndpoint","classification":"truePositive","description":"Files were encrypted.","recommendedActions":"Isolate the device.","alertWebUrl":"https://security.microsoft.com/alerts/da637-1_2","evidence":[{"@odata.type":"#microsoft.graph.security.deviceEvidence","deviceDnsName":"lt-0423","mdeDeviceId":"1E5BC9D7E413DDD7902C2932E418702B84D0CC07","verdict":"malicious"},{"@odata.type":"#microsoft.graph.security.fileEvidence","fileDetails":{"fileName":"locker.exe","sha1":"0123456789abcdef0123456789abcdef01234567"},"remediationStatus":"active"},{"@odata.type":"#microsoft.graph.security.userEvidence","userAccount":{"userPrincipalName":"ann@contoso.example"}},{"@odata.type":"#microsoft.graph.security.deviceEvidence","mdeDeviceId":"not-a-device-id"}]}"##)
        let alert = try await call("alert", #"{"id":"da637-1_2"}"#, service)
        XCTAssertFalse(alert.isError, alert.text)
        for words in ["Ransomware behaviour", "Files were encrypted.", "Isolate the device.", "lt-0423 (device, Defender for Endpoint ID 1e5bc9d7e413ddd7902c2932e418702b84d0cc07)",
                      "locker.exe (file, SHA1 0123456789abcdef0123456789abcdef01234567)", "remediation active", "ann@contoso.example (user)"] {
            XCTAssertTrue(alert.text.contains(words), "\(words): \(alert.text)")
        }
        let devices = try XCTUnwrap(alert.structured?["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.compactMap { $0["id"] as? String }, ["1e5bc9d7e413ddd7902c2932e418702b84d0cc07"], "a malformed device ID is never passed on")
        XCTAssertEqual(alert.structured?["files"] as? [String], ["0123456789abcdef0123456789abcdef01234567"])
        for bad in [#"{"id":"../users"}"#, #"{"id":"a b"}"#, #"{"id":""}"#] {
            let refused = try await call("alert", bad, service)
            XCTAssertTrue(refused.isError, bad)
        }
        service.answers["/v1.0/security/alerts_v2/other"] = (200, #"{"id":"someone-else","title":"Not this one"}"#)
        let mismatched = try await call("alert", #"{"id":"other"}"#, service)
        XCTAssertTrue(mismatched.isError && !mismatched.text.contains("Not this one"), mismatched.text)
    }

    func testAnIncidentListsItsAlertsAndSaysWhenGraphDidNot() async throws {
        let service = FakeService()
        service.answers[EntraTests.key("/v1.0/security/incidents/28282", ["$expand": "alerts"])] = (200, #"{"id":"28282","displayName":"Multi-stage incident","severity":"high","status":"active","alerts":[{"id":"a1","title":"First alert","severity":"high","status":"new","createdDateTime":"2026-11-14T08:00:00Z"},{"id":"a2","title":"Second alert","severity":"medium","createdDateTime":"2026-11-14T09:00:00Z"}]}"#)
        let incident = try await call("incident", #"{"id":"28282"}"#, service)
        XCTAssertTrue(incident.text.contains("Multi-stage incident") && incident.text.contains("2 alerts"), incident.text)
        XCTAssertLessThan(incident.text.range(of: "Second alert")!.lowerBound, incident.text.range(of: "First alert")!.lowerBound, "newest first")
        service.answers[EntraTests.key("/v1.0/security/incidents/7", ["$expand": "alerts"])] = (200, #"{"id":"7","displayName":"Bare"}"#)
        let bare = try await call("incident", #"{"id":"7"}"#, service)
        XCTAssertTrue(bare.text.contains("did not list its alerts, so which it holds is not known"), bare.text)
        XCTAssertTrue(bare.text.contains("severity unknown") && bare.text.contains("status unknown"), "unknown is never none: \(bare.text)")
    }

    func testHuntSendsTheQueryAndSaysWhatAnEmptyResultIsNot() async throws {
        let service = FakeService()
        service.answers["/v1.0/security/runHuntingQuery"] = (200, #"{"schema":[{"name":"Timestamp","type":"DateTime"},{"name":"FileName","type":"String"}],"results":[{"Timestamp":"2026-11-14T08:01:00Z","FileName":"cmd.exe"}]}"#)
        let hunt = try await call("hunt", #"{"query":"DeviceProcessEvents | take 1","timespan":"P7D"}"#, service)
        XCTAssertFalse(hunt.isError, hunt.text)
        XCTAssertTrue(hunt.text.contains("cmd.exe"), hunt.text)
        let posted = try XCTUnwrap(service.requests.last)
        XCTAssertEqual(posted.httpMethod, "POST")
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: posted.httpBody ?? Data()) as? [String: String]), ["Query": "DeviceProcessEvents | take 1", "Timespan": "P7D"])
        service.answers["/v1.0/security/runHuntingQuery"] = (200, #"{"schema":[{"name":"FileName","type":"String"}],"results":[]}"#)
        let empty = try await call("hunt", #"{"query":"EmailEvents | take 1"}"#, service)
        XCTAssertTrue(empty.text.contains("no rows") && empty.text.contains("not proof nothing happened"), empty.text)
        service.answers["/v1.0/security/runHuntingQuery"] = (200, #"{"schema":[{"name":"FileName","type":"String"}]}"#)
        let malformed = try await call("hunt", #"{"query":"EmailEvents | take 1"}"#, service)
        XCTAssertTrue(malformed.isError, "an answer without its results is unreadable, never empty: \(malformed.text)")
        service.answers["/v1.0/security/runHuntingQuery"] = (400, #"{"error":{"code":"BadRequest","message":"Query could not be parsed at 'tak'"}}"#)
        let wrong = try await call("hunt", #"{"query":"EmailEvents | tak 1"}"#, service)
        XCTAssertTrue(wrong.isError && wrong.text.contains("could not be parsed"), wrong.text)
        let before = service.requests.count
        for bad in [#"{"query":""}"#, #"{"query":"X","timespan":"P7D\"; drop"}"#] {
            let refused = try await call("hunt", bad, service)
            XCTAssertTrue(refused.isError, bad)
        }
        XCTAssertEqual(service.requests.count, before)
        XCTAssertTrue(Defender.capped(Defender.huntRows).contains("more may match"))
    }

    func testDevicesAndDeviceReadDeviceInfoWithValuesThatCannotBreakTheQuery() async throws {
        let service = FakeService()
        service.sequences["/v1.0/security/runHuntingQuery"] = [
            (200, #"{"schema":[{"name":"DeviceId"},{"name":"DeviceName"}],"results":[{"DeviceId":"\#(device)","DeviceName":"lt-0423.contoso.com","OSPlatform":"Windows11","OnboardingStatus":"Onboarded","SensorHealthState":"Active","ExposureLevel":"High","IsInternetFacing":true,"Timestamp":"2026-11-23T08:00:00Z"},{"DeviceId":"\#(String(repeating: "a", count: 40))","DeviceName":"lt-0424"}]}"#),
        ]
        let devices = try await call("devices", #"{"name":"lt-04","platform":"Windows11","limit":1}"#, service)
        XCTAssertFalse(devices.isError, devices.text)
        XCTAssertTrue(devices.text.contains("lt-0423.contoso.com [\(device)]") && devices.text.contains("exposure High") && devices.text.contains("internet-facing"), devices.text)
        XCTAssertTrue(devices.text.contains("More devices match than the 1 kept"), devices.text)
        let query = try XCTUnwrap(queries(service).last)
        XCTAssertTrue(query.contains(#"DeviceName startswith "lt-04""#) && query.contains(#"OSPlatform == "Windows11""#) && query.contains("take 2"), query)
        for bad in [#"{"name":"lt\" or 1==1 //"}"#, #"{"name":"a\nb"}"#, #"{"platform":"Plan9"}"#] {
            let refused = try await call("devices", bad, service)
            XCTAssertTrue(refused.isError, bad)
        }
        let injected = try await call("device", #"{"device":"x\") | union *"}"#, service)
        XCTAssertTrue(injected.isError, injected.text)
        XCTAssertEqual(queries(service).count, 1, "refused before anything is sent")

        // One device: what is read, and what could not be, apart.
        service.sequences["/v1.0/security/runHuntingQuery"] = [
            (200, #"{"schema":[{"name":"DeviceId"}],"results":[{"DeviceId":"\#(device)","DeviceName":"lt-0423","OnboardingStatus":"Onboarded","DeviceManualTags":"[\"VIP\"]"}]}"#),
            (429, #"{"error":{"code":"TooManyRequests","message":"Too many requests"}}"#),
            (200, #"{"schema":[{"name":"AlertId"}],"results":[{"AlertId":"da1","Title":"Ransomware behaviour","Severity":"High","Timestamp":"2026-11-23T07:00:00Z"}]}"#),
        ]
        let one = try await call("device", #"{"device":"\#(device.uppercased())"}"#, service)
        XCTAssertFalse(one.isError, one.text)
        XCTAssertTrue(one.text.contains("tags VIP") && one.text.contains("Ransomware behaviour [da1]"), one.text)
        XCTAssertTrue(one.text.contains("Could not read: its network addresses"), one.text)
        XCTAssertTrue(queries(service).suffix(3).allSatisfy { $0.contains(#"DeviceId == "\#(device)""#) }, "\(queries(service))")
        service.sequences["/v1.0/security/runHuntingQuery"] = [(200, #"{"schema":[{"name":"DeviceId"}],"results":[]}"#)]
        let missing = try await call("device", #"{"device":"lt-9999"}"#, service)
        XCTAssertFalse(missing.isError)
        XCTAssertTrue(missing.text.contains("reported no device lt-9999") && missing.text.contains("outside the admin's device groups"), missing.text)
    }

    func testMalformedAnswersAreErrorsAndThrottlingSaysHowLongToWait() async throws {
        let service = FakeService()
        service.answers["/v1.0/security/alerts_v2"] = (200, #"{"alerts":[]}"#)
        let malformed = try await call("alerts", "{}", service)
        XCTAssertTrue(malformed.isError, "a page without its value is unreadable, never empty: \(malformed.text)")
        service.answers["/v1.0/security/alerts_v2"] = (200, #"{"value":[{"title":"no id"}]}"#)
        let partial = try await call("alerts", "{}", service)
        XCTAssertTrue(partial.isError, partial.text)
        service.responseHeaders = ["Retry-After": "42"]
        service.answers["/v1.0/security/incidents"] = (429, #"{"error":{"code":"TooManyRequests","message":"Too many requests"}}"#)
        let throttled = try await call("incidents", "{}", service)
        XCTAssertTrue(throttled.isError && throttled.text.contains("asked to wait 42 seconds"), throttled.text)
    }

    func testRefusalsSayWhetherALicenceAPermissionOrARoleIsMissing() async throws {
        let service = FakeService()
        service.answers["/v1.0/security/alerts_v2"] = (403, #"{"error":{"code":"Forbidden","message":"Missing role permissions on the request."}}"#)
        let denied = try await call("alerts", "{}", service)
        XCTAssertTrue(denied.isError && denied.text.contains("SecurityAlert.Read.All") && denied.text.contains("Security Reader") && denied.text.contains("check-access"), denied.text)
        service.answers["/v1.0/security/incidents"] = (403, #"{"error":{"code":"Forbidden","message":"The tenant is not provisioned for Microsoft Defender XDR; a license is required."}}"#)
        let unlicensed = try await call("incidents", "{}", service)
        XCTAssertTrue(unlicensed.isError && unlicensed.text.contains("needs Microsoft Defender XDR in the tenant"), unlicensed.text)
        service.answers["/v1.0/security/runHuntingQuery"] = (401, #"{"error":{"code":"InvalidAuthenticationToken","message":"Access token has expired."}}"#)
        let expired = try await call("hunt", #"{"query":"DeviceInfo | take 1"}"#, service)
        XCTAssertTrue(expired.isError && expired.text.contains("Connect the tool again"), expired.text)
    }

    func testCheckAccessSaysWhatWorksWhichPlansHaveDataAndWhoIsSignedIn() async throws {
        let service = FakeService()
        service.answers["/v1.0/organization"] = (200, #"{"value":[{"id":"4f1c2e3d-0000-4000-8000-000000000001","displayName":"Contoso","verifiedDomains":[{"name":"contoso.onmicrosoft.com"}]}]}"#)
        service.answers["/v1.0/security/alerts_v2"] = (200, #"{"value":[]}"#)
        service.answers["/v1.0/security/incidents"] = (403, #"{"error":{"code":"Forbidden","message":"Missing role permissions."}}"#)
        service.answers["/v1.0/security/runHuntingQuery"] = (200, #"{"schema":[{"name":"Table"},{"name":"Rows"}],"results":[{"Table":"DeviceInfo","Rows":1200},{"Table":"EmailEvents","Rows":0}]}"#)
        service.answers["/v1.0/me"] = (200, #"{"id":"22222222-2222-4222-8222-222222222222","userPrincipalName":"pion-defender-audit@contoso.example"}"#)
        let checked = try await call("check-access", "{}", service)
        XCTAssertFalse(checked.isError, checked.text)
        for words in ["✓ Signed in to the tenant Contoso", "✓ Alerts", "✗ Incidents: either the app lacks the delegated permission SecurityIncident.Read.All",
                      "✓ Advanced hunting", "Data in the last 7 days from: Defender for Endpoint (DeviceInfo)",
                      "No data in the last 7 days from: Defender for Office 365 (EmailEvents), Defender for Identity (IdentityLogonEvents), Defender for Cloud Apps (CloudAppEvents)",
                      "Signed in as pion-defender-audit@contoso.example", "offline_access"] {
            XCTAssertTrue(checked.text.contains(words), "\(words): \(checked.text)")
        }
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" || $0.url?.path.hasSuffix("runHuntingQuery") == true }, "it changes nothing")
    }

    /// Who holds which Entra role is in Defender's hunting tables, so an audit of privileges can start there.
    func testItsInstructionsSayWhereEntraRolesAre() {
        XCTAssertTrue(Defender.preset.defaultInstructions.contains("IdentityInfo"))
        XCTAssertTrue(Defender.preset.defaultInstructions.contains("AssignedRoles"))
    }

    /// What a compromised account touched is in Defender's hunting tables: files on devices, and files and mail in
    /// Microsoft 365 apps.
    func testItsInstructionsSayWhereDownloadsAndFileAccessAre() {
        for table in ["DeviceFileEvents", "CloudAppEvents", "FileDownloaded", "EmailEvents"] {
            XCTAssertTrue(Defender.preset.defaultInstructions.contains(table), table)
        }
    }
}

extension Defender {
    static func iso(_ date: Date) -> String { Entra.iso(date) }
}
