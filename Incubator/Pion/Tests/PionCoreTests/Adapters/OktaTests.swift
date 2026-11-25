import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class OktaTests: XCTestCase {
    private let acme = try! Okta.preset.makeConnection(name: "Okta — Acme", values: ["domain": "acme.okta.com", "clientID": "0oaPionAudit"])
    private let contoso = try! Okta.preset.makeConnection(name: "Okta — Contoso", values: ["domain": "contoso.okta.com", "clientID": "0oaPionAudit"])

    private func call(_ tool: String, _ arguments: String, on service: FakeService, in connection: ToolConnection? = nil)
        async throws -> (text: String, isError: Bool, structured: [String: Any]?) {
        let data = try await Okta.adapter.run(tool, arguments: Data(arguments.utf8), connection: connection ?? acme, access: service)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? "", result["isError"] as? Bool ?? false,
                result["structuredContent"] as? [String: Any])
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        let items = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private let user = #"{"id":"00u1","status":"ACTIVE","created":"2024-01-02T03:04:05.000Z","lastLogin":"2026-11-14T09:03:00.000Z","passwordChanged":"2026-10-01T00:00:00.000Z","profile":{"login":"m.okafor@acme.example","email":"m.okafor@acme.example","firstName":"Mira","lastName":"Okafor"}}"#

    func testEachAccountIsItsOwnOrgSignedInAtItsOwnAuthorizationServer() throws {
        XCTAssertEqual(acme.endpoint.absoluteString, "https://acme.okta.com/api/v1")
        XCTAssertEqual(contoso.endpoint.absoluteString, "https://contoso.okta.com/api/v1")
        XCTAssertNil(acme.tokenHeader, "no API token: it signs in through OAuth")
        XCTAssertNil(acme.tokenScheme)
        XCTAssertFalse(acme.keepsSecret)
        XCTAssertEqual(acme.settings?["clientID"], "0oaPionAudit")
        XCTAssertEqual(acme.adapter, "okta")
        guard case .connection(let configuration) = Okta.preset.configuration else { return XCTFail() }
        XCTAssertNil(configuration.tokenRevocation)
        XCTAssertEqual(configuration.oauthClientField, "clientID")
        XCTAssertEqual(configuration.oauthHostField, "domain")
        let oauth = try XCTUnwrap(configuration.oauth(for: acme.settings))
        XCTAssertEqual(oauth.issuer.absoluteString, "https://acme.okta.com")
        XCTAssertEqual(oauth.authorizationEndpoint.absoluteString, "https://acme.okta.com/oauth2/v1/authorize")
        XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "https://acme.okta.com/oauth2/v1/token")
        XCTAssertEqual(oauth.revocationEndpoint?.absoluteString, "https://acme.okta.com/oauth2/v1/revoke")
        XCTAssertEqual(configuration.oauth(for: contoso.settings)?.tokenEndpoint.host, "contoso.okta.com")
        XCTAssertNil(oauth.deviceAuthorizationEndpoint, "an authorization code with PKCE, not a device code")
        XCTAssertFalse(oauth.usesResourceIndicator)
        XCTAssertEqual(oauth.authorizationParameters, ["prompt": "login"], "the admin signs in afresh, never as whoever the browser is signed in as")
        XCTAssertEqual(configuration.oauth?.tokenEndpoint.host, "okta.invalid", "the preset's own host is never reachable")
        XCTAssertTrue(oauth.scopes.allSatisfy { $0.hasSuffix(".read") || $0.hasSuffix(".read.self") || $0 == "offline_access" }, "Okta Detection only reads")
        XCTAssertEqual(Set(oauth.scopes), ["okta.users.read", "okta.users.read.self", "okta.groups.read", "okta.apps.read", "okta.logs.read",
                                           "okta.roles.read", "okta.apiTokens.read", "offline_access"])
        XCTAssertTrue(Okta.setup.contains { $0.contains("com.pdparchitect.pion:/oauth2callback") }, "the setup names the redirect URI Pion uses")
        XCTAssertTrue(Okta.auditScopes.allSatisfy { scope in Okta.setup.contains { $0.contains("`\(scope)`") } }, "the setup grants every scope asked for")
        defer { ToolCatalog.use(ToolCatalog.noodle) }
        ToolCatalog.use(PionCatalogue.entries)
        XCTAssertTrue(ToolConnectionService.signsInThroughBrowser(acme))
        XCTAssertFalse(ToolConnectionService.signsInWithCode(acme))
        XCTAssertEqual(ToolConnectionService.configuredRedirectURI(for: acme, bundleIdentifier: "com.pdparchitect.pion")?.absoluteString,
                       "com.pdparchitect.pion:/oauth2callback")
        XCTAssertEqual(ToolConnectionService.configuredRedirectURI(for: contoso, bundleIdentifier: "com.pdparchitect.pion.local")?.absoluteString,
                       "com.pdparchitect.pion.local:/oauth2callback")
        XCTAssertEqual(Okta.preset.name, "Okta Detection")
        XCTAssertEqual(Okta.preset.id, "bdc65def-9c77-4503-9d57-eac000822cce", "connections made before keep working")
        XCTAssertEqual(Okta.adapter.watchedTool, "security-events")
        XCTAssertNotEqual(acme.id, contoso.id)
        XCTAssertNotNil(PionAdapters.all["okta"])
    }

    func testFindingAUserAsksOnlyItsOwnOrg() async throws {
        let service = FakeService()
        service.answers["/api/v1/users"] = (200, "[\(user)]")
        let found = try await call("find-user", #"{"query":"m.okafor"}"#, on: service)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("Mira Okafor"), found.text)
        XCTAssertTrue(found.text.contains("ACTIVE"), found.text)
        let users = try XCTUnwrap(found.structured?["users"] as? [[String: Any]])
        XCTAssertEqual(users.first?["login"] as? String, "m.okafor@acme.example")
        XCTAssertEqual(users.first?["lastLogin"] as? String, "2026-11-14T09:03:00.000Z")
        XCTAssertEqual(query(service.requests.first), ["q": "m.okafor", "limit": "10"])
        _ = try await call("find-user", #"{"query":"m.okafor"}"#, on: service, in: contoso)
        XCTAssertEqual(service.requests.map { $0.url!.host! }, ["acme.okta.com", "contoso.okta.com"])
    }

    func testAUsersGroupsAppsAndFactors() async throws {
        let service = FakeService()
        service.answers["/api/v1/users/00u1/groups"] = (200, #"[{"id":"00g1","profile":{"name":"Finance","description":"Payroll team"}}]"#)
        service.answers["/api/v1/users/00u1"] = (200, user)
        service.answers["/api/v1/apps"] = (200, #"[{"id":"0oa1","label":"Workday","name":"workday","status":"ACTIVE"}]"#)
        service.answers["/api/v1/users/00u1/factors"] = (200, #"[{"id":"opf1","factorType":"push","provider":"OKTA","status":"ACTIVE","created":"2025-01-01T00:00:00.000Z"}]"#)
        let groups = try await call("user-groups", #"{"user":"00u1"}"#, on: service)
        XCTAssertTrue(groups.text.contains("Finance"), groups.text)
        let apps = try await call("user-apps", #"{"user":"00u1"}"#, on: service)
        XCTAssertEqual((apps.structured?["apps"] as? [[String: Any]])?.first?["label"] as? String, "Workday")
        XCTAssertEqual(queryItems(service.requests.last)["filter"], #"user.id eq "00u1""#, "every app assigned, hidden ones and those through groups too")
        let factors = try await call("user-factors", #"{"user":"00u1"}"#, on: service)
        XCTAssertTrue(factors.text.contains("push"), factors.text)
        XCTAssertEqual((factors.structured?["factors"] as? [[String: Any]])?.first?["status"] as? String, "ACTIVE")
    }

    func testSignInEventsAreFilteredOnTheServiceNewestFirst() async throws {
        let service = FakeService()
        service.answers["/api/v1/logs"] = (200, #"[{"uuid":"e1","published":"2026-11-14T09:06:00.000Z","eventType":"user.session.start","displayMessage":"User login to Okta","outcome":{"result":"SUCCESS"},"actor":{"alternateId":"m.okafor@acme.example","displayName":"Mira Okafor"},"client":{"ipAddress":"203.0.113.77","geographicalContext":{"city":"Lagos","country":"Nigeria"},"userAgent":{"rawUserAgent":"Mozilla/5.0"}}}]"#)
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 86_400))
        let events = try await call("sign-in-events", #"{"user":"m.okafor@acme.example","ip":"203.0.113.77","failuresOnly":true,"since":"\#(since)","limit":20}"#, on: service)
        XCTAssertFalse(events.isError, events.text)
        XCTAssertTrue(events.text.contains("203.0.113.77"), events.text)
        XCTAssertEqual((events.structured?["events"] as? [[String: Any]])?.first?["city"] as? String, "Lagos")
        let sent = query(service.requests.first)
        XCTAssertEqual(sent["filter"], #"actor.alternateId eq "m.okafor@acme.example" and client.ipAddress eq "203.0.113.77" and outcome.result eq "FAILURE""#)
        XCTAssertEqual(sent["since"], since)
        XCTAssertNotNil(sent["until"], "always bounded, so Okta's pages end")
        XCTAssertEqual(sent["limit"], "20")
        XCTAssertEqual(sent["sortOrder"], "DESCENDING")

        _ = try await call("sign-in-events", "{}", on: service)
        XCTAssertNotNil(query(service.requests.last)["since"], "an open-ended search still has a window")
    }

    func testValuesThatCouldChangeAFilterAreRefused() async throws {
        let service = FakeService()
        for arguments in [#"{"user":"x\" or actor.id pr \"y"}"#, #"{"ip":"not an ip"}"#, #"{"since":"yesterday"}"#,
                          #"{"eventType":"a\\b"}"#, #"{"limit":500}"#, #"{"target":"x\" or target.id pr \"y"}"#,
                          #"{"since":"2020-01-01T00:00:00Z"}"#, #"{"since":"2026-11-20T00:00:00Z","until":"2026-11-19T00:00:00Z"}"#] {
            let result = try await call("sign-in-events", arguments, on: service)
            XCTAssertTrue(result.isError, arguments)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    // MARK: Breach scope

    /// The apps a user let act for them, with what they may do: each one keeps working after a password change.
    func testAUsersGrantsSayWhichAppsActForThemAndWithWhatScopes() async throws {
        let service = FakeService()
        service.answers["/api/v1/users/00u1/grants"] = (200, #"[{"id":"oag1","clientId":"0oa-crm","scopeId":"scp1","status":"ACTIVE","source":"END_USER","created":"2026-11-14T09:00:00.000Z","issuer":"https://acme.okta.com","_embedded":{"scope":{"name":"okta.users.read"}}}]"#)
        let grants = try await callTool(Okta.adapter, "user-grants", #"{"user":"00u1"}"#, on: service, in: acme)
        XCTAssertFalse(grants.isError, grants.text)
        XCTAssertTrue(grants.text.contains("0oa-crm") && grants.text.contains("okta.users.read") && grants.text.contains("granted by the user"), grants.text)
        XCTAssertEqual(queryItems(service.requests.last)["expand"], "scope")
    }

    /// Who holds an admin role, and which: the accounts that can change the org.
    func testAdminRolesListEachAdminWithTheirRoles() async throws {
        let service = FakeService()
        service.answers["/api/v1/iam/assignees/users"] = (200, #"{"value":[{"id":"00u1"},{"id":"00u2"}]}"#)
        service.answers["/api/v1/users/00u1/roles"] = (200, #"[{"id":"ra1","type":"SUPER_ADMIN","label":"Super Administrator","status":"ACTIVE","assignmentType":"USER"}]"#)
        service.answers["/api/v1/users/00u2/roles"] = (200, #"[{"id":"ra2","type":"READ_ONLY_ADMIN","label":"Read Only Administrator","status":"ACTIVE","assignmentType":"GROUP"}]"#)
        service.answers["/api/v1/users/00u1"] = (200, #"{"id":"00u1","status":"ACTIVE","profile":{"login":"it@acme.example"}}"#)
        service.answers["/api/v1/users/00u2"] = (200, #"{"id":"00u2","status":"ACTIVE","profile":{"login":"pion@acme.example"}}"#)
        let admins = try await callTool(Okta.adapter, "admin-roles", "{}", on: service, in: acme)
        XCTAssertFalse(admins.isError, admins.text)
        let lines = admins.text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].contains("it@acme.example") && lines[0].contains("Super Administrator"), admins.text)
        XCTAssertTrue(lines.contains { $0.contains("pion@acme.example") && $0.contains("Read Only Administrator (through a group)") }, admins.text)
    }

    /// API tokens act as the admin who made them, from anywhere unless limited: who made each, and when it was last used.
    func testAPITokensSayWhoMadeEachAndWhenItExpires() async throws {
        let service = FakeService()
        service.answers["/api/v1/api-tokens"] = (200, #"[{"id":"t1","name":"terraform","userId":"00u1","clientName":"Okta API","created":"2025-01-01T00:00:00.000Z","expiresAt":"2026-12-01T00:00:00.000Z","lastUpdated":"2026-11-14T09:00:00.000Z","network":{"connection":"ANYWHERE"}}]"#)
        service.answers["/api/v1/users/00u1"] = (200, #"{"id":"00u1","status":"ACTIVE","profile":{"login":"it@acme.example"}}"#)
        let tokens = try await callTool(Okta.adapter, "api-tokens", "{}", on: service, in: acme)
        XCTAssertFalse(tokens.isError, tokens.text)
        XCTAssertTrue(tokens.text.contains("terraform") && tokens.text.contains("it@acme.example") && tokens.text.contains("from anywhere")
                      && tokens.text.contains("expires 2026-12-01"), tokens.text)
    }

    /// A refusal names the custom role the signed-in admin needs, as the Read-Only Administrator cannot see admins.
    func testARefusedAuditSaysWhichRoleItNeeds() async throws {
        let service = FakeService()
        service.answers["/api/v1/iam/assignees/users"] = (403, #"{"errorCode":"E0000006","errorSummary":"You do not have permission to perform the requested action"}"#)
        let refused = try await callTool(Okta.adapter, "admin-roles", "{}", on: service, in: acme)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("View roles, resources, and admin assignments"), refused.text)
    }

    // MARK: Honest listings

    private func link(_ query: String, host: String = "acme.okta.com", path: String = "/api/v1/users/00u1/groups") -> [String: String] {
        ["Link": #"<https://\#(host)\#(path)?limit=200>; rel="self", <https://\#(host)\#(path)?\#(query)>; rel="next""#]
    }

    /// Every page is read, each asked of the org's own host with only Okta's cursor taken from its link.
    func testListingsFollowOktaNextLinksOnlyOnTheOrgsOwnHost() async throws {
        let service = FakeService()
        let path = "/api/v1/users/00u1/groups"
        service.sequences[path] = [(200, #"[{"id":"00g1","type":"OKTA_GROUP","profile":{"name":"Finance"}}]"#),
                                   (200, #"[{"id":"00g2","type":"APP_GROUP","profile":{"name":"AD Admins"}}]"#)]
        service.sequenceHeaders[path] = [link("after=00g1&limit=200&evil=1"), [:]]
        let groups = try await call("user-groups", #"{"user":"00u1"}"#, on: service)
        XCTAssertFalse(groups.isError, groups.text)
        XCTAssertTrue(groups.text.contains("Finance") && groups.text.contains("AD Admins (from an app)"), groups.text)
        XCTAssertEqual(groups.structured?["complete"] as? Bool, true)
        XCTAssertEqual(service.requests.count, 2)
        XCTAssertEqual(queryItems(service.requests.last), ["after": "00g1", "limit": "200"], "only the cursor is taken from Okta's link")
        XCTAssertTrue(service.requests.allSatisfy { $0.url?.host == "acme.okta.com" && $0.url?.path == path })

        // A next link anywhere else is never followed, and the result says it stopped.
        for elsewhere in [link("after=x", host: "evil.example"), link("after=x", path: "/api/v1/users"), link("cursor=x")] {
            let other = FakeService()
            other.sequences[path] = [(200, #"[{"id":"00g1","type":"OKTA_GROUP","profile":{"name":"Finance"}}]"#)]
            other.sequenceHeaders[path] = [elsewhere]
            let cut = try await call("user-groups", #"{"user":"00u1"}"#, on: other)
            XCTAssertEqual(other.requests.count, 1)
            XCTAssertTrue(cut.text.contains("read so far") && cut.text.contains("Incomplete: stopped at page 2 reading groups"), cut.text)
            XCTAssertEqual(cut.structured?["complete"] as? Bool, false)
        }
    }

    /// Find-user, grants, admins and tokens each say when they kept less than matched.
    func testEveryListingSaysWhenItStoppedEarlyOrMatchedMore() async throws {
        let service = FakeService()
        service.sequences["/api/v1/users"] = [(200, "[\(user)]")]
        service.sequenceHeaders["/api/v1/users"] = [link("after=00u1&limit=1&q=mira", path: "/api/v1/users")]
        let found = try await call("find-user", #"{"query":"mira","limit":1}"#, on: service)
        XCTAssertTrue(found.text.contains("More users match than the 1 kept"), found.text)
        XCTAssertEqual(service.requests.count, 1, "find-user reads one page and says more match")

        // Admins come in pages whose next link is in the body.
        let admins = FakeService()
        admins.sequences["/api/v1/iam/assignees/users"] = [
            (200, #"{"value":[{"id":"00u1"}],"_links":{"next":{"href":"https://acme.okta.com/api/v1/iam/assignees/users?after=00u1&limit=100"}}}"#),
            (200, #"{"value":[{"id":"00u2"}],"_links":{}}"#)]
        for id in ["00u1", "00u2"] {
            admins.answers["/api/v1/users/\(id)/roles"] = (200, #"[{"id":"ra\#(id)","type":"ORG_ADMIN","label":"Organization Administrator","assignmentType":"USER"}]"#)
        }
        admins.answers["/api/v1/users/00u1"] = (200, #"{"id":"00u1","profile":{"login":"one@acme.example"}}"#)
        admins.answers["/api/v1/users/00u2"] = (429, #"{"errorCode":"E0000047","errorSummary":"API call exceeded rate limit due to too many requests."}"#)
        let listed = try await callTool(Okta.adapter, "admin-roles", "{}", on: admins, in: acme)
        XCTAssertFalse(listed.isError, listed.text)
        XCTAssertTrue(listed.text.contains("one@acme.example") && listed.text.contains("00u2: Organization Administrator"), listed.text)
        XCTAssertTrue(listed.text.contains("1 admin's login could not be read"), listed.text)
        XCTAssertEqual(queryItems(admins.requests.first { $0.url?.path == "/api/v1/iam/assignees/users" && queryItems($0)["after"] != nil }), ["after": "00u1", "limit": "100"])

        // Grants and tokens past the first page are read too.
        let grants = FakeService()
        grants.sequences["/api/v1/users/00u1/grants"] = [(200, #"[{"id":"oag1","clientId":"0oa-crm","source":"END_USER"}]"#), (200, #"[{"id":"oag2","clientId":"0oa-mail","source":"ADMIN"}]"#)]
        grants.sequenceHeaders["/api/v1/users/00u1/grants"] = [link("after=oag1&expand=scope&limit=200", path: "/api/v1/users/00u1/grants"), [:]]
        let read = try await callTool(Okta.adapter, "user-grants", #"{"user":"00u1"}"#, on: grants, in: acme)
        XCTAssertTrue(read.text.contains("0oa-crm") && read.text.contains("0oa-mail") && read.text.contains("granted by an admin"), read.text)
        let tokens = FakeService()
        tokens.sequences["/api/v1/api-tokens"] = [(200, #"[{"id":"00T1","name":"one","userId":"00u1"}]"#), (200, #"[{"id":"00T2","name":"two","userId":"00u1"}]"#)]
        tokens.sequenceHeaders["/api/v1/api-tokens"] = [link("after=00T1&limit=200", path: "/api/v1/api-tokens"), [:]]
        tokens.answers["/api/v1/users/00u1"] = (200, #"{"id":"00u1","profile":{"login":"it@acme.example"}}"#)
        let all = try await callTool(Okta.adapter, "api-tokens", "{}", on: tokens, in: acme)
        XCTAssertTrue(all.text.contains("one [00T1]") && all.text.contains("two [00T2]"), all.text)
    }

    /// Okta's System Log search is bounded, newest first, and says when more matched than it kept.
    func testSignInEventsSayWhenMoreMatchedThanKept() async throws {
        let service = FakeService()
        service.sequences["/api/v1/logs"] = [(200, #"[{"uuid":"e1","published":"2026-11-14T09:06:00.000Z","eventType":"user.mfa.factor.reset_all","outcome":{"result":"SUCCESS"},"actor":{"alternateId":"admin@acme.example"},"target":[{"id":"00u1","type":"User","alternateId":"m.okafor@acme.example"}]}]"#)]
        service.sequenceHeaders["/api/v1/logs"] = [link("after=e1&limit=1", path: "/api/v1/logs")]
        let events = try await call("sign-in-events", #"{"target":"m.okafor@acme.example","limit":1}"#, on: service)
        XCTAssertFalse(events.isError, events.text)
        XCTAssertTrue(events.text.contains("on m.okafor@acme.example") && events.text.contains("More events match than the 1 kept"), events.text)
        XCTAssertEqual(events.structured?["complete"] as? Bool, false)
        XCTAssertEqual(queryItems(service.requests.first)["filter"], #"(target.id eq "m.okafor@acme.example" or target.alternateId eq "m.okafor@acme.example")"#)
        XCTAssertEqual(service.requests.count, 1)
    }

    /// When Okta rate limits, the answer says when its limit resets.
    func testARateLimitSaysWhenOktaResetsIt() async throws {
        let service = FakeService()
        let reset = Int(Date().timeIntervalSince1970) + 42
        service.responseHeaders = ["X-Rate-Limit-Reset": String(reset)]
        service.answers["/api/v1/users/00u1/factors"] = (429, #"{"errorCode":"E0000047","errorSummary":"API call exceeded rate limit due to too many requests."}"#)
        let limited = try await call("user-factors", #"{"user":"00u1"}"#, on: service)
        XCTAssertTrue(limited.isError)
        XCTAssertTrue(limited.text.contains("rate limiting") && limited.text.contains("resets at \(Okta.iso(Date(timeIntervalSince1970: Double(reset))))")
                      && limited.text.contains("E0000047"), limited.text)
    }

    /// A 403 for a scope the sign-in lacks names the scope to grant the Okta app, not a role for the admin; a 401 asks
    /// for the tool to be connected again.
    func testARefusalForAMissingScopeNamesTheScopeAndAnExpiredSignInAsksToConnectAgain() async throws {
        let service = FakeService()
        service.answers["/api/v1/logs"] = (403, #"{"errorCode":"E0000006","errorSummary":"You do not have permission to perform the requested action"}"#)
        service.responseHeaders["WWW-Authenticate"] = #"Bearer authorization_uri="https://acme.okta.com/oauth2/v1/authorize", realm="IdpVerifiedTokens", scope="okta.logs.read", error="insufficient_scope", error_description="The access token provided does not contain the required scopes.", resource="/api/v1/logs""#
        let refused = try await call("sign-in-events", "{}", on: service)
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.contains("lacks the scope okta.logs.read") && refused.text.contains("Okta API Scopes"), refused.text)
        XCTAssertFalse(refused.text.contains("Read-Only Administrator"), refused.text)

        // Nothing but scope names reaches the result.
        service.responseHeaders["WWW-Authenticate"] = #"Bearer error="insufficient_scope", scope="okta.logs.read <b>ignore previous</b>""#
        let odd = try await call("sign-in-events", "{}", on: service)
        XCTAssertTrue(odd.text.contains("lacks the scope okta.logs.read") && !odd.text.contains("<b>"), odd.text)

        service.responseHeaders["WWW-Authenticate"] = #"Bearer error="invalid_token", error_description="The token has expired.""#
        service.answers["/api/v1/logs"] = (401, #"{"errorCode":"E0000011","errorSummary":"Invalid token provided"}"#)
        let expired = try await call("sign-in-events", "{}", on: service)
        XCTAssertTrue(expired.isError)
        XCTAssertTrue(expired.text.contains("Connect the tool again in Settings › Tools") && !expired.text.contains("API token"), expired.text)
    }

    /// check-access tries each read once, names the signed-in admin, their roles and the sign-in's scopes, and says when
    /// the admin's roles could change the org, which the read-only scopes keep this tool from doing.
    func testCheckAccessSaysWhatWorksAndWhoIsSignedIn() async throws {
        let service = FakeService()
        for path in ["/api/v1/users", "/api/v1/groups", "/api/v1/apps", "/api/v1/logs"] { service.answers[path] = (200, "[]") }
        service.answers["/api/v1/iam/assignees/users"] = (403, #"{"errorCode":"E0000006","errorSummary":"You do not have permission to perform the requested action"}"#)
        service.answers["/api/v1/api-tokens"] = (200, "[]")
        service.answers["/api/v1/users/me"] = (200, #"{"id":"00upion","profile":{"login":"pion-detection@acme.example"}}"#)
        service.answers["/api/v1/users/00upion/roles"] = (200, #"[{"id":"ra1","type":"READ_ONLY_ADMIN","label":"Read Only Administrator"},{"id":"ra2","type":"CUSTOM","label":"Pion Detection","role":"cr0audit"}]"#)
        service.answers["/api/v1/iam/roles/cr0audit/permissions"] = (200, #"{"permissions":[{"label":"okta.iam.read"},{"label":"okta.users.apitokens.read"}]}"#)
        let checked = try await call("check-access", "{}", on: service)
        XCTAssertFalse(checked.isError, checked.text)
        XCTAssertTrue(checked.text.contains("✓ System Log") && checked.text.contains("✗ Admin assignments") && checked.text.contains("okta.iam.read"), checked.text)
        XCTAssertTrue(checked.text.contains("Signed in as pion-detection@acme.example") && checked.text.contains("✓ The signed-in admin cannot change the org"), checked.text)
        XCTAssertTrue(checked.text.contains("okta.logs.read") && checked.text.contains("offline_access") && checked.text.contains("0oaPionAudit"),
                      "it reports the sign-in's scopes and the app they are granted to: \(checked.text)")
        XCTAssertFalse(service.requests.contains { $0.url!.path.hasSuffix("/current") }, "no API token of its own to read")
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" }, "it changes nothing")

        service.answers["/api/v1/iam/roles/cr0audit/permissions"] = (200, #"{"permissions":[{"label":"okta.iam.read"},{"label":"okta.users.lifecycle.suspend"}]}"#)
        let broad = try await call("check-access", "{}", on: service)
        XCTAssertTrue(broad.text.contains("⚠ The signed-in admin's roles also allow changes: okta.users.lifecycle.suspend")
                      && broad.text.contains("scopes only read"), broad.text)
    }

    /// A page that fails after others keeps what they held, saying where and why it stopped; the first failing fails
    /// the call.
    func testAListingThatFailsPartWayKeepsWhatItReadAndSaysWhere() async throws {
        let service = FakeService()
        let path = "/api/v1/users/00u1/grants"
        service.sequences[path] = [(200, #"[{"id":"oag1","clientId":"0oa-crm","source":"END_USER"}]"#),
                                   (500, #"{"errorCode":"E0000009","errorSummary":"Internal Server Error"}"#)]
        service.sequenceHeaders[path] = [link("after=oag1&limit=200", path: path), [:]]
        let partial = try await call("user-grants", #"{"user":"00u1"}"#, on: service)
        XCTAssertFalse(partial.isError, partial.text)
        XCTAssertTrue(partial.text.contains("0oa-crm"), "the first page's evidence is kept: \(partial.text)")
        XCTAssertTrue(partial.text.contains("Incomplete: stopped at page 2 reading grants because") && partial.text.contains("HTTP 500"), partial.text)
        XCTAssertEqual(partial.structured?["complete"] as? Bool, false)

        let first = FakeService()
        first.answers[path] = (500, #"{"errorCode":"E0000009","errorSummary":"Internal Server Error"}"#)
        let failed = try await call("user-grants", #"{"user":"00u1"}"#, on: first)
        XCTAssertTrue(failed.isError, failed.text)
    }

    /// An answer that is not the listing Okta gives, such as an envelope without its value, is an error, never "nothing
    /// found".
    func testAMalformedListingIsAnErrorNotAnEmptyResult() async throws {
        for body in [#"{"_links":{}}"#, #"{"value":null}"#, #"{"value":{"id":"00u1"}}"#, #"{"errorSummary":"odd"}"#] {
            let service = FakeService()
            service.answers["/api/v1/iam/assignees/users"] = (200, body)
            let admins = try await call("admin-roles", "{}", on: service)
            XCTAssertTrue(admins.isError, body)
            XCTAssertFalse(admins.text.contains("Nobody holds"), admins.text)
        }
        let service = FakeService()
        service.answers["/api/v1/users/00u1/groups"] = (200, #"{"groups":[]}"#)
        let groups = try await call("user-groups", #"{"user":"00u1"}"#, on: service)
        XCTAssertTrue(groups.isError && !groups.text.contains("in no groups"), groups.text)
        // An empty array is an honest empty listing.
        service.answers["/api/v1/users/00u1/groups"] = (200, "[]")
        let none = try await call("user-groups", #"{"user":"00u1"}"#, on: service)
        XCTAssertFalse(none.isError, none.text)
        XCTAssertTrue(none.text.contains("in no groups"), none.text)
    }
}

