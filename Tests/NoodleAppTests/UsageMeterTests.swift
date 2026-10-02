import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class UsageMeterTests: XCTestCase {
    /// Claude reports model usage and cost cumulatively for the whole process.
    func testClaudeResultsBecomePerTurnDifferencesPerModel() {
        var meter = UsageMeter()
        func result(_ models: [String: [String: Any]]) -> [String: Any] {
            ["type": "result", "session_id": "s", "modelUsage": models]
        }
        func model(_ input: Int, _ output: Int, _ read: Int, _ write: Int, _ cost: Double) -> [String: Any] {
            ["inputTokens": input, "outputTokens": output, "cacheReadInputTokens": read,
             "cacheCreationInputTokens": write, "thinkingTokens": 3, "costUSD": cost, "canonicalModel": "claude-opus-5-5"]
        }
        let first = meter.readings(result(["claude-opus-5-5-20260101": model(10, 50, 1000, 200, 0.5)]), provider: .claudeCode)
        XCTAssertEqual(first, [UsageReading(model: "claude-opus-5-5",
            tokens: UsageTokens(input: 10, output: 50, cacheRead: 1000, cacheWrite: 200, reasoning: 3), costUSD: 0.5, session: "s")])
        let second = meter.readings(result(["claude-opus-5-5-20260101": model(15, 80, 3000, 200, 0.75),
                                            "claude-haiku-4-5-20251001": ["inputTokens": 7, "outputTokens": 9, "costUSD": 0.01]]),
                                    provider: .claudeCode)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.first { $0.model == "claude-opus-5-5" },
                       UsageReading(model: "claude-opus-5-5", tokens: UsageTokens(input: 5, output: 30, cacheRead: 2000), costUSD: 0.25, session: "s"))
        XCTAssertEqual(second.first { $0.model == "claude-haiku-4-5-20251001" }?.tokens.total, 16)
        XCTAssertTrue(meter.readings(result(["claude-opus-5-5-20260101": model(15, 80, 3000, 200, 0.75)]), provider: .claudeCode).isEmpty)
        XCTAssertTrue(meter.readings(["type": "assistant"], provider: .claudeCode).isEmpty)
    }

    /// A resumed Claude session reports its totals from before the restart, so
    /// only what the ledger has not recorded for that session is new.
    func testResumedClaudeSessionCountsOnlyWhatWasNotRecorded() {
        var meter = UsageMeter()
        func result(_ session: String, _ output: Int, _ read: Int, _ cost: Double) -> [String: Any] {
            ["type": "result", "session_id": session, "modelUsage": ["claude-opus-5-5-20260101": [
                "inputTokens": 10, "outputTokens": output, "cacheReadInputTokens": read, "costUSD": cost,
                "canonicalModel": "claude-opus-5-5"]]]
        }
        let recorded = ["claude-opus-5-5": UsageTotal(tokens: UsageTokens(input: 10, output: 50, cacheRead: 1000), costUSD: 0.5)]
        var asked: [String] = []
        let resumed = meter.readings(result("s", 80, 3000, 0.75), provider: .claudeCode) { asked.append($0); return recorded }
        XCTAssertEqual(asked, ["s"])
        XCTAssertEqual(resumed, [UsageReading(model: "claude-opus-5-5", tokens: UsageTokens(output: 30, cacheRead: 2000),
            costUSD: 0.25, session: "s")])
        let next = meter.readings(result("s", 90, 3500, 0.875), provider: .claudeCode) { _ in recorded }
        XCTAssertEqual(next.first?.tokens, UsageTokens(output: 10, cacheRead: 500))
        XCTAssertEqual(next.first?.costUSD, 0.125)

        // Totals below what was recorded mean Claude did not restore them.
        var fresh = UsageMeter()
        XCTAssertEqual(fresh.readings(result("s", 5, 100, 0.25), provider: .claudeCode) { _ in recorded }.first?.tokens,
                       UsageTokens(input: 10, output: 5, cacheRead: 100))
    }

    func testCodexTokenUsageSeparatesCachedInput() {
        var meter = UsageMeter()
        let message: [String: Any] = ["method": "thread/tokenUsage/updated", "params": [
            "threadId": "t", "turnId": "u", "model": "gpt-5.5",
            "tokenUsage": ["last": ["inputTokens": 1000, "cachedInputTokens": 600, "outputTokens": 40,
                                    "reasoningOutputTokens": 30, "totalTokens": 1040],
                           "total": ["inputTokens": 9000, "cachedInputTokens": 0, "outputTokens": 0,
                                     "reasoningOutputTokens": 0, "totalTokens": 9000]]]]
        XCTAssertEqual(meter.readings(message, provider: .codex), [UsageReading(model: "gpt-5.5",
            tokens: UsageTokens(input: 400, output: 40, cacheRead: 600, reasoning: 30), costUSD: nil)])
        XCTAssertTrue(meter.readings(["method": "item/completed", "params": [:]], provider: .codex).isEmpty)
    }

    /// ACP's per-turn usage arrives with the prompt response; its session cost is cumulative and not used.
    func testACPPromptUsageKeepsCachedTokensApart() {
        var meter = UsageMeter()
        let message: [String: Any] = ["model": "big-pickle", "result": ["stopReason": "end_turn", "usage": [
            "inputTokens": 99, "outputTokens": 16, "totalTokens": 12147, "cachedReadTokens": 12032,
            "cachedWriteTokens": 5, "thoughtTokens": 7]]]
        for provider in [HarnessProvider.openCode, .grokBuild, .fx] {
            XCTAssertEqual(meter.readings(message, provider: provider), [UsageReading(model: "big-pickle",
                tokens: UsageTokens(input: 99, output: 16, cacheRead: 12032, cacheWrite: 5, reasoning: 7), costUSD: nil)])
        }
        let update: [String: Any] = ["method": "session/update", "params": ["sessionId": "s", "update": [
            "sessionUpdate": "usage_update", "used": 12147, "size": 200000, "cost": ["amount": 0.5, "currency": "USD"]]]]
        XCTAssertTrue(meter.readings(update, provider: .openCode).isEmpty)
    }

    func testACPForwardsPromptUsageWithTheSessionModel() async throws {
        let f = try HarnessRuntimeFixture(), wire = HarnessWire()
        defer { f.cleanUp() }
        var received: [[String: Any]] = []
        let process = ACPAgentProcess(provider: .fx, agent: .init(displayName: "ACP", harnessIdentifier: "fx"),
            executableURL: f.root, workspaceURL: f.workspace, extendedAccess: true, recoverInterruptedWork: false,
            onSnapshot: { _ in }, onHeartbeat: {}, onUnexpectedTermination: { _, _, _ in },
            onActivity: { received.append($0) }, makeConnection: { wire }, sleep: { try await f.clock.sleep($0) })
        f.processes.append(process)
        process.start()
        try await f.wait { wire.count("initialize") > 0 }
        try wire.reply("initialize", result: ["protocolVersion": 1, "agentInfo": ["version": "2.0.7"]])
        try await f.wait { wire.count("session/new") > 0 }
        try wire.reply("session/new", result: ["sessionId": "fixture-session", "models": ["currentModelId": "fx-default"]])
        try await f.wait { process.snapshot.phase == .ready }
        process.notify()
        try await f.wait { wire.count("session/prompt") == 1 }
        try wire.reply("session/prompt", result: ["stopReason": "end_turn", "usage": ["inputTokens": 3, "outputTokens": 4, "totalTokens": 7]])
        try await f.wait { process.snapshot.phase == .ready }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?["model"] as? String, "fx-default")
        XCTAssertEqual(((received.first?["result"] as? [String: Any])?["usage"] as? [String: Any])?["outputTokens"] as? Int, 4)
    }

    func testCodexForwardsTokenUsageForItsThreadWithTheThreadModel() async throws {
        let f = try HarnessRuntimeFixture(), wire = HarnessWire()
        defer { f.cleanUp() }
        var received: [[String: Any]] = []
        let process = CodexAgentProcess(agent: .init(displayName: "Codex", harnessIdentifier: "codex"),
            executableURL: f.root, workspaceURL: f.workspace, extendedAccess: true, recoverInterruptedWork: false,
            onSnapshot: { _ in }, onHeartbeat: {}, onUnexpectedTermination: { _, _, _ in },
            onActivity: { received.append($0) }, makeConnection: { wire }, sleep: { try await f.clock.sleep($0) })
        f.processes.append(process)
        process.start()
        try await f.wait { wire.count("initialize") > 0 }
        try wire.reply("initialize")
        try await f.wait { wire.count("thread/start") > 0 }
        try wire.reply("thread/start", result: ["thread": ["id": "fixture-thread"], "model": "gpt-5.5"])
        try await f.wait { wire.count("thread/name/set") > 0 }
        try wire.reply("thread/name/set")
        try await f.wait { process.snapshot.phase == .ready }
        process.notify()
        try await f.wait { wire.count("turn/start") == 1 }
        try wire.reply("turn/start", result: ["turn": ["id": "current"]])
        await f.drain()
        func usage(_ thread: String, _ turn: String) -> [String: Any] {
            ["method": "thread/tokenUsage/updated", "params": ["threadId": thread, "turnId": turn,
                "tokenUsage": ["last": ["inputTokens": 1], "total": ["inputTokens": 1]]]]
        }
        wire.emit(usage("other-thread", "current"))
        wire.emit(usage("fixture-thread", "current"))
        wire.emit(["method": "turn/completed", "params": ["threadId": "fixture-thread", "turn": ["id": "current", "status": "completed"]]])
        // Usage for the last model call can arrive after the turn has completed.
        wire.emit(usage("fixture-thread", "current"))
        wire.emit(usage("fixture-thread", "older"))
        // Messages are handled in order, so once this marker is forwarded every one before it was handled.
        wire.emit(usage("fixture-thread", "current"))
        func forwarded() -> [[String: Any]] { received.filter { $0["method"] as? String == "thread/tokenUsage/updated" } }
        try await f.wait { forwarded().count >= 3 }
        XCTAssertEqual(forwarded().map { ($0["params"] as? [String: Any])?["turnId"] as? String }, ["current", "current", "current"])
        XCTAssertEqual((forwarded().first?["params"] as? [String: Any])?["model"] as? String, "gpt-5.5")
    }
}

@MainActor final class UsageHistoryTests: XCTestCase {
    func testStoreKeepsUsageReportedByTheRuntime() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        let sample = UsageSample(date: Date(), agentID: f.a.id, agentName: f.a.displayName, harness: "claude-code",
            model: "claude-opus-5-5", tokens: UsageTokens(input: 3, output: 4), costUSD: 0.01)
        let revision = f.store.usage.revision
        f.store.runtime.onUsage?(sample)
        XCTAssertEqual(f.store.usage.revision, revision + 1)
        let today = Calendar.current.startOfDay(for: Date())
        let days = f.store.usage.days(from: today, to: today.addingTimeInterval(86_400), agentID: nil)
        XCTAssertEqual(days.map(\.tokens.total), [7])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.repository.rootURL.appendingPathComponent("usage.sqlite").path))
    }

    func testRuntimeReadsWhatTheLedgerRecordedForASession() throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        f.store.runtime.onUsage?(UsageSample(date: Date(), agentID: f.a.id, agentName: f.a.displayName, harness: "claude-code",
            model: "claude-opus-5-5", tokens: UsageTokens(input: 3, output: 4), costUSD: 0.25, session: "s"))
        XCTAssertEqual(f.store.runtime.recordedUsage?("s"),
                       ["claude-opus-5-5": UsageTotal(tokens: UsageTokens(input: 3, output: 4), costUSD: 0.25)])
    }
}
