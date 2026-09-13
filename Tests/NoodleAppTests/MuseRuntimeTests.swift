import Foundation
import NoodleCore
import XCTest
@testable import Noodle

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
}
