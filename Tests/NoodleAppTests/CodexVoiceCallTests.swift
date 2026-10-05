import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class CodexVoiceCallTests: XCTestCase {
    private let conversationID = UUID()
    private var events: [VoiceCallEvent] = []

    private func fixture() throws -> HarnessRuntimeFixture {
        let f = try HarnessRuntimeFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }
    private func ready(_ f: HarnessRuntimeFixture, _ wire: HarnessWire, _ p: CodexAgentProcess) async throws {
        p.start(); try await f.openCodex(wire)
    }
    private func call(_ f: HarnessRuntimeFixture, _ wire: HarnessWire, _ p: CodexAgentProcess,
                      lines: [VoiceCallLine] = []) async throws {
        try p.startVoiceCall(.init(offer: "offer-sdp", voice: "juniper", conversationID: conversationID,
                                   personName: "Alex", recentLines: lines)) { [weak self] in self?.events.append($0) }
        try await f.wait { wire.count("thread/realtime/start") > 0 }
        try wire.reply("thread/realtime/start")
        await f.drain()
    }
    private func realtime(_ wire: HarnessWire, _ name: String, _ params: [String: Any] = [:], thread: String = "fixture-thread") {
        wire.emit(["method": "thread/realtime/\(name)", "params": params.merging(["threadId": thread]) { $1 }])
    }
    private func agentMessage(_ wire: HarnessWire, turn: String, _ text: String) {
        wire.emit(["method": "item/completed", "params": [
            "threadId": "fixture-thread", "turnId": turn, "item": ["type": "agentMessage", "id": UUID().uuidString, "text": text]
        ]])
    }
    private func complete(_ wire: HarnessWire, turn: String) {
        wire.emit(["method": "turn/completed", "params": ["threadId": "fixture-thread", "turn": ["id": turn, "status": "completed"]]])
    }

    func testACallAskedForWhileCodexStartsIsPlacedOnceItsThreadOpens() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        p.start()
        try p.startVoiceCall(.init(offer: "offer-sdp", voice: nil, conversationID: conversationID, personName: "Alex")) { [weak self] in
            self?.events.append($0)
        }
        await f.drain()
        XCTAssertEqual(wire.count("thread/realtime/start"), 0)
        try await f.openCodex(wire)
        try await f.wait { wire.count("thread/realtime/start") == 1 }
        let params = try XCTUnwrap(wire.last("thread/realtime/start")["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "fixture-thread")
        // Without a chosen voice Codex speaks with its own default.
        XCTAssertNil(params["voice"])
        XCTAssertEqual(wire.count("thread/realtime/listVoices"), 0)
        p.stop()

        let hungUpWire = HarnessWire(), hungUp = f.codex(hungUpWire)
        hungUp.start()
        try hungUp.startVoiceCall(.init(offer: "offer-sdp", voice: "cove", conversationID: conversationID, personName: "Alex")) { _ in }
        hungUp.endVoiceCall()
        try await f.openCodex(hungUpWire, resuming: true)
        await f.drain()
        XCTAssertEqual(hungUpWire.count("thread/realtime/start"), 0)
        XCTAssertEqual(hungUpWire.count("thread/realtime/stop"), 0)
    }

    func testCallStartsOverWebRTCWithContextAndRelaysTheAnswerAndSpokenLines() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await ready(f, wire, p)
        try await call(f, wire, p, lines: [.init(.person, "Can you check the build?"), .init(.bot, "On it.")])

        let params = try XCTUnwrap(wire.last("thread/realtime/start")["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "fixture-thread")
        XCTAssertEqual(params["outputModality"] as? String, "audio")
        XCTAssertEqual(params["version"] as? String, "v3")
        XCTAssertEqual(params["voice"] as? String, "juniper")
        XCTAssertEqual(params["clientManagedHandoffs"] as? Bool, true)
        XCTAssertEqual(params["transport"] as? [String: String], ["type": "webrtc", "sdp": "offer-sdp"])
        XCTAssertEqual(params["realtimeStartInstructions"] as? String,
                       VoiceCallDocumentation.startInstructions(conversationID: conversationID, personName: "Alex"))
        XCTAssertEqual(params["realtimeEndInstructions"] as? String, VoiceCallDocumentation.endInstructions)
        XCTAssertEqual(params["initialItems"] as? [[String: String]], [
            ["role": "user", "text": "Can you check the build?"], ["role": "assistant", "text": "On it."]
        ])

        realtime(wire, "sdp", ["sdp": "answer-sdp"])
        realtime(wire, "started", ["version": "v3"])
        realtime(wire, "transcript/done", ["role": "user", "text": " What changed? "])
        realtime(wire, "transcript/done", ["role": "assistant", "text": "Two files."], thread: "other-thread")
        realtime(wire, "transcript/done", ["role": "assistant", "text": "Two files."])
        realtime(wire, "closed")
        realtime(wire, "started")
        try await f.wait { self.events.count >= 5 }
        await f.drain()
        XCTAssertEqual(events, [.answer("answer-sdp"), .started, .line(.init(.person, "What changed?")),
                                .line(.init(.bot, "Two files.")), .ended(nil)])
    }

    func testSpokenRequestTurnIsTrackedTakesTypedMessagesAndItsAnswerIsReadAloud() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await ready(f, wire, p)
        try await call(f, wire, p)

        wire.emit(["method": "turn/started", "params": ["threadId": "fixture-thread", "turn": ["id": "voice-turn"]]])
        try await f.wait { p.snapshot.phase == .working }
        p.notify(immediately: true)
        await f.drain()
        XCTAssertEqual(wire.count("turn/start"), 0)
        XCTAssertEqual((try wire.last("turn/steer")["params"] as? [String: Any])?["expectedTurnId"] as? String, "voice-turn")
        try wire.reply("turn/steer", result: ["turnId": "voice-turn"])

        agentMessage(wire, turn: "voice-turn", "Checking now.")
        agentMessage(wire, turn: "voice-turn", "[FINAL] The build passed.")
        complete(wire, turn: "voice-turn")
        try await f.wait { p.snapshot.phase == .ready }
        let speech = try XCTUnwrap(wire.last("thread/realtime/appendSpeech")["params"] as? [String: Any])
        XCTAssertEqual(speech["text"] as? String, "The build passed.")
        XCTAssertEqual(wire.count("thread/realtime/appendSpeech"), 1)
    }

    func testOnlyAnswersToSpokenRequestsAreReadAloud() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await ready(f, wire, p)
        try await call(f, wire, p)

        p.notify(); try wire.reply("turn/start", result: ["turn": ["id": "typed-turn"]])
        try await f.wait { p.snapshot.phase == .working }
        agentMessage(wire, turn: "typed-turn", "Replied in the conversation.")
        complete(wire, turn: "typed-turn")
        try await f.wait { p.snapshot.phase == .ready }
        XCTAssertEqual(wire.count("thread/realtime/appendSpeech"), 0)

        p.notify(); try wire.reply("turn/start", result: ["turn": ["id": "joined-turn"]])
        try await f.wait { p.snapshot.phase == .working }
        realtime(wire, "itemAdded", ["item": ["handoff_id": "handoff-one", "input_transcript": "and rename it"]])
        agentMessage(wire, turn: "joined-turn", "Renamed it.")
        complete(wire, turn: "joined-turn")
        try await f.wait { p.snapshot.phase == .ready }
        XCTAssertEqual((try wire.last("thread/realtime/appendSpeech")["params"] as? [String: Any])?["text"] as? String, "Renamed it.")

        p.endVoiceCall()
        p.notify(); try wire.reply("turn/start", result: ["turn": ["id": "after-call"]])
        try await f.wait { p.snapshot.phase == .working }
        wire.emit(["method": "turn/started", "params": ["threadId": "fixture-thread", "turn": ["id": "after-call"]]])
        agentMessage(wire, turn: "after-call", "Done.")
        complete(wire, turn: "after-call")
        try await f.wait { p.snapshot.phase == .ready }
        XCTAssertEqual(wire.count("thread/realtime/appendSpeech"), 1)
    }

    func testTypedTextReachesTheCallAndHangingUpStopsItQuietly() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await ready(f, wire, p)
        XCTAssertTrue(p.canReceiveHeartbeat)
        try await call(f, wire, p)
        // Heartbeats and session rollover would interrupt the call.
        XCTAssertFalse(p.canReceiveHeartbeat)

        p.sendToVoiceCall("Sent in the conversation during the call:\nhere it is")
        let typed = try XCTUnwrap(wire.last("thread/realtime/appendText")["params"] as? [String: Any])
        XCTAssertEqual(typed["threadId"] as? String, "fixture-thread")
        XCTAssertEqual(typed["text"] as? String, "Sent in the conversation during the call:\nhere it is")

        p.endVoiceCall()
        XCTAssertEqual((try wire.last("thread/realtime/stop")["params"] as? [String: Any])?["threadId"] as? String, "fixture-thread")
        realtime(wire, "closed")
        p.sendToVoiceCall("too late")
        await f.drain()
        XCTAssertEqual(events, [])
        XCTAssertEqual(wire.count("thread/realtime/appendText"), 1)
        XCTAssertTrue(p.canReceiveHeartbeat)
    }

    func testCallErrorsReachThePersonAsTheirMessageOnly() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await ready(f, wire, p)
        try await call(f, wire, p)
        realtime(wire, "error", ["message": "{\n  \"error\": {\n    \"message\": \"Invalid SDP offer.\",\n    \"code\": \"invalid_offer\"\n  }\n}"])
        await f.drain()
        try await call(f, wire, p)
        realtime(wire, "error", ["message": "realtime voice `marin` is not supported for v3"])
        await f.drain()
        XCTAssertEqual(events, [.ended("Invalid SDP offer."), .ended("realtime voice `marin` is not supported for v3")])
    }

    func testFailedStartAndStoppedRuntimeEndTheCallWithoutFailingTheBot() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.codex(wire)
        try await ready(f, wire, p)
        try p.startVoiceCall(.init(offer: "offer-sdp", voice: "cove", conversationID: conversationID, personName: "Alex")) { [weak self] in
            self?.events.append($0)
        }
        try await f.wait { wire.count("thread/realtime/start") > 0 }
        try wire.reply("thread/realtime/start", error: ["code": -32600, "message": "Invalid SDP offer."])
        await f.drain()
        XCTAssertEqual(events, [.ended("Invalid SDP offer.")])
        XCTAssertEqual(p.snapshot.phase, .ready)

        events = []
        try await call(f, wire, p)
        p.stop()
        XCTAssertEqual(events.count, 1)
        guard case .ended(let detail) = events.first else { return XCTFail("The call did not end") }
        XCTAssertNotNil(detail)
        XCTAssertThrowsError(try p.startVoiceCall(.init(offer: "o", voice: "cove", conversationID: conversationID, personName: "Alex")) { _ in })
    }
}
