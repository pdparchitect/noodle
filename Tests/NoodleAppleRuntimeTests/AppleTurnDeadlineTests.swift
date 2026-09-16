import XCTest
@testable import NoodleAppleRuntime

final class AppleTurnDeadlineTests: XCTestCase {
    func testNoProgressStopsAtFiveMinutes() {
        let deadline = AppleTurnDeadline(now: 100)
        XCTAssertNil(deadline.exceeded(at: 399))
        XCTAssertEqual(deadline.remaining(at: 399), 1)
        XCTAssertEqual(deadline.exceeded(at: 400), .idle)
        XCTAssertEqual(deadline.remaining(at: 401), 0)
    }

    func testToolProgressKeepsMultiStepWorkAliveBeyondFiveMinutes() {
        var deadline = AppleTurnDeadline(now: 0)
        for time in stride(from: 240.0, through: 1_440.0, by: 240.0) {
            XCTAssertNil(deadline.exceeded(at: time))
            deadline.noteActivity(at: time)
        }
        XCTAssertNil(deadline.exceeded(at: 1_700))
        XCTAssertEqual(deadline.exceeded(at: 1_740), .idle)
    }

    func testActivityCannotExtendOverallCeiling() {
        var deadline = AppleTurnDeadline(now: 0)
        for time in stride(from: 200.0, through: 1_600.0, by: 200.0) { deadline.noteActivity(at: time) }
        deadline.noteActivity(at: 1_799)
        XCTAssertEqual(deadline.remaining(at: 1_799), 1)
        XCTAssertEqual(deadline.exceeded(at: 1_800), .total)
    }

    func testLateOlderActivityCannotShortenDeadline() {
        var deadline = AppleTurnDeadline(now: 0)
        deadline.noteActivity(at: 200)
        deadline.noteActivity(at: 100)
        XCTAssertEqual(deadline.remaining(at: 400), 100)
    }

    func testNewTurnStartsWithFreshLimits() {
        let first = AppleTurnDeadline(now: 0)
        XCTAssertEqual(first.exceeded(at: 300), .idle)
        let next = AppleTurnDeadline(now: 300)
        XCTAssertNil(next.exceeded(at: 300))
        XCTAssertEqual(next.remaining(at: 300), 300)
    }
}
