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
        service.answers["/api/datasources/uid/prom1"] = (200, #"{"uid":"prom1","type":"prometheus","jsonData":{}}"#)
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
        let posted = service.requests.first { $0.url?.path == "/api/ds/query" }
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(posted?.httpBody)) as? [String: Any])
        XCTAssertEqual(sent["from"] as? String, "now-6h")
        XCTAssertEqual(sent["to"] as? String, "now")
        let query = try XCTUnwrap((sent["queries"] as? [[String: Any]])?.first)
        XCTAssertEqual(query["expr"] as? String, "sum by (code, job) (rate(http_requests_total[5m]))")
        XCTAssertEqual((query["datasource"] as? [String: String])?["uid"], "prom1")
        XCTAssertEqual(query["refId"] as? String, "A")
        XCTAssertEqual(posted?.httpMethod, "POST")
    }

    func testAQueryTheDataSourceRefusesSaysWhy() async throws {
        let service = FakeService()
        service.answers["/api/datasources/uid/prom1"] = (200, #"{"uid":"prom1","type":"prometheus"}"#)
        service.answers["/api/ds/query"] = (200, #"{"results":{"A":{"error":"parse error at char 4"}}}"#)
        let result = try await callTool(Grafana.adapter, "query", #"{"datasource":"prom1","query":"{\"expr\":\"sum(\"}"}"#, on: service, in: cloud)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("parse error at char 4"), result.text)
    }

    /// Runs `query` over the data source `uid`, saying whether it was refused and whether it reached the data source.
    private func ask(_ service: FakeService, _ uid: String, _ model: [String: Any]) async throws -> (result: AdapterResult, sent: Bool) {
        let before = service.requests.filter { $0.url?.path == "/api/ds/query" }.count
        let query = try String(decoding: JSONSerialization.data(withJSONObject: model), as: UTF8.self)
        let body = try String(decoding: JSONSerialization.data(withJSONObject: ["datasource": uid, "query": query]), as: UTF8.self)
        let result = try await callTool(Grafana.adapter, "query", body, on: service, in: local)
        return (result, service.requests.filter { $0.url?.path == "/api/ds/query" }.count > before)
    }

    private func sources() -> FakeService {
        let service = FakeService()
        service.answers["/api/ds/query"] = (200, #"{"results":{"A":{"frames":[]}}}"#)
        service.answers["/api/datasources/uid/pg1"] = (200, #"{"uid":"pg1","type":"grafana-postgresql-datasource","jsonData":{}}"#)
        service.answers["/api/datasources/uid/my1"] = (200, #"{"uid":"my1","type":"mysql","jsonData":{}}"#)
        service.answers["/api/datasources/uid/ms1"] = (200, #"{"uid":"ms1","type":"mssql","jsonData":{}}"#)
        service.answers["/api/datasources/uid/influxql1"] = (200, #"{"uid":"influxql1","type":"influxdb","jsonData":{"httpMode":"POST"}}"#)
        service.answers["/api/datasources/uid/flux1"] = (200, #"{"uid":"flux1","type":"influxdb","jsonData":{"version":"Flux"}}"#)
        service.answers["/api/datasources/uid/adx1"] = (200, #"{"uid":"adx1","type":"grafana-azure-data-explorer-datasource","jsonData":{}}"#)
        return service
    }

    func testSQLThatWouldChangeTheDatabaseIsRefusedBeforeItIsSent() async throws {
        let service = sources()
        for sql in ["DELETE FROM users", "select 1; drop table users", "UPDATE t SET a=1", "INSERT INTO t VALUES (1)",
                    // A WITH that deletes, and a SELECT that writes a table, both start by reading.
                    "WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone",
                    "SELECT * INTO stolen FROM users",
                    // Comments, and quoting the check could read otherwise than the database.
                    "SELECT 1 /* x */", "SELECT 1 -- x",
                    "SELECT $$ ' $$, 1 FROM (WITH d AS (DELETE FROM t RETURNING *) SELECT 1) x WHERE 'a' = 'a'",
                    "SELECT 'a\\' , (WITH d AS (DELETE FROM t RETURNING *) SELECT 1) WHERE 'b' = 'b'",
                    "SELECT a[']'], 1 FROM (WITH d AS (DELETE FROM t RETURNING *) SELECT 1) x WHERE 'x' = 'x'",
                    // Functions that change something or run text as SQL, however a schema names them.
                    "SELECT pg_catalog.setval('s', 1)", "SELECT dblink_exec('db', 'drop table t')", "SELECT query_to_xml('delete from t returning 1', true, true, '')",
                    "SELECT 'unclosed"] {
            let (result, sent) = try await ask(service, "pg1", ["rawSql": sql])
            XCTAssertTrue(result.isError, sql)
            XCTAssertFalse(sent, sql)
        }
        for sql in ["SELECT count(*) FROM logins WHERE ok = false;", "with x as (select 1) select * from x",
                    "SELECT action FROM audit WHERE action = 'DELETE' AND note = 'it''s set into place'",
                    "SELECT replace(name, 'a', 'b') FROM users WHERE $__timeFilter(time)"] {
            let (result, sent) = try await ask(service, "pg1", ["rawSql": sql])
            XCTAssertFalse(result.isError, "\(sql): \(result.text)")
            XCTAssertTrue(sent, sql)
        }
        let worded = try await ask(service, "pg1", ["rawSql": "WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone"])
        XCTAssertTrue(worded.result.text.contains("DELETE outside quoted text"), worded.result.text)
        // MySQL's # comments and backticks; SQL Server's statements that need no semicolon, and its brackets.
        for (uid, sql) in [("my1", "SELECT 1 # x"), ("my1", "SELECT `a'b`, 1 INTO OUTFILE '/tmp/x'"), ("ms1", "SELECT 1 DROP TABLE users"),
                           ("ms1", "SELECT 1 EXEC('DROP TABLE users')"), ("ms1", "SELECT [a'b], 1 FROM t WAITFOR DELAY '0:0:1' INSERT INTO t VALUES (1)")] {
            let (result, sent) = try await ask(service, uid, ["rawSql": sql])
            XCTAssertTrue(result.isError && !sent, "\(uid): \(sql)")
        }
        let brackets = try await ask(service, "ms1", ["rawSql": "SELECT [time], [value] FROM metrics"])
        XCTAssertFalse(brackets.result.isError, brackets.result.text)
        let noSQL = try await ask(service, "pg1", ["format": "table"])
        XCTAssertTrue(noSQL.result.isError && !noSQL.sent)
        let notJSON = try await callTool(Grafana.adapter, "query", #"{"datasource":"pg1","query":"up"}"#, on: service, in: local)
        XCTAssertTrue(notJSON.isError)
    }

    func testInfluxQLAndFluxThatWouldWriteAreRefusedBeforeTheyAreSent() async throws {
        let service = sources()
        for query in [#"SELECT mean("value") INTO "db"."rp"."cpu_copy" FROM "cpu" GROUP BY *"#, "DROP MEASUREMENT cpu", "DELETE FROM cpu",
                      "CREATE USER x WITH PASSWORD 'y' WITH ALL PRIVILEGES", "KILL QUERY 1", "SELECT 1 -- x"] {
            let (result, sent) = try await ask(service, "influxql1", ["query": query])
            XCTAssertTrue(result.isError && !sent, query)
        }
        let read = try await ask(service, "influxql1", ["query": #"SELECT mean("value") FROM "cpu" WHERE host = 'drop into' GROUP BY time(1m)"#, "rawQuery": false])
        XCTAssertFalse(read.result.isError, read.result.text)
        let posted = try XCTUnwrap(service.requests.last { $0.url?.path == "/api/ds/query" })
        let sent = try XCTUnwrap(((JSONSerialization.jsonObject(with: try XCTUnwrap(posted.httpBody)) as? [String: Any])?["queries"] as? [[String: Any]])?.first)
        XCTAssertEqual(sent["rawQuery"] as? Bool, true, "a query Grafana would build from parts Pion has not read")

        for flux in [#"from(bucket: "a") |> range(start: -1h) |> to(bucket: "b")"#,
                     "import \"experimental\"\nfrom(bucket: \"a\") |> range(start: -1h) |> experimental.to(bucket: \"b\")",
                     "import \"sql\"\nfrom(bucket: \"a\") |> range(start: -1h) |> sql.to(driverName: \"postgres\", dataSourceName: \"x\", table: \"t\")",
                     "import \"influxdata/influxdb\"\nfrom(bucket: \"a\") |> range(start: -1h) |> influxdb.wideTo(bucket: \"b\")",
                     "import \"http\"\nhttp.post(url: \"https://example.com\", data: bytes(v: \"x\"))"] {
            let (result, sent) = try await ask(service, "flux1", ["query": flux])
            XCTAssertTrue(result.isError && !sent, flux)
        }
        let flux = try await ask(service, "flux1", ["query": "import \"strings\"\nfrom(bucket: \"a\") |> range(start: -1h) |> drop(columns: [\"x\"]) |> set(key: \"k\", value: \"v\")"])
        XCTAssertFalse(flux.result.isError, flux.result.text)
        let into = try await ask(service, "influxql1", ["query": "SELECT * INTO x FROM y"])
        XCTAssertTrue(into.result.text.contains("INTO outside quoted text"), into.result.text)
    }

    func testAQueryOverADataSourcePionCannotCheckIsRefused() async throws {
        let service = sources()
        let adx = try await ask(service, "adx1", ["query": ".drop table Logs"])
        XCTAssertTrue(adx.result.isError && !adx.sent, adx.result.text)
        XCTAssertTrue(adx.result.text.contains("grafana-azure-data-explorer-datasource"), adx.result.text)
        // Not known at all: refused, never sent.
        let unknown = try await ask(service, "mystery", ["expr": "up"])
        XCTAssertTrue(unknown.result.isError && !unknown.sent, unknown.result.text)
        XCTAssertTrue(unknown.result.text.contains("did not say what kind of data source"), unknown.result.text)
        // A service account that may not read the data source learns its kind from the settings Grafana gives its pages.
        service.answers["/api/datasources/uid/loki1"] = (403, #"{"message":"Permission denied"}"#)
        service.answers["/api/frontend/settings"] = (200, #"{"datasources":{"Loki":{"uid":"loki1","type":"loki","jsonData":{}}}}"#)
        let loki = try await ask(service, "loki1", ["expr": #"{app="auth"}"#])
        XCTAssertFalse(loki.result.isError, loki.result.text)
        XCTAssertTrue(loki.sent)
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

    func testCheckAccessTriesEachReadOnceAndSaysWhatToChangeForThoseRefused() async throws {
        let service = FakeService()
        service.answers["/api/org"] = (200, #"{"id":1,"name":"Main Org."}"#)
        service.answers["/api/search"] = (200, #"[{"uid":"web-01"}]"#)
        service.answers["/api/datasources"] = (403, #"{"message":"You'll need additional permissions to perform this action. Permissions needed: datasources:read"}"#)
        service.answers["/api/alertmanager/grafana/api/v2/alerts"] = (200, "[]")
        service.answers["/api/annotations"] = (200, "[]")
        let access = try await callTool(Grafana.adapter, "check-access", "{}", on: service, in: local)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("✓ Token: it belongs to the organisation Main Org. (ID 1)"), access.text)
        XCTAssertTrue(access.text.contains("✓ Dashboards"), access.text)
        XCTAssertTrue(access.text.contains("✗ Data sources: the service account's role may not list data sources"), access.text)
        XCTAssertTrue(access.text.contains("datasources:read"), access.text)
        XCTAssertTrue(access.text.contains("✓ Firing alerts"), access.text)
        XCTAssertTrue(access.text.contains("✓ Annotations"), access.text)
        XCTAssertEqual(service.requests.first?.url?.absoluteString, "http://localhost:3000/api/org/")
        XCTAssertTrue(service.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testCheckAccessStopsAtATokenGrafanaRefuses() async throws {
        let service = FakeService()
        service.answers["/api/org"] = (401, #"{"message":"invalid API key"}"#)
        let access = try await callTool(Grafana.adapter, "check-access", "{}", on: service, in: cloud)
        XCTAssertTrue(access.text.contains("✗ Token: Grafana did not accept the token"), access.text)
        XCTAssertTrue(access.text.contains("Settings › Tools"), access.text)
        XCTAssertEqual(service.requests.count, 1)
    }
}
