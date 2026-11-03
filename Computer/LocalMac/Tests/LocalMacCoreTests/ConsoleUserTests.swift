import Foundation
import XCTest
@testable import LocalMacCore
import LocalMacPrivate

final class ConsoleUserTests: XCTestCase {
    private let owner: [String: Any] = ["kCGSSessionIDKey": 257, "kCGSSessionUserIDKey": 501, "kCGSSessionGroupIDKey": 20,
        "kCGSSessionUserNameKey": "pdp", "kCGSSessionOnConsoleKey": true]
    private let background: [String: Any] = ["kCGSSessionIDKey": 296, "kCGSSessionUserIDKey": 503, "kCGSSessionGroupIDKey": 20,
        "kCGSSessionUserNameKey": "noodle_2836c01de6574432b316", "kCGSSessionOnConsoleKey": false]

    private func needsRepublish(_ published: UInt32?, _ sessions: [[String: Any]]) -> Bool {
        LocalMacConsoleUser.needsRepublish(published: published, sessions: sessions, managed: [503])
    }

    func testBackgroundLoginPublishedAsConsoleUserNeedsTheOwnerRepublished() {
        XCTAssertTrue(needsRepublish(503, [background, owner]))
    }
    func testStaleRecordAfterTheBackgroundSessionEndedNeedsTheOwnerRepublished() {
        XCTAssertTrue(needsRepublish(503, [owner]))
    }
    func testCorrectRecordIsLeftAlone() {
        XCTAssertFalse(needsRepublish(501, [background, owner]))
    }
    func testAnotherPersonsFastUserSwitchIsLeftAlone() {
        XCTAssertFalse(needsRepublish(502, [background, owner]))
    }
    func testManagedAccountBroughtOnConsoleIsLeftAlone() {
        var onConsole = background; onConsole["kCGSSessionOnConsoleKey"] = true
        var away = owner; away["kCGSSessionOnConsoleKey"] = false
        XCTAssertFalse(needsRepublish(503, [onConsole, away]))
    }
    func testNothingIsRepublishedWithoutAnOnConsoleUser() {
        var away = owner; away["kCGSSessionOnConsoleKey"] = false
        XCTAssertFalse(needsRepublish(503, [background, away]))
        XCTAssertFalse(needsRepublish(nil, [background, owner]))
    }

    func testConfigdIsFoundByItsExecutable() {
        XCTAssertGreaterThan(NLMProcessIDForExecutable("/usr/libexec/configd"), 1)
        XCTAssertEqual(NLMProcessIDForExecutable("/usr/libexec/no-such-daemon"), 0)
    }
    func testFirstConfigdRestartRunsAtOnce() {
        XCTAssertEqual(LocalMacConfigdRestart().wait(now: Date(timeIntervalSince1970: 100)), 0)
    }
    func testConfigdRestartWithinTheIntervalWaitsForTheRest() {
        var restart = LocalMacConfigdRestart()
        restart.ran(at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(restart.wait(now: Date(timeIntervalSince1970: 104)), LocalMacConfigdRestart.interval - 4, accuracy: 0.001)
    }
    func testConfigdRestartAfterTheIntervalRunsAtOnce() {
        var restart = LocalMacConfigdRestart()
        restart.ran(at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(restart.wait(now: Date(timeIntervalSince1970: 100 + LocalMacConfigdRestart.interval)), 0)
    }
}
