import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class SplunkTests: XCTestCase {
    private let splunk = try! Splunk.preset.makeConnection(name: "Splunk", values: ["host": "acme.splunkcloud.com"])

    func testADeploymentIsReachedOnItsManagementPortWithABearerToken() {
        XCTAssertEqual(splunk.endpoint.absoluteString, "https://acme.splunkcloud.com:8089/services")
        XCTAssertEqual(splunk.tokenHeader, "Authorization")
        XCTAssertNil(splunk.tokenScheme)
        XCTAssertNotNil(PionAdapters.all["splunk"])
    }

    func testASplunkSearchRunsOnceAndReturnsItsRows() async throws {
        let service = FakeService()
        service.answers["/services/search/jobs"] = (200, #"{"fields":[{"name":"_time"},{"name":"src_ip"},{"name":"user"}],"results":[{"_time":"2026-11-14T09:06:00.000+00:00","src_ip":"203.0.113.77","user":["m.okafor","mokafor"]}]}"#)
        let found = try await callTool(Splunk.adapter, "search", #"{"query":"index=auth action=failure | stats count by src_ip","earliest":"-7d"}"#, on: service, in: splunk)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("203.0.113.77"), found.text)
        XCTAssertTrue(found.text.contains("m.okafor, mokafor"), found.text)
        XCTAssertEqual(found.structured?["columns"] as? [String], ["_time", "src_ip", "user"])
        let sent = formItems(service.requests.first)
        XCTAssertEqual(sent["search"], "search index=auth action=failure | stats count by src_ip")
        XCTAssertEqual(sent["exec_mode"], "oneshot")
        XCTAssertEqual(sent["output_mode"], "json")
        XCTAssertEqual(sent["earliest_time"], "-7d")
        XCTAssertEqual(sent["latest_time"], "now")
        XCTAssertEqual(service.requests.first?.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    }

    func testSearchesThatWouldChangeDataAreRefused() async throws {
        let service = FakeService()
        for query in ["index=main | delete", "| outputlookup bad.csv", "index=x | sendemail to=a@b.c", "index=x |collect index=y", ""] {
            let result = try await callTool(Splunk.adapter, "search", #"{"query":"\#(query)"}"#, on: service, in: splunk)
            XCTAssertTrue(result.isError, query)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testCheckAccessSaysWhoseTokenItIsAndWhichIndexesItMaySearch() async throws {
        let service = FakeService()
        service.answers["/services/authentication/current-context"] = (200, #"{"entry":[{"name":"context","content":{"username":"pion","roles":["pion_search"],"capabilities":["search","rest_properties_get"]}}]}"#)
        service.answers["/services/search/jobs"] = (200, #"{"results":[{"index":"main"},{"index":"auth"}]}"#)
        let access = try await callTool(Splunk.adapter, "check-access", "{}", on: service, in: splunk)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("✓ Token: user pion, with the role pion_search"), access.text)
        XCTAssertTrue(access.text.contains("✓ Searches: the role may search 2 indexes: auth, main"), access.text)
        XCTAssertFalse(access.text.contains("✗"), access.text)
        XCTAssertEqual(service.requests.first?.httpMethod, "GET")
        XCTAssertEqual(queryItems(service.requests.first)["output_mode"], "json")
        let search = formItems(service.requests.last)
        XCTAssertEqual(search["search"], "| eventcount summarize=false index=* | dedup index | fields index")
        XCTAssertEqual(search["exec_mode"], "oneshot")
    }

    func testCheckAccessSaysWhatToChangeForARefusedTokenOrARoleThatMayNotSearch() async throws {
        let service = FakeService()
        service.answers["/services/authentication/current-context"] = (401, #"{"messages":[{"type":"WARN","text":"call not properly authenticated"}]}"#)
        let wrong = try await callTool(Splunk.adapter, "check-access", "{}", on: service, in: splunk)
        XCTAssertFalse(wrong.isError, wrong.text)
        XCTAssertTrue(wrong.text.contains("✗ Token: Splunk did not accept the token"), wrong.text)
        XCTAssertTrue(wrong.text.contains("Settings › Tools"), wrong.text)
        XCTAssertEqual(service.requests.count, 1)

        service.answers["/services/authentication/current-context"] = (200, #"{"entry":[{"content":{"username":"pion","roles":["user"],"capabilities":["edit_user","list_inputs"]}}]}"#)
        let role = try await callTool(Splunk.adapter, "check-access", "{}", on: service, in: splunk)
        XCTAssertTrue(role.text.contains("✗ Searches: the user's roles lack the search capability"), role.text)
        XCTAssertTrue(role.text.contains("capabilities that change Splunk, which searching never needs: edit_user"), role.text)
        XCTAssertEqual(service.requests.count, 2, "a role that may not search is not tried")
    }
}
