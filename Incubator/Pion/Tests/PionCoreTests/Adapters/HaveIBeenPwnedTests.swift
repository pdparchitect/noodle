import Foundation
import NoodleCore
@testable import PionCore
import XCTest

final class HaveIBeenPwnedTests: XCTestCase {
    private let connection = try! HaveIBeenPwned.preset.makeConnection(name: "Have I Been Pwned")

    func testAnAddressesBreachesAndPastes() async throws {
        XCTAssertEqual(connection.endpoint.absoluteString, "https://haveibeenpwned.com/api/v3")
        XCTAssertEqual(connection.tokenHeader, "hibp-api-key")
        let service = FakeService()
        service.answers["/api/v3/breachedaccount/m.okafor@kestrel.example"] = (200, #"[{"Name":"Example","Title":"Example Forum","Domain":"forum.example","BreachDate":"2024-03-01","DataClasses":["Email addresses","Passwords"],"IsVerified":true}]"#)
        let breached = try await callTool(HaveIBeenPwned.adapter, "breaches", #"{"email":"m.okafor@kestrel.example"}"#, on: service, in: connection)
        XCTAssertFalse(breached.isError, breached.text)
        XCTAssertTrue(breached.text.contains("Example Forum"), breached.text)
        XCTAssertTrue(breached.text.contains("Passwords"), breached.text)
        XCTAssertEqual(queryItems(service.requests.first)["truncateResponse"], "false")
        let clean = try await callTool(HaveIBeenPwned.adapter, "breaches", #"{"email":"new@kestrel.example"}"#, on: service, in: connection)
        XCTAssertFalse(clean.isError, "an address in no breach is a finding, not a failure")
        XCTAssertTrue(clean.text.contains("not in any known breach"), clean.text)
        let refused = try await callTool(HaveIBeenPwned.adapter, "breaches", #"{"email":"not an address"}"#, on: service, in: connection)
        XCTAssertTrue(refused.isError)
        XCTAssertNotNil(PionAdapters.all["haveibeenpwned"])
    }
}
