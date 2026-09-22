import Foundation
import XCTest
@testable import LocalMacCore

final class OrphanSweepTests: XCTestCase {
    let a = UUID(), b = UUID()
    let start = Date(timeIntervalSinceReferenceDate: 0)
    func testOrphanExpiresOnlyAfterTheWholeGracePeriod() {
        var sweep = LocalMacOrphanSweep(grace: 300)
        XCTAssertEqual(sweep.expired(signedIn: [a], attached: [], now: start), [])
        XCTAssertEqual(sweep.expired(signedIn: [a], attached: [], now: start + 299), [])
        XCTAssertEqual(sweep.expired(signedIn: [a], attached: [], now: start + 300), [a])
    }
    func testAttachedDesktopIsNeverAnOrphan() {
        var sweep = LocalMacOrphanSweep(grace: 0)
        XCTAssertEqual(sweep.expired(signedIn: [a, b], attached: [a], now: start), [b])
    }
    func testReconnectRestartsTheClock() {
        var sweep = LocalMacOrphanSweep(grace: 300)
        _ = sweep.expired(signedIn: [a], attached: [], now: start)
        _ = sweep.expired(signedIn: [a], attached: [a], now: start + 200)
        XCTAssertEqual(sweep.expired(signedIn: [a], attached: [], now: start + 400), [])
        XCTAssertEqual(sweep.expired(signedIn: [a], attached: [], now: start + 700), [a])
    }
    func testLogoutRestartsTheClock() {
        var sweep = LocalMacOrphanSweep(grace: 300)
        _ = sweep.expired(signedIn: [a], attached: [], now: start)
        _ = sweep.expired(signedIn: [], attached: [], now: start + 200)
        XCTAssertEqual(sweep.expired(signedIn: [a], attached: [], now: start + 400), [])
    }
    func testFailedReleaseIsRetried() {
        var sweep = LocalMacOrphanSweep(grace: 300)
        _ = sweep.expired(signedIn: [a], attached: [], now: start)
        XCTAssertEqual(sweep.expired(signedIn: [a], attached: [], now: start + 300), [a])
        XCTAssertEqual(sweep.expired(signedIn: [a], attached: [], now: start + 330), [a])
    }
}
