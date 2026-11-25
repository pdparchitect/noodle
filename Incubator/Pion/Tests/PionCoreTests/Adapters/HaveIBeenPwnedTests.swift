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

    func testCheckAccessReadsTheSubscription() async throws {
        let service = FakeService()
        service.answers["/api/v3/subscription/status"] = (200, #"{"SubscriptionName":"Pwned 1","Description":"","SubscribedUntil":"2027-03-01T00:00:00","Rpm":10,"DomainSearchMaxBreachedAccounts":25}"#)
        let access = try await callTool(HaveIBeenPwned.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertFalse(access.isError, access.text)
        XCTAssertTrue(access.text.contains("✓ API key: the Pwned 1 subscription, until 2027-03-01, 10 requests a minute"), access.text)
    }

    func testCheckAccessSaysWhatToChangeForAKeyHaveIBeenPwnedRefuses() async throws {
        let service = FakeService()
        service.answers["/api/v3/subscription/status"] = (401, #"{"statusCode":401,"message":"Access denied due to invalid hibp-api-key."}"#)
        let access = try await callTool(HaveIBeenPwned.adapter, "check-access", "{}", on: service, in: connection)
        XCTAssertTrue(access.text.contains("✗ API key: Have I Been Pwned did not accept the key"), access.text)
        XCTAssertTrue(access.text.contains("haveibeenpwned.com/API/Key"), access.text)
    }
}
