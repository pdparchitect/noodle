import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class RuntimeCoordinatorCallbackTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }
    func testReplacedRuntimeCannotOverwriteCurrentStatusOrHeartbeat() throws {
        let f = try fixture(), agent = try f.agent(), old = try f.start(agent)
        f.runtime.restart(agent: agent, repository: f.repository)
        _ = try XCTUnwrap(f.factory.processes.last)
        old.transition(.failed, detail: "Late failure from stopped runtime")
        old.launch.onHeartbeat()
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
        XCTAssertNil(f.runtime.lastHeartbeatDates[agent.id])
    }

    func testDeletedRuntimeCannotRecreateSnapshot() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        f.runtime.stop(agentID: agent.id)
        process.transition(.working)
        process.launch.onHeartbeat()
        XCTAssertNil(f.runtime.snapshots[agent.id])
        XCTAssertNil(f.runtime.lastHeartbeatDates[agent.id])
    }

    func testShutdownRejectsLateCallbacksBeforeTheNextLaunch() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        f.runtime.stopAll()
        process.transition(.working)
        process.launch.onHeartbeat()
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .offline)
        XCTAssertNil(f.runtime.lastHeartbeatDates[agent.id])
    }

    func testRuntimeCannotPublishStateForAnotherBot() throws {
        let f = try fixture(), a = try f.agent("A"), b = try f.agent("B")
        let first = try f.start(a)
        _ = try f.start(b)
        first.launch.onSnapshot(.init(agentID: b.id, phase: .failed, detail: "Wrong identity"))
        XCTAssertEqual(f.runtime.snapshot(for: b.id).phase, .ready)
    }

    func testTerminatedRuntimeCannotOverwritePendingRecoveryStatus() async throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.crash()
        _ = try await f.clock.next(.seconds(1))
        let recovery = f.runtime.snapshot(for: agent.id).detail
        process.transition(.ready)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .starting)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).detail, recovery)
    }
}
