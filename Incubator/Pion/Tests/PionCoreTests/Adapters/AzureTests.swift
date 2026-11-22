import Foundation
import NoodleCore
import NoodleToolConnections
@testable import PionCore
import XCTest

final class AzureTests: XCTestCase {
    private let subscription = "8a7f3c2e-0000-4000-8000-000000000002"
    private var azure: ToolConnection {
        try! Azure.preset.makeConnection(name: "Azure", values: ["tenant": "contoso.onmicrosoft.com", "subscription": subscription])
    }
    private var root: String { "/subscriptions/" + subscription + "/providers/" }

    func testAnAccountIsOneSubscriptionWithTokensForAzure() {
        XCTAssertEqual(azure.endpoint.absoluteString, "https://management.azure.com")
        XCTAssertEqual(azure.clientCredentials?.tokenEndpoint.absoluteString, "https://login.microsoftonline.com/contoso.onmicrosoft.com/oauth2/v2.0/token")
        XCTAssertEqual(azure.clientCredentials?.scope, "https://management.azure.com/.default")
        XCTAssertNotNil(PionAdapters.all["azure"])
        XCTAssertEqual(Azure.adapter.watchedTool, "defender-alerts")
    }

    func testActivityLogFiltersTheRequestAndKeepsOnlyFailures() async throws {
        let service = FakeService()
        let path = root + "Microsoft.Insights/eventtypes/management/values"
        let since = ServiceInput.daysAgo(2), until = ServiceInput.daysAgo(1)
        service.answers[path] = (200, """
        {"value":[{"eventDataId":"ok","eventTimestamp":"\(until)","status":{"value":"Succeeded"}},
        {"eventDataId":"failed","eventTimestamp":"\(since)","caller":"admin@example.com","resourceId":"/vm/one",
        "operationName":{"value":"write","localizedValue":"Update VM"},"status":{"value":"Failed"}}]}
        """)
        let found = try await callTool(Azure.adapter, "activity-log", """
        {"caller":"admin@example.com","resourceGroup":"production","resource":"/vm/one","failuresOnly":true,"since":"\(since)","until":"\(until)","limit":1}
        """, on: service, in: azure)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("Update VM"), found.text)
        let events = try XCTUnwrap(found.structured?["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["eventDataId"] as? String, "failed")
        XCTAssertEqual(service.requests.first?.url?.path, path)
        let query = queryItems(service.requests.first)
        XCTAssertEqual(query["api-version"], "2015-04-01")
        XCTAssertEqual(query["$filter"], "eventTimestamp ge '\(since)' and eventTimestamp le '\(until)' and caller eq 'admin@example.com' and resourceGroupName eq 'production' and resourceUri eq '/vm/one'")
    }

    func testDefenderAlertsAreFilteredAndSortedWithTheirEvidence() async throws {
        let service = FakeService()
        service.answers[root + "Microsoft.Security/alerts"] = (200, alerts)
        let found = try await callTool(Azure.adapter, "defender-alerts", #"{"severity":"High","status":"Active","since":"2026-01-01T00:00:00Z","limit":1}"#, on: service, in: azure)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("Suspicious VM"), found.text)
        let kept = try XCTUnwrap(found.structured?["alerts"] as? [[String: Any]])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?["id"] as? String, "newest")
        let properties = try XCTUnwrap(kept.first?["properties"] as? [String: Any])
        XCTAssertEqual(properties["compromisedEntity"] as? String, "vm-one")
        XCTAssertEqual(properties["techniques"] as? [String], ["T1059"])
        XCTAssertEqual(properties["intent"] as? String, "Execution")
        XCTAssertEqual(properties["alertUri"] as? String, "https://portal.azure.com/alert")
        XCTAssertEqual((properties["resourceIdentifiers"] as? [[String: String]])?.first?["azureResourceId"], "/vm/one")
        XCTAssertEqual(queryItems(service.requests.first)["api-version"], "2022-01-01")
        XCTAssertEqual(service.requests.first?.url?.path, root + "Microsoft.Security/alerts")
    }

    func testResourceGraphReturnsATable() async throws {
        let service = FakeService()
        service.answers["/providers/Microsoft.ResourceGraph/resources"] = (200, #"{"data":{"columns":[{"name":"name","type":"string"},{"name":"count","type":"integer"}],"rows":[["vm-one",2]]}}"#)
        let found = try await callTool(Azure.adapter, "resource-graph", #"{"query":"Resources | summarize count() by name | take 10"}"#, on: service, in: azure)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("vm-one"), found.text)
        XCTAssertNotNil(found.structured)
        let request = try XCTUnwrap(service.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/providers/Microsoft.ResourceGraph/resources")
        XCTAssertEqual(queryItems(request)["api-version"], "2022-10-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["subscriptions"] as? [String], [subscription])
        XCTAssertEqual(body["query"] as? String, "Resources | summarize count() by name | take 10")
        XCTAssertEqual(body["options"] as? [String: String], ["resultFormat": "table"])
    }

    func testRoleAssignmentsResolveRoleNamesAndFilterPrincipals() async throws {
        let service = FakeService()
        let roles = root + "Microsoft.Authorization/roleAssignments"
        let definitions = root + "Microsoft.Authorization/roleDefinitions"
        service.answers[roles] = (200, #"{"value":[{"id":"assignment","properties":{"principalId":"8a7f3c2e-0000-4000-8000-000000000003","principalType":"ServicePrincipal","roleDefinitionId":"/roles/reader","scope":"/subscriptions/one"}}]}"#)
        service.answers[definitions] = (200, #"{"value":[{"id":"/roles/reader","properties":{"roleName":"Reader"}}]}"#)
        let found = try await callTool(Azure.adapter, "role-assignments", #"{"principalId":"8a7f3c2e-0000-4000-8000-000000000003"}"#, on: service, in: azure)
        XCTAssertFalse(found.isError, found.text)
        XCTAssertTrue(found.text.contains("Reader on /subscriptions/one"), found.text)
        XCTAssertEqual((found.structured?["assignments"] as? [[String: Any]])?.first?["roleName"] as? String, "Reader")
        XCTAssertEqual(service.requests.map { $0.url!.path }, [roles, definitions])
        XCTAssertEqual(queryItems(service.requests.first)["$filter"], "principalId eq '8a7f3c2e-0000-4000-8000-000000000003'")
        XCTAssertTrue(service.requests.allSatisfy { queryItems($0)["api-version"] == "2022-04-01" })
        let scoped = try await callTool(Azure.adapter, "role-assignments", #"{"atScope":true}"#, on: service, in: azure)
        XCTAssertFalse(scoped.isError, scoped.text)
        XCTAssertEqual(queryItems(service.requests[2])["$filter"], "atScope()")
    }

    func testItsTriggerFindsOnlyNewHighAlertsNewestFirst() async throws {
        let service = FakeService()
        service.answers[root + "Microsoft.Security/alerts"] = (200, alerts)
        let since = try XCTUnwrap(ServiceAlert.time("2026-11-19T09:00:00Z"))
        let found = try await Azure.adapter.alerts(since: since, connection: azure, access: service)
        XCTAssertEqual(found.map(\.id), ["newest", "new"])
        XCTAssertEqual(Azure.adapter.watchedTool, "defender-alerts")
        let many = (0..<(ServiceAlert.most + 2)).map { "{\"id\":\"\($0)\",\"properties\":{\"severity\":\"High\",\"timeGeneratedUtc\":\"2026-11-19T09:15:00Z\"}}" }.joined(separator: ",")
        service.answers[root + "Microsoft.Security/alerts"] = (200, "{\"value\":[\(many)]}")
        let capped = try await Azure.adapter.alerts(since: since, connection: azure, access: service)
        XCTAssertEqual(capped.count, ServiceAlert.most)
    }

    func testEmptyResultsAndServiceErrors() async throws {
        for (tool, path, arguments, empty) in [
            ("activity-log", root + "Microsoft.Insights/eventtypes/management/values", "{}", #"{"value":[]}"#),
            ("defender-alerts", root + "Microsoft.Security/alerts", "{}", #"{"value":[]}"#),
            ("resource-graph", "/providers/Microsoft.ResourceGraph/resources", #"{"query":"Resources | take 1"}"#, #"{"data":{"columns":[],"rows":[]}}"#),
            ("role-assignments", root + "Microsoft.Authorization/roleAssignments", "{}", #"{"value":[]}"#),
        ] {
            let service = FakeService()
            service.answers[path] = (200, empty)
            service.answers[root + "Microsoft.Authorization/roleDefinitions"] = (200, #"{"value":[]}"#)
            let found = try await callTool(Azure.adapter, tool, arguments, on: service, in: azure)
            XCTAssertFalse(found.isError, found.text)
            XCTAssertNotNil(found.structured)
            service.answers[path] = (403, #"{"error":{"message":"Reader role required"}}"#)
            let denied = try await callTool(Azure.adapter, tool, arguments, on: service, in: azure)
            XCTAssertTrue(denied.isError, denied.text)
            XCTAssertTrue(denied.text.contains("Reader role required"), denied.text)
        }
        let service = FakeService()
        service.answers[root + "Microsoft.Security/alerts"] = (200, #"{"value":[]}"#)
        let found = try await Azure.adapter.alerts(since: Date(), connection: azure, access: service)
        XCTAssertTrue(found.isEmpty)
    }

    func testInputsRejectInjectionAndInvalidRangesBeforeRequests() async throws {
        for (tool, arguments) in [
            ("activity-log", #"{"caller":"x' or true"}"#),
            ("activity-log", #"{"resourceGroup":"x' or true"}"#),
            ("activity-log", #"{"resource":"x' or true"}"#),
            ("activity-log", #"{"since":"2026-01-01T00:00:00Z' or true"}"#),
            ("activity-log", #"{"since":"2000-01-01T00:00:00Z"}"#),
            ("activity-log", #"{"until":"2000-01-01T00:00:00Z"}"#),
            ("activity-log", #"{"limit":0}"#),
            ("defender-alerts", #"{"severity":"High' or true"}"#),
            ("defender-alerts", #"{"status":"Active' or true"}"#),
            ("defender-alerts", #"{"since":"not a time"}"#),
            ("defender-alerts", #"{"limit":101}"#),
            ("resource-graph", #"{"query":" "}"#),
            ("role-assignments", #"{"principalId":"x' or true"}"#),
            ("role-assignments", #"{"principalId":"8a7f3c2e-0000-4000-8000-000000000003","atScope":true}"#),
        ] {
            let service = FakeService()
            let found = try await callTool(Azure.adapter, tool, arguments, on: service, in: azure)
            XCTAssertTrue(found.isError, "\(tool): \(found.text)")
            XCTAssertTrue(service.requests.isEmpty, tool)
        }
        let bad = try Azure.preset.makeConnection(name: "Bad", values: ["tenant": "contoso.onmicrosoft.com", "subscription": "not-a-guid"])
        for (tool, arguments) in [("activity-log", "{}"), ("defender-alerts", "{}"), ("resource-graph", #"{"query":"Resources | take 1"}"#), ("role-assignments", "{}")] {
            let service = FakeService()
            let found = try await callTool(Azure.adapter, tool, arguments, on: service, in: bad)
            XCTAssertTrue(found.isError, found.text)
            XCTAssertTrue(service.requests.isEmpty)
        }
    }

    private var alerts: String {
        #"{"value":[{"id":"old","properties":{"severity":"High","timeGeneratedUtc":"2026-11-19T08:59:59Z"}},{"id":"new","properties":{"severity":"High","status":"Active","timeGeneratedUtc":"2026-11-19T09:10:00Z"}},{"id":"low","properties":{"severity":"Low","timeGeneratedUtc":"2026-11-19T09:20:00Z"}},{"id":"newest","name":"alert-one","properties":{"alertDisplayName":"Suspicious VM","severity":"High","status":"Active","timeGeneratedUtc":"2026-11-19T09:15:00.1234567Z","compromisedEntity":"vm-one","resourceIdentifiers":[{"azureResourceId":"/vm/one","type":"AzureResource"}],"techniques":["T1059"],"intent":"Execution","alertUri":"https://portal.azure.com/alert"}},{"id":"undated","properties":{"severity":"High"}}]}"#
    }
}
