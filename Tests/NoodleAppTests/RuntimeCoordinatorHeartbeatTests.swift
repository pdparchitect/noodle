import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class RuntimeCoordinatorHeartbeatTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    func testHeartbeatWaitsForDeadlineAndNeverCatchesUpInABurst() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.canReceiveHeartbeat = true
        f.runtime.configureHeartbeats(intervalMinutes: 1)
        let initial = f.clock.date
        f.runtime.seedHeartbeatActivity(for: agent.id, at: initial)
        f.clock.date = initial.addingTimeInterval(59)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 0)
        f.clock.date = initial.addingTimeInterval(60)
        f.runtime.checkHeartbeats()
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 1)
        XCTAssertEqual(f.runtime.lastHeartbeatDates[agent.id], f.clock.date)
        f.clock.date = initial.addingTimeInterval(86_400)
        f.runtime.checkHeartbeats()
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 2)
    }

    func testOverdueBusyBotsKeepTheirHeartbeatUntilTheyCanReceiveIt() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        f.runtime.configureHeartbeats(intervalMinutes: 1)
        f.runtime.seedHeartbeatActivity(for: agent.id, at: f.clock.date.addingTimeInterval(-600))
        process.transition(.working)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 0)
        XCTAssertNil(f.runtime.lastHeartbeatDates[agent.id])
        // A runtime may become ready without reporting a completed work transition.
        process.canReceiveHeartbeat = true
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 1)
    }

    func testFinishingRealWorkAndNewMessagesRestartTheInactivityCountdown() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.canReceiveHeartbeat = true
        f.runtime.configureHeartbeats(intervalMinutes: 1)
        f.runtime.seedHeartbeatActivity(for: agent.id, at: f.clock.date.addingTimeInterval(-600))
        process.transition(.working)
        process.transition(.ready)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 0)
        f.clock.date.addTimeInterval(59)
        f.runtime.recordActivity(for: agent.id)
        f.clock.date.addTimeInterval(59)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 0)
        f.clock.date.addTimeInterval(1)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 1)
    }

    func testPerBotSettingsDoNotResetOtherBotsAndReenableStartsFreshCountdown() throws {
        let f = try fixture(), a = try f.agent("A"), b = try f.agent("B")
        let first = try f.start(a), second = try f.start(b)
        first.canReceiveHeartbeat = true; second.canReceiveHeartbeat = true
        f.runtime.configureHeartbeats(intervalMinutes: 1)
        f.runtime.seedHeartbeatActivity(for: a.id, at: f.clock.date)
        f.runtime.seedHeartbeatActivity(for: b.id, at: f.clock.date)
        f.clock.date.addTimeInterval(30)
        f.runtime.setHeartbeatEnabled(false, for: a.id)
        f.clock.date.addTimeInterval(30)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(first.heartbeats, 0)
        XCTAssertEqual(second.heartbeats, 1)
        f.runtime.setHeartbeatEnabled(true, for: a.id)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(first.heartbeats, 0)
        f.clock.date.addTimeInterval(60)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(first.heartbeats, 1)
        XCTAssertEqual(second.heartbeats, 2)
    }

    func testGlobalDisableAndIntervalChangeRebaseAllTrackedBots() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.canReceiveHeartbeat = true
        f.runtime.seedHeartbeatActivity(for: agent.id, at: f.clock.date)
        f.runtime.configureHeartbeats(enabled: false, intervalMinutes: 1)
        f.clock.date.addTimeInterval(600)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 0)
        f.runtime.configureHeartbeats(enabled: true)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 0)
        f.clock.date.addTimeInterval(30)
        f.runtime.configureHeartbeats(intervalMinutes: 2)
        f.clock.date.addTimeInterval(119)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 0)
        f.clock.date.addTimeInterval(1)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 1)
        XCTAssertEqual(AgentHeartbeatConfiguration.load(from: f.defaults), f.runtime.heartbeatConfiguration)
    }

    func testRelaunchKeepsPersistedActivityAndLastHeartbeatButRemovalClearsThem() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.canReceiveHeartbeat = true
        f.runtime.configureHeartbeats(intervalMinutes: 1)
        f.runtime.seedHeartbeatActivity(for: agent.id, at: f.clock.date.addingTimeInterval(-60))
        f.runtime.checkHeartbeats()
        let last = f.clock.date
        f.runtime.stopAll()
        let reloaded = AgentRuntimeCoordinator(discovery: f.discovery, defaults: f.defaults,
            makeProcess: { f.factory.make($0) }, sleep: { try await f.clock.sleep($0) }, now: { f.clock.date })
        defer { reloaded.stopAll() }
        XCTAssertEqual(reloaded.lastHeartbeatDates[agent.id], last)
        XCTAssertEqual(reloaded.heartbeatConfiguration.intervalMinutes, 1)
        reloaded.seedHeartbeatActivity(for: agent.id, at: last.addingTimeInterval(-600))
        reloaded.start(agent: agent, repository: f.repository)
        let next = try XCTUnwrap(f.factory.processes.last)
        next.canReceiveHeartbeat = true
        reloaded.checkHeartbeats()
        XCTAssertEqual(next.heartbeats, 0, "Reseeding must not replace persisted activity")
        f.clock.date.addTimeInterval(60)
        reloaded.checkHeartbeats()
        XCTAssertEqual(next.heartbeats, 1)
        reloaded.stop(agentID: agent.id)
        XCTAssertNil(reloaded.lastHeartbeatDates[agent.id])
        XCTAssertNil(f.defaults.dictionary(forKey: "Noodle.heartbeat.lastDates")?[agent.id.uuidString])
        XCTAssertNil(f.defaults.dictionary(forKey: "Noodle.heartbeat.lastActivityDates")?[agent.id.uuidString])
    }

    func testMalformedSavedDatesAreIgnored() throws {
        let f = try fixture(), agent = try f.agent()
        for key in ["Noodle.heartbeat.lastDates", "Noodle.heartbeat.lastActivityDates"] {
            f.defaults.set(["invalid UUID": 10, agent.id.uuidString: "not a date"], forKey: key)
        }
        let runtime = AgentRuntimeCoordinator(discovery: f.discovery, defaults: f.defaults)
        XCTAssertTrue(runtime.lastHeartbeatDates.isEmpty)
    }
}
