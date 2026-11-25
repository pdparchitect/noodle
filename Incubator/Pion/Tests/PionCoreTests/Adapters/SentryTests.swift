import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class SentryTests: XCTestCase {
    static let clientID = "3f9c2a7e5b1d4c8f0a6e9b2d7c4f1a8e5b3d0c6f9a2e7b4d1c8f5a0e3b6d9c2f"
    private let cloud = try! Sentry.cloud.makeConnection(name: "Sentry", values: ["region": "de.sentry.io", "org": "kestrel-labs", "clientID": SentryTests.clientID])
    private let local = try! Sentry.server.makeConnection(name: "Sentry", values: ["host": "sentry.kestrel.example", "org": "sentry", "clientID": SentryTests.clientID])

    func testSentryAndASelfHostedOneShareOneAdapterAndSignInWithACode() throws {
        XCTAssertEqual(cloud.endpoint.absoluteString, "https://de.sentry.io/api/0/organizations/kestrel-labs")
        XCTAssertEqual(local.endpoint.absoluteString, "https://sentry.kestrel.example/api/0/organizations/sentry")
        for address in ["http://sentry.kestrel.example", "sentry.kestrel.example:9000", "sentry", "https://sentry.kestrel.example"] {
            XCTAssertThrowsError(try Sentry.server.makeConnection(name: "Sentry", values: ["host": address, "org": "sentry", "clientID": Self.clientID]),
                                 "a sign-in anywhere but https on the default port: \(address)")
        }
        for account in [cloud, local] {
            XCTAssertEqual(account.adapter, "sentry")
            XCTAssertNil(account.tokenHeader, "no token to paste: it signs in with a code")
            XCTAssertFalse(account.keepsSecret)
            XCTAssertEqual(account.settings?["clientID"], Self.clientID)
        }
        XCTAssertNotNil(PionAdapters.all["sentry"])

        guard case .connection(let sentry) = Sentry.cloud.configuration, case .connection(let server) = Sentry.server.configuration else { return XCTFail() }
        XCTAssertEqual(sentry.oauthClientField, "clientID")
        XCTAssertNil(sentry.oauthHostField, "sentry.io signs in for both regions")
        let oauth = try XCTUnwrap(sentry.oauth(for: cloud.settings))
        XCTAssertEqual(oauth.issuer.absoluteString, "https://sentry.io")
        XCTAssertEqual(oauth.authorizationEndpoint.absoluteString, "https://sentry.io/oauth/authorize/")
        XCTAssertEqual(oauth.tokenEndpoint.absoluteString, "https://sentry.io/oauth/token/")
        XCTAssertEqual(oauth.deviceAuthorizationEndpoint?.absoluteString, "https://sentry.io/oauth/device/code/")
        XCTAssertNil(oauth.revocationEndpoint, "Sentry documents none")
        XCTAssertFalse(oauth.usesResourceIndicator)
        XCTAssertTrue(oauth.clients.isEmpty, "each person registers their own")
        XCTAssertEqual(oauth.scopes, ["event:read", "org:read"])
        XCTAssertTrue(oauth.scopes.allSatisfy { $0.hasSuffix(":read") }, "Sentry only reads")
        XCTAssertTrue(oauth.unlistedScopes.isEmpty)

        // A self-hosted Sentry signs in at its own host, the device code included, and never at the preset's.
        XCTAssertEqual(server.oauthClientField, "clientID")
        XCTAssertEqual(server.oauthHostField, "host")
        XCTAssertEqual(server.oauth?.tokenEndpoint.host, "sentry.invalid", "the preset's own host is never reachable")
        let own = try XCTUnwrap(server.oauth(for: local.settings))
        XCTAssertEqual(own.issuer.absoluteString, "https://sentry.kestrel.example")
        XCTAssertEqual(own.authorizationEndpoint.absoluteString, "https://sentry.kestrel.example/oauth/authorize/")
        XCTAssertEqual(own.tokenEndpoint.absoluteString, "https://sentry.kestrel.example/oauth/token/")
        XCTAssertEqual(own.deviceAuthorizationEndpoint?.absoluteString, "https://sentry.kestrel.example/oauth/device/code/")
        XCTAssertEqual(own.scopes, oauth.scopes)

        let cloudSetup = Sentry.cloudSetup.joined(separator: "\n"), serverSetup = Sentry.serverSetup.joined(separator: "\n")
        for setup in [cloudSetup, serverSetup] {
            XCTAssertTrue(Sentry.scopes.allSatisfy { setup.contains("`\($0)`") }, setup)
            XCTAssertTrue(setup.contains("**Public**") && setup.contains("Client ID"), setup)
            XCTAssertFalse(setup.localizedCaseInsensitiveContains("token"), "no token to make: \(setup)")
        }
        XCTAssertTrue(serverSetup.contains("26.2.0"), "an older server cannot sign in with a code")

        defer { ToolCatalog.use(ToolCatalog.noodle) }
        ToolCatalog.use(PionCatalogue.entries)
        XCTAssertTrue(ToolConnectionService.signsInWithCode(cloud))
        XCTAssertTrue(ToolConnectionService.signsInWithCode(local))
    }

    func testARefusalSaysWhichScopeOrToSignInAgain() async throws {
        let service = FakeService()
        service.answers["/api/0/organizations/sentry/issues"] = (403, #"{"detail":"You do not have permission to perform this action."}"#)
        service.answers["/api/0/organizations/sentry/projects"] = (401, #"{"detail":"Invalid token"}"#)
        let issues = try await callTool(Sentry.adapter, "issues", "{}", on: service, in: local)
        XCTAssertTrue(issues.isError)
        XCTAssertTrue(issues.text.contains("lacks the scope event:read") && issues.text.contains("Sign in again in Settings › Tools"), issues.text)
        let projects = try await callTool(Sentry.adapter, "projects", "{}", on: service, in: local)
        XCTAssertTrue(projects.isError)
        XCTAssertTrue(projects.text.contains("did not accept the sign-in") && projects.text.contains("Invalid token"), projects.text)
    }

    func testCheckAccessTriesEachReadAndListsTheScopes() async throws {
        let service = FakeService()
        service.answers["/api/0/organizations/kestrel-labs/projects"] = (200, #"[{"id":"4504","slug":"web"}]"#)
        service.answers["/api/0/organizations/kestrel-labs/issues"] = (200, #"[{"id":"5203481129"}]"#)
        service.answers["/api/0/organizations/kestrel-labs/issues/5203481129/events/latest"] = (200, #"{"id":"9f1c"}"#)
        let result = try await callTool(Sentry.adapter, "check-access", "{}", on: service, in: cloud)
        XCTAssertFalse(result.isError, result.text)
        for line in ["✓ Projects (org:read)", "✓ Issues (event:read)", "✓ Issue events (event:read)",
                     "event:read, org:read, granted to the Sentry API application \(Self.clientID)"] {
            XCTAssertTrue(result.text.contains(line), result.text)
        }
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" }, "it only reads")

        let refused = FakeService()
        refused.answers["/api/0/organizations/kestrel-labs/projects"] = (200, "[]")
        refused.answers["/api/0/organizations/kestrel-labs/issues"] = (403, "{}")
        let partial = try await callTool(Sentry.adapter, "check-access", "{}", on: refused, in: cloud)
        XCTAssertTrue(partial.text.contains("✓ Projects"), partial.text)
        XCTAssertTrue(partial.text.contains("✗ Issues: the sign-in lacks the scope event:read"), partial.text)
        XCTAssertTrue(partial.text.contains("no issue in the last 14 days"), partial.text)
    }

    func testIssuesAreSearchedForTheOrganisationWithTheirCounts() async throws {
        let service = FakeService()
        service.answers["/api/0/organizations/sentry/issues"] = (200, #"""
        [{"id":"5203481129","shortId":"WEB-7Q","title":"ValueError: bad token","culprit":"auth.verify","level":"error",
          "status":"unresolved","count":"184","userCount":12,"firstSeen":"2026-11-17T08:00:00Z","lastSeen":"2026-11-18T01:59:00Z",
          "permalink":"https://sentry.kestrel.example/organizations/sentry/issues/5203481129/","project":{"slug":"web"}}]
        """#)
        let result = try await callTool(Sentry.adapter, "issues", #"{"query":"is:unresolved level:error","project":"4504","period":"14d","sort":"freq"}"#,
                                        on: service, in: local)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("WEB-7Q [error, unresolved] ValueError: bad token — 184 events, 12 users"), result.text)
        XCTAssertTrue(result.text.contains("(ID 5203481129)"), result.text)
        let sent = queryItems(service.requests.first)
        XCTAssertEqual(sent["query"], "is:unresolved level:error")
        XCTAssertEqual(sent["project"], "4504")
        XCTAssertEqual(sent["statsPeriod"], "14d")
        XCTAssertEqual(sent["sort"], "freq")
        // Sentry's addresses end in a slash, and it redirects those that do not, which a tool never follows.
        XCTAssertTrue(service.requests.first?.url?.absoluteString.hasPrefix("https://sentry.kestrel.example/api/0/organizations/sentry/issues/?") == true,
                      service.requests.first?.url?.absoluteString ?? "")
        for bad in [#"{"period":"forever"}"#, #"{"project":"web"}"#, #"{"sort":"random"}"#, #"{"limit":500}"#] {
            let refused = try await callTool(Sentry.adapter, "issues", bad, on: service, in: local)
            XCTAssertTrue(refused.isError, bad)
        }
    }

    func testAnIssuesLatestEventShowsItsExceptionOwnFramesRequestUserAndTags() async throws {
        let service = FakeService()
        service.answers["/api/0/organizations/kestrel-labs/issues/5203481129/events/latest"] = (200, #"""
        {"eventID":"9f1c","title":"ValueError: bad token","dateCreated":"2026-11-18T01:59:00Z",
         "entries":[{"type":"exception","data":{"values":[{"type":"ValueError","value":"bad token",
            "stacktrace":{"frames":[{"filename":"site-packages/jwt.py","function":"decode","lineNo":88,"inApp":false},
                                    {"filename":"auth/verify.py","function":"verify","lineNo":42,"inApp":true}]}}]}},
                    {"type":"request","data":{"url":"https://app.example/login","method":"POST"}}],
         "user":{"id":"u-7","email":"m.okafor@example.com","ip_address":"203.0.113.77"},
         "tags":[{"key":"browser","value":"Chrome 131"},{"key":"release","value":"web@4.2.0"}]}
        """#)
        let result = try await callTool(Sentry.adapter, "issue-event", #"{"issue":"5203481129"}"#, on: service, in: cloud)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("ValueError: bad token"), result.text)
        XCTAssertTrue(result.text.contains("at verify (auth/verify.py:42)"), result.text)
        XCTAssertFalse(result.text.contains("jwt.py"), "a library's frame was shown as the service's own")
        XCTAssertTrue(result.text.contains("Request: POST https://app.example/login"), result.text)
        XCTAssertTrue(result.text.contains("User: m.okafor@example.com, u-7, 203.0.113.77"), result.text)
        XCTAssertTrue(result.text.contains("release=web@4.2.0"), result.text)
        let refused = try await callTool(Sentry.adapter, "issue-event", #"{"issue":"../../projects"}"#, on: service, in: cloud)
        XCTAssertTrue(refused.isError)
    }

    func testProjectsListEachOnesID() async throws {
        let service = FakeService()
        service.answers["/api/0/organizations/sentry/projects"] = (200, #"[{"id":"4504","slug":"web","name":"Web","platform":"python"}]"#)
        let result = try await callTool(Sentry.adapter, "projects", "{}", on: service, in: local)
        XCTAssertEqual(result.text, "Web (web, ID 4504), python")
    }
}
