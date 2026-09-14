import ComputerCore
import Foundation
import XCTest
@testable import NoodleComputer

final class LocalNetworkAccessTests: XCTestCase {
    func testDenialCompletesAllWaitersAndIgnoresLaterEvents() async {
        let connection = ProbeConnection()
        let probe = LocalNetworkAccessProbe(connection: connection)
        let first = Task { await probe.check() }
        let second = Task { await probe.check() }
        await fulfillment(of: [connection.started], timeout: 1)
        connection.report(true)
        connection.report(false)
        let firstResult = await first.value, secondResult = await second.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertEqual(connection.counts.starts, 1)
        XCTAssertEqual(connection.counts.cancels, 1)
    }

    func testReachableConnectionDoesNotOfferPermissionRecovery() async {
        let connection = ProbeConnection()
        let probe = LocalNetworkAccessProbe(connection: connection)
        let check = Task { await probe.check() }
        await fulfillment(of: [connection.started], timeout: 1)
        connection.report(false)
        let denied = await check.value
        XCTAssertFalse(denied)
        XCTAssertEqual(connection.counts.cancels, 1)
    }

    func testUnresponsiveConnectionTimesOutWithoutAssumingDenial() async {
        let connection = ProbeConnection()
        let probe = LocalNetworkAccessProbe(connection: connection, timeout: 0.02)
        let denied = await probe.check()
        XCTAssertFalse(denied)
        XCTAssertEqual(connection.counts.cancels, 1)
        connection.report(true) // A queued event after the deadline must be harmless.
        let later = await probe.check()
        XCTAssertFalse(later)
        XCTAssertEqual(connection.counts.starts, 1)
    }

    func testCancellationStopsTheConnectionAndIgnoresLateDenial() async {
        let connection = ProbeConnection()
        let probe = LocalNetworkAccessProbe(connection: connection)
        let check = Task { await probe.check() }
        await fulfillment(of: [connection.started], timeout: 1)
        check.cancel()
        let denied = await check.value
        XCTAssertFalse(denied)
        XCTAssertEqual(connection.counts.cancels, 1)
        connection.report(true)
        let later = await probe.check()
        XCTAssertFalse(later)
    }

    func testAlreadyCancelledTaskDoesNotWaitForTheDeadline() async {
        let connection = ProbeConnection()
        let probe = LocalNetworkAccessProbe(connection: connection, timeout: 60)
        let completed = expectation(description: "Cancelled probe completes")
        let check = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let denied = await probe.check()
            XCTAssertFalse(denied)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 1)
        check.cancel()
        XCTAssertEqual(connection.counts.cancels, 1)
    }

    @MainActor func testRecoveryClearsWhenRetryStartsOrAnUnrelatedFailureReplacesIt() {
        let session = ComputerSession(Computer(name: "Desktop", kind: .container))
        session.recordStartupFailure(ComputerStartupRecovery.localNetwork)
        XCTAssertEqual(session.startupRecovery, .localNetwork)
        XCTAssertTrue(session.phase.canStart)
        XCTAssertEqual(session.phase.startFailureDescription,
                       "Computer did not start: \(ComputerStartupRecovery.localNetwork.localizedDescription)")

        session.phase = .starting
        XCTAssertNil(session.startupRecovery)
        XCTAssertFalse(session.phase.canStart)
        session.recordStartupFailure(ComputerStartupRecovery.localNetwork)
        let offline = URLError(.notConnectedToInternet)
        session.recordStartupFailure(offline)
        XCTAssertNil(session.startupRecovery) // Generic offline errors don't prove a privacy denial.
        XCTAssertEqual(session.phase.startFailureDescription, "Computer did not start: \(offline.localizedDescription)")
        session.recordStartupFailure(ComputerStartupRecovery.localNetwork)
        session.phase = .stopped
        XCTAssertNil(session.startupRecovery)
        XCTAssertTrue(session.phase.canStart)
    }

    func testOnlyStoppedAndFailedComputersCanStart() {
        XCTAssertTrue(ComputerPhase.stopped.canStart)
        XCTAssertTrue(ComputerPhase.failed("Permission denied").canStart)
        for phase: ComputerPhase in [.starting, .running, .stopping, .updating] {
            XCTAssertFalse(phase.canStart)
        }
    }
}

/// No sockets or privacy changes: late reports simulate already queued callbacks.
private final class ProbeConnection: LocalNetworkProbeConnection, @unchecked Sendable {
    let started = XCTestExpectation(description: "Probe starts")
    private let lock = NSLock()
    private var callback: (@Sendable (Bool) -> Void)?
    private var starts = 0
    private var cancels = 0
    var counts: (starts: Int, cancels: Int) { lock.withLock { (starts, cancels) } }

    func start(on queue: DispatchQueue, report: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { starts += 1; callback = report }
        started.fulfill()
    }
    func report(_ denied: Bool) { lock.withLock { callback }?(denied) }
    func cancel() { lock.withLock { cancels += 1 } }
}
