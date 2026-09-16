import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class RuntimeCoordinatorAccessTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    func testAppsGrantWaitsForStopAndDoesNotGrantSystemAccess() throws {
        for provider: HarnessProvider in [.codex, .claudeCode] {
            let f = try fixture(), agent = try f.agent(harness: provider), process = try f.start(agent)
            XCTAssertFalse(process.launch.appsEnabled)
            process.automaticallyStops = false
            f.runtime.setAppsEnabled(true, agent: agent, repository: f.repository)
            XCTAssertFalse(AgentAccessConfiguration.load(from: f.defaults).appsEnabled(for: agent))
            f.runtime.setExtendedAccess(true, agent: agent, repository: f.repository)
            XCTAssertEqual(process.stops, 1)
            process.finishStop(true)
            XCTAssertTrue(AgentAccessConfiguration.load(from: f.defaults).appsEnabled(for: agent))
            XCTAssertTrue(try XCTUnwrap(f.factory.processes.last).launch.appsEnabled)
            XCTAssertFalse(try XCTUnwrap(f.factory.processes.last).launch.extendedAccess)
        }
    }

    func testAppsRevocationPersistsBeforeFailedStopAndKickKeepsItRevoked() throws {
        let f = try fixture(), agent = try f.agent()
        f.runtime.setAppsEnabled(true, agent: agent, repository: f.repository)
        let process = try XCTUnwrap(f.factory.processes.last)
        process.automaticallyStops = false
        f.runtime.setAppsEnabled(false, agent: agent, repository: f.repository)
        XCTAssertFalse(AgentAccessConfiguration.load(from: f.defaults).appsEnabled(for: agent))
        process.finishStop(false)
        f.runtime.start(agent: agent, repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 1)
        XCTAssertNil(f.runtime.kick(agent: agent, repository: f.repository))
        process.finishStop(true)
        XCTAssertFalse(try XCTUnwrap(f.factory.processes.last).launch.appsEnabled)
        XCTAssertEqual(f.factory.processes.count, 2)
    }

    func testFailedOrCancelledAppsGrantNeverPersists() throws {
        for shutdown in [false, true] {
            let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
            process.automaticallyStops = false
            f.runtime.setAppsEnabled(true, agent: agent, repository: f.repository)
            if shutdown { f.runtime.stopAll() }
            process.finishStop(shutdown)
            XCTAssertFalse(AgentAccessConfiguration.load(from: f.defaults).appsEnabled(for: agent))
            XCTAssertEqual(f.factory.processes.count, 1)
        }
    }

    func testAppsCannotBeEnabledForUnsupportedHarnessAndDeletionRevokesGrant() throws {
        let f = try fixture(), agent = try f.agent(), unsupported = try f.agent(harness: .grokBuild)
        f.runtime.setAppsEnabled(true, agent: unsupported, repository: f.repository)
        XCTAssertFalse(f.runtime.accessConfiguration.appsEnabled(for: unsupported))
        XCTAssertTrue(f.factory.processes.isEmpty)
        f.runtime.setAppsEnabled(true, agent: agent, repository: f.repository)
        f.runtime.stop(agentID: agent.id)
        XCTAssertFalse(AgentAccessConfiguration.load(from: f.defaults).appsEnabled(for: agent))
    }

    func testGrantIsPersistedOnlyAfterTheRestrictedProcessStops() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.automaticallyStops = false
        f.runtime.setExtendedAccess(true, agent: agent, repository: f.repository)
        XCTAssertFalse(AgentAccessConfiguration.load(from: f.defaults).isExtended(for: agent))
        XCTAssertEqual(f.factory.processes.count, 1)
        f.runtime.setExtendedAccess(false, agent: agent, repository: f.repository)
        XCTAssertEqual(process.stops, 1)
        process.finishStop(true)
        XCTAssertTrue(AgentAccessConfiguration.load(from: f.defaults).isExtended(for: agent))
        XCTAssertTrue(f.factory.processes.last!.launch.extendedAccess)
        XCTAssertEqual(f.factory.processes.count, 2)
    }

    func testRevocationPersistsBeforeStopAndFailedStopCannotRestart() throws {
        let f = try fixture(), agent = try f.agent()
        f.runtime.setExtendedAccess(true, agent: agent, repository: f.repository)
        let process = try XCTUnwrap(f.factory.processes.last)
        process.automaticallyStops = false
        f.runtime.setExtendedAccess(false, agent: agent, repository: f.repository)
        XCTAssertFalse(AgentAccessConfiguration.load(from: f.defaults).isExtended(for: agent))
        process.finishStop(false)
        f.runtime.start(agent: agent, repository: f.repository)
        f.runtime.setExtendedAccess(true, agent: agent, repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 1)
        XCTAssertFalse(f.runtime.accessConfiguration.isExtended(for: agent))
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .failed)
        XCTAssertTrue(f.runtime.snapshot(for: agent.id).detail.contains("Could not confirm"))
    }

    func testFailedGrantAndShutdownNeverPersistBroaderAccess() throws {
        for shutdown in [false, true] {
            let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
            process.automaticallyStops = false
            f.runtime.setExtendedAccess(true, agent: agent, repository: f.repository)
            if shutdown { f.runtime.stopAll() }
            process.finishStop(shutdown)
            XCTAssertFalse(AgentAccessConfiguration.load(from: f.defaults).isExtended(for: agent))
            XCTAssertEqual(f.factory.processes.count, 1)
        }
    }

    func testClaudeCanSwitchFromRestrictedToAutonomousAndBack() throws {
        let f = try fixture(), agent = try f.agent(harness: .claudeCode)
        let restricted = try f.start(agent)
        XCTAssertFalse(restricted.launch.extendedAccess)
        f.runtime.setExtendedAccess(true, agent: agent, repository: f.repository)
        XCTAssertEqual(restricted.stops, 1)
        let autonomous = try XCTUnwrap(f.factory.processes.last)
        XCTAssertTrue(autonomous.launch.extendedAccess)
        f.runtime.setExtendedAccess(false, agent: agent, repository: f.repository)
        XCTAssertEqual(autonomous.stops, 1)
        XCTAssertFalse(try XCTUnwrap(f.factory.processes.last).launch.extendedAccess)
        XCTAssertFalse(AgentAccessConfiguration.load(from: f.defaults).isExtended(for: agent))
        XCTAssertEqual(f.factory.processes.count, 3)
    }

    func testDeletingOneBotRevokesOnlyItsAccess() throws {
        let f = try fixture(), a = try f.agent("A"), b = try f.agent("B")
        f.runtime.setExtendedAccess(true, agent: a, repository: f.repository)
        f.runtime.setExtendedAccess(true, agent: b, repository: f.repository)
        f.runtime.stop(agentID: a.id)
        let stored = AgentAccessConfiguration.load(from: f.defaults)
        XCTAssertFalse(stored.isExtended(for: a))
        XCTAssertTrue(stored.isExtended(for: b))
        XCTAssertEqual(f.runtime.snapshot(for: b.id).phase, .ready)
    }

    func testOldStopCompletionCannotFinishANewerAccessChange() throws {
        let f = try fixture(), agent = try f.agent(), old = try f.start(agent)
        old.automaticallyStops = false
        f.runtime.setExtendedAccess(true, agent: agent, repository: f.repository)
        f.runtime.stop(agentID: agent.id)
        let current = try f.start(agent)
        current.automaticallyStops = false
        f.runtime.setExtendedAccess(true, agent: agent, repository: f.repository)
        old.finishStop(true)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertFalse(f.runtime.accessConfiguration.isExtended(for: agent))
        XCTAssertTrue(f.runtime.changingAccess.contains(agent.id))
        current.finishStop(true)
        XCTAssertEqual(f.factory.processes.count, 3)
        XCTAssertTrue(f.runtime.accessConfiguration.isExtended(for: agent))
    }

    func testOldRestartCompletionCannotFinishANewerRestart() throws {
        let f = try fixture(), agent = try f.agent(), old = try f.start(agent)
        old.automaticallyStops = false
        f.runtime.restart(agent: agent, repository: f.repository)
        f.runtime.stop(agentID: agent.id)
        let current = try f.start(agent)
        current.automaticallyStops = false
        var updated = agent
        updated.modelIdentifier = "replacement-model"
        f.runtime.restart(agent: updated, repository: f.repository)
        old.finishStop(true)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertTrue(f.runtime.changingAccess.contains(agent.id))
        current.finishStop(true)
        XCTAssertEqual(f.factory.processes.count, 3)
        XCTAssertEqual(f.factory.processes.last?.configuration.modelIdentifier, "replacement-model")
    }
}
