import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class SentryTests: XCTestCase {
    private let cloud = try! Sentry.cloud.makeConnection(name: "Sentry", values: ["region": "de.sentry.io", "org": "kestrel-labs"])
    private let local = try! Sentry.server.makeConnection(name: "Sentry", values: ["address": "http://sentry:9000", "org": "sentry"])

    func testSentryAndASelfHostedOneShareOneAdapterWithABearerToken() throws {
        XCTAssertEqual(cloud.endpoint.absoluteString, "https://de.sentry.io/api/0/organizations/kestrel-labs")
        XCTAssertEqual(local.endpoint.absoluteString, "http://sentry:9000/api/0/organizations/sentry")
        XCTAssertThrowsError(try Sentry.server.makeConnection(name: "Sentry", values: ["address": "http://sentry.example.com", "org": "sentry"]),
                             "a token sent in the clear across the internet")
        for account in [cloud, local] {
            XCTAssertEqual(account.adapter, "sentry")
            XCTAssertEqual(account.tokenHeader, "Authorization")
        }
        XCTAssertNotNil(PionAdapters.all["sentry"])
    }

    func testIssuesAreSearchedForTheOrganisationWithTheirCounts() async throws {
        let service = FakeService()
        service.answers["/api/0/organizations/sentry/issues"] = (200, #"""
        [{"id":"5203481129","shortId":"WEB-7Q","title":"ValueError: bad token","culprit":"auth.verify","level":"error",
          "status":"unresolved","count":"184","userCount":12,"firstSeen":"2026-11-17T08:00:00Z","lastSeen":"2026-11-18T01:59:00Z",
          "permalink":"http://sentry:9000/organizations/sentry/issues/5203481129/","project":{"slug":"web"}}]
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
        XCTAssertTrue(service.requests.first?.url?.absoluteString.hasPrefix("http://sentry:9000/api/0/organizations/sentry/issues/?") == true,
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
