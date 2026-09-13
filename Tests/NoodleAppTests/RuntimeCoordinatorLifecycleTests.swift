import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class RuntimeCoordinatorLifecycleTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    func testStartsOnceWithPreparedWorkspaceAndRestrictedAccess() throws {
        let f = try fixture(), agent = try f.agent()
        let process = try f.start(agent)
        f.runtime.start(agent: agent, repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 1)
        XCTAssertEqual(process.starts, 1)
        XCTAssertFalse(process.launch.extendedAccess)
        XCTAssertFalse(process.launch.recoverInterruptedWork)
        XCTAssertEqual(process.launch.provider, .codex)
        XCTAssertEqual(process.launch.workspaceURL, f.repository.directory(for: agent))
        XCTAssertTrue(FileManager.default.fileExists(atPath: process.launch.workspaceURL.appendingPathComponent("AGENTS.md").path))
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
    }

    func testMissingHarnessAndInstallationNeverConstructRuntime() throws {
        let f = try fixture(), missing = try f.agent("No harness", harness: nil), unavailable = try f.agent("No Muse", harness: .muse)
        for agent in [missing, unavailable] {
            f.runtime.start(agent: agent, repository: f.repository)
            XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .failed)
        }
        XCTAssertTrue(f.runtime.snapshot(for: missing.id).detail.contains("Choose a harness"))
        XCTAssertTrue(f.runtime.snapshot(for: unavailable.id).detail.contains("not installed"))
        XCTAssertTrue(f.factory.processes.isEmpty)
    }

    func testUnsafeWorkspaceFailsBeforeRuntimeConstruction() throws {
        let f = try fixture(), agent = try f.agent()
        let workspace = f.repository.directory(for: agent)
        let managed = workspace.appendingPathComponent(".agents")
        try FileManager.default.removeItem(at: managed)
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: outside)
        f.runtime.start(agent: agent, repository: f.repository)
        XCTAssertTrue(f.factory.processes.isEmpty)
        XCTAssertTrue(f.runtime.snapshot(for: agent.id).detail.contains("Could not prepare"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testRestartWaitsForConfirmedStopAndUsesNewConfiguration() throws {
        let f = try fixture(), agent = try f.agent(), old = try f.start(agent)
        old.automaticallyStops = false
        var updated = agent
        updated.modelIdentifier = "new-model"
        f.runtime.restart(agent: updated, repository: f.repository)
        f.runtime.restart(agent: updated, repository: f.repository)
        f.runtime.start(agent: updated, repository: f.repository)
        XCTAssertEqual(old.stops, 1)
        XCTAssertEqual(f.factory.processes.count, 1)
        XCTAssertTrue(f.runtime.changingAccess.contains(agent.id))
        old.finishStop(true)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertEqual(f.factory.processes.last?.configuration, updated)
        XCTAssertFalse(f.runtime.changingAccess.contains(agent.id))
    }

    func testFailedStopBlocksStartAndReconcile() throws {
        let f = try fixture(), agent = try f.agent(), old = try f.start(agent)
        old.automaticallyStops = false
        f.runtime.restart(agent: agent, repository: f.repository)
        old.finishStop(false)
        f.runtime.start(agent: agent, repository: f.repository)
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        XCTAssertEqual(f.factory.processes.count, 1)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .failed)
        XCTAssertTrue(f.runtime.snapshot(for: agent.id).detail.contains("could not be stopped"))
    }

    func testShutdownInvalidatesPendingRestartCompletion() throws {
        let f = try fixture(), agent = try f.agent(), old = try f.start(agent)
        old.automaticallyStops = false
        f.runtime.restart(agent: agent, repository: f.repository)
        f.runtime.stopAll()
        old.finishStop(true)
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        XCTAssertEqual(f.factory.processes.count, 1)
        XCTAssertTrue(f.runtime.changingAccess.isEmpty)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .offline)
        f.runtime.startAll(agents: [agent], repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
    }

    func testRefreshStopsRemovedBotsAndRestartsOnlyChangedConfiguration() throws {
        let f = try fixture(), a = try f.agent("A"), b = try f.agent("B")
        let first = try f.start(a), second = try f.start(b)
        f.runtime.refresh(agents: [a, b], repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 2)
        var updated = b
        updated.modelIdentifier = "updated-model"
        f.runtime.refresh(agents: [updated], repository: f.repository)
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(second.stops, 1)
        XCTAssertNil(f.runtime.snapshots[a.id])
        XCTAssertEqual(f.factory.processes.count, 3)
        XCTAssertEqual(f.factory.processes.last?.configuration, updated)
    }

    func testResetThreadClearsOnlySelectedAccessModeAndRecoveryMarker() throws {
        let f = try fixture(), agent = try f.agent()
        let storage = f.repository.storage(for: agent.id)
        let restricted = storage.sessionState(provider: .codex, extendedAccess: false)
        let extended = storage.sessionState(provider: .codex, extendedAccess: true)
        for url in [restricted, restricted.appendingPathExtension("unfinished"), extended] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("saved state".utf8).write(to: url)
        }
        f.runtime.restart(agent: agent, repository: f.repository, resetThread: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: restricted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restricted.appendingPathExtension("unfinished").path))
        XCTAssertEqual(try Data(contentsOf: extended), Data("saved state".utf8))
        XCTAssertEqual(f.factory.processes.count, 1)
    }
}
