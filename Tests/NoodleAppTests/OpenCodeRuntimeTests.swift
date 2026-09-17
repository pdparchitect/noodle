import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class OpenCodeRuntimeTests: XCTestCase {
    func testBrokenProviderOutputReportsCauseAndPreservesSessionAndUnfinishedWork() async throws {
        let f = try HarnessRuntimeFixture(); defer { f.cleanUp() }
        let wire = HarnessWire(), runtime = f.acp(wire, provider: .openCode)
        runtime.start(); try await f.openACP(wire, provider: .openCode); runtime.notify()
        let session = try Data(contentsOf: f.state(.openCode))
        runtime.notify() // A queued follow-up must not turn a provider failure into a retry loop.
        try wire.reply("session/prompt", error: ["code": -32603, "message": "private request details",
            "data": ["service": "session", "errorName": "provider.invalid-output"]])
        try await f.wait { runtime.snapshot.phase == .failed }
        XCTAssertTrue(runtime.snapshot.detail.contains("incomplete or invalid response"))
        XCTAssertFalse(runtime.snapshot.detail.contains("private request details"))
        XCTAssertNil(runtime.snapshot.failure, "A model failure is not an authentication failure")
        XCTAssertEqual(try Data(contentsOf: f.state(.openCode)), session)
        XCTAssertTrue(f.recovery(.openCode).hasUnfinishedTurn)
        XCTAssertEqual(wire.count("session/prompt"), 1)
        XCTAssertTrue(f.failures.isEmpty)
        runtime.stop { _ in }
        let next = HarnessWire(), recovered = f.acp(next, provider: .openCode)
        recovered.start(); try await f.openACP(next, provider: .openCode, resuming: true)
        try await f.wait { next.count("session/prompt") == 1 }
        XCTAssertEqual(next.count("session/new"), 0)
        let params = try XCTUnwrap(next.last("session/prompt")["params"] as? [String: Any])
        let prompt = try XCTUnwrap(params["prompt"] as? [[String: Any]])
        XCTAssertEqual(prompt.first?["text"] as? String, AgentWakeReason.runtimeRecovered.eventText)
        XCTAssertTrue(f.recovery(.openCode).hasUnfinishedTurn)
        try next.reply("session/prompt", result: ["stopReason": "end_turn"])
        try await f.wait { recovered.canReceiveHeartbeat }
        XCTAssertFalse(f.recovery(.openCode).hasUnfinishedTurn)
    }

    func testMissingSessionPausesAndRetainsPointerForKick() async throws {
        let f = try HarnessRuntimeFixture(); defer { f.cleanUp() }
        let old = HarnessWire(), first = f.acp(old, provider: .openCode)
        first.start(); try await f.openACP(old, provider: .openCode); first.stop { _ in }
        let before = try Data(contentsOf: f.state(.openCode)), wire = HarnessWire(), runtime = f.acp(wire, provider: .openCode)
        runtime.start(); try await f.wait { wire.count("initialize") == 1 }
        try wire.reply("initialize", result: ["protocolVersion": 1, "agentInfo": ["version": "2.0.7"]])
        try await f.wait { wire.count("session/load") == 1 }
        try wire.reply("session/load", error: ["code": -32602, "message": "session not found: fixture-session", "data": ["sessionId": "fixture-session"]])
        try await f.wait { runtime.snapshot.phase == .failed }
        runtime.notify(); wire.onExit?(1); await f.drain()
        XCTAssertEqual(runtime.snapshot.failure, .missingSession("fixture-session"))
        XCTAssertEqual(try Data(contentsOf: f.state(.openCode)), before)
        XCTAssertEqual(wire.count("session/new"), 0)
        XCTAssertTrue(f.failures.isEmpty)
    }

    func testAuthenticationFailurePreservesUnfinishedWorkAndHidesProviderPayload() async throws {
        let f = try HarnessRuntimeFixture(); defer { f.cleanUp() }
        let wire = HarnessWire(), runtime = f.acp(wire, provider: .openCode)
        runtime.start(); try await f.openACP(wire, provider: .openCode); runtime.notify()
        try wire.reply("session/prompt", error: ["code": -32000, "message": "private account details"])
        try await f.wait { runtime.snapshot.phase == .failed }
        XCTAssertEqual(runtime.snapshot.failure, .authenticationRequired)
        XCTAssertFalse(runtime.snapshot.detail.contains("private account"))
        XCTAssertTrue(f.recovery(.openCode).hasUnfinishedTurn)
        wire.onExit?(1); runtime.notify(); await f.drain()
        XCTAssertTrue(f.failures.isEmpty)
    }

    func testRestrictedPermissionIsOnceOnlySessionScopedAndCancelsWithTurn() async throws {
        let f = try HarnessRuntimeFixture(); defer { f.cleanUp() }
        let wire = HarnessWire(), runtime = f.acp(wire, provider: .openCode, extended: false)
        runtime.start(); try await f.openACP(wire, provider: .openCode); runtime.notify()
        func permission(_ id: String, session: String = "fixture-session") {
            wire.emit(["id": id, "method": "session/request_permission", "params": ["sessionId": session,
                "options": [["kind": "allow_always", "optionId": "always"], ["kind": "allow_once", "optionId": "once"]]]])
        }
        func outcome(_ id: String) -> [String: String]? {
            (wire.writes.last { $0["id"] as? String == id }?["result"] as? [String: Any])?["outcome"] as? [String: String]
        }
        permission("allowed"); permission("foreign", session: "other-bot")
        wire.emit(["id": "fs", "method": "fs/read_text_file", "params": ["path": "/private"]])
        try await f.wait { wire.writes.contains { $0["id"] as? String == "fs" && $0["error"] != nil } }
        XCTAssertEqual(outcome("allowed")?["optionId"], "once")
        XCTAssertEqual(outcome("foreign")?["outcome"], "cancelled")
        XCTAssertEqual((wire.writes.last { $0["id"] as? String == "fs" }?["error"] as? [String: Any])?["code"] as? Int, -32601)
        runtime.notify(immediately: true); permission("cancelled")
        try await f.wait { wire.writes.contains { $0["id"] as? String == "cancelled" && $0["result"] != nil } }
        XCTAssertEqual(outcome("cancelled")?["outcome"], "cancelled")
        XCTAssertEqual(wire.count("session/cancel"), 1)
        try wire.reply("session/prompt", result: ["stopReason": "cancelled"])
        try await f.wait { wire.count("session/prompt") == 2 }
        try wire.reply("session/prompt", result: ["stopReason": "end_turn"])
        try await f.wait { runtime.canReceiveHeartbeat }
    }
}
