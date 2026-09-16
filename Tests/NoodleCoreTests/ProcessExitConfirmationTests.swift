import Foundation
import XCTest
@testable import NoodleCore

final class ProcessExitConfirmationTests: XCTestCase {
    func testConfirmsARealProcessAndItsGroupHaveExited() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let stopped = expectation(description: "Child and process group exited")
        let queue = DispatchQueue(label: "Noodle.exit-test")
        ProcessExitConfirmation.wait(process: child, groupID: child.processIdentifier, queue: queue) { result in
            XCTAssertTrue(result)
            XCTAssertFalse(child.isRunning)
            stopped.fulfill()
        }
        queue.asyncAfter(deadline: .now() + 0.3) { child.terminate() }
        await fulfillment(of: [stopped], timeout: 3)
    }

    func testSlowExitIsConfirmedAfterTheOldTwoHundredMillisecondWindow() {
        let clock = ExitClock()
        var result: Bool?
        ProcessExitConfirmation.wait(isStopped: { clock.time >= 1.5 }, now: { clock.time },
                                     schedule: clock.schedule, completion: { result = $0 })
        clock.advance(to: 0.3)
        XCTAssertNil(result)
        clock.advance(to: 2)
        XCTAssertEqual(result, true)
        XCTAssertNil(clock.pending)
    }

    func testUnconfirmedExitTimesOutAndCanBeCheckedAgain() {
        let clock = ExitClock()
        var stopped = false
        var results: [Bool] = []
        func check() {
            ProcessExitConfirmation.wait(isStopped: { stopped }, now: { clock.time },
                                         schedule: clock.schedule, completion: { results.append($0) })
        }
        check()
        clock.advance(to: 6)
        XCTAssertEqual(results, [false])
        XCTAssertNil(clock.pending)
        stopped = true
        check()
        XCTAssertEqual(results, [false, true])
    }
}

private final class ExitClock {
    var time: TimeInterval = 0
    var pending: (() -> Void)?
    private var next: TimeInterval = 0
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        next = time + delay
        pending = action
    }
    func advance(to target: TimeInterval) {
        while next <= target, let action = pending {
            time = next
            pending = nil
            action()
        }
        time = target
    }
}
