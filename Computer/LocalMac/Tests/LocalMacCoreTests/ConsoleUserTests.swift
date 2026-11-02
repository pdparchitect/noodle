import Foundation
import XCTest
@testable import LocalMacCore

final class ConsoleUserTests: XCTestCase {
    private let owner: [String: Any] = ["kCGSSessionIDKey": 257, "kCGSSessionUserIDKey": 501, "kCGSSessionGroupIDKey": 20,
        "kCGSSessionUserNameKey": "pdp", "kCGSSessionOnConsoleKey": true]
    private let background: [String: Any] = ["kCGSSessionIDKey": 296, "kCGSSessionUserIDKey": 503, "kCGSSessionGroupIDKey": 20,
        "kCGSSessionUserNameKey": "noodle_2836c01de6574432b316", "kCGSSessionOnConsoleKey": false]

    func testBackgroundLoginPublishedAsConsoleUserIsReplacedByTheOwner() {
        let repair = LocalMacConsoleUser.repair(published: 503, sessions: [background, owner], managed: [503])
        XCTAssertEqual(repair, LocalMacConsoleUser(name: "pdp", uid: 501, gid: 20))
    }
    func testStaleRecordAfterTheBackgroundSessionEndedIsReplaced() {
        XCTAssertEqual(LocalMacConsoleUser.repair(published: 503, sessions: [owner], managed: [503])?.uid, 501)
    }
    func testCorrectRecordIsLeftAlone() {
        XCTAssertNil(LocalMacConsoleUser.repair(published: 501, sessions: [background, owner], managed: [503]))
    }
    func testAnotherPersonsFastUserSwitchIsLeftAlone() {
        XCTAssertNil(LocalMacConsoleUser.repair(published: 502, sessions: [background, owner], managed: [503]))
    }
    func testManagedAccountBroughtOnConsoleIsLeftAlone() {
        var onConsole = background; onConsole["kCGSSessionOnConsoleKey"] = true
        var away = owner; away["kCGSSessionOnConsoleKey"] = false
        XCTAssertNil(LocalMacConsoleUser.repair(published: 503, sessions: [onConsole, away], managed: [503]))
    }
    func testNothingIsPublishedWithoutAnOnConsoleUser() {
        var away = owner; away["kCGSSessionOnConsoleKey"] = false
        XCTAssertNil(LocalMacConsoleUser.repair(published: 503, sessions: [background, away], managed: [503]))
        XCTAssertNil(LocalMacConsoleUser.repair(published: nil, sessions: [background, owner], managed: [503]))
    }
}
