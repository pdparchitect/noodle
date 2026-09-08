import Foundation
import NoodleCore

/// Persistent ACP transport. Agent output stays in the harness; Messenger is
/// the sole author of user-visible messages, just as for Codex and Claude.
@MainActor
final class FxAgentProcess: AgentRuntimeProcess {
    let configuration: AgentRecord
    private let executableURL: URL
    private let workspaceURL: URL
    private let extendedAccess: Bool
    private let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    private let onHeartbeat: @MainActor () -> Void
    private let onUnexpectedTermination: @MainActor (FxAgentProcess, String, Bool) -> Void
    private let stateURL: URL
    private var turnRecovery: AgentTurnRecovery
    private var sessionID: String?
    private var connection: ExtendedAgentConnection?
    private var running = false
    private var stopped = false
    private var turnIsActive = false
    private var reviewHeld = false
    private var notificationPending = false
    private var recoveryPending: Bool
    private var pid: Int32?
    private var sequence = 0
    private enum Purpose { case initialize, create, load, prompt(AgentWakeReason) }
    private var requests: [Int: Purpose] = [:]
    private var startupTimeout: Task<Void, Never>?
    private struct State: Codable { let sessionID: String }
    private lazy var trace = RuntimeTrace(agentID: configuration.id, provider: .fx, workspace: workspaceURL)
    private lazy var reader = JSONLineReader { [weak self] object in
        Task { @MainActor in self?.receive(object) }
    }
    private(set) var snapshot: AgentRuntimeSnapshot

    init(agent: AgentRecord, executableURL: URL, workspaceURL: URL, extendedAccess: Bool,
         recoverInterruptedWork: Bool,
         onSnapshot: @escaping @MainActor (AgentRuntimeSnapshot) -> Void,
         onHeartbeat: @escaping @MainActor () -> Void,
         onUnexpectedTermination: @escaping @MainActor (FxAgentProcess, String, Bool) -> Void) {
        configuration = agent
        self.executableURL = executableURL
        self.workspaceURL = workspaceURL
        self.extendedAccess = extendedAccess
        self.onSnapshot = onSnapshot
        self.onHeartbeat = onHeartbeat
        self.onUnexpectedTermination = onUnexpectedTermination
        stateURL = workspaceURL.appendingPathComponent(extendedAccess ? ".agents/fx-runtime-extended.json" : ".agents/fx-runtime.json")
        turnRecovery = AgentTurnRecovery(sessionStateURL: stateURL)
        recoveryPending = recoverInterruptedWork || turnRecovery.hasUnfinishedTurn
        if let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(State.self, from: data),
           FxProtocol.validIdentifier(state.sessionID) { sessionID = state.sessionID }
        snapshot = .init(agentID: agent.id, phase: .offline, detail: "Not started")
    }

    var isAlive: Bool { running || !extendedAccess }
    var hasInterruptedWork: Bool { recoveryPending || turnIsActive || notificationPending || turnRecovery.hasUnfinishedTurn }
    var canReceiveHeartbeat: Bool { running && snapshot.phase == .ready && !turnIsActive && !notificationPending }

    func start() {
        guard connection == nil else { return }
        guard extendedAccess else { update(.failed, "FX requires autonomous access in Settings → Security"); return }
        stopped = false
        update(.starting, "Starting FX")
        trace.runtimeStarting()
        do {
            let connection = try ExtendedAgentConnection()
            self.connection = connection
            connection.onData = { [weak self] data, isError in
                // Do not expose arbitrary stderr, which can include private config.
                guard !isError else { return }
                Task { @MainActor in self?.reader.receive(data) }
            }
            connection.onExit = { [weak self] code in Task { @MainActor in self?.terminated("FX exited with status \(code)") } }
            connection.onFailure = { [weak self] error in Task { @MainActor in self?.terminated(error) } }
            running = true
            startupTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.terminated("FX session startup timed out")
            }
            connection.start(provider: .fx, agentID: configuration.id, executablePath: executableURL.path,
                             modelIdentifier: configuration.modelIdentifier) { [weak self] pid, error in
                Task { @MainActor in
                    guard let self, !self.stopped, self.running else { return }
                    if let error { self.terminated(error); return }
                    self.pid = pid
                    self.request(.initialize, method: "initialize", params: FxProtocol.initializeParameters)
                }
            }
        } catch { terminated(error.localizedDescription) }
    }

    func stop(completion: @escaping (Bool) -> Void) {
        stopped = true
        running = false
        startupTimeout?.cancel()
        trace.finish(.runtimeStopped)
        requests.removeAll()
        turnIsActive = false
        notificationPending = false
        let connection = connection
        self.connection = nil
        update(.offline, "Stopped")
        if let connection { connection.stop(reply: completion) } else { completion(true) }
    }
    func notify() {
        RuntimeDiagnostics.notificationQueued(agentID: configuration.id, coalesced: notificationPending)
        notificationPending = true
        if connection == nil { start() }
        sendPending()
    }
    func heartbeat() { if canReceiveHeartbeat { startTurn(.heartbeat) } }
    func resolveApproval(_ approval: AgentApprovalRequest, allow: Bool, answers: [String: String]) {}

    private func openSession() {
        var params: [String: Any] = ["cwd": workspaceURL.path, "mcpServers": []]
        if let sessionID {
            params["sessionId"] = sessionID
            request(.load, method: "session/load", params: params)
        } else { request(.create, method: "session/new", params: params) }
    }
    private func sendPending() {
        guard notificationPending, running, snapshot.phase == .ready, !turnIsActive else { return }
        notificationPending = false
        startTurn(.inboxChanged)
    }
    private func startTurn(_ reason: AgentWakeReason) {
        guard let sessionID, running, !turnIsActive else { return }
        do { try turnRecovery.begin() }
        catch { update(.failed, "Could not persist unfinished FX work: \(error.localizedDescription)"); return }
        turnIsActive = true
        reviewHeld = false
        trace.begin(reason: reason)
        request(.prompt(reason), method: "session/prompt", params: ["sessionId": sessionID, "prompt": [["type": "text", "text": reason.eventText]]])
        guard running else { return }
        trace.record(.wakeSubmitted)
        if reason == .heartbeat { onHeartbeat() }
        update(.working, reason == .runtimeRecovered ? "Recovering interrupted work" : (reason == .heartbeat ? "Heartbeat: checking for follow-up work" : "Checking for new messages"))
    }
    private func request(_ purpose: Purpose, method: String, params: [String: Any]) {
        sequence += 1
        requests[sequence] = purpose
        send(["jsonrpc": "2.0", "id": sequence, "method": method, "params": params])
    }
    private func send(_ object: [String: Any]) {
        do {
            guard let connection else { throw HarnessSetupError("FX connection closed") }
            connection.write(try JSONSerialization.data(withJSONObject: object) + Data([10]))
        } catch { terminated(error.localizedDescription) }
    }
    private func receive(_ object: [String: Any]) {
        guard !stopped, running else { return }
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            if let id = RuntimeRequestID(object["id"]) {
                if method == "session/request_permission" {
                    send(["jsonrpc": "2.0", "id": id.json, "result": FxProtocol.permissionResponse(params: params, sessionID: sessionID, extendedAccess: extendedAccess)])
                } else {
                    send(["jsonrpc": "2.0", "id": id.json, "error": ["code": -32601, "message": "Unsupported client request"]])
                }
            } else if method == "session/update", params["sessionId"] as? String == sessionID, turnIsActive {
                trace.outputObserved()
                if let update = params["update"] as? [String: Any], FxProtocol.reviewWasHeld(update) { reviewHeld = true }
            }
            return
        }
        guard let id = object["id"] as? Int, let purpose = requests.removeValue(forKey: id) else { return }
        if let error = object["error"] as? [String: Any] {
            // Only an explicit missing session permits discarding its pointer.
            if case .load = purpose, error["message"] as? String == "Session not found" {
                do { try FileManager.default.removeItem(at: stateURL) }
                catch { terminated("Could not clear FX's missing session"); return }
                sessionID = nil
                openSession()
            } else if case .prompt = purpose {
                turnIsActive = false
                trace.finish(.turnFailed)
                update(.failed, FxProtocol.turnFailureDescription(error))
            } else { terminated("FX session setup failed: \(String((error["message"] as? String ?? "Unknown error").prefix(300)))") }
            return
        }
        guard let result = object["result"] as? [String: Any] else { terminated("FX returned an invalid ACP response"); return }
        switch purpose {
        case .initialize:
            guard result["protocolVersion"] as? Int == 1 else { terminated("FX uses an unsupported ACP version"); return }
            openSession()
        case .create, .load:
            if let returned = result["sessionId"] as? String { sessionID = returned }
            guard let sessionID, FxProtocol.validIdentifier(sessionID) else { terminated("FX did not identify its session"); return }
            do {
                try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(State(sessionID: sessionID)).write(to: stateURL, options: .atomic)
            } catch { terminated("Could not save the FX session"); return }
            startupTimeout?.cancel()
            update(.ready, "FX ready")
            if recoveryPending {
                recoveryPending = false
                startTurn(.runtimeRecovered)
            } else { sendPending() }
        case .prompt:
            guard let stopReason = result["stopReason"] as? String else { terminated("FX returned no turn completion reason"); return }
            turnIsActive = false
            guard !reviewHeld, stopReason == "end_turn" else {
                trace.finish(.turnFailed)
                update(.failed, reviewHeld ? "FX held tool execution: its safety reviewer is unavailable. Retry when FX's review service recovers." : "FX stopped before completing the turn. Retry Startup to resume.")
                return
            }
            do { try turnRecovery.finish() }
            catch { update(.failed, "Could not record finished FX work"); return }
            turnIsActive = false
            trace.finish(.turnCompleted)
            update(.ready, "FX ready")
            sendPending()
        }
    }
    private func terminated(_ detail: String) {
        guard !stopped else { return }
        let needsRecovery = hasInterruptedWork
        stopped = true
        running = false
        turnIsActive = false
        startupTimeout?.cancel()
        connection?.invalidate()
        connection = nil
        trace.finish(.runtimeDisconnected)
        update(.failed, detail)
        onUnexpectedTermination(self, detail, needsRecovery)
    }
    private func update(_ phase: AgentRuntimePhase, _ detail: String) {
        snapshot = .init(agentID: configuration.id, phase: phase, detail: detail, processIdentifier: pid)
        onSnapshot(snapshot)
    }
}
