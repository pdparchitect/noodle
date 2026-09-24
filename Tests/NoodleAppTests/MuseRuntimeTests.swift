import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class MuseRuntimeTests: XCTestCase {
    private func fixture() throws -> MuseRuntimeFixture {
        let f = try MuseRuntimeFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    func testStartupChoosesAccessModeAndPersistsSessionBeforeBecomingReady() async throws {
        for extended in [false, true] {
            let f = try fixture(), (process, wire) = f.make(extended: extended)
            process.start()
            try await f.waitUntil { process.snapshot.phase == .ready }
            XCTAssertEqual(wire.extendedAccess, extended)
            XCTAssertEqual(wire.count("initialize"), 1)
            XCTAssertEqual(wire.count("initialized"), 1)
            XCTAssertEqual(wire.count("session/start"), 1)
            XCTAssertEqual(try f.saved(extended: extended)["sessionID"] as? String, wire.session)
            XCTAssertTrue(process.isAlive)
            XCTAssertTrue(process.canReceiveHeartbeat)
            XCTAssertFalse(process.hasInterruptedWork)
        }
    }

    func testRestartResumesSavedSessionAndRestoresSelectedModel() async throws {
        let f = try fixture(), (first, wire) = f.make()
        first.start()
        try await f.waitUntil { first.snapshot.phase == .ready }
        first.stop { XCTAssertTrue($0) }
        let (second, next) = f.make()
        second.start()
        try await f.waitUntil { second.snapshot.phase == .ready }
        XCTAssertEqual(next.count("session/resume"), 1)
        XCTAssertEqual(next.count("session/start"), 0)
        XCTAssertEqual(next.session, wire.session)
        XCTAssertEqual(next.count("session/setModel"), 1)
    }

    func testCompletionBeforeAcknowledgementFinishesExactlyOneTurn() async throws {
        let f = try fixture(), (process, wire) = f.make()
        wire.finishBeforeAcknowledgement = true
        process.start()
        try await f.waitUntil { process.snapshot.phase == .ready }
        process.notify()
        try await f.waitUntil { wire.count("turn/start") == 1 && process.snapshot.phase == .ready }
        XCTAssertFalse(process.hasInterruptedWork)
        XCTAssertFalse(AgentTurnRecovery(sessionStateURL: f.state()).hasUnfinishedTurn)
        XCTAssertTrue(f.failures.isEmpty)
    }

    func testQueuedNotificationCanBePromotedToSteerTheActiveTurn() async throws {
        let f = try fixture(), (process, wire) = f.make()
        process.start()
        try await f.waitUntil { process.snapshot.phase == .ready }
        process.notify()
        try await f.waitUntil { wire.turn != nil && process.snapshot.phase == .working }
        let queued = process.notify(immediately: false)
        XCTAssertEqual(wire.count("turn/start"), 1)
        XCTAssertEqual(wire.count("turn/steer"), 0)
        process.promoteNotification(queued)
        try await f.waitUntil { wire.count("turn/steer") == 1 }
        XCTAssertEqual(wire.calls.first { $0.0 == "turn/steer" }?.1["expectedTurnId"] as? String, wire.turn)
        wire.complete()
        try await f.waitUntil { process.snapshot.phase == .ready }
        XCTAssertEqual(wire.count("turn/start"), 1)
        XCTAssertFalse(process.hasInterruptedWork)
    }

    /// A message promoted before Muse acknowledges the turn steers only once the
    /// turn ID is known. If the turn ends while the steer is in flight the bot
    /// takes no heartbeat until the steer is answered, and a rejected steer
    /// becomes a follow-up turn that ignores completions for other turns.
    func testSteeringWaitsForTurnAcknowledgementAndSteerReply() async throws {
        let f = try fixture(), (process, wire) = f.make()
        process.start()
        try await f.waitUntil { process.snapshot.phase == .ready }
        wire.heldMethods = ["turn/start", "turn/steer"]
        process.notify()
        try await f.waitUntil { wire.heldReplies["turn/start"] != nil }
        process.notify(immediately: true)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(wire.count("turn/steer"), 0)
        wire.release("turn/start")
        try await f.waitUntil { wire.heldReplies["turn/steer"] != nil }
        XCTAssertEqual(wire.calls.first { $0.0 == "turn/steer" }?.1["expectedTurnId"] as? String, wire.turn)
        wire.heldMethods = []
        wire.complete()
        try await f.waitUntil { process.snapshot.phase == .ready }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(process.canReceiveHeartbeat, "The unanswered steer still holds the message")
        XCTAssertEqual(wire.count("turn/start"), 1)
        wire.release("turn/steer", reject: true)
        try await f.waitUntil { wire.count("turn/start") == 2 && process.snapshot.phase == .working }
        wire.complete(turnID: UUID().uuidString)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(process.snapshot.phase, .working)
        wire.complete()
        try await f.waitUntil { process.canReceiveHeartbeat }
        XCTAssertFalse(process.hasInterruptedWork)
        XCTAssertTrue(f.failures.isEmpty)
    }

    func testInvalidTurnAcknowledgementPreservesUnfinishedWorkForRecovery() async throws {
        let f = try fixture(), (process, wire) = f.make()
        wire.invalidAcknowledgement = true
        process.start()
        try await f.waitUntil { process.snapshot.phase == .ready }
        process.notify()
        try await f.waitUntil { process.snapshot.phase == .failed }
        XCTAssertEqual(f.failures, [true])
        XCTAssertTrue(AgentTurnRecovery(sessionStateURL: f.state()).hasUnfinishedTurn)
        XCTAssertFalse(process.isAlive)
        XCTAssertTrue(process.snapshot.detail.contains("invalid turn acknowledgement"))
    }

    func testRepeatedProjectionFailureRecoversOnceThenPausesUntilExplicitStop() async throws {
        let f = try fixture(), (process, wire) = f.make()
        wire.terminalErrors = ["projectionError", "projectionError"]
        process.start()
        try await f.waitUntil { process.snapshot.phase == .ready }
        process.notify()
        try await f.waitUntil { process.snapshot.phase == .failed }
        XCTAssertEqual(wire.count("session/start"), 2)
        XCTAssertEqual(wire.count("turn/start"), 2)
        XCTAssertTrue(f.failures.isEmpty, "A terminal history failure must not trigger automatic restart")
        XCTAssertTrue(process.isAlive, "Paused runtimes block automatic reconciliation")
        XCTAssertTrue(process.hasInterruptedWork)
        XCTAssertEqual((try f.saved()["previousSessionIDs"] as? [String])?.count, 1)
        process.stop { XCTAssertTrue($0) }
        XCTAssertFalse(process.isAlive, "Explicitly stopped runtimes must no longer report alive")
        XCTAssertEqual(process.snapshot.phase, .offline)
    }

    func testRestrictedApprovalIsOnceOnlyAndDuplicateStageIsIgnored() async throws {
        let f = try fixture(), (process, wire) = f.make()
        process.start()
        try await f.waitUntil { process.snapshot.phase == .ready }
        process.notify()
        try await f.waitUntil { process.snapshot.phase == .working && wire.turn != nil }
        let params: [String: Any] = ["sessionId": wire.session, "approvalId": "fixture-approval",
            "currentRequirementId": ["approvalId": "fixture-approval", "sourceIndex": 0],
            "availableChoices": [["choiceId": "persistent", "decision": "approvedForSession", "scope": "session"],
                                 ["choiceId": "once", "decision": "approved", "scope": "once"]]]
        wire.emit(["method": "approval/requested", "params": params])
        wire.emit(["method": "approval/updated", "params": params])
        try await f.waitUntil { wire.count("approval/decide") >= 1 }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(wire.count("approval/decide"), 1)
        XCTAssertEqual(wire.calls.first { $0.0 == "approval/decide" }?.1["choiceId"] as? String, "once")
        XCTAssertEqual(process.snapshot.phase, .working)
    }

    func testChangingModelStartsFreshAndIncludesHistoryRecoveryInTheWake() async throws {
        let f = try fixture(), (first, previous) = f.make(model: "old-model")
        first.start()
        try await f.waitUntil { first.snapshot.phase == .ready }
        first.stop { XCTAssertTrue($0) }
        let (next, wire) = f.make(model: "new-model", recovering: true)
        next.start()
        try await f.waitUntil { wire.count("turn/start") == 1 }
        XCTAssertEqual(wire.count("session/resume"), 0)
        XCTAssertNotEqual(wire.session, previous.session)
        let inputs = try XCTUnwrap(wire.calls.first { $0.0 == "turn/start" }?.1["input"] as? [[String: String]])
        XCTAssertTrue(inputs[0]["text"]?.contains(AgentWakeReason.runtimeRecovered.eventText) == true)
        XCTAssertTrue(inputs[0]["text"]?.contains(MessengerDocumentation.recoveredModelContext) == true)
        XCTAssertEqual(try f.saved()["previousSessionIDs"] as? [String], [previous.session])
    }

    func testUnexpectedWorkspaceFailsWithoutSavingAnIncorrectSession() async throws {
        let f = try fixture(), (process, wire) = f.make()
        wire.invalidWorkspace = true
        process.start()
        try await f.waitUntil { process.snapshot.phase == .failed }
        XCTAssertEqual(f.failures, [false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state().path))
        XCTAssertEqual(wire.invalidations, 1)
    }

    private func working(_ f: MuseRuntimeFixture) async throws -> (MuseAgentProcess, MuseWireFixture) {
        let (process, wire) = f.make()
        process.start()
        try await f.waitUntil { process.snapshot.phase == .ready }
        process.notify()
        try await f.waitUntil { process.snapshot.phase == .working && wire.turn != nil }
        return (process, wire)
    }

    func testApprovalForAnotherSessionIsIgnored() async throws {
        let f = try fixture(), (process, wire) = try await working(f)
        let params: [String: Any] = ["sessionId": UUID().uuidString, "approvalId": "fixture-approval",
            "currentRequirementId": ["approvalId": "fixture-approval", "sourceIndex": 0],
            "availableChoices": [["choiceId": "once", "decision": "approved", "scope": "once"]]]
        wire.emit(["method": "approval/requested", "params": params])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(wire.count("approval/decide"), 0)
        XCTAssertEqual(process.snapshot.phase, .working)
    }

    /// Only the active turn's completion ends work; a scheduled retry is shown and work goes on.
    func testUnrelatedCompletionAndRetriesKeepWorkActive() async throws {
        let f = try fixture(), (process, wire) = try await working(f)
        wire.emit(["method": "turn/completed", "params": ["sessionId": wire.session, "turnId": UUID().uuidString,
                                                           "terminal": "completed"]])
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(process.snapshot.phase, .working)
        XCTAssertTrue(process.hasInterruptedWork, "An acknowledgement alone never completes work")
        wire.emit(["method": "turn/retryScheduled", "params": ["sessionId": wire.session, "turnId": try XCTUnwrap(wire.turn),
            "nextAttempt": 2, "maxAttempts": 10, "retryDelayMs": 60000, "reason": "HTTP 503"]])
        try await f.waitUntil { process.snapshot.detail.contains("Retry 2/10") }
        XCTAssertEqual(process.snapshot.phase, .working)
        XCTAssertTrue(process.hasInterruptedWork)
    }

    func testStoppingKeepsUnfinishedWorkAndTheNextStartRecoversIt() async throws {
        let f = try fixture(), (process, _) = try await working(f)
        process.stop { XCTAssertTrue($0) }
        XCTAssertTrue(process.hasInterruptedWork)
        let (next, wire) = f.make()
        wire.finishBeforeAcknowledgement = true
        next.start()
        try await f.waitUntil { next.snapshot.phase == .ready && !next.hasInterruptedWork }
        XCTAssertEqual(wire.count("session/resume"), 1)
        let inputs = try XCTUnwrap(wire.calls.first { $0.0 == "turn/start" }?.1["input"] as? [[String: String]])
        XCTAssertEqual(inputs.first?["text"], AgentWakeReason.runtimeRecovered.eventText)
    }

    func testRejectedTurnFailsButKeepsTheWorkToRecover() async throws {
        let f = try fixture(), (process, wire) = f.make()
        wire.failTurn = true
        process.start()
        try await f.waitUntil { process.snapshot.phase == .ready }
        process.notify()
        try await f.waitUntil { process.snapshot.phase == .failed }
        XCTAssertTrue(process.hasInterruptedWork)
    }

    /// A runtime paused by a permanent failure takes no new turns, and stays paused after a relaunch
    /// instead of starting yet another session.
    func testPermanentFailurePauseHoldsAcrossNotificationsAndRelaunch() async throws {
        let f = try fixture(), (process, wire) = f.make()
        wire.terminalErrors = ["projectionError", "projectionError"]
        process.start()
        try await f.waitUntil { process.snapshot.phase == .ready }
        process.notify()
        try await f.waitUntil { process.snapshot.phase == .failed }
        XCTAssertTrue(process.snapshot.detail.contains("Fixture failure"))
        let turns = wire.count("turn/start")
        process.notify()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(wire.count("turn/start"), turns)
        process.stop { XCTAssertTrue($0) }
        // The incompatible history is still there after a relaunch; recovery was already tried once.
        let (relaunched, next) = f.make()
        next.terminalErrors = ["projectionError"]
        relaunched.start()
        try await f.waitUntil { relaunched.snapshot.phase == .failed }
        XCTAssertEqual(next.count("session/start"), 0)
    }

    /// An old session pointer has no workspace. A session bound elsewhere is replaced by a fresh one here,
    /// which is told how to recover its context.
    func testLegacySessionFromAnotherWorkspaceIsReplaced() async throws {
        let f = try fixture()
        try FileManager.default.createDirectory(at: f.state().deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionID": UUID().uuidString]).write(to: f.state())
        let (process, wire) = f.make()
        wire.resumedWorkspace = f.root.path
        wire.finishBeforeAcknowledgement = true
        process.start()
        try await f.waitUntil { process.snapshot.phase == .ready && !process.hasInterruptedWork && wire.count("turn/start") == 1 }
        XCTAssertEqual(wire.count("session/resume"), 1)
        XCTAssertEqual(wire.count("session/start"), 1)
        let inputs = try XCTUnwrap(wire.calls.first { $0.0 == "turn/start" }?.1["input"] as? [[String: String]])
        XCTAssertTrue(inputs.first?["text"]?.contains(MessengerDocumentation.recoveredModelContext) == true)
    }
}
