import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class ACPRuntimeTests: XCTestCase {
    private func fixture() throws -> HarnessRuntimeFixture {
        let f = try HarnessRuntimeFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }

    func testProvidersConfigureAccessModelEffortAndResumeSavedSessions() async throws {
        for provider in [HarnessProvider.apple, .fx, .grokBuild] {
            for extended in [false, true] {
                let f = try fixture(), wire = HarnessWire(), p = f.acp(wire, provider: provider, extended: extended)
                p.start(); try await f.openACP(wire, provider: provider)
                XCTAssertTrue(p.canReceiveHeartbeat)
                XCTAssertEqual(wire.launches.first?.0, provider)
                XCTAssertEqual(wire.launches.first?.1, extended)
                p.stop { _ in }
                let next = HarnessWire(), resumed = f.acp(next, provider: provider, extended: extended)
                resumed.start(); try await f.openACP(next, provider: provider, resuming: true)
                XCTAssertEqual(next.count("session/new"), 0)
                XCTAssertTrue(resumed.canReceiveHeartbeat)
            }
        }
    }

    func testUnsupportedProtocolAndMalformedSessionNeverBecomeReady() async throws {
        for invalidVersion in [false, true] {
            let f = try fixture(), wire = HarnessWire(), p = f.acp(wire)
            p.start(); try await f.wait { wire.count("initialize") == 1 }
            try wire.reply("initialize", result: ["protocolVersion": invalidVersion ? 2 : 1])
            if !invalidVersion {
                try await f.wait { wire.count("session/new") == 1 }
                try wire.reply("session/new", result: ["sessionId": "bad session\n"])
            }
            try await f.wait { p.snapshot.phase == .failed }
            XCTAssertFalse(p.isAlive); XCTAssertEqual(f.failures.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.state(.fx).path))
        }
    }

    func testSessionWriteFailureStopsStartupBeforeSendingPendingPrompt() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.acp(wire)
        try FileManager.default.createDirectory(at: f.state(.fx), withIntermediateDirectories: true)
        p.notify(); try await f.wait { wire.count("initialize") == 1 }
        try wire.reply("initialize", result: ["protocolVersion": 1])
        try await f.wait { wire.count("session/new") == 1 }
        try wire.reply("session/new", result: ["sessionId": "fixture-session"])
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertEqual(wire.count("session/prompt"), 0)
        XCTAssertEqual(f.failures.first?.1, true)
    }

    func testMissingFXSessionStartsFreshButGrokPausesAndRetainsPointer() async throws {
        for provider in [HarnessProvider.fx, .grokBuild] {
            let f = try fixture(), old = HarnessWire(), first = f.acp(old, provider: provider)
            first.start(); try await f.openACP(old, provider: provider); first.stop { _ in }
            let wire = HarnessWire(), p = f.acp(wire, provider: provider)
            p.start(); try await f.wait { wire.count("initialize") == 1 }
            try wire.reply("initialize", result: ["protocolVersion": 1])
            if provider == .grokBuild {
                try await f.wait { wire.count("authenticate") == 1 }; try wire.reply("authenticate")
            }
            try await f.wait { wire.count("session/load") == 1 }
            try wire.reply("session/load", error: ["message": "Session not found"])
            if provider == .fx {
                try await f.wait { wire.count("session/new") == 1 }
                XCTAssertFalse(FileManager.default.fileExists(atPath: f.state(provider).path))
            } else {
                try await f.wait { p.snapshot.phase == .failed }
                XCTAssertTrue(FileManager.default.fileExists(atPath: f.state(provider).path))
                XCTAssertTrue(p.isAlive)
                p.notify(); wire.onExit?(1); await f.drain()
                XCTAssertEqual(wire.count("session/new"), 0); XCTAssertTrue(f.failures.isEmpty)
                p.stop { _ in }; XCTAssertFalse(p.isAlive)
            }
        }
    }

    func testNonMissingLoadFailureRetainsSavedPointer() async throws {
        let f = try fixture(), old = HarnessWire(), first = f.acp(old)
        first.start(); try await f.openACP(old); first.stop { _ in }
        let before = try Data(contentsOf: f.state(.fx)), wire = HarnessWire(), p = f.acp(wire)
        p.start(); try await f.wait { wire.count("initialize") == 1 }; try wire.reply("initialize", result: ["protocolVersion": 1])
        try await f.wait { wire.count("session/load") == 1 }
        try wire.reply("session/load", error: ["message": "Unauthorized private account"])
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertEqual(try Data(contentsOf: f.state(.fx)), before)
        XCTAssertEqual(wire.count("session/new"), 0)
        XCTAssertFalse(p.snapshot.detail.contains("private account"))
    }

    func testPromotedWakeCancelsOnceAndWaitsForPromptCompletion() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.acp(wire)
        p.start(); try await f.openACP(wire); p.notify()
        let id = p.notify(); p.promoteNotification(id); p.promoteNotification(id)
        XCTAssertEqual(wire.count("session/cancel"), 1)
        XCTAssertEqual(wire.count("session/prompt"), 1)
        try wire.reply("session/prompt", result: ["stopReason": "cancelled"])
        try await f.wait { wire.count("session/prompt") == 2 }
        try wire.reply("session/prompt", result: ["stopReason": "end_turn"])
        try await f.wait { p.canReceiveHeartbeat }
        XCTAssertFalse(f.recovery(.fx).hasUnfinishedTurn)
    }

    func testPermissionRepliesAreSessionScopedOnceOnlyAndCancelledDuringInterrupt() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.acp(wire, extended: false)
        p.start(); try await f.openACP(wire); p.notify()
        for (id, session) in [("foreign", "other-session"), ("allowed", "fixture-session")] {
            wire.emit(["id": id, "method": "session/request_permission", "params": ["sessionId": session,
                "options": [["kind": "allow_always", "optionId": "forever"], ["kind": "allow_once", "optionId": "once"]]]])
        }
        await f.drain()
        func outcome(_ id: String) throws -> [String: String] {
            let reply = try XCTUnwrap(wire.writes.last { $0["id"] as? String == id })
            return try XCTUnwrap((reply["result"] as? [String: Any])?["outcome"] as? [String: String])
        }
        XCTAssertEqual(try outcome("foreign")["outcome"], "cancelled")
        XCTAssertEqual(try outcome("allowed")["optionId"], "once")
        p.notify(immediately: true)
        wire.emit(["id": "cancelled", "method": "session/request_permission", "params": ["sessionId": "fixture-session",
            "options": [["kind": "allow_once", "optionId": "once"]]]])
        wire.emit(["id": "unsupported", "method": "fs/read_text_file", "params": [:]])
        await f.drain()
        XCTAssertEqual(try outcome("cancelled")["outcome"], "cancelled")
        XCTAssertEqual((wire.writes.last { $0["id"] as? String == "unsupported" }?["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testFailedTurnPreservesMarkerAndNextRuntimeRecovers() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.acp(wire)
        p.start(); try await f.openACP(wire); p.notify()
        try wire.reply("session/prompt", error: ["message": "ConnectionResetByPeer"])
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertTrue(f.recovery(.fx).hasUnfinishedTurn)
        p.stop { _ in }
        let next = HarnessWire(), recovered = f.acp(next)
        recovered.start(); try await f.openACP(next, resuming: true)
        try await f.wait { next.count("session/prompt") == 1 }
        let params = try XCTUnwrap(next.last("session/prompt")["params"] as? [String: Any])
        XCTAssertEqual((params["prompt"] as? [[String: String]])?.first?["text"], AgentWakeReason.runtimeRecovered.eventText)
    }

    func testGrokUsageFailurePausesWithoutRestartAndKeepsUnfinishedWork() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.acp(wire, provider: .grokBuild)
        p.start(); try await f.openACP(wire, provider: .grokBuild); p.notify()
        try wire.reply("session/prompt", error: ["message": "Private billing account", "data": ["http_status": 402]])
        try await f.wait { p.snapshot.phase == .failed }
        wire.onExit?(1); p.notify(); await f.drain()
        XCTAssertTrue(f.failures.isEmpty)
        XCTAssertTrue(p.isAlive); XCTAssertTrue(f.recovery(.grokBuild).hasUnfinishedTurn)
        XCTAssertFalse(p.snapshot.detail.contains("Private billing"))
        XCTAssertEqual(wire.launches.count, 1)
        p.stop { _ in }; XCTAssertFalse(p.isAlive)
    }
}
