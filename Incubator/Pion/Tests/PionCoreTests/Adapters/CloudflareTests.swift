import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class CloudflareTests: XCTestCase {
    private let cloudflare = try! Cloudflare.preset.makeConnection(name: "Cloudflare", values: ["account": "023e105f4ecef8ad9ca31a8372d0c353"])

    func testAnAccountIsReachedWithAnAPIToken() {
        XCTAssertEqual(cloudflare.endpoint.absoluteString, "https://api.cloudflare.com/client/v4")
        XCTAssertEqual(cloudflare.tokenHeader, "Authorization")
        XCTAssertEqual(cloudflare.settings?["account"], "023e105f4ecef8ad9ca31a8372d0c353")
        XCTAssertNotNil(PionAdapters.all["cloudflare"])
    }

    func testAZonesDNSRecords() async throws {
        let service = FakeService()
        service.answers["/client/v4/zones"] = (200, #"{"success":true,"result":[{"id":"z1","name":"kestrel.example","status":"active"}]}"#)
        service.answers["/client/v4/zones/z1/dns_records"] = (200, #"{"success":true,"result":[{"type":"A","name":"mail.kestrel.example","content":"203.0.113.77","proxied":false,"ttl":300,"modified_on":"2026-11-13T16:02:00Z"}]}"#)
        let records = try await callTool(Cloudflare.adapter, "zone-dns", #"{"zone":"kestrel.example"}"#, on: service, in: cloudflare)
        XCTAssertFalse(records.isError, records.text)
        XCTAssertTrue(records.text.contains("A mail.kestrel.example → 203.0.113.77"), records.text)
        XCTAssertEqual(queryItems(service.requests.first)["name"], "kestrel.example")
    }

    func testTheAccountAuditLog() async throws {
        let service = FakeService()
        service.answers["/client/v4/accounts/023e105f4ecef8ad9ca31a8372d0c353/audit_logs"] = (200, #"{"success":true,"result":[{"id":"l1","when":"2026-11-14T08:00:00Z","action":{"type":"rec_add","result":true},"actor":{"email":"ops@kestrel.example","ip":"198.51.100.4","type":"user"},"resource":{"type":"DNS_record","id":"r1"}}]}"#)
        let log = try await callTool(Cloudflare.adapter, "audit-log", #"{"since":"2026-11-13T00:00:00Z","actor":"ops@kestrel.example"}"#, on: service, in: cloudflare)
        XCTAssertFalse(log.isError, log.text)
        XCTAssertTrue(log.text.contains("rec_add"), log.text)
        XCTAssertTrue(log.text.contains("198.51.100.4"), log.text)
        let sent = queryItems(service.requests.first)
        XCTAssertEqual(sent["since"], "2026-11-13T00:00:00Z")
        XCTAssertEqual(sent["actor.email"], "ops@kestrel.example")
        XCTAssertEqual(sent["direction"], "desc")
    }

    func testFirewallEventsComeFromTheGraphQLAPIForTheZone() async throws {
        let service = FakeService()
        service.answers["/client/v4/zones"] = (200, #"{"success":true,"result":[{"id":"z1","name":"kestrel.example"}]}"#)
        service.answers["/client/v4/graphql"] = (200, #"{"data":{"viewer":{"zones":[{"firewallEventsAdaptive":[{"datetime":"2026-11-14T09:00:00Z","action":"block","clientIP":"203.0.113.77","clientCountryName":"NG","clientRequestPath":"/login","source":"waf","userAgent":"curl/8"}]}]}},"errors":null}"#)
        let events = try await callTool(Cloudflare.adapter, "firewall-events", #"{"zone":"kestrel.example","ip":"203.0.113.77","since":"2026-11-14T00:00:00Z"}"#, on: service, in: cloudflare)
        XCTAssertFalse(events.isError, events.text)
        XCTAssertTrue(events.text.contains("block"), events.text)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: service.requests.last?.httpBody ?? Data()) as? [String: Any])
        let variables = try XCTUnwrap(body["variables"] as? [String: Any])
        XCTAssertEqual(variables["zoneTag"] as? String, "z1")
        let filter = try XCTUnwrap(variables["filter"] as? [String: String])
        XCTAssertEqual(filter["clientIP"], "203.0.113.77")
        XCTAssertEqual(filter["datetime_geq"], "2026-11-14T00:00:00Z")
        XCTAssertTrue((body["query"] as? String)?.contains("firewallEventsAdaptive") == true)
    }

    func testAGraphQLErrorReachesTheAgent() async throws {
        let service = FakeService()
        service.answers["/client/v4/zones"] = (200, #"{"success":true,"result":[{"id":"z1","name":"kestrel.example"}]}"#)
        service.answers["/client/v4/graphql"] = (200, #"{"data":null,"errors":[{"message":"zone does not have access to the path"}]}"#)
        let events = try await callTool(Cloudflare.adapter, "firewall-events", #"{"zone":"kestrel.example"}"#, on: service, in: cloudflare)
        XCTAssertTrue(events.isError)
        XCTAssertTrue(events.text.contains("does not have access"), events.text)
    }
}
