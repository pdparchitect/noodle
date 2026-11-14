import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class ElasticTests: XCTestCase {
    private let elastic = try! Elastic.preset.makeConnection(name: "Elastic", values: ["host": "acme.es.eu-west-1.aws.elastic.cloud"])

    func testADeploymentIsReachedWithAnApiKey() {
        XCTAssertEqual(elastic.endpoint.absoluteString, "https://acme.es.eu-west-1.aws.elastic.cloud")
        XCTAssertEqual(elastic.tokenScheme, "ApiKey")
        XCTAssertNotNil(PionAdapters.all["elastic"])
    }

    func testElasticRunsESQL() async throws {
        let service = FakeService()
        service.answers["/_query"] = (200, #"{"columns":[{"name":"@timestamp","type":"date"},{"name":"source.ip","type":"ip"},{"name":"event.count","type":"long"}],"values":[["2026-11-14T09:06:00.000Z","203.0.113.77",12]]}"#)
        let found = try await callTool(Elastic.adapter, "esql", #"{"query":"FROM logs-* | WHERE source.ip == \"203.0.113.77\" | LIMIT 10"}"#, on: service, in: elastic)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("203.0.113.77 | 12"), found.text)
        let body = try JSONSerialization.jsonObject(with: service.requests.first?.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body?["query"], #"FROM logs-* | WHERE source.ip == "203.0.113.77" | LIMIT 10"#)
    }
}
