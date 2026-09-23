import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class AgentActivityRuntimeTests: XCTestCase {
    func testCodexActivityFollowsOnlyCurrentThreadAndTurn() async throws {
        let f = try HarnessRuntimeFixture(), wire = HarnessWire()
        defer { f.cleanUp() }
        var received: [[String: Any]] = []
        let process = CodexAgentProcess(agent: .init(displayName: "Codex", harnessIdentifier: "codex"),
            executableURL: f.root, workspaceURL: f.workspace, extendedAccess: true, recoverInterruptedWork: false,
            onSnapshot: { _ in }, onHeartbeat: {}, onUnexpectedTermination: { _, _, _ in },
            onActivity: { received.append($0) }, makeConnection: { wire }, sleep: { try await f.clock.sleep($0) })
        f.processes.append(process)
        process.start()
        try await f.openCodex(wire)
        process.notify()
        try await f.wait { wire.count("turn/start") == 1 }
        try wire.reply("turn/start", result: ["turn": ["id": "current"]])
        await f.drain()
        for (thread, turn) in [("other-thread", "current"), ("fixture-thread", "old-turn"), ("fixture-thread", "current")] {
            wire.emit(["method": "item/agentMessage/delta", "params": ["threadId": thread, "turnId": turn, "itemId": "i", "delta": "hello"]])
        }
        try await f.wait { received.count == 1 }
        process.stop { _ in }
        wire.emit(["method": "item/agentMessage/delta", "params": ["threadId": "fixture-thread", "turnId": "current", "delta": "late"]])
        await f.drain()
        XCTAssertEqual(received.count, 1)
    }

    func testClaudeActivityUsesCurrentSessionAndIgnoresLateCallbacks() async throws {
        let f = try HarnessRuntimeFixture(), wire = HarnessWire()
        defer { f.cleanUp() }
        var received: [[String: Any]] = []
        let process = ClaudeAgentProcess(agent: .init(displayName: "Claude", harnessIdentifier: "claudeCode"),
            executableURL: f.root, workspaceURL: f.workspace, extendedAccess: true, recoverInterruptedWork: false,
            onSnapshot: { _ in }, onHeartbeat: {}, onUnexpectedTermination: { _, _, _ in },
            onActivity: { received.append($0) }, makeConnection: { wire }, sleep: { try await f.clock.sleep($0) })
        f.processes.append(process)
        process.start()
        try await f.wait { process.canReceiveHeartbeat }
        process.notify()
        try await f.wait { wire.count("user") == 1 }
        let session = try XCTUnwrap(wire.launches.last?.2)
        func event(_ id: UUID) -> [String: Any] {
            ["type": "assistant", "session_id": id.uuidString, "message": ["content": [["type": "text", "text": "hello"]]]]
        }
        wire.emit(event(UUID()))
        wire.emit(event(session))
        try await f.wait { received.count == 1 }
        process.stop { _ in }
        wire.emit(event(session))
        await f.drain()
        XCTAssertEqual(received.count, 1)
    }

    func testACPActivityAcrossAllProvidersValidatesSession() async throws {
        for provider in [HarnessProvider.fx, .grokBuild, .apple] {
            let f = try HarnessRuntimeFixture(), wire = HarnessWire()
            defer { f.cleanUp() }
            var received: [[String: Any]] = []
            let process = ACPAgentProcess(provider: provider,
                agent: .init(displayName: "ACP", harnessIdentifier: provider.rawValue, modelIdentifier: "fixture-model", reasoningEffort: "high"),
                executableURL: f.root, workspaceURL: f.workspace, extendedAccess: true, recoverInterruptedWork: false,
                onSnapshot: { _ in }, onHeartbeat: {}, onUnexpectedTermination: { _, _, _ in },
                onActivity: { received.append($0) }, makeConnection: { wire }, sleep: { try await f.clock.sleep($0) })
            f.processes.append(process)
            process.start()
            try await f.openACP(wire, provider: provider)
            process.notify()
            try await f.wait { wire.count("session/prompt") == 1 }
            for session in ["foreign", "fixture-session"] {
                wire.emit(["method": "session/update", "params": ["sessionId": session, "update": [
                    "sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "hello"]]]])
            }
            try await f.wait { received.count == 1 }
            XCTAssertEqual(received.count, 1, provider.rawValue)
        }
    }

    func testMuseForwardsStableItemEventsWithoutTopLevelTurnID() async throws {
        let f = try MuseRuntimeFixture(), wire = MuseWireFixture(workspace: f.workspace)
        defer { f.cleanUp() }
        let log = AgentActivityLog()
        let process = MuseAgentProcess(agent: .init(displayName: "Muse", harnessIdentifier: "muse"),
            executableURL: f.root, workspaceURL: f.workspace, extendedAccess: false, recoverInterruptedWork: false,
            onSnapshot: { _ in }, onHeartbeat: {}, onUnexpectedTermination: { _, _, _ in },
            onActivity: { AgentActivityParser.events($0, provider: .muse).forEach { log.record($0) } }, makeConnection: { wire })
        f.processes.append(process)
        process.start()
        try await f.waitUntil { process.canReceiveHeartbeat }
        process.notify()
        try await f.waitUntil { wire.turn != nil }
        wire.emit(["method": "item/delta", "params": ["sessionId": "foreign", "itemId": "i", "delta": "foreign"]])
        wire.emit(["method": "item/delta", "params": ["sessionId": wire.session, "itemId": "i", "delta": "hello"]])
        try await f.waitUntil { !log.entries.isEmpty }
        wire.emit(["method": "item/completed", "params": ["sessionId": wire.session, "item": [
            "itemId": "i", "kind": "agentMessage", "status": "completed", "revision": 2, "text": "hello world", "turnId": wire.turn!]]])
        try await f.waitUntil { log.entries.first?.detail == "hello world" }
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertFalse(log.text.contains("foreign"))
    }
}
