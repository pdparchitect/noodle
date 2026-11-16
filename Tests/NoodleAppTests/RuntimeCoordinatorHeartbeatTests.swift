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
        f.clock.date = initial.addingTimeInterval(86_400)
        f.runtime.checkHeartbeats()
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 2)
    }

    /// Every app counts a bot's first heartbeat from the last message in any of its conversations, else from when it was made.
    func testHeartbeatsCountFromTheLastMessageInABotsConversations() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.canReceiveHeartbeat = true
        f.runtime.configureHeartbeats(intervalMinutes: 1)
        let conversations = try f.repository.loadConversations().filter { $0.participantIDs.contains(agent.id) }
        XCTAssertFalse(conversations.isEmpty)
        let said = f.clock.date.addingTimeInterval(-30)
        f.runtime.seedHeartbeatActivity(for: [agent], conversations: conversations) { id in
            conversations.contains { $0.id == id } ? said : nil
        }
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 0, "Half an interval since it last spoke")
        f.clock.date.addTimeInterval(30)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 1)
    }

    func testOverdueBusyBotsKeepTheirHeartbeatUntilTheyCanReceiveIt() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        f.runtime.configureHeartbeats(intervalMinutes: 1)
        f.runtime.seedHeartbeatActivity(for: agent.id, at: f.clock.date.addingTimeInterval(-600))
        process.transition(.working)
        f.runtime.checkHeartbeats()
        XCTAssertEqual(process.heartbeats, 0)
        XCTAssertNil(f.runtime.lastActiveDates[agent.id])
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

    func testBotIsLastActiveWhenItsTurnEnds() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.transition(.working)
        f.clock.date.addTimeInterval(90)
        process.transition(.ready)
        let finished = f.clock.date
        f.clock.date.addTimeInterval(600)
        f.runtime.recordActivity(for: agent.id)
        f.runtime.configureHeartbeats(intervalMinutes: 5)
        XCTAssertEqual(f.runtime.lastActiveDates[agent.id], finished)
    }

    func testBotIsLastActiveWhenARestartCutsItsTurnShort() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.transition(.working)
        f.clock.date.addTimeInterval(90)
        let cut = f.clock.date
        f.runtime.restart(agent: agent, repository: f.repository)
        f.clock.date.addTimeInterval(600)
        XCTAssertEqual(f.runtime.lastActiveDates[agent.id], cut)
    }

    func testScheduledWakeFiresOnceWhenDueAndTheBotIsFree() async throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        let start = f.clock.date
        _ = try f.repository.scheduleWake(agentID: agent.id, at: start.addingTimeInterval(600), note: "Check the build", now: start)
        f.runtime.refreshWakes(for: agent.id, repository: f.repository)
        await f.runtime.settleWakes()
        process.canReceiveHeartbeat = true
        f.clock.date = start.addingTimeInterval(599)
        f.runtime.checkWakes(repository: f.repository)
        await f.runtime.settleWakes()
        XCTAssertEqual(process.wakes, 0)
        f.clock.date = start.addingTimeInterval(700)
        process.canReceiveHeartbeat = false
        f.runtime.checkWakes(repository: f.repository)
        await f.runtime.settleWakes()
        XCTAssertEqual(process.wakes, 0, "A busy bot keeps its wake until it is free")
        process.canReceiveHeartbeat = true
        f.runtime.checkWakes(repository: f.repository)
        await f.runtime.settleWakes()
        f.runtime.checkWakes(repository: f.repository)
        await f.runtime.settleWakes()
        XCTAssertEqual(process.wakes, 1)
        XCTAssertEqual(process.heartbeats, 0)
        XCTAssertEqual(try f.repository.listWakes(agentID: agent.id).due.map(\.note), ["Check the build"])
    }

    func testANoteFromNoodleWakesTheBotOnceItIsFree() async throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.canReceiveHeartbeat = false
        f.runtime.wake(agent.id, note: "Build box is unused", repository: f.repository)
        await f.runtime.settleWakes()
        f.runtime.checkWakes(repository: f.repository)
        XCTAssertEqual(process.wakes, 0, "A busy bot gets the note when it is free")
        process.canReceiveHeartbeat = true
        f.runtime.checkWakes(repository: f.repository)
        XCTAssertEqual(process.wakes, 1)
        XCTAssertEqual(try f.repository.listWakes(agentID: agent.id).due.map(\.note), ["Build box is unused"])
    }

    func testOrganizeOnlyReachesAnIdleBot() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        XCTAssertFalse(f.runtime.canOrganize(agent.id))
        f.runtime.organize(agent.id)
        XCTAssertEqual(process.organizes, 0, "A busy bot is never interrupted")
        process.canReceiveHeartbeat = true
        XCTAssertTrue(f.runtime.canOrganize(agent.id))
        f.runtime.organize(agent.id)
        XCTAssertEqual(process.organizes, 1)
        XCTAssertEqual(process.heartbeats, 0)
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

    func testRelaunchKeepsPersistedActivityAndLastActiveButRemovalClearsThem() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.canReceiveHeartbeat = true
        f.runtime.configureHeartbeats(intervalMinutes: 1)
        f.runtime.seedHeartbeatActivity(for: agent.id, at: f.clock.date.addingTimeInterval(-60))
        f.runtime.checkHeartbeats()
        process.transition(.working)
        process.transition(.ready)
        let last = f.clock.date
        f.runtime.stopAll()
        let reloaded = AgentRuntimeCoordinator(discovery: f.discovery, defaults: f.defaults,
            makeProcess: { f.factory.make($0) }, sleep: { try await f.clock.sleep($0) }, now: { f.clock.date })
        defer { reloaded.stopAll() }
        XCTAssertEqual(reloaded.lastActiveDates[agent.id], last)
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
        XCTAssertNil(reloaded.lastActiveDates[agent.id])
        XCTAssertNil(f.defaults.dictionary(forKey: "Noodle.heartbeat.lastDates")?[agent.id.uuidString])
        XCTAssertNil(f.defaults.dictionary(forKey: "Noodle.heartbeat.lastActivityDates")?[agent.id.uuidString])
    }

    func testMalformedSavedDatesAreIgnored() throws {
        let f = try fixture(), agent = try f.agent()
        for key in ["Noodle.heartbeat.lastDates", "Noodle.heartbeat.lastActivityDates"] {
            f.defaults.set(["invalid UUID": 10, agent.id.uuidString: "not a date"], forKey: key)
        }
        let runtime = AgentRuntimeCoordinator(discovery: f.discovery, defaults: f.defaults)
        XCTAssertTrue(runtime.lastActiveDates.isEmpty)
    }
}
