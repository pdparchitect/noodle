import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class AntigravityRuntimeTests: XCTestCase {
    private let conversation = "8dd9b97a-fa4d-41e8-932b-b2446bfde88a"

    private func fixture() throws -> HarnessRuntimeFixture {
        let f = try HarnessRuntimeFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }
    private func ready(_ f: HarnessRuntimeFixture, _ p: AntigravityAgentProcess) async throws {
        p.start(); try await f.wait { p.canReceiveHeartbeat }
    }
    private func prompts(_ wire: HarnessWire) -> Int { wire.writes.filter { $0["event"] as? String == "user" }.count }
    private func initialize(_ wire: HarnessWire, _ id: String? = nil) {
        wire.emit(["event": "init", "conversation_id": id ?? conversation, "init": ["cwd": "/w", "permission_mode": "always-proceed"]])
    }
    private func complete(_ wire: HarnessWire, status: String = "SUCCESS", error: String? = nil) {
        var result: [String: Any] = ["conversation_id": conversation, "status": status, "response": "done\n"]
        result["error"] = error
        wire.emit(["event": "result", "result": result])
    }

    func testConversationIsSavedFromInitAndResumedInTheSameAccessMode() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.antigravity(wire, extended: false)
        try await ready(f, p)
        XCTAssertEqual(wire.launches.first?.0, .antigravity)
        XCTAssertEqual(wire.launches.first?.1, false)
        XCTAssertNil(wire.launches.first?.2)
        XCTAssertEqual(wire.launches.first?.3, false)
        initialize(wire)
        try await f.wait { FileManager.default.fileExists(atPath: f.state(.antigravity, extended: false).path) }
        p.stop()

        let next = HarnessWire(), resumed = f.antigravity(next, extended: false)
        try await ready(f, resumed)
        XCTAssertEqual(next.launches.first?.2, UUID(uuidString: conversation))
        XCTAssertEqual(next.launches.first?.3, true)
        // The CLI replaces a conversation it no longer has; its answer is what resumes next.
        let replacement = UUID()
        initialize(next, replacement.uuidString)
        try await f.wait { AntigravitySessionState(url: f.state(.antigravity, extended: false)).conversationID == replacement }
        resumed.stop()

        let other = HarnessWire(), autonomous = f.antigravity(other)
        try await ready(f, autonomous)
        XCTAssertNil(other.launches.first?.2)
        XCTAssertTrue(f.failures.isEmpty)
    }

    func testOneTurnPerResultAndUrgentMessagesWaitForTheTurnToEnd() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.antigravity(wire)
        try await ready(f, p)
        initialize(wire)
        p.notify(); try await f.wait { self.prompts(wire) == 1 }
        XCTAssertEqual(p.snapshot.phase, .working)
        XCTAssertTrue(f.recovery(.antigravity).hasUnfinishedTurn)
        let content = ((wire.writes.last?["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["type"] as? String, "text")

        // The stream has no interrupt; nothing but prompts is ever written.
        p.notify(immediately: true); await f.drain()
        XCTAssertEqual(wire.writes.count, 1)
        complete(wire); try await f.wait { self.prompts(wire) == 2 }
        complete(wire); try await f.wait { p.canReceiveHeartbeat }
        XCTAssertFalse(f.recovery(.antigravity).hasUnfinishedTurn)
        p.heartbeat(); try await f.wait { self.prompts(wire) == 3 }
        XCTAssertEqual(f.heartbeats, 1)
    }

    func testFailedTurnKeepsTheRuntimeAndShowsTheCLIsReason() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.antigravity(wire)
        try await ready(f, p)
        p.notify(); try await f.wait { self.prompts(wire) == 1 }
        complete(wire, status: "ERROR", error: "model unavailable")
        try await f.wait { p.canReceiveHeartbeat }
        XCTAssertTrue(p.snapshot.detail.contains("model unavailable"))
        XCTAssertTrue(p.isAlive)
        XCTAssertTrue(f.failures.isEmpty)
    }

    func testSignedOutPausesForSignInWithoutRestarting() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.antigravity(wire)
        try await ready(f, p)
        p.notify(); try await f.wait { self.prompts(wire) == 1 }
        wire.onData?(Data("Error: authentication required. Run 'agy' to log in, then retry.\n".utf8), true)
        await f.drain()
        wire.onExit?(1)
        try await f.wait { p.snapshot.phase == .failed }
        XCTAssertEqual(p.snapshot.failure, .authenticationRequired)
        XCTAssertTrue(p.hasInterruptedWork)
        XCTAssertTrue(f.failures.isEmpty)
    }

    func testUnexpectedExitReportsTheErrorAndUnfinishedWork() async throws {
        let f = try fixture(), wire = HarnessWire(), p = f.antigravity(wire)
        try await ready(f, p)
        p.notify(); try await f.wait { self.prompts(wire) == 1 }
        wire.onData?(Data("Failed to start: listen tcp 127.0.0.1:0: bind: operation not permitted\n".utf8), true)
        await f.drain()
        wire.onExit?(1)
        try await f.wait { !f.failures.isEmpty }
        XCTAssertTrue(f.failures[0].0.contains("operation not permitted"))
        XCTAssertTrue(f.failures[0].1)
        XCTAssertNil(p.snapshot.failure)
    }

    func testActivityShowsTextAndToolsFromACapturedTurn() throws {
        func event(_ text: String) throws -> [AgentActivityEvent] {
            let message = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            return AgentActivityParser.events(message, provider: .antigravity)
        }
        let started = try event(#"{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"echo hello-from-agy"}}}}"#)
        XCTAssertEqual(started.map(\.title), ["run_command: started"])
        XCTAssertTrue(started[0].detail.contains("echo hello-from-agy"))
        let failed = try event(#"{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"ERROR","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","error":{"type":"TOOL_ERROR","message":"permission check failed"}}}}"#)
        XCTAssertEqual(failed.map(\.title), ["run_command: failed"])
        XCTAssertEqual(failed[0].detail, "permission check failed")
        let done = try event(#"{"event":"step_update","step_update":{"conversation_id":"c","step_index":3,"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","output":"hello-from-agy\r\n"}}}"#)
        XCTAssertEqual(done.map(\.title), ["run_command: completed", "Tool output"])
        let text = try event(#"{"event":"step_update","step_update":{"conversation_id":"c","step_index":4,"state":"ACTIVE","step_type":"agent_response","text_delta":"`echo`"}}"#)
        XCTAssertEqual(text.map(\.title), ["Output"])
        XCTAssertEqual(text[0].streamID, "c:4")
        XCTAssertTrue(text[0].appending)
        XCTAssertTrue(try event(#"{"event":"step_update","step_update":{"conversation_id":"c","step_index":0,"state":"DONE","step_type":"user_input"}}"#).isEmpty)
        XCTAssertTrue(try event(#"{"event":"init","conversation_id":"c","init":{"tools":["run_command"]}}"#).isEmpty)
        XCTAssertTrue(try event(#"{"event":"result","result":{"status":"SUCCESS","response":"private reply"}}"#).isEmpty)
    }
}
