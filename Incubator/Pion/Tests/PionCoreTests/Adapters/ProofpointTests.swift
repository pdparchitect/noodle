import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class ProofpointTests: XCTestCase {
    private let tap = try! Proofpoint.preset.makeConnection(name: "Proofpoint TAP")

    func testTheLastHoursMessagesAndClicks() async throws {
        XCTAssertEqual(tap.endpoint.absoluteString, "https://tap-api-v2.proofpoint.com/v2")
        XCTAssertEqual(tap.tokenScheme, "Basic")
        let service = FakeService()
        service.answers["/v2/siem/all"] = (200, #"{"messagesDelivered":[{"messageTime":"2026-11-14T08:51:00Z","sender":"payroll@kestrel-logistlcs.example","recipient":["m.okafor@kestrel.example"],"subject":"Q4 payroll correction","senderIP":"203.0.113.77","threatsInfoMap":[{"threat":"https://payroll-kestrel.example/login","classification":"phish","threatStatus":"active"}]}],"messagesBlocked":[],"clicksPermitted":[{"clickTime":"2026-11-14T09:02:00Z","recipient":"m.okafor@kestrel.example","url":"https://payroll-kestrel.example/login","classification":"phish","clickIP":"198.51.100.20"}],"clicksBlocked":[]}"#)
        let events = try await callTool(Proofpoint.adapter, "siem-events", #"{"minutes":60}"#, on: service, in: tap)
        XCTAssertFalse(events.isError, events.text)
        XCTAssertTrue(events.text.contains("Q4 payroll correction"), events.text)
        XCTAssertTrue(events.text.contains("clicked"), events.text)
        XCTAssertTrue(events.text.contains("m.okafor@kestrel.example"), events.text)
        XCTAssertEqual(queryItems(service.requests.first), ["format": "json", "sinceSeconds": "3600"])
        let tooLong = try await callTool(Proofpoint.adapter, "siem-events", #"{"minutes":600}"#, on: service, in: tap)
        XCTAssertTrue(tooLong.isError)
        XCTAssertNotNil(PionAdapters.all["proofpoint"])
    }

    func testItsTriggerFindsThreatsThatGotThroughInTheLastHourAtMost() async throws {
        // Delivered threats and permitted clicks reached people; blocked ones did not.
        let service = FakeService()
        service.answers["/v2/siem/all"] = (200, #"{"messagesDelivered":[{"GUID":"m1","messageTime":"2026-11-19T09:11:00.000Z"}],"messagesBlocked":[{"GUID":"b1","messageTime":"2026-11-19T09:12:00.000Z"}],"clicksPermitted":[{"id":"c1","clickTime":"2026-11-19T09:14:00.000Z"}],"clicksBlocked":[{"id":"x1","clickTime":"2026-11-19T09:13:00.000Z"}]}"#)
        let threats = try await Proofpoint.adapter.alerts(since: Date().addingTimeInterval(-1_800), connection: tap, access: service)
        XCTAssertEqual(threats.map(\.id), ["c1", "m1"])
        let seconds = try XCTUnwrap(queryItems(service.requests.last)["sinceSeconds"].flatMap(Int.init))
        XCTAssertTrue((1_800...1_802).contains(seconds), "\(seconds)")
        _ = try await Proofpoint.adapter.alerts(since: Date().addingTimeInterval(-10_800), connection: tap, access: service)
        XCTAssertEqual(queryItems(service.requests.last)["sinceSeconds"], "3600", "Proofpoint gives an hour at most")
        XCTAssertEqual(Proofpoint.adapter.watchedTool, "siem-events")
    }
}
