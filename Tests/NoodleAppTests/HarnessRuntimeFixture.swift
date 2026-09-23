import Foundation
import NoodleCore
import XCTest
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class HarnessWire: HarnessRuntimeConnection {
    var onData: ((Data, Bool) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onFailure: ((String) -> Void)?
    var writes: [[String: Any]] = []
    var launches: [(HarnessProvider, Bool, UUID?, Bool)] = []
    var appSelections: [Bool] = []
    var startReply: ((Int32, String?) -> Void)?
    var stopReply: ((Bool) -> Void)?
    var replacement: HarnessWire?
    var automaticStart = true
    var automaticStop = true
    var stopCalls = 0
    var invalidations = 0
    func startHarness(provider: HarnessProvider, agentID: UUID, executablePath: String,
                      extendedAccess: Bool, appsEnabled: Bool, sessionID: UUID?, resumeSession: Bool,
                      modelIdentifier: String?, effortIdentifier: String?, reply: @escaping (Int32, String?) -> Void) {
        launches.append((provider, extendedAccess, sessionID, resumeSession))
        appSelections.append(appsEnabled)
        startReply = reply
        if automaticStart { reply(1234, nil) }
    }
    func write(_ data: Data) {
        do { writes.append(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])) }
        catch { XCTFail("Invalid runtime request: \(error)") }
    }
    func emit(_ message: [String: Any]) {
        do { onData?(try JSONSerialization.data(withJSONObject: message) + Data([10]), false) }
        catch { XCTFail("Invalid fixture message: \(error)") }
    }
    func count(_ method: String) -> Int { writes.filter { $0["method"] as? String == method || $0["type"] as? String == method }.count }
    func last(_ method: String) throws -> [String: Any] {
        try XCTUnwrap(writes.last { $0["method"] as? String == method || $0["type"] as? String == method })
    }
    func reply(_ method: String, result: [String: Any] = [:], error: [String: Any]? = nil) throws {
        let id = try XCTUnwrap(last(method)["id"])
        emit(error.map { ["id": id, "error": $0] } ?? ["id": id, "result": result])
    }
    func stop(reply: @escaping (Bool) -> Void) { stopCalls += 1; stopReply = reply; if automaticStop { reply(true) } }
    func invalidate() { invalidations += 1 }
}

@MainActor final class HarnessRuntimeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-harness-\(UUID())").resolvingSymlinksInPath()
    var workspace: URL { root.appendingPathComponent("workspace") }
    var processes: [any AgentRuntimeProcess] = []
    var failures: [(String, Bool)] = []
    var heartbeats = 0
    let clock = RuntimeClockFixture()
    init() throws { try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true) }
    func state(_ provider: HarnessProvider, extended: Bool = true) -> URL {
        AgentStorageLayout(workspace: workspace).sessionState(provider: provider, extendedAccess: extended)
    }
    func recovery(_ provider: HarnessProvider, extended: Bool = true) -> AgentTurnRecovery {
        AgentTurnRecovery(sessionStateURL: state(provider, extended: extended))
    }
    func codex(_ wire: HarnessWire, extended: Bool = true, apps: Bool = false) -> CodexAgentProcess {
        let p = CodexAgentProcess(agent: agent(.codex), executableURL: root, workspaceURL: workspace,
            extendedAccess: extended, appsEnabled: apps, recoverInterruptedWork: false,
            onSnapshot: { _ in }, onHeartbeat: { [weak self] in self?.heartbeats += 1 },
            onUnexpectedTermination: { [weak self] _, detail, recovery in self?.failures.append((detail, recovery)) },
            makeConnection: { wire.replacement ?? wire }, sleep: { [clock] in try await clock.sleep($0) }, now: { [clock] in clock.date })
        processes.append(p); return p
    }
    func claude(_ wire: HarnessWire, extended: Bool = true, apps: Bool = false) -> ClaudeAgentProcess {
        let p = ClaudeAgentProcess(agent: agent(.claudeCode), executableURL: root, workspaceURL: workspace,
            extendedAccess: extended, appsEnabled: apps, recoverInterruptedWork: false,
            onSnapshot: { _ in }, onHeartbeat: { [weak self] in self?.heartbeats += 1 },
            onUnexpectedTermination: { [weak self] _, detail, recovery in self?.failures.append((detail, recovery)) },
            makeConnection: { wire.replacement ?? wire }, sleep: { [clock] in try await clock.sleep($0) })
        processes.append(p); return p
    }
    func acp(_ wire: HarnessWire, provider: HarnessProvider = .fx, extended: Bool = true) -> ACPAgentProcess {
        let p = ACPAgentProcess(provider: provider, agent: agent(provider), executableURL: root, workspaceURL: workspace,
            extendedAccess: extended, recoverInterruptedWork: false,
            onSnapshot: { _ in }, onHeartbeat: { [weak self] in self?.heartbeats += 1 },
            onUnexpectedTermination: { [weak self] _, detail, recovery in self?.failures.append((detail, recovery)) },
            makeConnection: { wire.replacement ?? wire }, sleep: { [clock] in try await clock.sleep($0) })
        processes.append(p); return p
    }
    func antigravity(_ wire: HarnessWire, extended: Bool = true) -> AntigravityAgentProcess {
        let p = AntigravityAgentProcess(agent: agent(.antigravity), executableURL: root, workspaceURL: workspace,
            extendedAccess: extended, recoverInterruptedWork: false,
            onSnapshot: { _ in }, onHeartbeat: { [weak self] in self?.heartbeats += 1 },
            onUnexpectedTermination: { [weak self] _, detail, recovery in self?.failures.append((detail, recovery)) },
            makeConnection: { wire.replacement ?? wire }, sleep: { [clock] in try await clock.sleep($0) })
        processes.append(p); return p
    }
    private func agent(_ provider: HarnessProvider) -> AgentRecord {
        .init(displayName: "Fixture bot", harnessIdentifier: provider.rawValue, modelIdentifier: provider == .openCode ? "test/fixture-model" : "fixture-model", reasoningEffort: "high")
    }
    func wait(_ predicate: () -> Bool) async throws { try await clock.waitUntil(predicate) }
    func drain() async { for _ in 0..<20 { await Task.yield() } }
    func openCodex(_ wire: HarnessWire, thread: String = "fixture-thread", resuming: Bool = false) async throws {
        try await wait { wire.count("initialize") > 0 }
        try wire.reply("initialize")
        let method = resuming ? "thread/resume" : "thread/start"
        try await wait { wire.count(method) > 0 }
        try wire.reply(method, result: ["thread": ["id": thread]])
        try await wait { wire.count("thread/name/set") > 0 }
        try wire.reply("thread/name/set")
        try await wait { self.processes.last?.snapshot.phase == .ready || self.processes.last?.snapshot.phase == .working }
    }
    func openACP(_ wire: HarnessWire, provider: HarnessProvider = .fx, resuming: Bool = false) async throws {
        try await wait { wire.count("initialize") > 0 }
        try wire.reply("initialize", result: ["protocolVersion": 1, "agentInfo": ["version": "2.0.7"]])
        if provider == .grokBuild {
            try await wait { wire.count("authenticate") > 0 }; try wire.reply("authenticate")
        }
        let method = resuming ? "session/load" : "session/new"
        try await wait { wire.count(method) > 0 }
        try wire.reply(method, result: ["sessionId": "fixture-session"])
        if provider == .openCode {
            try await wait { wire.count("session/set_config_option") == 1 }
            XCTAssertEqual((try wire.last("session/set_config_option")["params"] as? [String: Any])?["configId"] as? String, "model")
            try wire.reply("session/set_config_option")
            try await wait { wire.count("session/set_config_option") == 2 }
            XCTAssertEqual((try wire.last("session/set_config_option")["params"] as? [String: Any])?["configId"] as? String, "effort")
            try wire.reply("session/set_config_option")
        }
        if provider == .grokBuild || provider == .apple {
            try await wait { wire.count("session/set_model") > 0 }; try wire.reply("session/set_model")
        }
        if provider == .grokBuild {
            try await wait { wire.count("session/set_mode") > 0 }; try wire.reply("session/set_mode")
        }
        try await wait { self.processes.last?.snapshot.phase == .ready || self.processes.last?.snapshot.phase == .working }
    }
    func cleanUp() {
        processes.forEach { $0.stop { _ in } }
        clock.releaseAll()
        try? FileManager.default.removeItem(at: root)
    }
}
