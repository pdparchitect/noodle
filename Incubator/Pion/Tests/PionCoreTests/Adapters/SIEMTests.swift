import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class SIEMTests: XCTestCase {
    private let splunk = try! Splunk.preset.makeConnection(name: "Splunk", values: ["host": "acme.splunkcloud.com"])
    private let elastic = try! Elastic.preset.makeConnection(name: "Elastic", values: ["host": "acme.es.eu-west-1.aws.elastic.cloud"])
    private let sentinel = try! Sentinel.preset.makeConnection(name: "Sentinel",
        values: ["tenant": "contoso.onmicrosoft.com", "workspace": "8a7f3c2e-0000-4000-8000-000000000002"])

    private func call(_ adapter: OperationAdapter, _ tool: String, _ arguments: String, on service: FakeService,
                      in connection: MCPConnectionRecord) async throws -> (text: String, isError: Bool, structured: [String: Any]?) {
        let data = try await adapter.run(tool, arguments: Data(arguments.utf8), connection: connection, access: service)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (((result["content"] as? [[String: Any]])?.first?["text"]) as? String ?? "", result["isError"] as? Bool ?? false,
                result["structuredContent"] as? [String: Any])
    }

    private func form(_ request: URLRequest?) -> [String: String] {
        let body = String(data: request?.httpBody ?? Data(), encoding: .utf8) ?? ""
        let items = URLComponents(string: "https://x/?" + body)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testEachSIEMIsReachedWhereItsAccountSays() {
        XCTAssertEqual(splunk.endpoint.absoluteString, "https://acme.splunkcloud.com:8089/services")
        XCTAssertEqual(splunk.tokenHeader, "Authorization")
        XCTAssertNil(splunk.tokenScheme)
        XCTAssertEqual(elastic.endpoint.absoluteString, "https://acme.es.eu-west-1.aws.elastic.cloud")
        XCTAssertEqual(elastic.tokenScheme, "ApiKey")
        XCTAssertEqual(sentinel.endpoint.absoluteString, "https://api.loganalytics.azure.com/v1/workspaces/8a7f3c2e-0000-4000-8000-000000000002")
        XCTAssertEqual(sentinel.clientCredentials?.tokenEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token")
        XCTAssertEqual(sentinel.clientCredentials?.scope, "https://api.loganalytics.io/.default")
        for name in ["splunk", "elastic", "sentinel"] { XCTAssertNotNil(PionAdapters.all[name], name) }
    }

    func testASplunkSearchRunsOnceAndReturnsItsRows() async throws {
        let service = FakeService()
        service.answers["/services/search/jobs"] = (200, #"{"fields":[{"name":"_time"},{"name":"src_ip"},{"name":"user"}],"results":[{"_time":"2026-11-14T09:06:00.000+00:00","src_ip":"203.0.113.77","user":["m.okafor","mokafor"]}]}"#)
        let found = try await call(Splunk.adapter, "search", #"{"query":"index=auth action=failure | stats count by src_ip","earliest":"-7d"}"#, on: service, in: splunk)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("203.0.113.77"), found.text)
        XCTAssertTrue(found.text.contains("m.okafor, mokafor"), found.text)
        XCTAssertEqual(found.structured?["columns"] as? [String], ["_time", "src_ip", "user"])
        let sent = form(service.requests.first)
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
            let result = try await call(Splunk.adapter, "search", #"{"query":"\#(query)"}"#, on: service, in: splunk)
            XCTAssertTrue(result.isError, query)
        }
        XCTAssertTrue(service.requests.isEmpty)
    }

    func testElasticRunsESQL() async throws {
        let service = FakeService()
        service.answers["/_query"] = (200, #"{"columns":[{"name":"@timestamp","type":"date"},{"name":"source.ip","type":"ip"},{"name":"event.count","type":"long"}],"values":[["2026-11-14T09:06:00.000Z","203.0.113.77",12]]}"#)
        let found = try await call(Elastic.adapter, "esql", #"{"query":"FROM logs-* | WHERE source.ip == \"203.0.113.77\" | LIMIT 10"}"#, on: service, in: elastic)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("203.0.113.77 | 12"), found.text)
        let body = try JSONSerialization.jsonObject(with: service.requests.first?.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body?["query"], #"FROM logs-* | WHERE source.ip == "203.0.113.77" | LIMIT 10"#)
    }

    func testSentinelRunsKQLOverItsWorkspace() async throws {
        let service = FakeService()
        service.answers["/v1/workspaces/8a7f3c2e-0000-4000-8000-000000000002/query"] = (200, #"{"tables":[{"name":"PrimaryResult","columns":[{"name":"TimeGenerated","type":"datetime"},{"name":"IPAddress","type":"string"}],"rows":[["2026-11-14T09:06:00Z","203.0.113.77"]]}]}"#)
        let found = try await call(Sentinel.adapter, "query", #"{"query":"SigninLogs | where ResultType != 0 | take 10"}"#, on: service, in: sentinel)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("203.0.113.77"), found.text)
        let body = try JSONSerialization.jsonObject(with: service.requests.first?.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body, ["query": "SigninLogs | where ResultType != 0 | take 10", "timespan": "P7D"])
    }
}
