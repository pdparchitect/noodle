import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

/// Grok Build's paused states: confirmed context recovery, missing saved
/// sessions and usage limits. Each waits for an explicit Kick instead of
/// reconnecting, and keeps the saved session and unfinished work.
@MainActor final class GrokRecoveryTests: XCTestCase {
    private func fixture() throws -> HarnessRuntimeFixture {
        let f = try HarnessRuntimeFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }
    private func handshake(_ f: HarnessRuntimeFixture, _ wire: HarnessWire) async throws {
        try await f.wait { wire.count("initialize") == 1 }
        try wire.reply("initialize", result: ["protocolVersion": 1])
        try await f.wait { wire.count("authenticate") == 1 }
        try wire.reply("authenticate")
    }
    /// Completes startup, answering session/new or session/load with `session`.
    private func open(_ f: HarnessRuntimeFixture, _ wire: HarnessWire, _ p: ACPAgentProcess,
                      session: String, resuming: Bool) async throws {
        try await handshake(f, wire)
        let method = resuming ? "session/load" : "session/new"
        try await f.wait { wire.count(method) == 1 }
        if resuming { XCTAssertEqual(try params(wire, method)["sessionId"] as? String, session) }
        try wire.reply(method, result: ["sessionId": session])
        try await f.wait { wire.count("session/set_model") == 1 }; try wire.reply("session/set_model")
        try await f.wait { wire.count("session/set_mode") == 1 }; try wire.reply("session/set_mode")
        try await f.wait { p.snapshot.phase == .ready || p.snapshot.phase == .working }
    }
    private func params(_ wire: HarnessWire, _ method: String) throws -> [String: Any] {
        try XCTUnwrap(wire.last(method)["params"] as? [String: Any])
    }
    private func promptText(_ wire: HarnessWire) throws -> String {
        try XCTUnwrap((params(wire, "session/prompt")["prompt"] as? [[String: String]])?.first?["text"])
    }
    /// Harness output is handled in order, so once a request sent after
    /// earlier messages is answered, those messages have been handled too.
    private func barrier(_ f: HarnessRuntimeFixture, _ wire: HarnessWire) async throws {
        let id = UUID().uuidString
        wire.emit(["id": id, "method": "fixture/barrier", "params": [:]])
        try await f.wait { wire.writes.contains { $0["id"] as? String == id } }
    }
    private func savedState(_ url: URL) throws -> ACPSessionState {
        try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: url))
    }
    /// Writes a saved session that a confirmed Kick has marked for replacement.
    private func prepareConfirmedRecovery(_ f: HarnessRuntimeFixture, extended: Bool = true) throws -> (URL, String) {
        let url = f.state(.grokBuild, extended: extended), old = UUID().uuidString
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ACPSessionState(sessionID: old).save(to: url)
        try ACPSessionState.prepareRecovery(at: url, replacing: old)
        return (url, old)
    }

    /// After a confirmed replacement the new session is told to rebuild its
    /// context from Messenger, including after the first turn is cancelled.
    /// A disconnect pauses recovery; relaunching does not retry it, and only
    /// an explicit retry resumes the saved replacement exactly once.
    func testConfirmedRecoveryRebuildsContextAndRetriesOnlyWhenAllowed() async throws {
        for extended in [false, true] {
            let f = try fixture(), (url, old) = try prepareConfirmedRecovery(f, extended: extended)
            let wire = HarnessWire(), p = f.acp(wire, provider: .grokBuild, extended: extended)
            p.start(); try await open(f, wire, p, session: "replacement-session", resuming: false)
            try await f.wait { wire.count("session/prompt") == 1 }
            XCTAssertEqual(wire.count("session/load"), 0)
            let first = try promptText(wire)
            XCTAssertTrue(first.contains(AgentWakeReason.runtimeRecovered.eventText))
            XCTAssertTrue(first.contains(MessengerDocumentation.recoveredModelContext))
            XCTAssertTrue(first.contains("--list-messages"))
            XCTAssertTrue(p.hasInterruptedWork)

            p.notify(immediately: true)
            try await f.wait { wire.count("session/cancel") == 1 }
            try wire.reply("session/prompt", result: ["stopReason": "cancelled"])
            try await f.wait { wire.count("session/prompt") == 2 }
            XCTAssertTrue(try promptText(wire).contains(MessengerDocumentation.recoveredModelContext),
                          "A cancelled recovery turn has not rebuilt the context yet")

            wire.onExit?(1)
            try await f.wait { p.snapshot.failure == .recoveryFailed }
            XCTAssertTrue(f.failures.isEmpty, "Recovery failures pause instead of entering supervision")
            let marker = url.appendingPathExtension("unfinished")
            let unfinished = try Data(contentsOf: marker)
            p.stop { _ in }

            let idle = HarnessWire(), relaunched = f.acp(idle, provider: .grokBuild, extended: extended)
            relaunched.start()
            XCTAssertEqual(relaunched.snapshot.failure, .recoveryFailed)
            XCTAssertTrue(relaunched.isAlive)
            relaunched.notify(immediately: true); relaunched.heartbeat(); relaunched.start(); await f.drain()
            XCTAssertTrue(idle.launches.isEmpty, "A relaunch does not retry blocked recovery")
            XCTAssertEqual(try Data(contentsOf: marker), unfinished)
            relaunched.stop { _ in }

            try ACPSessionState.allowRecoveryRetry(at: url)
            let next = HarnessWire(), retry = f.acp(next, provider: .grokBuild, extended: extended)
            retry.start(); try await open(f, next, retry, session: "replacement-session", resuming: true)
            try await f.wait { next.count("session/prompt") == 1 }
            XCTAssertEqual(next.count("session/new"), 0)
            XCTAssertTrue(try promptText(next).contains(MessengerDocumentation.recoveredModelContext))
            try next.reply("session/prompt", result: ["stopReason": "end_turn"])
            try await f.wait { retry.canReceiveHeartbeat }
            XCTAssertFalse(retry.hasInterruptedWork)
            let saved = try savedState(url)
            XCTAssertEqual(saved.sessionID, "replacement-session")
            XCTAssertEqual(saved.previousSessionIDs, [old])
            XCTAssertFalse(saved.needsHistoryRecovery); XCTAssertFalse(saved.recoveryBlocked)

            retry.notify()
            try await f.wait { next.count("session/prompt") == 2 }
            XCTAssertFalse(try promptText(next).contains(MessengerDocumentation.recoveredModelContext))
            try next.reply("session/prompt", result: ["stopReason": "end_turn"])
            try await f.wait { retry.canReceiveHeartbeat }
            XCTAssertTrue(f.failures.isEmpty)
        }
    }

    /// When the replacement session cannot be created, recovery pauses without
    /// prompting and stays paused across a relaunch until the user retries.
    func testFailedReplacementSessionPausesAcrossRelaunch() async throws {
        let f = try fixture(), (url, old) = try prepareConfirmedRecovery(f)
        let wire = HarnessWire(), p = f.acp(wire, provider: .grokBuild)
        p.start(); try await handshake(f, wire)
        try await f.wait { wire.count("session/new") == 1 }
        try wire.reply("session/new", error: ["code": -32603, "message": "Storage unavailable"])
        try await f.wait { p.snapshot.failure == .recoveryFailed }
        XCTAssertEqual(wire.count("session/prompt"), 0)
        XCTAssertTrue(f.failures.isEmpty)
        p.stop { _ in }

        let idle = HarnessWire(), relaunched = f.acp(idle, provider: .grokBuild)
        relaunched.start()
        XCTAssertEqual(relaunched.snapshot.failure, .recoveryFailed)
        XCTAssertTrue(idle.launches.isEmpty)
        let saved = try savedState(url)
        XCTAssertNil(saved.sessionID)
        XCTAssertEqual(saved.previousSessionIDs, [old])
        XCTAssertTrue(saved.recoveryBlocked)
    }

    /// A missing saved session pauses with a Kick prompt, keeps the saved
    /// pointer and unfinished marker unchanged, ignores late transport events,
    /// and a later start resumes the same session and finishes the work.
    func testMissingSavedSessionPausesAndLaterResumesTheSameSession() async throws {
        for error: [String: Any] in [
            ["code": -32603, "message": "Path not found.",
             "data": ["code": "FS_NOT_FOUND", "detail": "/private/account/session.json"]],
            ["code": -32603, "message": "Session not found"]
        ] {
            let f = try fixture(), url = f.state(.grokBuild), session = UUID().uuidString
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let state = try JSONSerialization.data(withJSONObject: ["sessionID": session])
            try state.write(to: url)
            var marker = f.recovery(.grokBuild); try marker.begin()
            let unfinished = try Data(contentsOf: url.appendingPathExtension("unfinished"))

            let wire = HarnessWire(), p = f.acp(wire, provider: .grokBuild)
            p.start(); try await handshake(f, wire)
            try await f.wait { wire.count("session/load") == 1 }
            try wire.reply("session/load", error: error)
            try await f.wait { p.snapshot.phase == .failed }
            XCTAssertEqual(p.snapshot.failure, .missingSession(session))
            XCTAssertTrue(p.snapshot.detail.contains("saved session") && p.snapshot.detail.contains("Kick"))
            XCTAssertFalse(p.snapshot.detail.contains("/private"))
            XCTAssertTrue(p.isAlive); XCTAssertTrue(p.hasInterruptedWork); XCTAssertFalse(p.canReceiveHeartbeat)
            XCTAssertEqual(wire.invalidations, 1)
            XCTAssertEqual(wire.count("session/new"), 0); XCTAssertEqual(wire.count("session/prompt"), 0)

            let paused = p.snapshot
            p.notify(immediately: true); p.heartbeat(); p.start()
            wire.onExit?(1); wire.onFailure?("Late disconnect")
            wire.emit(["id": 3, "result": ["sessionId": "stale-session"]])
            await f.drain()
            XCTAssertEqual(p.snapshot, paused)
            XCTAssertEqual(wire.launches.count, 1); XCTAssertEqual(wire.count("session/prompt"), 0)
            XCTAssertTrue(f.failures.isEmpty)
            XCTAssertEqual(try Data(contentsOf: url), state)
            XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("unfinished")), unfinished)
            p.stop { _ in }

            let next = HarnessWire(), restarted = f.acp(next, provider: .grokBuild)
            restarted.start(); try await open(f, next, restarted, session: session, resuming: true)
            try await f.wait { next.count("session/prompt") == 1 }
            XCTAssertEqual(next.count("session/new"), 0)
            try next.reply("session/prompt", result: ["stopReason": "end_turn"])
            try await f.wait { restarted.canReceiveHeartbeat }
            XCTAssertFalse(restarted.hasInterruptedWork)
            XCTAssertFalse(f.recovery(.grokBuild).hasUnfinishedTurn)
            XCTAssertTrue(f.failures.isEmpty)
        }
    }

    /// Other session/load failures, including FX reporting FS_NOT_FOUND, go
    /// to supervision and leave the saved session untouched.
    func testOtherLoadFailuresReachSupervisionAndKeepTheSavedSession() async throws {
        for (provider, code) in [(HarnessProvider.grokBuild, "CONNECTION_TIMEOUT"), (.fx, "FS_NOT_FOUND")] {
            let f = try fixture(), first = HarnessWire(), ready = f.acp(first, provider: provider)
            ready.start(); try await f.openACP(first, provider: provider); ready.stop { _ in }
            let state = try Data(contentsOf: f.state(provider))
            let wire = HarnessWire(), p = f.acp(wire, provider: provider)
            p.start()
            try await f.wait { wire.count("initialize") == 1 }
            try wire.reply("initialize", result: ["protocolVersion": 1])
            if provider == .grokBuild { try await f.wait { wire.count("authenticate") == 1 }; try wire.reply("authenticate") }
            try await f.wait { wire.count("session/load") == 1 }
            try wire.reply("session/load", error: ["code": -32603, "message": "Internal error", "data": ["code": code]])
            try await f.wait { f.failures.count == 1 }
            XCTAssertFalse(p.isAlive)
            XCTAssertFalse(p.snapshot.detail.contains("retries are paused"))
            XCTAssertNil(p.snapshot.failure)
            XCTAssertEqual(try Data(contentsOf: f.state(provider)), state)
            XCTAssertEqual(wire.count("session/new"), 0)
        }
    }

    /// FS_NOT_FOUND from a prompt describes a tool's input, not the session:
    /// the turn fails but the transport stays open and nothing is paused.
    func testPathErrorDuringTurnIsNotAMissingSession() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.acp(wire, provider: .grokBuild)
        p.start(); try await f.openACP(wire, provider: .grokBuild); p.notify()
        try await f.wait { wire.count("session/prompt") == 1 }
        try wire.reply("session/prompt", error: ["code": -32603, "message": "Path not found.", "data": ["code": "FS_NOT_FOUND"]])
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertEqual(wire.invalidations, 0)
        XCTAssertNil(p.snapshot.failure)
        XCTAssertFalse(p.snapshot.detail.contains("saved session"))
    }

    /// Grok reports an exhausted balance through its extended session updates
    /// before the prompt ends, whether by error, an error stop reason or an
    /// exit. Each pauses without retrying, keeps the saved session and the
    /// unfinished work, and a later start resumes them.
    func testUsageLimitUpdatesPauseAndKeepWorkForKick() async throws {
        let message = "API error (status 402 Payment Required): Grok Build usage balance exhausted"
        let shapes: [(String, [String: Any])] = [
            ("prompt error", ["sessionUpdate": "retry_state", "type": "failed", "error_type": "api", "message": message]),
            ("error stop reason", ["sessionUpdate": "turn_completed", "stop_reason": "error", "agent_result": message]),
            ("exit", ["sessionUpdate": "retry_state", "type": "failed", "error_type": "api", "message": message])
        ]
        for (ending, update) in shapes {
            let f = try fixture(), wire = HarnessWire(), p = f.acp(wire, provider: .grokBuild)
            p.start(); try await f.openACP(wire, provider: .grokBuild)
            let state = try Data(contentsOf: f.state(.grokBuild))
            p.notify(); try await f.wait { wire.count("session/prompt") == 1 && p.snapshot.phase == .working }
            wire.emit(["method": "_x.ai/session/update", "params": ["sessionId": "fixture-session", "update": update]])
            try await barrier(f, wire)
            switch ending {
            case "exit": wire.onExit?(1)
            case "error stop reason": try wire.reply("session/prompt", result: ["stopReason": "error"])
            default: try wire.reply("session/prompt", error: ["code": -32603, "message": "Internal error"])
            }
            try await f.wait { p.snapshot.phase == .failed }
            XCTAssertEqual(p.snapshot.failure, .usageLimit, ending)
            XCTAssertTrue(p.snapshot.detail.contains("usage limit") && p.snapshot.detail.contains("Kick"), ending)
            XCTAssertTrue(p.isAlive); XCTAssertTrue(p.hasInterruptedWork); XCTAssertFalse(p.canReceiveHeartbeat)
            XCTAssertEqual(wire.invalidations, 1, ending)

            let paused = p.snapshot
            p.notify(immediately: true); p.heartbeat(); p.start()
            wire.onExit?(1); wire.onFailure?("Late disconnect")
            try wire.reply("session/prompt", result: ["stopReason": "end_turn"])
            await f.drain()
            XCTAssertEqual(p.snapshot, paused, ending)
            XCTAssertEqual(wire.count("session/prompt"), 1); XCTAssertEqual(wire.launches.count, 1)
            XCTAssertTrue(f.failures.isEmpty)
            XCTAssertEqual(try Data(contentsOf: f.state(.grokBuild)), state)
            p.stop { _ in }

            let next = HarnessWire(), restarted = f.acp(next, provider: .grokBuild)
            restarted.start(); try await open(f, next, restarted, session: "fixture-session", resuming: true)
            try await f.wait { next.count("session/prompt") == 1 }
            try next.reply("session/prompt", result: ["stopReason": "end_turn"])
            try await f.wait { restarted.canReceiveHeartbeat }
            XCTAssertFalse(restarted.hasInterruptedWork)
            XCTAssertFalse(restarted.snapshot.detail.contains("usage limit"))
        }
    }

    /// Billing updates only count for Grok's own session during a turn:
    /// updates while idle, for another session, or sent to FX do not pause.
    func testUsageLimitUpdatesOutsideTheActiveGrokTurnAreIgnored() async throws {
        let update: [String: Any] = ["sessionUpdate": "retry_state", "type": "failed", "error_type": "api",
                                     "message": "Grok Build usage balance exhausted"]
        for provider in [HarnessProvider.grokBuild, .fx] {
            let f = try fixture(), wire = HarnessWire(), p = f.acp(wire, provider: provider)
            p.start(); try await f.openACP(wire, provider: provider)
            wire.emit(["method": "_x.ai/session/update", "params": ["sessionId": "fixture-session", "update": update]])
            try await barrier(f, wire)
            p.notify(); try await f.wait { wire.count("session/prompt") == 1 && p.snapshot.phase == .working }
            wire.emit(["method": "_x.ai/session/update", "params": ["sessionId": "other-session", "update": update]])
            if provider == .fx {
                wire.emit(["method": "_x.ai/session/update", "params": ["sessionId": "fixture-session", "update": update]])
            }
            try await barrier(f, wire)
            try wire.reply("session/prompt", result: ["stopReason": "end_turn"])
            try await f.wait { p.canReceiveHeartbeat }
            XCTAssertEqual(wire.invalidations, 0)
            XCTAssertNil(p.snapshot.failure)
        }
    }
}
