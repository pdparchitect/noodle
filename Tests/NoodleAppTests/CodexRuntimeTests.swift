import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class CodexRuntimeTests: XCTestCase {
    private func fixture() throws -> HarnessRuntimeFixture {
        let f = try HarnessRuntimeFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }
    private func active(_ f: HarnessRuntimeFixture, _ wire: HarnessWire, _ p: CodexAgentProcess) async throws {
        p.start(); try await f.openCodex(wire)
        p.notify(); try wire.reply("turn/start", result: ["turn": ["id": "turn-one"]])
        try await f.wait { p.snapshot.phase == .working }; await f.drain()
    }
    private func complete(_ wire: HarnessWire, thread: String = "fixture-thread", turn: String = "turn-one") {
        wire.emit(["method": "turn/completed", "params": ["threadId": thread, "turn": ["id": turn, "status": "completed"]]])
    }

    func testStartupPreservesAccessPolicyAndResumesSavedThread() async throws {
        for extended in [false, true] {
            let f = try fixture(), wire = HarnessWire(), p = f.codex(wire, extended: extended)
            p.start(); try await f.openCodex(wire)
            XCTAssertEqual(wire.launches.first?.1, extended)
            let params = try XCTUnwrap(wire.last("thread/start")["params"] as? [String: Any])
            XCTAssertEqual(params["approvalPolicy"] as? String, extended ? "on-request" : "never")
            p.heartbeat(); try wire.reply("turn/start", result: ["turn": ["id": "turn-one"]])
            try await f.wait { f.heartbeats == 1 }
            let turn = try XCTUnwrap(wire.last("turn/start")["params"] as? [String: Any])
            XCTAssertEqual((turn["sandboxPolicy"] as? [String: Any])?["type"] as? String, extended ? "workspaceWrite" : "externalSandbox")
            complete(wire); try await f.wait { p.canReceiveHeartbeat }
            p.stop()
            let next = HarnessWire(), restarted = f.codex(next, extended: extended)
            restarted.start(); try await f.openCodex(next, resuming: true)
            XCTAssertEqual(next.count("thread/start"), 0)
            XCTAssertEqual(restarted.snapshot.phase, .ready)
        }
    }

    func testCodexGetsNoGuidanceOtherHarnessesLack() async throws {
        for extended in [false, true] {
            let f = try fixture(), wire = HarnessWire(), p = f.codex(wire, extended: extended)
            p.start(); try await f.openCodex(wire)
            let params = try XCTUnwrap(wire.last("thread/start")["params"] as? [String: Any])
            XCTAssertEqual(params["developerInstructions"] as? String, MessengerDocumentation.bootstrapInstructions)
            p.stop()
        }
    }

    func testAppsSelectionReachesNewAndResumedRuntimesInBothAccessModes() async throws {
        for extended in [false, true] {
            let f = try fixture()
            for (index, apps) in [false, true, false].enumerated() {
                let wire = HarnessWire(), process = f.codex(wire, extended: extended, apps: apps)
                process.start(); try await f.openCodex(wire, resuming: index > 0)
                XCTAssertEqual(wire.appSelections, [apps])
                XCTAssertEqual(wire.launches.first?.1, extended)
                process.stop()
            }
        }
    }

    /// A rejected resume starts a fresh thread whose first turn rebuilds context.
    /// The new thread is saved at once, but recovery stays pending until Codex
    /// acknowledges that turn.
    func testRejectedResumeStartsFreshWithHistoryRecovery() async throws {
        let f = try fixture(), old = HarnessWire(), first = f.codex(old)
        first.start(); try await f.openCodex(old); first.stop()
        let wire = HarnessWire(), p = f.codex(wire)
        p.start(); try await f.wait { wire.count("initialize") == 1 }; try wire.reply("initialize")
        try await f.wait { wire.count("thread/resume") == 1 }
        try wire.reply("thread/resume", error: ["message": "Thread not found"])
        try await f.wait { wire.count("thread/start") == 1 }
        try wire.reply("thread/start", result: ["thread": ["id": "replacement"]])
        try await f.wait { wire.count("thread/name/set") == 1 }; try wire.reply("thread/name/set")
        try await f.wait { wire.count("turn/start") == 1 }
        let params = try XCTUnwrap(wire.last("turn/start")["params"] as? [String: Any])
        let input = try XCTUnwrap(params["input"] as? [[String: String]])
        XCTAssertTrue(input[0]["text"]?.contains(MessengerDocumentation.recoveredModelContext) == true)
        XCTAssertTrue(f.recovery(.codex).hasUnfinishedTurn)
        func saved() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.state(.codex))) as? [String: Any])
        }
        XCTAssertEqual(try saved()["threadID"] as? String, "replacement")
        XCTAssertEqual(try saved()["needsHistoryRecovery"] as? Bool, true, "Recovery stays pending until Codex accepts the turn")
        try wire.reply("turn/start", result: ["turn": ["id": "turn-one"]])
        try await f.wait { (try? saved()["needsHistoryRecovery"] as? Bool) == false }
        XCTAssertEqual(try saved()["threadID"] as? String, "replacement")
    }

    func testFailedSessionSaveDoesNotContinueStartupOrSubmitQueuedWork() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        let state = f.state(.codex)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        p.notify()
        try await f.wait { wire.count("initialize") == 1 }; try wire.reply("initialize")
        try await f.wait { wire.count("thread/start") == 1 }
        try wire.reply("thread/start", result: ["thread": ["id": "unsaved"]])
        await f.drain()
        XCTAssertEqual(p.snapshot.phase, .failed)
        XCTAssertEqual(wire.count("thread/name/set"), 0)
        XCTAssertEqual(wire.count("turn/start"), 0)
        XCTAssertTrue(p.hasInterruptedWork)
    }

    func testLateLaunchReplyAfterDisconnectDoesNotInitialize() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        wire.automaticStart = false; p.start()
        wire.onFailure?("Disconnected during launch")
        try await f.wait { p.snapshot.phase == .failed }
        wire.startReply?(999, nil); await f.drain()
        XCTAssertEqual(wire.count("initialize"), 0)
        XCTAssertEqual(f.failures.count, 1)
        XCTAssertTrue(p.snapshot.detail.contains("Disconnected during launch"))
    }

    func testCompletionBeforeAcknowledgementAndDuplicateCompletionFinishOnce() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        p.start(); try await f.openCodex(wire); p.notify()
        complete(wire)
        try wire.reply("turn/start", result: ["turn": ["id": "turn-one"]])
        try await f.wait { p.canReceiveHeartbeat }
        complete(wire); await f.drain()
        XCTAssertFalse(f.recovery(.codex).hasUnfinishedTurn)
        XCTAssertEqual(wire.count("turn/start"), 1)
    }

    func testForeignCompletionDoesNotClearWorkAndQueuedNotificationWaits() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await active(f, wire, p); p.notify()
        complete(wire, thread: "someone-else"); complete(wire, turn: "old-turn"); await f.drain()
        XCTAssertEqual(wire.count("turn/start"), 1)
        XCTAssertTrue(f.recovery(.codex).hasUnfinishedTurn)
        complete(wire); try await f.wait { wire.count("turn/start") == 2 }
    }

    func testRejectedSteerDefersNotificationUntilTurnCompletes() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await active(f, wire, p)
        let id = p.notify(); p.promoteNotification(id)
        XCTAssertEqual(wire.count("turn/steer"), 1)
        try wire.reply("turn/steer", error: ["message": "Turn already ending"]); await f.drain()
        XCTAssertEqual(wire.count("turn/steer"), 1)
        complete(wire); try await f.wait { wire.count("turn/start") == 2 }
    }

    /// A queued message promoted before Codex acknowledges the turn steers only
    /// once the turn ID is known. If the turn ends while the steer is in flight
    /// the bot takes no heartbeat until the steer is answered, and a rejected
    /// steer becomes a follow-up turn. An accepted steer adds no extra turn.
    func testSteeringWaitsForTurnAcknowledgementAndSteerReply() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        p.start(); try await f.openCodex(wire); p.notify()
        try await f.wait { wire.count("turn/start") == 1 }
        p.notify(immediately: true); await f.drain()
        XCTAssertEqual(wire.count("turn/steer"), 0)
        try wire.reply("turn/start", result: ["turn": ["id": "turn-one"]])
        try await f.wait { wire.count("turn/steer") == 1 }
        XCTAssertEqual((try wire.last("turn/steer")["params"] as? [String: Any])?["expectedTurnId"] as? String, "turn-one")
        complete(wire); try await f.wait { p.snapshot.phase == .ready }; await f.drain()
        XCTAssertFalse(p.canReceiveHeartbeat, "The unanswered steer still holds the message")
        XCTAssertEqual(wire.count("turn/start"), 1)
        try wire.reply("turn/steer", error: ["message": "Turn no longer active"])
        try await f.wait { wire.count("turn/start") == 2 }
        try wire.reply("turn/start", result: ["turn": ["id": "turn-two"]])
        try await f.wait { p.snapshot.phase == .working }
        complete(wire, turn: "stale-turn"); await f.drain()
        XCTAssertEqual(p.snapshot.phase, .working)
        complete(wire, turn: "turn-two"); try await f.wait { p.canReceiveHeartbeat }

        p.notify(); try await f.wait { wire.count("turn/start") == 3 }
        try wire.reply("turn/start", result: ["turn": ["id": "turn-three"]])
        await f.drain()
        p.notify(immediately: true)
        try await f.wait { wire.count("turn/steer") == 2 }
        try wire.reply("turn/steer", result: ["turnId": "turn-three"]); await f.drain()
        complete(wire, turn: "turn-three"); try await f.wait { p.canReceiveHeartbeat }
        XCTAssertEqual(wire.count("turn/start"), 3)
    }

    /// Retry errors apply only to the current thread's active turn and never
    /// rewrite the saved thread. An error before the turn acknowledgement still
    /// applies once acknowledged. A final error keeps the unfinished marker
    /// until Codex reports the failed turn, which clears it but stays failed.
    func testRetryErrorsAreScopedToTheActiveTurnAndKeepUnfinishedWork() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await active(f, wire, p)
        let state = try Data(contentsOf: f.state(.codex))
        func retry(thread: String = "fixture-thread", turn: String = "turn-one", willRetry: Bool = true) {
            wire.emit(["method": "error", "params": ["threadId": thread, "turnId": turn, "willRetry": willRetry,
                "error": ["codexErrorInfo": ["responseStreamConnectionFailed": ["httpStatusCode": NSNull()]]]]])
        }
        retry(thread: "another-thread"); await f.drain()
        XCTAssertNil(p.snapshot.reconnectingSince)
        retry(); try await f.wait { p.snapshot.reconnectingSince != nil }
        XCTAssertTrue(p.isAlive); XCTAssertFalse(p.canReceiveHeartbeat)
        XCTAssertTrue(f.recovery(.codex).hasUnfinishedTurn)
        XCTAssertEqual(try Data(contentsOf: f.state(.codex)), state)
        complete(wire); try await f.wait { p.canReceiveHeartbeat }
        XCTAssertFalse(f.recovery(.codex).hasUnfinishedTurn)
        retry(); await f.drain()
        XCTAssertEqual(p.snapshot.phase, .ready, "Errors after completion are ignored")
        XCTAssertNil(p.snapshot.reconnectingSince)

        p.notify(); try await f.wait { wire.count("turn/start") == 2 }
        retry(turn: "turn-two"); await f.drain()
        try wire.reply("turn/start", result: ["turn": ["id": "turn-two"]])
        try await f.wait { p.snapshot.reconnectingSince != nil }
        XCTAssertTrue(f.recovery(.codex).hasUnfinishedTurn)
        retry(turn: "turn-two", willRetry: false)
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertTrue(p.snapshot.detail.contains("Kick"))
        XCTAssertTrue(f.recovery(.codex).hasUnfinishedTurn)
        wire.emit(["method": "turn/completed", "params": ["threadId": "fixture-thread",
            "turn": ["id": "turn-two", "status": "failed", "error": ["message": "Connection failed"]]]])
        try await f.wait { !f.recovery(.codex).hasUnfinishedTurn }
        XCTAssertEqual(p.snapshot.phase, .failed)
        XCTAssertTrue(f.failures.isEmpty)
    }

    func testRetryErrorPreservesRecoveryAndOutputRestoresWorkingState() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await active(f, wire, p)
        wire.emit(["method": "error", "params": ["threadId": "fixture-thread", "turnId": "turn-one", "willRetry": true,
            "error": ["codexErrorInfo": ["responseStreamDisconnected": [:]], "message": "Private transport detail"]]])
        try await f.wait { p.snapshot.reconnectingSince != nil }
        XCTAssertEqual(p.snapshot.phase, .working)
        XCTAssertEqual(p.snapshot.detail, "Reconnecting…")
        XCTAssertTrue(p.snapshot.canKick)
        XCTAssertFalse(p.snapshot.detail.contains("Private transport"))
        XCTAssertTrue(f.recovery(.codex).hasUnfinishedTurn)
        wire.emit(["method": "item/agentMessage/delta", "params": ["threadId": "fixture-thread", "turnId": "turn-one", "delta": "hello"]])
        try await f.wait { p.snapshot.reconnectingSince == nil }
        complete(wire); try await f.wait { p.canReceiveHeartbeat }
        XCTAssertTrue(f.failures.isEmpty)
    }

    func testDisconnectPreservesRecoveryAndIsReportedOnlyOnce() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await active(f, wire, p)
        wire.onFailure?("Lost wire"); wire.onExit?(1)
        try await f.wait { p.snapshot.phase == .failed }; await f.drain()
        XCTAssertEqual(f.failures.count, 1); XCTAssertEqual(f.failures.first?.1, true)
        XCTAssertTrue(f.recovery(.codex).hasUnfinishedTurn)
        XCTAssertEqual(wire.invalidations, 1)
        p.stop(); complete(wire); await f.drain()
        XCTAssertEqual(p.snapshot.phase, .offline)
    }

    func testRepeatedConnectionErrorsKeepOriginalDeadlineAndDeferSteeringUntilProgress() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await active(f, wire, p)
        func retry(turn: String = "turn-one") {
            wire.emit(["method": "error", "params": ["threadId": "fixture-thread", "turnId": turn,
                "willRetry": true, "error": ["codexErrorInfo": ["responseStreamDisconnected": [:]]]]])
        }
        retry(turn: "old-turn"); await f.drain()
        XCTAssertNil(p.snapshot.reconnectingSince)
        retry(); try await f.wait { p.snapshot.reconnectingSince != nil }
        let since = p.snapshot.reconnectingSince
        f.clock.date += 599
        retry(); p.notify(immediately: true); await f.drain()
        XCTAssertEqual(p.snapshot.reconnectingSince, since)
        XCTAssertEqual(wire.count("turn/steer"), 0)
        XCTAssertFalse(p.canReceiveHeartbeat)
        wire.emit(["method": "item/agentMessage/delta", "params": ["threadId": "fixture-thread", "turnId": "old-turn"]])
        await f.drain(); XCTAssertEqual(p.snapshot.reconnectingSince, since)
        wire.emit(["method": "item/agentMessage/delta", "params": ["threadId": "fixture-thread", "turnId": "turn-one"]])
        try await f.wait { wire.count("turn/steer") == 1 }
        XCTAssertNil(p.snapshot.reconnectingSince)
        retry(); try await f.wait { p.snapshot.reconnectingSince == f.clock.date }
        complete(wire); try await f.wait { p.snapshot.phase == .ready }
        XCTAssertNil(p.snapshot.reconnectingSince)
    }

    func testTerminalAndAccountErrorsDoNotEnableConnectionRecovery() async throws {
        for info: Any in ["unauthorized", "usageLimitExceeded", "rateLimitExceeded", ["httpConnectionFailed": [:]]] {
            let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
            try await active(f, wire, p)
            wire.emit(["method": "error", "params": ["threadId": "fixture-thread", "turnId": "turn-one",
                "willRetry": info is String, "error": ["codexErrorInfo": info]]])
            try await f.wait { p.snapshot.phase == .failed }
            XCTAssertNil(p.snapshot.reconnectingSince)
            XCTAssertTrue(f.recovery(.codex).hasUnfinishedTurn)
        }
    }
    func testQuestionsAreAnsweredImmediatelyWithoutBlockingTurnCompletion() async throws {
        for extended in [false, true] {
            let f = try fixture(), wire = HarnessWire(), p = f.codex(wire, extended: extended)
            try await active(f, wire, p)
            for (id, turn) in [("current-question", "turn-one"), ("stale-question", "previous-turn")] {
                wire.emit(["id": id, "method": "item/tool/requestUserInput", "params": [
                    "threadId": "fixture-thread", "turnId": turn,
                    "questions": [["id": "choice", "question": "Which option?"]]]])
                try await f.wait { wire.writes.contains { $0["id"] as? String == id } }
                let replies = wire.writes.filter { $0["id"] as? String == id }
                XCTAssertEqual(replies.count, 1)
                let answers = try XCTUnwrap((replies.first?["result"] as? [String: Any])?["answers"] as? [String: Any])
                XCTAssertTrue(answers.isEmpty)
            }
            XCTAssertEqual(p.snapshot.phase, .working)
            XCTAssertFalse(p.snapshot.detail.contains("Waiting for your response"))
            complete(wire); try await f.wait { p.canReceiveHeartbeat }
            XCTAssertFalse(f.recovery(.codex, extended: extended).hasUnfinishedTurn)
        }
    }

    func testApprovalsHonorAccessAndRejectRequestsFromOldTurns() async throws {
        for extended in [false, true] {
            let f = try fixture(), wire = HarnessWire(), p = f.codex(wire, extended: extended)
            try await active(f, wire, p)
            for (id, turn) in [("current", "turn-one"), ("stale", "previous-turn")] {
                wire.emit(["id": id, "method": "item/commandExecution/requestApproval", "params": [
                    "threadId": "fixture-thread", "turnId": turn, "command": "fixture command"]])
            }
            try await f.wait { wire.writes.contains { $0["id"] as? String == "stale" } }
            func decision(_ id: String) -> String? {
                (wire.writes.last { $0["id"] as? String == id }?["result"] as? [String: Any])?["decision"] as? String
            }
            XCTAssertEqual(decision("current"), extended ? "accept" : "decline")
            XCTAssertEqual(decision("stale"), "decline")
        }
    }

}
