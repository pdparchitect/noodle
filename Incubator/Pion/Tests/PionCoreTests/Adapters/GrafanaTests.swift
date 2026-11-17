import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class GrafanaTests: XCTestCase {
    private let cloud = try! Grafana.cloud.makeConnection(name: "Grafana Cloud", values: ["host": "acme.grafana.net"])
    private let local = try! Grafana.server.makeConnection(name: "Grafana", values: ["address": "http://localhost:3000"])

    func testGrafanaCloudAndAGrafanaOnThisMacShareOneAdapterWithABearerToken() throws {
        XCTAssertEqual(cloud.endpoint.absoluteString, "https://acme.grafana.net/api")
        XCTAssertEqual(local.endpoint.absoluteString, "http://localhost:3000/api")
        XCTAssertEqual(try Grafana.server.makeConnection(name: "Grafana", values: ["address": "https://grafana.example.com/grafana/"]).endpoint.absoluteString,
                       "https://grafana.example.com/grafana/api")
        XCTAssertThrowsError(try Grafana.server.makeConnection(name: "Grafana", values: ["address": "http://grafana.example.com"]),
                             "a token sent in the clear across the internet")
        for account in [cloud, local] {
            XCTAssertEqual(account.adapter, "grafana")
            XCTAssertEqual(account.tokenHeader, "Authorization")
            XCTAssertNil(account.tokenScheme)
        }
        XCTAssertNotNil(PionAdapters.all["grafana"])
    }

    func testADashboardShowsEachPanelsDataSourceAndQueriesIncludingThoseInCollapsedRows() async throws {
        let service = FakeService()
        service.answers["/api/dashboards/uid/web-01"] = (200, #"""
        {"dashboard":{"title":"Web","panels":[
          {"title":"Errors","type":"timeseries","datasource":{"type":"prometheus","uid":"prom1"},
           "targets":[{"refId":"A","expr":"sum(rate(http_requests_total{code=~\"5..\"}[5m]))"}]},
          {"title":"Logs","type":"row","panels":[{"title":"Auth failures","type":"logs","datasource":{"type":"loki","uid":"loki1"},
           "targets":[{"refId":"A","expr":"{app=\"auth\"} |= \"failed\""}]}]}]}}
        """#)
        let result = try await callTool(Grafana.adapter, "dashboard", #"{"uid":"web-01"}"#, on: service, in: local)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Errors [prometheus prom1]"), result.text)
        XCTAssertTrue(result.text.contains(#"A: {app="auth"} |= "failed""#), result.text)
        XCTAssertFalse(result.text.contains("- Logs"), "a row counted as a panel")
        XCTAssertEqual(service.requests.first?.url?.absoluteString, "http://localhost:3000/api/dashboards/uid/web-01")
        let refused = try await callTool(Grafana.adapter, "dashboard", #"{"uid":"../admin"}"#, on: service, in: local)
        XCTAssertTrue(refused.isError)
    }

    func testAQueryRunsOverItsDataSourceAndReturnsEachSeriesRowsWithTheirLabels() async throws {
        let service = FakeService()
        service.answers["/api/ds/query"] = (200, #"""
        {"results":{"A":{"frames":[
          {"schema":{"fields":[{"name":"Time","type":"time"},{"name":"Value","type":"number","labels":{"code":"500","job":"web"}}]},
           "data":{"values":[[1763370000000,1763370060000],[2.5,3]]}},
          {"schema":{"fields":[{"name":"Time","type":"time"},{"name":"Value","type":"number","labels":{"code":"503","job":"web"}}]},
           "data":{"values":[[1763370000000],[0.5]]}}]}}}
        """#)
        let result = try await callTool(Grafana.adapter, "query",
            #"{"datasource":"prom1","query":"{\"expr\":\"sum by (code, job) (rate(http_requests_total[5m]))\"}","from":"now-6h"}"#,
            on: service, in: cloud)
        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(result.structured?["columns"] as? [String], ["series", "Time", "Value"])
        XCTAssertEqual(result.structured?["total"] as? Int, 3)
        XCTAssertTrue(result.text.contains("code=503, job=web | 2025-11-17T09:00:00Z | 0.5"), result.text)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(service.requests.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(sent["from"] as? String, "now-6h")
        XCTAssertEqual(sent["to"] as? String, "now")
        let query = try XCTUnwrap((sent["queries"] as? [[String: Any]])?.first)
        XCTAssertEqual(query["expr"] as? String, "sum by (code, job) (rate(http_requests_total[5m]))")
        XCTAssertEqual((query["datasource"] as? [String: String])?["uid"], "prom1")
        XCTAssertEqual(query["refId"] as? String, "A")
        XCTAssertEqual(service.requests.first?.httpMethod, "POST")
    }

    func testAQueryTheDataSourceRefusesSaysWhy() async throws {
        let service = FakeService()
        service.answers["/api/ds/query"] = (200, #"{"results":{"A":{"error":"parse error at char 4"}}}"#)
        let result = try await callTool(Grafana.adapter, "query", #"{"datasource":"prom1","query":"{\"expr\":\"sum(\"}"}"#, on: service, in: cloud)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("parse error at char 4"), result.text)
    }

    func testSQLThatWouldChangeTheDatabaseIsRefusedBeforeItIsSent() async throws {
        let service = FakeService()
        service.answers["/api/ds/query"] = (200, #"{"results":{"A":{"frames":[]}}}"#)
        for sql in ["DELETE FROM users", "select 1; drop table users", "UPDATE t SET a=1", "INSERT INTO t VALUES (1)"] {
            let body = try String(decoding: JSONSerialization.data(withJSONObject: ["datasource": "pg1", "query": #"{"rawSql":"\#(sql)"}"#]), as: UTF8.self)
            let result = try await callTool(Grafana.adapter, "query", body, on: service, in: local)
            XCTAssertTrue(result.isError, sql)
        }
        XCTAssertTrue(service.requests.isEmpty)
        for sql in ["SELECT count(*) FROM logins WHERE ok = false;", "with x as (select 1) select * from x"] {
            let body = try String(decoding: JSONSerialization.data(withJSONObject: ["datasource": "pg1", "query": #"{"rawSql":"\#(sql)"}"#]), as: UTF8.self)
            let result = try await callTool(Grafana.adapter, "query", body, on: service, in: local)
            XCTAssertFalse(result.isError, "\(sql): \(result.text)")
        }
        let notJSON = try await callTool(Grafana.adapter, "query", #"{"datasource":"pg1","query":"up"}"#, on: service, in: local)
        XCTAssertTrue(notJSON.isError)
    }

    func testFiringAlertsAndAnnotations() async throws {
        let service = FakeService()
        service.answers["/api/alertmanager/grafana/api/v2/alerts"] = (200, #"""
        [{"labels":{"alertname":"HighErrorRate","severity":"critical","job":"web"},"annotations":{"summary":"5xx above 5%"},"startsAt":"2026-11-17T09:02:00Z"}]
        """#)
        service.answers["/api/annotations"] = (200, #"[{"time":1763370000000,"text":"Deployed web 4.2.0","tags":["deploy","web"],"dashboardUID":"web-01"}]"#)
        let alerts = try await callTool(Grafana.adapter, "alerts", #"{"filter":"severity=\"critical\""}"#, on: service, in: local)
        XCTAssertTrue(alerts.text.contains("HighErrorRate since 2026-11-17T09:02:00Z: 5xx above 5% [job=web, severity=critical]"), alerts.text)
        XCTAssertEqual(queryItems(service.requests.first)["active"], "true")
        XCTAssertEqual(queryItems(service.requests.first)["filter"], #"severity="critical""#)

        let annotations = try await callTool(Grafana.adapter, "annotations", #"{"from":"now-2d","tags":["deploy"]}"#, on: service, in: local)
        XCTAssertTrue(annotations.text.contains("2025-11-17T09:00:00Z: Deployed web 4.2.0 [deploy, web]"), annotations.text)
        let sent = queryItems(service.requests.last)
        XCTAssertEqual(sent["tags"], "deploy")
        let from = try XCTUnwrap(Double(try XCTUnwrap(sent["from"])))
        XCTAssertEqual(from / 1000, Date().timeIntervalSince1970 - 2 * 86_400, accuracy: 60, "now-2d went as epoch milliseconds")
    }
}
