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

    func testCheckAccessSaysWhoseKeyItIsAndWhichIndicesItMayRead() async throws {
        let service = FakeService()
        service.answers["/_security/_authenticate"] = (200, #"{"username":"elastic-admin","authentication_type":"api_key","api_key":{"id":"VuaCfGcBCdbkQm-e5aOx","name":"pion"},"roles":[]}"#)
        service.answers["/_resolve/index/*"] = (200, #"{"indices":[{"name":"metrics-1"}],"aliases":[],"data_streams":[{"name":"logs-auth","backing_indices":[".ds-logs-auth-1"]}]}"#)
        service.answers["/_security/user/_has_privileges"] = (200, #"{"username":"elastic-admin","has_all_requested":false,"index":{"logs-auth":{"read":true},"metrics-1":{"read":false}}}"#)
        service.answers["/_query"] = (200, #"{"columns":[{"name":"ok","type":"integer"}],"values":[[1]]}"#)
        let access = try await callTool(Elastic.adapter, "check-access", "{}", on: service, in: elastic)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains(#"✓ API key: the API key "pion" of elastic-admin"#), access.text)
        XCTAssertTrue(access.text.contains("✓ Indices it can see: 2 indices and data streams"), access.text)
        XCTAssertTrue(access.text.contains("✓ Reading them: it may read logs-auth; not metrics-1"), access.text)
        XCTAssertTrue(access.text.contains("✓ ES|QL: runs"), access.text)
        let asked = try JSONSerialization.jsonObject(with: try XCTUnwrap(service.requests.first { $0.url?.path == "/_security/user/_has_privileges" }?.httpBody)) as? [String: Any]
        XCTAssertEqual(((asked?["index"] as? [[String: Any]])?.first?["privileges"]) as? [String], ["read"])
        let query = try JSONSerialization.jsonObject(with: try XCTUnwrap(service.requests.last?.httpBody)) as? [String: Any]
        XCTAssertEqual(query?["query"] as? String, "ROW ok = 1")
    }

    func testCheckAccessSaysWhatToChangeForARefusedKeyOrMissingIndexPrivileges() async throws {
        let service = FakeService()
        service.answers["/_security/_authenticate"] = (401, #"{"error":{"type":"security_exception","reason":"unable to authenticate with provided credentials"},"status":401}"#)
        let wrong = try await callTool(Elastic.adapter, "check-access", "{}", on: service, in: elastic)
        XCTAssertTrue(wrong.text.contains("✗ API key: Elasticsearch did not accept the API key"), wrong.text)
        XCTAssertEqual(service.requests.count, 1)

        service.answers["/_security/_authenticate"] = (200, #"{"username":"pion","authentication_type":"api_key","api_key":{"id":"k1"}}"#)
        service.answers["/_resolve/index/*"] = (403, #"{"error":{"type":"security_exception","reason":"action [indices:admin/resolve/index] is unauthorized"},"status":403}"#)
        service.answers["/_query"] = (200, #"{"columns":[],"values":[]}"#)
        let index = try await callTool(Elastic.adapter, "check-access", "{}", on: service, in: elastic)
        XCTAssertTrue(index.text.contains("✗ Indices it can see: the API key may not see index metadata: add view_index_metadata"), index.text)
        XCTAssertFalse(index.text.contains("Reading them"), index.text)
    }
}
