import Foundation
import NoodleCore
import XCTest
@testable import Noodle

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

    func testRetryErrorPreservesRecoveryAndOutputRestoresWorkingState() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await active(f, wire, p)
        wire.emit(["method": "error", "params": ["threadId": "fixture-thread", "turnId": "turn-one", "willRetry": true,
            "error": ["codexErrorInfo": ["responseStreamDisconnected": [:]], "message": "Private transport detail"]]])
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertTrue(p.snapshot.detail.contains("Retrying automatically"))
        XCTAssertFalse(p.snapshot.detail.contains("Private transport"))
        XCTAssertTrue(f.recovery(.codex).hasUnfinishedTurn)
        wire.emit(["method": "item/agentMessage/delta", "params": ["threadId": "fixture-thread", "turnId": "turn-one", "delta": "hello"]])
        try await f.wait { p.snapshot.phase == .working }
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
