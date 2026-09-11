import Foundation
import NoodleCore

/// Persistent ACP transport. Agent output stays in the harness; Messenger is
/// the sole author of user-visible messages, just as for Codex and Claude.
@MainActor
final class ACPAgentProcess: AgentRuntimeProcess {
    let configuration: AgentRecord
    private let provider: HarnessProvider
    private var name: String { provider.displayName }
    private let executableURL: URL
    private let workspaceURL: URL
    private let extendedAccess: Bool
    private let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    private let onHeartbeat: @MainActor () -> Void
    private let onUnexpectedTermination: @MainActor (ACPAgentProcess, String, Bool) -> Void
    private let stateURL: URL
    private var turnRecovery: AgentTurnRecovery
    private var sessionID: String?
    private var connection: ExtendedAgentConnection?
    private var running = false
    private var stopped = false
    private var turnIsActive = false
    private var interruptRequested = false
    private var interruptTimeout: Task<Void, Never>?
    private var reviewHeld = false
    private var notifications = PendingAgentNotification()
    private var notificationPending: Bool { notifications.isPending }
    private var recoveryPending: Bool
    private var pid: Int32?
    private var sequence = 0
    private enum Purpose { case initialize, authenticate, create, load, model, effort, prompt(AgentWakeReason) }
    private var requests: [Int: Purpose] = [:]
    private var startupTimeout: Task<Void, Never>?
    private struct State: Codable { let sessionID: String }
    private lazy var trace = RuntimeTrace(agentID: configuration.id, provider: provider, workspace: workspaceURL)
    private lazy var reader = JSONLineReader { [weak self] object in
        Task { @MainActor in self?.receive(object) }
    }
    private(set) var snapshot: AgentRuntimeSnapshot

    init(provider: HarnessProvider, agent: AgentRecord, executableURL: URL, workspaceURL: URL, extendedAccess: Bool,
         recoverInterruptedWork: Bool,
         onSnapshot: @escaping @MainActor (AgentRuntimeSnapshot) -> Void,
         onHeartbeat: @escaping @MainActor () -> Void,
         onUnexpectedTermination: @escaping @MainActor (ACPAgentProcess, String, Bool) -> Void) {
        precondition(provider == .fx || provider == .grokBuild)
        self.provider = provider
        configuration = agent
        self.executableURL = executableURL
        self.workspaceURL = workspaceURL
        self.extendedAccess = extendedAccess
        self.onSnapshot = onSnapshot
        self.onHeartbeat = onHeartbeat
        self.onUnexpectedTermination = onUnexpectedTermination
        let prefix = provider == .fx ? "fx" : "grok"
        stateURL = workspaceURL.appendingPathComponent(extendedAccess ? ".agents/\(prefix)-runtime-extended.json" : ".agents/\(prefix)-runtime.json")
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
        guard extendedAccess else { update(.failed, "\(name) requires autonomous access in Settings → Security"); return }
        stopped = false
        compatibilityIssue = nil
        update(.starting, "Starting \(name)")
        trace.runtimeStarting()
        do {
            let connection = try ExtendedAgentConnection()
            self.connection = connection
            connection.onData = { [weak self] data, isError in
                Task { @MainActor in
                    guard let self else { return }
                    if isError {
                        // Classify known CLI rejections without exposing private stderr.
                        if let issue = HarnessVersionPolicy.startupIssue(provider: self.provider, text: String(decoding: data.prefix(4096), as: UTF8.self)) {
                            self.compatibilityIssue = issue
                        }
                    } else { self.reader.receive(data) }
                }
            }
            connection.onExit = { [weak self] code in Task { @MainActor in self?.terminated("Harness exited with status \(code)") } }
            connection.onFailure = { [weak self] error in Task { @MainActor in self?.terminated(error) } }
            running = true
            startupTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.terminated("Harness session startup timed out")
            }
            connection.start(provider: provider, agentID: configuration.id, executablePath: executableURL.path,
                             modelIdentifier: configuration.modelIdentifier,
                             effortIdentifier: provider == .grokBuild ? configuration.reasoningEffort : nil) { [weak self] pid, error in
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
        interruptTimeout?.cancel()
        interruptRequested = false
        trace.finish(.runtimeStopped)
        requests.removeAll()
        turnIsActive = false
        notifications.take()
        let connection = connection
        self.connection = nil
        update(.offline, "Stopped")
        if let connection { connection.stop(reply: completion) } else { completion(true) }
    }
    @discardableResult
    func notify(immediately: Bool = false) -> UUID {
        RuntimeDiagnostics.notificationQueued(agentID: configuration.id, coalesced: notificationPending)
        let notificationID = notifications.enqueue(immediately: immediately)
        if connection == nil { start() }
        sendPending()
        return notificationID
    }

    func promoteNotification(_ id: UUID) {
        notifications.promote(id)
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
        guard notificationPending, running, let sessionID else { return }
        if turnIsActive {
            guard notifications.isImmediate, !interruptRequested, snapshot.phase == .working else { return }
            interruptRequested = true
            send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionID]])
            trace.record(.turnInterruptRequested)
            interruptTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, self.interruptRequested else { return }
                self.terminated("\(self.name) did not finish cancelling its turn.")
            }
            return
        }
        guard snapshot.phase == .ready else { return }
        notifications.take()
        startTurn(.inboxChanged)
    }
    private func startTurn(_ reason: AgentWakeReason) {
        guard let sessionID, running, !turnIsActive else { return }
        do { try turnRecovery.begin() }
        catch { update(.failed, "Could not persist unfinished \(name) work: \(error.localizedDescription)"); return }
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
            guard let connection else { throw HarnessSetupError("\(name) connection closed") }
            connection.write(try JSONSerialization.data(withJSONObject: object) + Data([10]))
        } catch { terminated(error.localizedDescription) }
    }
    private func receive(_ object: [String: Any]) {
        guard !stopped, running else { return }
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            if let id = RuntimeRequestID(object["id"]) {
                if method == "session/request_permission" {
                    let response: [String: Any] = interruptRequested
                        ? ["outcome": ["outcome": "cancelled"]]
                        : FxProtocol.permissionResponse(params: params, sessionID: sessionID, extendedAccess: extendedAccess)
                    send(["jsonrpc": "2.0", "id": id.json, "result": response])
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
                catch { terminated("Could not clear \(name)'s missing session"); return }
                sessionID = nil
                openSession()
            } else if case .prompt = purpose {
                interruptTimeout?.cancel()
                interruptRequested = false
                turnIsActive = false
                trace.finish(.turnFailed)
                update(.failed, provider == .fx ? FxProtocol.turnFailureDescription(error) : "Grok Build could not complete the turn. Check its account and model, then use Retry Startup. Unfinished work is preserved.")
            } else { terminated("\(name) session setup failed. Check its sign-in and selected model in Settings.") }
            return
        }
        guard let result = object["result"] as? [String: Any] else { terminated("\(name) returned an invalid ACP response"); return }
        switch purpose {
        case .initialize:
            guard result["protocolVersion"] as? Int == 1 else { terminated("\(name) uses an unsupported ACP version"); return }
            if provider == .grokBuild {
                request(.authenticate, method: "authenticate", params: ["methodId": "cached_token"])
            } else { openSession() }
        case .authenticate:
            openSession()
        case .create, .load:
            if let returned = result["sessionId"] as? String { sessionID = returned }
            guard let sessionID, FxProtocol.validIdentifier(sessionID) else { terminated("\(name) did not identify its session"); return }
            do {
                try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(State(sessionID: sessionID)).write(to: stateURL, options: .atomic)
            } catch { terminated("Could not save the \(name) session"); return }
            if provider == .grokBuild, let model = configuration.modelIdentifier {
                request(.model, method: "session/set_model", params: ["sessionId": sessionID, "modelId": model])
            } else { configureEffort() }
        case .model:
            // Grok can return a model rejection inside a successful RPC envelope.
            if let meta = result["_meta"] as? [String: Any], let model = meta["model"] as? [String: Any], model["Err"] != nil {
                terminated("Grok Build rejected the selected model."); return
            }
            configureEffort()
        case .effort:
            sessionReady()
        case .prompt:
            guard let stopReason = result["stopReason"] as? String else { terminated("\(name) returned no turn completion reason"); return }
            let wasInterrupted = interruptRequested && stopReason == "cancelled"
            interruptRequested = false
            interruptTimeout?.cancel()
            turnIsActive = false
            guard !reviewHeld, stopReason == "end_turn" || wasInterrupted else {
                trace.finish(.turnFailed)
                update(.failed, reviewHeld ? "\(name) held tool execution: its safety reviewer is unavailable. Retry when the review service recovers." : "\(name) stopped before completing the turn. Retry Startup to resume.")
                return
            }
            do { try turnRecovery.finish() }
            catch { update(.failed, "Could not record finished \(name) work"); return }
            turnIsActive = false
            trace.finish(wasInterrupted ? .turnInterrupted : .turnCompleted)
            update(.ready, "\(name) ready")
            sendPending()
        }
    }
    private func configureEffort() {
        if provider == .grokBuild, let sessionID, let effort = configuration.reasoningEffort {
            request(.effort, method: "session/set_mode", params: ["sessionId": sessionID, "modeId": effort])
        } else { sessionReady() }
    }

    private func sessionReady() {
        startupTimeout?.cancel()
        update(.ready, "\(name) ready")
        if recoveryPending {
            recoveryPending = false
            startTurn(.runtimeRecovered)
        } else { sendPending() }
    }
    private var compatibilityIssue: String?

    private func terminated(_ detail: String) {
        interruptTimeout?.cancel()
        let detail = compatibilityIssue ?? HarnessVersionPolicy.startupIssue(provider: provider, text: detail) ?? detail
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
