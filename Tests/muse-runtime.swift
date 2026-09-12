import Foundation
import NoodleCore

@MainActor protocol AgentRuntimeProcess: AnyObject {}

/// Deterministic wire double for the real MuseAgentProcess implementation.
/// Does not launch Muse, touch a real account, or make model calls.
@MainActor final class ExtendedAgentConnection {
    static var current: ExtendedAgentConnection?
    static var workspace = ""
    static var hold = false
    static var failTurn = false
    static var terminalError: String?
    static var repeatError = false
    static var session = MuseProtocol.commandID()
    static var resumedWorkspace: String?
    var onData: ((Data, Bool) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onFailure: ((String) -> Void)?
    var methods: [String] = []
    var prompts: [String] = []
    var turn: String?
    init() throws { Self.current = self }
    func start(provider: HarnessProvider, agentID: UUID, executablePath: String, modelIdentifier: String?,
               effortIdentifier: String?, reply: @escaping (Int32, String?) -> Void) {
        precondition(provider == .muse); reply(12345, nil)
    }
    func write(_ data: Data) {
        let request = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let method = request["method"] as! String
        methods.append(method)
        guard let id = request["id"] as? Int else { return }
        let params = request["params"] as! [String: Any]
        var result: [String: Any] = [:]
        switch method {
        case "initialize":
            result = ["schema": ["version": 1], "serverInfo": ["name": "muse"], "sessionDurability": "durable"]
        case "session/start", "session/resume":
            if method == "session/start" { Self.session = MuseProtocol.commandID() }
            precondition(params["approvalMode"] == nil, "Never override Muse's startup approval policy")
            result = ["session": ["sessionId": Self.session, "workspaceRoot": method == "session/resume" ? (Self.resumedWorkspace ?? Self.workspace) : Self.workspace, "activeTurnId": NSNull()], "pendingRequests": []]
        case "session/setModel": result = ["status": "accepted"]
        case "turn/start":
            precondition(params["ifBusy"] as? String == "queue")
            prompts.append((params["input"] as! [[String: String]])[0]["text"]!)
            if Self.failTurn {
                emit(["id": id, "error": ["code": -32030, "message": "fixture failure"]]); return
            }
            let turn = MuseProtocol.commandID(); self.turn = turn
            result = ["commandId": params["commandId"]!, "status": "accepted", "turnId": turn, "disposition": "started"]
            if let kind = Self.terminalError {
                if !Self.repeatError { Self.terminalError = nil }
                emit(["method": "turn/completed", "params": ["sessionId": Self.session, "turnId": turn,
                    "terminal": "failed", "error": ["kind": kind, "retryable": false, "message": "fixture terminal failure"]]])
            } else if !Self.hold { complete(turn: turn) } // Intentionally before the acknowledgement.
        default: preconditionFailure("Unexpected MSP method: \(method)")
        }
        emit(["id": id, "result": result])
    }
    func complete(turn: String, terminal: String = "completed") {
        emit(["method": "turn/completed", "params": ["sessionId": Self.session, "turnId": turn, "terminal": terminal]])
    }
    func emit(_ object: [String: Any]) {
        onData?(try! JSONSerialization.data(withJSONObject: object) + Data([10]), false)
    }
    func invalidate() {}
    func stop(reply: @escaping (Bool) -> Void) { reply(true) }
}

@main struct MuseRuntimeChecks {
    @MainActor static func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Timed out waiting for runtime state")
    }
    @MainActor static func main() async throws {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("muse-runtime-\(UUID())")
        let root = package.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        ExtendedAgentConnection.workspace = root.path
        let agent = AgentRecord(displayName: "Fixture", harnessIdentifier: "muse", modelIdentifier: "muse-spark-1.3", reasoningEffort: "high")
        func make(extended: Bool = true) -> MuseAgentProcess {
            MuseAgentProcess(agent: agent, executableURL: URL(fileURLWithPath: "/fixture/muse"), workspaceURL: root,
                extendedAccess: extended, recoverInterruptedWork: false, onSnapshot: { _ in }, onHeartbeat: {},
                onUnexpectedTermination: { _, _, _ in })
        }
        let restricted = make(extended: false)
        restricted.start()
        precondition(restricted.snapshot.phase == .failed && ExtendedAgentConnection.current == nil)

        let first = make(); first.start()
        await eventually { first.snapshot.phase == .ready }
        first.notify()
        await eventually { first.snapshot.phase == .ready && ExtendedAgentConnection.current!.prompts.count == 1 }
        precondition(!first.hasInterruptedWork, "Early completion must match the later ack")

        ExtendedAgentConnection.hold = true
        first.notify()
        await eventually { first.snapshot.phase == .working }
        let wire = ExtendedAgentConnection.current!
        await eventually { wire.prompts.count == 2 }
        wire.complete(turn: MuseProtocol.commandID())
        try await Task.sleep(for: .milliseconds(20))
        precondition(first.snapshot.phase == .working, "Unrelated completion must not clear active work")
        precondition(first.hasInterruptedWork, "An ack alone never completes work")
        wire.emit(["method": "turn/retryScheduled", "params": ["sessionId": ExtendedAgentConnection.session,
            "turnId": wire.turn!, "nextAttempt": 2, "maxAttempts": 10, "retryDelayMs": 60000, "reason": "HTTP 503"]])
        await eventually { first.snapshot.detail.contains("Retry 2/10") }
        precondition(first.snapshot.phase == .working && first.hasInterruptedWork)
        first.stop { precondition($0) }
        precondition(first.hasInterruptedWork, "Stopping must preserve unfinished work")

        ExtendedAgentConnection.hold = false
        let recovered = make(); recovered.start()
        await eventually { recovered.snapshot.phase == .ready && !recovered.hasInterruptedWork }
        let recoveryWire = ExtendedAgentConnection.current!
        precondition(recoveryWire.methods.contains("session/resume"))
        precondition(recoveryWire.prompts == [AgentWakeReason.runtimeRecovered.eventText])

        ExtendedAgentConnection.failTurn = true
        recovered.notify()
        await eventually { recovered.snapshot.phase == .failed }
        precondition(recovered.hasInterruptedWork, "A rejected turn must retain recovery intent")

        ExtendedAgentConnection.failTurn = false
        ExtendedAgentConnection.terminalError = "projectionError"
        let repaired = make(); repaired.start()
        await eventually { repaired.snapshot.phase == .ready && !repaired.hasInterruptedWork }
        let repairedWire = ExtendedAgentConnection.current!
        precondition(repairedWire.methods.contains("session/resume") && repairedWire.methods.contains("session/start"))
        precondition(repairedWire.prompts.count == 2)
        precondition(repairedWire.prompts.last!.contains(MessengerDocumentation.recoveredModelContext))
        let stateURL = AgentStorageLayout(workspace: root).sessionState(provider: .muse, extendedAccess: true)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
        precondition((saved["previousSessionIDs"] as! [String]).count == 1, "Preserve the incompatible session ID")
        repaired.stop { precondition($0) }

        // Model changes must not reuse opaque model history, but keep Noodle's workspace.
        let changedAgent = AgentRecord(id: agent.id, displayName: "Fixture", harnessIdentifier: "muse", modelIdentifier: "muse-spark-1.2", reasoningEffort: "high")
        let changed = MuseAgentProcess(agent: changedAgent, executableURL: URL(fileURLWithPath: "/fixture/muse"), workspaceURL: root,
            extendedAccess: true, recoverInterruptedWork: false, onSnapshot: { _ in }, onHeartbeat: {}, onUnexpectedTermination: { _, _, _ in })
        changed.start()
        await eventually { changed.snapshot.phase == .ready }
        precondition(!ExtendedAgentConnection.current!.methods.contains("session/resume"))
        changed.notify()
        await eventually { !changed.hasInterruptedWork }
        precondition(ExtendedAgentConnection.current!.prompts.last!.contains(MessengerDocumentation.recoveredModelContext))

        // A second incompatible projection and other permanent turn errors must stay
        // visibly failed, not tell the supervisor to restart forever.
        ExtendedAgentConnection.terminalError = "projectionError"
        ExtendedAgentConnection.repeatError = true
        changed.notify()
        await eventually { changed.snapshot.phase == .failed }
        precondition(changed.isAlive && changed.hasInterruptedWork)
        precondition(changed.snapshot.detail.contains("fixture terminal failure"))
        let count = ExtendedAgentConnection.current!.prompts.count
        changed.notify()
        try await Task.sleep(for: .milliseconds(20))
        precondition(ExtendedAgentConnection.current!.prompts.count == count)
        changed.stop { precondition($0) }
        let afterRelaunch = MuseAgentProcess(agent: changedAgent, executableURL: URL(fileURLWithPath: "/fixture/muse"), workspaceURL: root,
            extendedAccess: true, recoverInterruptedWork: false, onSnapshot: { _ in }, onHeartbeat: {}, onUnexpectedTermination: { _, _, _ in })
        afterRelaunch.start()
        await eventually { afterRelaunch.snapshot.phase == .failed }
        precondition(!ExtendedAgentConnection.current!.methods.contains("session/start"), "Recovery attempt must survive relaunch")
        afterRelaunch.stop { precondition($0) }

        // The legacy pointer has no workspace field. A session still bound to
        // the old package root must recover in the new workspace before work.
        ExtendedAgentConnection.terminalError = nil
        ExtendedAgentConnection.repeatError = false
        ExtendedAgentConnection.resumedWorkspace = package.path
        try JSONSerialization.data(withJSONObject: ["sessionID": ExtendedAgentConnection.session])
            .write(to: stateURL)
        let moved = make(); moved.start()
        await eventually { moved.snapshot.phase == .ready && !moved.hasInterruptedWork }
        precondition(ExtendedAgentConnection.current!.methods.contains("session/resume"))
        precondition(ExtendedAgentConnection.current!.methods.contains("session/start"))
        precondition(ExtendedAgentConnection.current!.prompts.last!.contains(MessengerDocumentation.recoveredModelContext))
        moved.stop { precondition($0) }
        ExtendedAgentConnection.resumedWorkspace = nil
        print("Muse runtime lifecycle, isolated history repair, model-change isolation, bounded recovery and permanent-failure pause passed.")
    }
}
