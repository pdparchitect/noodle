import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class ClaudeRuntimeTests: XCTestCase {
    private func fixture() throws -> HarnessRuntimeFixture {
        let f = try HarnessRuntimeFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }
    private func ready(_ f: HarnessRuntimeFixture, _ wire: HarnessWire, _ p: ClaudeAgentProcess) async throws {
        p.start(); try await f.wait { p.canReceiveHeartbeat }
    }
    private func confirm(_ wire: HarnessWire) throws {
        wire.emit(["type": "system", "subtype": "init", "session_id": try XCTUnwrap(wire.launches.last?.2).uuidString])
    }
    private func complete(_ wire: HarnessWire, session: UUID? = nil, failed: Bool = false) throws {
        wire.emit(["type": "result", "session_id": try (session ?? XCTUnwrap(wire.launches.last?.2)).uuidString,
                   "is_error": failed, "result": failed ? "Fixture task failed" : "done"])
    }

    func testRestrictedStartupPersistsAndResumesItsOwnSession() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.claude(wire, extended: false)
        XCTAssertFalse(p.isAlive)
        try await ready(f, wire, p)
        XCTAssertEqual(wire.launches.first?.1, false)
        XCTAssertTrue(p.isAlive)
        try confirm(wire)
        try await f.wait { FileManager.default.fileExists(atPath: f.state(.claudeCode, extended: false).path) }
        p.notify(); try await f.wait { wire.count("user") == 1 }
        try complete(wire); try await f.wait { p.canReceiveHeartbeat }
        p.stop()
        XCTAssertFalse(p.isAlive)
        let next = HarnessWire(), resumed = f.claude(next, extended: false)
        try await ready(f, next, resumed)
        XCTAssertEqual(next.launches.first?.1, false)
        XCTAssertEqual(next.launches.first?.2, wire.launches.first?.2)
        XCTAssertEqual(next.launches.first?.3, true)
        resumed.stop()
        let other = HarnessWire(), autonomous = f.claude(other)
        try await ready(f, other, autonomous)
        XCTAssertEqual(other.launches.first?.1, true)
        XCTAssertNotEqual(other.launches.first?.2, wire.launches.first?.2)
        XCTAssertEqual(other.launches.first?.3, false)
        XCTAssertTrue(f.failures.isEmpty)
    }

    func testRestrictedStartupFailureDoesNotRetryWithAutonomousAccess() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.claude(wire, extended: false)
        wire.automaticStart = false
        p.start()
        wire.startReply?(0, "Private login unavailable")
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertEqual(wire.launches.count, 1)
        XCTAssertEqual(wire.launches.first?.1, false)
        XCTAssertFalse(p.isAlive)
    }

    func testAppsSelectionReachesNewAndResumedRuntimesInBothAccessModes() async throws {
        for extended in [false, true] {
            let f = try fixture()
            for (index, apps) in [false, true, false].enumerated() {
                let wire = HarnessWire(), process = f.claude(wire, extended: extended, apps: apps)
                try await ready(f, wire, process)
                XCTAssertEqual(wire.appSelections, [apps])
                XCTAssertEqual(wire.launches.first?.1, extended)
                XCTAssertEqual(wire.launches.first?.3, index > 0)
                try confirm(wire)
                try await f.wait { FileManager.default.fileExists(atPath: f.state(.claudeCode, extended: extended).path) }
                await f.drain(); process.stop()
            }
        }
    }

    func testSessionIsSavedOnlyAfterConfirmationAndThenResumed() async throws {
        let f = try fixture(), wire = HarnessWire(), first = f.claude(wire)
        try await ready(f, wire, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state(.claudeCode).path))
        try confirm(wire); try await f.wait { FileManager.default.fileExists(atPath: f.state(.claudeCode).path) }
        first.stop()
        let next = HarnessWire(), second = f.claude(next)
        try await ready(f, next, second)
        XCTAssertEqual(next.launches.first?.2, wire.launches.first?.2)
        XCTAssertEqual(next.launches.first?.3, true)
    }

    func testWrongSessionConfirmationFailsWithoutWritingState() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.claude(wire)
        try await ready(f, wire, p)
        wire.emit(["type": "system", "subtype": "init", "session_id": UUID().uuidString])
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertEqual(f.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state(.claudeCode).path))
    }

    func testSessionPersistenceFailureDisconnectsWithoutLosingPendingTurn() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.claude(wire)
        try FileManager.default.createDirectory(at: f.state(.claudeCode), withIntermediateDirectories: true)
        p.notify(); try await f.wait { wire.count("user") == 1 }
        try confirm(wire); try await f.wait { p.snapshot.phase == .failed }
        XCTAssertEqual(f.failures.first?.1, true)
        XCTAssertTrue(f.recovery(.claudeCode).hasUnfinishedTurn)
    }

    func testQueuedNotificationsCoalesceAndForeignResultsAreIgnored() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.claude(wire)
        try await ready(f, wire, p); p.notify(); p.notify(); p.notify()
        try complete(wire, session: UUID()); await f.drain()
        XCTAssertEqual(wire.count("user"), 1)
        XCTAssertTrue(f.recovery(.claudeCode).hasUnfinishedTurn)
        try complete(wire); try await f.wait { wire.count("user") == 2 }
        try complete(wire, failed: true); try await f.wait { p.canReceiveHeartbeat }
        XCTAssertFalse(f.recovery(.claudeCode).hasUnfinishedTurn)
        XCTAssertTrue(p.snapshot.detail.contains("Fixture task failed"))
    }

    func testBackgroundTasksKeepTheBotWorkingAfterItsTurnEnds() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.claude(wire)
        let session = { try XCTUnwrap(wire.launches.last?.2).uuidString }
        try await ready(f, wire, p); p.notify()
        wire.emit(["type": "system", "subtype": "background_tasks_changed", "session_id": try session(),
                   "tasks": [["task_id": "fixture-task", "task_type": "local_agent"]]])
        try complete(wire); await f.drain()
        XCTAssertEqual(p.snapshot.phase, .working)
        XCTAssertFalse(p.canReceiveHeartbeat)
        p.notify(); try await f.wait { wire.count("user") == 2 }
        try complete(wire); await f.drain()
        XCTAssertEqual(p.snapshot.phase, .working)
        wire.emit(["type": "system", "subtype": "background_tasks_changed", "session_id": try session(), "tasks": []])
        try await f.wait { p.canReceiveHeartbeat }
    }

    func testTurnClaudeStartsByItselfIsShownAndRecorded() async throws {
        var activity: [String] = []
        let f = try fixture(), wire = HarnessWire(), p = f.claude(wire) { activity.append($0["type"] as? String ?? "") }
        try await ready(f, wire, p)
        wire.emit(["type": "assistant", "session_id": try XCTUnwrap(wire.launches.last?.2).uuidString,
                   "parent_tool_use_id": NSNull(), "message": ["content": [["type": "text", "text": "Task finished"]]]])
        await f.drain()
        XCTAssertEqual(p.snapshot.phase, .working)
        XCTAssertFalse(p.canReceiveHeartbeat)
        XCTAssertEqual(activity, ["assistant"])
        try complete(wire); try await f.wait { p.canReceiveHeartbeat }
        XCTAssertFalse(f.recovery(.claudeCode).hasUnfinishedTurn)
    }

    func testInterruptWaitsForBothAcknowledgementAndCompletionInEitherOrder() async throws {
        for acknowledgementFirst in [false, true] {
            let f = try fixture(), wire = HarnessWire(), p = f.claude(wire)
            try await ready(f, wire, p); p.notify()
            let id = p.notify(); p.promoteNotification(id)
            let requestID = try XCTUnwrap(wire.last("control_request")["request_id"] as? String)
            let ack: [String: Any] = ["type": "control_response", "response": ["request_id": requestID, "subtype": "success"]]
            if acknowledgementFirst { wire.emit(ack) } else { try complete(wire) }
            await f.drain(); XCTAssertEqual(wire.count("user"), 1)
            if acknowledgementFirst { try complete(wire) } else { wire.emit(ack) }
            try await f.wait { wire.count("user") == 2 }
            XCTAssertEqual(wire.count("control_request"), 1)
        }
    }

    func testRejectedInterruptDefersWithoutRepeatedRequests() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.claude(wire)
        try await ready(f, wire, p); p.notify(); p.notify(immediately: true)
        let id = try XCTUnwrap(wire.last("control_request")["request_id"] as? String)
        wire.emit(["type": "control_response", "response": ["request_id": id, "subtype": "error"]])
        await f.drain(); XCTAssertEqual(wire.count("control_request"), 1)
        try complete(wire); try await f.wait { wire.count("user") == 2 }
    }

    func testExplicitMissingSessionClearsOnlyPointerAndPreservesRecovery() async throws {
        let f = try fixture(), old = HarnessWire(), first = f.claude(old)
        try await ready(f, old, first); try confirm(old); await f.drain(); first.stop()
        let wire = HarnessWire(), p = f.claude(wire)
        try await ready(f, wire, p); p.notify()
        let id = try XCTUnwrap(wire.launches.last?.2).uuidString
        wire.emit(["type": "result", "subtype": "error_during_execution", "is_error": true,
            "num_turns": 0, "session_id": id, "result": "No conversation found with session ID: \(id)"])
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state(.claudeCode).path))
        XCTAssertTrue(f.recovery(.claudeCode).hasUnfinishedTurn)
        XCTAssertEqual(f.failures.first?.1, true)
    }

    func testExpiredSignInPausesForSignInAndKeepsTheTurn() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.claude(wire)
        try await ready(f, wire, p); try confirm(wire)
        p.notify(); try await f.wait { wire.count("user") == 1 }
        wire.emit(["type": "result", "subtype": "error_during_execution", "is_error": true,
            "session_id": try XCTUnwrap(wire.launches.last?.2).uuidString,
            "result": "Failed to authenticate: OAuth session expired and could not be refreshed"])
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertEqual(p.snapshot.failure, .authenticationRequired)
        XCTAssertTrue(p.hasInterruptedWork)
        XCTAssertFalse(p.isAlive)
        XCTAssertTrue(f.failures.isEmpty, "Restarting cannot sign the user in")
    }

    func testSafetyStopPausesAfterTheTurnUntilKicked() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.claude(wire)
        try await ready(f, wire, p); try confirm(wire)
        p.notify(); try await f.wait { wire.count("user") == 1 }
        let session = try XCTUnwrap(wire.launches.last?.2).uuidString
        wire.emit(["type": "assistant", "session_id": session,
                   "message": ["role": "assistant", "stop_reason": "refusal", "content": []]])
        await f.drain()
        XCTAssertEqual(p.snapshot.phase, .working, "Claude Code continues once after a refusal")
        try complete(wire)
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertEqual(p.snapshot.failure, .safetyStop)
        XCTAssertTrue(p.isAlive, "A paused bot must not look lost, or the coordinator restarts it")
        XCTAssertFalse(p.hasInterruptedWork, "Kick must not replay the stopped turn")
        XCTAssertTrue(f.failures.isEmpty)
        p.notify(); p.heartbeat(); await f.drain()
        XCTAssertEqual(wire.launches.count, 1, "New messages wait for Kick")
        XCTAssertEqual(wire.count("user"), 1)

        var stopped: Bool?
        p.stop { stopped = $0 }
        try await f.wait { stopped == true }
        XCTAssertFalse(p.isAlive)
        let next = HarnessWire(), resumed = f.claude(next)
        try await ready(f, next, resumed)
        XCTAssertEqual(next.launches.first?.2, wire.launches.first?.2, "Resume keeps the session")
        XCTAssertEqual(next.launches.first?.3, true)
        XCTAssertFalse(next.writes.contains { $0["type"] as? String == "user" }, "The stopped turn is not replayed")
    }

    func testRestartWaitsForStopConfirmationAndIgnoresDuplicateReply() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.claude(wire)
        try await ready(f, wire, p)
        wire.automaticStop = false
        var confirmed: Bool?
        p.stop { confirmed = $0 }
        p.start()
        XCTAssertEqual(wire.launches.count, 1)
        XCTAssertFalse(p.canReceiveHeartbeat)
        let reply = try XCTUnwrap(wire.stopReply)
        reply(true); await f.drain()
        XCTAssertEqual(confirmed, true)
        p.start(); try await f.wait { p.canReceiveHeartbeat }
        reply(false); await f.drain()
        XCTAssertEqual(confirmed, true)
        XCTAssertEqual(p.snapshot.phase, .ready)
    }

    func testStoppedOrDisconnectedLaunchCannotDeliverLateWork() async throws {
        for stop in [false, true] {
            let f = try fixture(), wire = HarnessWire(), p = f.claude(wire)
            wire.automaticStart = false; p.notify()
            if stop { p.stop() } else { wire.onFailure?("Fixture disconnected") }
            await f.drain(); wire.startReply?(888, nil); await f.drain()
            XCTAssertEqual(wire.count("user"), 0)
            XCTAssertFalse(p.isAlive)
            XCTAssertEqual(p.snapshot.phase, stop ? .offline : .failed)
        }
    }
}
