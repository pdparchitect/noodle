import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class RuntimeCoordinatorRecoveryTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    func testCrashBackoffIsBoundedAndCarriesInterruptedWorkIntoTheReplacement() async throws {
        let f = try fixture(), agent = try f.agent()
        var process = try f.start(agent)
        for (index, seconds) in [1, 2, 4, 8, 16, 30, 30].enumerated() {
            let checkpoint = f.clock.waits.count
            process.crash(needsRecovery: index == 0)
            let delay = try await f.clock.next(.seconds(seconds), after: checkpoint)
            XCTAssertTrue(f.runtime.snapshot(for: agent.id).detail.contains("in \(seconds) seconds"))
            f.runtime.reconcile(agents: [agent], repository: f.repository)
            XCTAssertEqual(f.factory.processes.count, index + 1)
            delay.resolve(.success(()))
            try await f.clock.waitUntil { f.factory.processes.count == index + 2 }
            process = f.factory.processes.last!
            XCTAssertEqual(process.launch.recoverInterruptedWork, index == 0)
        }
    }

    func testStableRuntimeResetsBackoff() async throws {
        let f = try fixture(), agent = try f.agent(), first = try f.start(agent)
        first.crash()
        let delay = try await f.clock.next(.seconds(1))
        let checkpoint = f.clock.waits.count
        delay.resolve(.success(()))
        try await f.clock.waitUntil { f.factory.processes.count == 2 }
        let stable = try await f.clock.next(.seconds(60), after: checkpoint)
        stable.resolve(.success(()))
        // The stable handler and a main-actor barrier complete before the next crash.
        for _ in 0..<10 { await Task.yield() }
        let nextCheckpoint = f.clock.waits.count
        f.factory.processes.last!.crash()
        _ = try await f.clock.next(.seconds(1), after: nextCheckpoint)
        XCTAssertTrue(f.runtime.snapshot(for: agent.id).detail.contains("in 1 seconds"))
    }

    func testWakeRecoveryReplacesBackoffOnceAndKeepsLiveBotsRunning() async throws {
        let f = try fixture(), a = try f.agent("A"), b = try f.agent("B")
        let first = try f.start(a), second = try f.start(b)
        first.crash(needsRecovery: true)
        let delay = try await f.clock.next(.seconds(1))
        f.runtime.reconcile(agents: [a, b], repository: f.repository, immediately: true)
        try await f.clock.waitUntil { f.factory.processes.count == 3 }
        delay.resolve(.success(()))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.factory.processes.count, 3)
        XCTAssertEqual(second.stops, 0)
        XCTAssertTrue(f.factory.processes.last!.launch.recoverInterruptedWork)
    }

    func testLostConnectionWithoutTerminationCallbackStillRecoversUnfinishedWork() async throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.isAlive = false
        process.hasInterruptedWork = true
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        try await f.clock.waitUntil { f.factory.processes.count == 2 }
        XCTAssertEqual(process.stops, 1)
        XCTAssertTrue(f.factory.processes.last!.launch.recoverInterruptedWork)
    }

    func testShutdownCancelsBackoffAndIgnoresLateTermination() async throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.crash()
        let delay = try await f.clock.next(.seconds(1))
        f.runtime.stopAll()
        await fulfillment(of: [delay.cancelled], timeout: 2)
        delay.resolve(.success(()))
        process.crash(needsRecovery: true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.factory.processes.count, 1)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .offline)
    }

    func testRemovingCrashedBotCancelsItsPendingRestart() async throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.crash(needsRecovery: true)
        let delay = try await f.clock.next(.seconds(1))
        f.runtime.refresh(agents: [])
        await fulfillment(of: [delay.cancelled], timeout: 2)
        delay.resolve(.success(()))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(f.factory.processes.count, 1, "Removed bots must not reappear through supervision")
        XCTAssertNil(f.runtime.snapshots[agent.id])
    }

    func testStaleTerminationCannotRestartAReplacement() throws {
        let f = try fixture(), agent = try f.agent(), first = try f.start(agent)
        f.runtime.restart(agent: agent, repository: f.repository)
        first.crash(needsRecovery: true)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
    }
}
