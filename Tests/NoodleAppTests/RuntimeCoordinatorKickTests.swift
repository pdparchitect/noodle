import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class RuntimeCoordinatorKickTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    private func missingSession(_ f: RuntimeCoordinatorFixture) throws -> (AgentRecord, RuntimeProcessFixture, URL, String) {
        let agent = try f.agent(harness: .grokBuild), process = try f.start(agent)
        let url = f.repository.storage(for: agent.id).sessionState(provider: .grokBuild, extendedAccess: false)
        let id = UUID().uuidString
        try ACPSessionState(sessionID: id).save(to: url)
        process.transition(.failed, failure: .missingSession(id))
        return (agent, process, url, id)
    }

    func testOrdinaryKickRestartsWithoutConfirmationOrSessionChanges() throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        process.transition(.failed)
        XCTAssertNil(f.runtime.kick(agent: agent, repository: f.repository))
        XCTAssertEqual(process.stops, 1)
        XCTAssertEqual(f.factory.processes.count, 2)
    }

    func testKickRetriesFailedSettingsRestartAndPreservesUnfinishedWork() throws {
        let f = try fixture(), agent = try f.agent(), old = try f.start(agent)
        old.hasInterruptedWork = true
        old.transition(.working)
        old.automaticallyStops = false
        let state = f.repository.storage(for: agent.id).sessionState(provider: .codex, extendedAccess: false)
        try Data("saved session".utf8).write(to: state)
        var recovery = AgentTurnRecovery(sessionStateURL: state)
        try recovery.begin()
        let marker = try Data(contentsOf: state.appendingPathExtension("unfinished"))
        var updated = agent
        updated.updatedAt = agent.updatedAt.addingTimeInterval(1)
        f.runtime.restart(agent: updated, repository: f.repository)
        old.finishStop(false)
        let failure = f.runtime.snapshot(for: agent.id)
        f.runtime.refresh(agents: [updated], repository: f.repository)
        f.runtime.reconcile(agents: [updated], repository: f.repository, immediately: true)
        f.runtime.notify([updated], repository: f.repository)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id), failure)
        XCTAssertEqual(old.stops, 1, "Automatic refresh must keep the failed stop available for explicit retry")

        for attempt in 2...3 {
            XCTAssertNil(f.runtime.kick(agent: updated, repository: f.repository))
            XCTAssertEqual(old.stops, attempt, "Kick must retry the original runtime's stop")
            XCTAssertEqual(f.factory.processes.count, 1, "Never overlap an unconfirmed old runtime")
            old.finishStop(attempt == 3)
        }
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertEqual(f.factory.processes.last?.configuration, updated)
        XCTAssertTrue(f.factory.processes.last!.launch.recoverInterruptedWork)
        XCTAssertEqual(try Data(contentsOf: state), Data("saved session".utf8))
        XCTAssertEqual(try Data(contentsOf: state.appendingPathExtension("unfinished")), marker)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .ready)
    }

    func testKickAfterFailedAccessRevocationRetainsRestrictedAccess() throws {
        let f = try fixture(), agent = try f.agent()
        f.runtime.setExtendedAccess(true, agent: agent, repository: f.repository)
        let old = try XCTUnwrap(f.factory.processes.last)
        old.automaticallyStops = false
        f.runtime.setExtendedAccess(false, agent: agent, repository: f.repository)
        old.finishStop(false)
        XCTAssertNil(f.runtime.kick(agent: agent, repository: f.repository))
        XCTAssertEqual(old.stops, 2)
        XCTAssertEqual(f.factory.processes.count, 1)
        old.finishStop(true)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertFalse(f.factory.processes.last!.launch.extendedAccess)
    }

    func testMissingSessionDoesNothingUntilConfirmedThenPreservesWorkAndOtherAccessMode() throws {
        let f = try fixture(), (agent, process, url, id) = try missingSession(f)
        let original = try Data(contentsOf: url)
        let otherMode = f.repository.storage(for: agent.id).sessionState(provider: .grokBuild, extendedAccess: true)
        try original.write(to: otherMode)
        var work = AgentTurnRecovery(sessionStateURL: url)
        try work.begin()
        let marker = try Data(contentsOf: url.appendingPathExtension("unfinished"))
        let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
        XCTAssertEqual(request.failure, .missingSession(id))
        XCTAssertTrue(request.message.contains("may be lost"))
        XCTAssertEqual(process.stops, 0, "Opening or cancelling the confirmation must leave the bot alone")
        XCTAssertEqual(try Data(contentsOf: url), original)

        process.automaticallyStops = false
        f.runtime.confirmKick(request, repository: f.repository)
        XCTAssertEqual(try Data(contentsOf: url), original, "Wait for the exact runtime to stop before changing state")
        process.finishStop(true)
        let state = try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: url))
        XCTAssertNil(state.sessionID)
        XCTAssertEqual(state.previousSessionIDs, [id])
        XCTAssertTrue(state.needsHistoryRecovery)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("unfinished")), marker)
        XCTAssertEqual(try Data(contentsOf: otherMode), original)
        XCTAssertEqual(f.factory.processes.count, 2)
        f.runtime.confirmKick(request, repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 2, "Confirmation cannot be replayed")
    }

    func testOldConfirmationCannotResetReplacementOrRemovedBot() throws {
        for remove in [false, true] {
            let f = try fixture(), (agent, _, url, _) = try missingSession(f)
            let original = try Data(contentsOf: url)
            let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
            if remove { f.runtime.refresh(agents: []) }
            else { f.runtime.restart(agent: agent, repository: f.repository) }
            let count = f.factory.processes.count
            f.runtime.confirmKick(request, repository: f.repository)
            XCTAssertEqual(f.factory.processes.count, count)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testUnconfirmedStopAndShutdownPreserveSession() throws {
        for shutdown in [false, true] {
            let f = try fixture(), (agent, process, url, _) = try missingSession(f)
            let original = try Data(contentsOf: url)
            let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
            process.automaticallyStops = false
            f.runtime.confirmKick(request, repository: f.repository)
            if shutdown { f.runtime.stopAll() }
            process.finishStop(shutdown)
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(f.factory.processes.count, 1)
        }
    }

    func testAccountFailuresOfferRetryWithoutReplacingSession() throws {
        for failure in [AgentRuntimeFailure.usageLimit, .authenticationRequired] {
            let f = try fixture(), (agent, process, url, _) = try missingSession(f)
            let original = try Data(contentsOf: url)
            process.transition(.failed, failure: failure)
            let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
            XCTAssertEqual(request.failure, failure)
            XCTAssertEqual(process.stops, 0)
            f.runtime.confirmKick(request, repository: f.repository)
            XCTAssertEqual(f.factory.processes.count, 2)
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testSessionChangedWhileStoppingIsPreservedAndDoesNotEnterSupervision() throws {
        let f = try fixture(), (agent, process, url, _) = try missingSession(f)
        let request = try XCTUnwrap(f.runtime.kick(agent: agent, repository: f.repository))
        process.automaticallyStops = false
        f.runtime.confirmKick(request, repository: f.repository)
        let replacement = ACPSessionState(sessionID: UUID().uuidString)
        try replacement.save(to: url)
        process.finishStop(true)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .failed)
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        f.runtime.notify([agent], repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: url)), replacement)
        XCTAssertNil(f.runtime.kick(agent: agent, repository: f.repository))
        XCTAssertEqual(f.factory.processes.count, 2, "The next Kick must check the current session instead of repeating stale recovery")
        XCTAssertEqual(try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: url)), replacement)
    }

    func testKickExplicitlyUnblocksAnInterruptedRecovery() throws {
        let f = try fixture(), (agent, process, url, _) = try missingSession(f)
        var state = ACPSessionState(sessionID: UUID().uuidString)
        state.needsHistoryRecovery = true
        state.recoveryBlocked = true
        try state.save(to: url)
        process.transition(.failed, failure: .recoveryFailed)
        XCTAssertNil(f.runtime.kick(agent: agent, repository: f.repository))
        let saved = try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.sessionID, state.sessionID)
        XCTAssertTrue(saved.needsHistoryRecovery)
        XCTAssertFalse(saved.recoveryBlocked)
        XCTAssertEqual(f.factory.processes.count, 2)
    }
}
