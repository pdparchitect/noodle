import Foundation
import NoodleCore

/// Persistent MSP transport. Only Messenger creates chat messages; MSP events
/// drive lifecycle and recovery, never a second copy of the assistant's output.
@MainActor
final class MuseAgentProcess: AgentRuntimeProcess {
    let configuration: AgentRecord
    private let executableURL: URL
    private let workspaceURL: URL
    private let extendedAccess: Bool
    private let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    private let onHeartbeat: @MainActor () -> Void
    private let onUnexpectedTermination: @MainActor (MuseAgentProcess, String, Bool) -> Void
    private let stateURL: URL
    private var turnRecovery: AgentTurnRecovery
    private var sessionID: String?
    private var activeTurnID: String?
    private var steeringNotificationID: UUID?
    private var steeringTimeout: Task<Void, Never>?
    private var earlyCompletions: [String: [String: Any]] = [:]
    private var approvalStages = Set<String>()
    private var connection: ExtendedAgentConnection?
    private var running = false
    private var stopped = false
    private var paused = false
    private var previousSessionIDs: [String] = []
    private var projectionRecoveryAttempted = false
    private var needsHistoryRecovery = false
    private var openingExistingSession = false
    private var turnIsActive = false
    private var notifications = PendingAgentNotification()
    private var notificationPending: Bool { notifications.isPending }
    private var recoveryPending: Bool
    private var pid: Int32?
    private var sequence = 0
    private enum Purpose { case initialize, open, model, approvalDecision, prompt(String), steer(String, UUID, String) }
    private var requests: [Int: Purpose] = [:]
    private var startupTimeout: Task<Void, Never>?
    private struct State: Codable {
        let sessionID: String
        var workspaceRoot: String? = nil
        var modelIdentifier: String? = nil
        var modelRecorded: Bool? = nil
        var previousSessionIDs: [String]? = nil
        var projectionRecoveryAttempted: Bool? = nil
        var needsHistoryRecovery: Bool? = nil
    }
    private lazy var trace = RuntimeTrace(agentID: configuration.id, provider: .muse, workspace: workspaceURL)
    private lazy var reader = JSONLineReader { [weak self] object in
        Task { @MainActor in self?.receive(object) }
    }
    private(set) var snapshot: AgentRuntimeSnapshot

    init(agent: AgentRecord, executableURL: URL, workspaceURL: URL, extendedAccess: Bool,
         recoverInterruptedWork: Bool,
         onSnapshot: @escaping @MainActor (AgentRuntimeSnapshot) -> Void,
         onHeartbeat: @escaping @MainActor () -> Void,
         onUnexpectedTermination: @escaping @MainActor (MuseAgentProcess, String, Bool) -> Void) {
        configuration = agent
        self.executableURL = executableURL
        self.workspaceURL = workspaceURL
        self.extendedAccess = extendedAccess
        self.onSnapshot = onSnapshot
        self.onHeartbeat = onHeartbeat
        self.onUnexpectedTermination = onUnexpectedTermination
        stateURL = AgentStorageLayout(workspace: workspaceURL).sessionState(provider: .muse, extendedAccess: extendedAccess)
        turnRecovery = AgentTurnRecovery(sessionStateURL: stateURL)
        recoveryPending = recoverInterruptedWork || turnRecovery.hasUnfinishedTurn
        if let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(State.self, from: data),
           UUID(uuidString: state.sessionID) != nil {
            sessionID = state.sessionID
            previousSessionIDs = state.previousSessionIDs ?? []
            projectionRecoveryAttempted = state.projectionRecoveryAttempted ?? false
            needsHistoryRecovery = state.needsHistoryRecovery ?? false
            // Muse's opaque reasoning history is route-specific. Keep the old log,
            // but start fresh when the user explicitly changes the selected model.
            if (state.modelRecorded == true && state.modelIdentifier != agent.modelIdentifier) ||
                (state.workspaceRoot != nil && state.workspaceRoot != workspaceURL.path) {
                previousSessionIDs.append(state.sessionID)
                sessionID = nil
                needsHistoryRecovery = true
                projectionRecoveryAttempted = false
            }
        }
        snapshot = .init(agentID: agent.id, phase: .offline, detail: "Not started")
    }

    var isAlive: Bool { running || paused }
    var hasInterruptedWork: Bool { recoveryPending || turnIsActive || notificationPending || steeringNotificationID != nil || turnRecovery.hasUnfinishedTurn }
    var canReceiveHeartbeat: Bool { running && snapshot.phase == .ready && !turnIsActive && !notificationPending && steeringNotificationID == nil }

    func start() {
        guard connection == nil else { return }
        stopped = false; paused = false
        update(.starting, "Starting Muse Code")
        trace.runtimeStarting()
        do {
            let connection = try ExtendedAgentConnection()
            self.connection = connection
            connection.onData = { [weak self] data, isError in
                Task { @MainActor in
                    guard let self else { return }
                    if !isError { self.reader.receive(data) }
                    else if let issue = HarnessVersionPolicy.startupIssue(provider: .muse, text: String(decoding: data.prefix(4096), as: UTF8.self)) {
                        self.terminated(issue)
                    }
                }
            }
            connection.onExit = { [weak self] code in Task { @MainActor in self?.terminated("Muse Code exited with status \(code)") } }
            connection.onFailure = { [weak self] error in Task { @MainActor in self?.terminated(error) } }
            running = true
            startupTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.terminated("Muse Code session startup timed out")
            }
            let started: (Int32, String?) -> Void = { [weak self] pid, error in
                Task { @MainActor in
                    guard let self, !self.stopped, self.running else { return }
                    if let error { self.terminated(error); return }
                    self.pid = pid
                    self.request(.initialize, method: "initialize", params: MuseProtocol.initialize)
                }
            }
            if extendedAccess {
                connection.start(provider: .muse, agentID: configuration.id, executablePath: executableURL.path,
                                 modelIdentifier: configuration.modelIdentifier, effortIdentifier: configuration.reasoningEffort, reply: started)
            } else {
                connection.startRestrictedMuse(agentID: configuration.id, executablePath: executableURL.path,
                                               modelIdentifier: configuration.modelIdentifier, effortIdentifier: configuration.reasoningEffort, reply: started)
            }
        } catch { terminated(error.localizedDescription) }
    }

    func stop(completion: @escaping (Bool) -> Void) {
        stopped = true; running = false
        startupTimeout?.cancel()
        trace.finish(.runtimeStopped)
        requests.removeAll(); earlyCompletions.removeAll()
        steeringNotificationID = nil
        steeringTimeout?.cancel()
        turnIsActive = false; notifications.take()
        let connection = connection
        self.connection = nil
        update(.offline, "Stopped")
        if let connection { connection.stop(reply: completion) } else { completion(true) }
    }
    @discardableResult
    func notify(immediately: Bool = false) -> UUID {
        RuntimeDiagnostics.notificationQueued(agentID: configuration.id, coalesced: notificationPending)
        let notificationID = notifications.enqueue(immediately: immediately)
        guard !paused else { return notificationID }
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
        openingExistingSession = sessionID != nil
        var params: [String: Any] = ["commandId": MuseProtocol.commandID()]
        if let sessionID {
            params["sessionId"] = sessionID
            params["excludeItems"] = true
            request(.open, method: "session/resume", params: params)
        } else {
            params["workspaceRoot"] = workspaceURL.path
            params["providerId"] = "meta"
            if let model = configuration.modelIdentifier { params["modelId"] = model }
            request(.open, method: "session/start", params: params)
        }
    }
    private func sendPending() {
        guard notificationPending, running, steeringNotificationID == nil, let sessionID else { return }
        if turnIsActive {
            guard notifications.isImmediate, snapshot.phase == .working, let activeTurnID,
                  let notificationID = notifications.take() else { return }
            let commandID = MuseProtocol.commandID()
            steeringNotificationID = notificationID
            request(.steer(commandID, notificationID, activeTurnID), method: "turn/steer", params: [
                "commandId": commandID, "sessionId": sessionID, "expectedTurnId": activeTurnID,
                "input": [["type": "text", "text": AgentWakeReason.inboxChanged.eventText]]
            ])
            trace.record(.inboxSteerSubmitted)
            steeringTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, self.steeringNotificationID == notificationID else { return }
                self.terminated("Muse Code did not acknowledge message steering.")
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
        catch { terminated("Could not persist unfinished Muse work"); return }
        turnIsActive = true
        activeTurnID = nil
        earlyCompletions.removeAll()
        approvalStages.removeAll()
        trace.begin(reason: reason)
        let commandID = MuseProtocol.commandID()
        request(.prompt(commandID), method: "turn/start", params: MuseProtocol.turnParameters(
            sessionID: sessionID, commandID: commandID,
            text: reason.eventText + (needsHistoryRecovery ? "\n\n" + MessengerDocumentation.recoveredModelContext : ""),
            effort: configuration.reasoningEffort))
        guard running else { return }
        trace.record(.wakeSubmitted)
        if reason == .heartbeat { onHeartbeat() }
        update(.working, reason == .runtimeRecovered ? "Recovering interrupted work" : "Checking for new messages")
    }
    private func request(_ purpose: Purpose, method: String, params: [String: Any]) {
        sequence += 1; requests[sequence] = purpose
        send(["jsonrpc": "2.0", "id": sequence, "method": method, "params": params])
    }
    private func send(_ object: [String: Any]) {
        do {
            guard let connection else { throw HarnessSetupError("Muse connection closed") }
            connection.write(try JSONSerialization.data(withJSONObject: object) + Data([10]))
        } catch { terminated(error.localizedDescription) }
    }
    private func receive(_ object: [String: Any]) {
        guard !stopped, running else { return }
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            guard params["sessionId"] as? String == sessionID, sessionID != nil else { return }
            if method == "approval/requested" || method == "approval/request" || method == "approval/updated" {
                guard let decision = MuseProtocol.approvalParameters(params, sessionID: sessionID,
                                                                    extendedAccess: extendedAccess, restrictedAccess: !extendedAccess) else {
                    terminated("Muse Code requires an approval Noodle cannot safely resolve. Open the session in Muse Terminal."); return
                }
                let stage = "\(decision["approvalId"]!):\((decision["requirementId"] as! [String: Any])["sourceIndex"]!)"
                guard approvalStages.insert(stage).inserted else { return }
                request(.approvalDecision, method: "approval/decide", params: decision)
            } else if method == "userInput/requested" || method == "userInput/request" {
                terminated("Muse Code needs interactive approval or input. Check the session in Muse Terminal, then Retry Startup.")
            } else if method == "turn/retryScheduled", turnIsActive,
                      params["turnId"] as? String == activeTurnID,
                      let detail = MuseProtocol.retryDetail(params) {
                update(.working, detail)
            } else if method == "turn/completed", turnIsActive, let turnID = params["turnId"] as? String {
                if activeTurnID == nil {
                    // A fast terminal event may arrive before the turn/start ack.
                    guard earlyCompletions.count < 8 else { terminated("Muse returned too many unmatched turn results"); return }
                    earlyCompletions[turnID] = params
                } else if activeTurnID == turnID { completeTurn(params) }
            } else if method.hasPrefix("item/"), turnIsActive { trace.outputObserved() }
            return
        }
        guard let id = object["id"] as? Int, let purpose = requests.removeValue(forKey: id) else { return }
        guard object["error"] == nil, let result = object["result"] as? [String: Any] else {
            if case .steer(_, let notificationID, _) = purpose {
                steeringTimeout?.cancel()
                steeringNotificationID = nil
                notifications.restore(notificationID)
                trace.record(.inboxSteerRejected)
                sendPending()
                return
            }
            terminated("Muse Code rejected a session request. Check muse login and the selected model in Terminal, then Retry Startup. Unfinished work is preserved.")
            return
        }
        switch purpose {
        case .initialize:
            do { try MuseProtocol.validateInitialization(result, durable: true) }
            catch { terminated(error.localizedDescription); return }
            send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
            openSession()
        case .open:
            if openingExistingSession, let session = result["session"] as? [String: Any],
               session["sessionId"] as? String == sessionID,
               session["workspaceRoot"] as? String == workspaceURL.deletingLastPathComponent().path {
                // Muse sessions are bound to their original working directory.
                // Preserve the old pointer and recover from Noodle's chat history
                // in a fresh session after the flat-workspace migration.
                recoverModelContext()
                return
            }
            guard let session = result["session"] as? [String: Any], let returned = session["sessionId"] as? String,
                  UUID(uuidString: returned) != nil, sessionID == nil || sessionID == returned,
                  session["workspaceRoot"] as? String == workspaceURL.path else {
                terminated("Muse Code returned an unexpected session or workspace"); return
            }
            sessionID = returned
            do {
                try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try saveState()
            } catch { terminated("Could not save the Muse Code session"); return }
            if let pending = result["pendingRequests"] as? [Any], !pending.isEmpty {
                terminated("Muse Code has pending interactive requests. Resolve them in Muse Terminal, then Retry Startup."); return
            }
            if let active = session["activeTurnId"] as? String {
                activeTurnID = active; turnIsActive = true; recoveryPending = false
                do { try turnRecovery.begin() } catch { terminated("Could not track resumed Muse work"); return }
                startupTimeout?.cancel(); update(.working, "Resuming Muse work")
                sendPending()
                return
            }
            if openingExistingSession, let model = configuration.modelIdentifier {
                request(.model, method: "session/setModel", params: ["commandId": MuseProtocol.commandID(),
                    "sessionId": returned, "model": ["modelId": model, "providerId": "meta"]])
            } else { sessionReady() }
        case .model: sessionReady()
        case .prompt(let commandID):
            guard result["status"] as? String == "accepted", result["commandId"] as? String == commandID,
                  let turnID = result["turnId"] as? String, UUID(uuidString: turnID) != nil else {
                terminated("Muse Code returned an invalid turn acknowledgement"); return
            }
            activeTurnID = turnID
            if let completion = earlyCompletions.removeValue(forKey: turnID) { completeTurn(completion) }
            earlyCompletions.removeAll()
            sendPending()
        case .steer(let commandID, let notificationID, let expectedTurnID):
            steeringTimeout?.cancel()
            steeringNotificationID = nil
            if result["status"] as? String != "accepted" || result["commandId"] as? String != commandID ||
                result["turnId"] as? String != expectedTurnID {
                notifications.restore(notificationID)
                trace.record(.inboxSteerRejected)
            }
            sendPending()
        case .approvalDecision:
            guard result["status"] as? String == "accepted" else { terminated("Muse Code rejected a tool approval"); return }
        }
    }
    private func sessionReady() {
        startupTimeout?.cancel()
        update(.ready, "Muse Code ready")
        if recoveryPending { recoveryPending = false; startTurn(.runtimeRecovered) }
        else { sendPending() }
    }
    private func completeTurn(_ params: [String: Any]) {
        guard params["terminal"] as? String == "completed" else {
            trace.finish(.turnFailed)
            let error = params["error"] as? [String: Any]
            if error?["kind"] as? String == "projectionError", !projectionRecoveryAttempted {
                recoverModelContext()
                return
            }
            // A terminal model/configuration error is not a lost process. Restarting
            // cannot repair non-retryable history and used to create an endless loop.
            pause(MuseProtocol.turnFailureDetail(params))
            return
        }
        do { try turnRecovery.finish() }
        catch { terminated("Could not record finished Muse work"); return }
        turnIsActive = false; activeTurnID = nil
        projectionRecoveryAttempted = false; needsHistoryRecovery = false
        do { try saveState() } catch { pause("Could not save completed Muse session state. Retry Startup."); return }
        trace.finish(.turnCompleted)
        update(.ready, "Muse Code ready")
        sendPending()
    }
    private func saveState() throws {
        guard let sessionID else { return }
        try JSONEncoder().encode(State(sessionID: sessionID, workspaceRoot: workspaceURL.path, modelIdentifier: configuration.modelIdentifier,
            modelRecorded: true, previousSessionIDs: previousSessionIDs,
            projectionRecoveryAttempted: projectionRecoveryAttempted,
            needsHistoryRecovery: needsHistoryRecovery)).write(to: stateURL, options: .atomic)
    }
    private func recoverModelContext() {
        steeringTimeout?.cancel()
        if let steeringNotificationID { notifications.restore(steeringNotificationID) }
        steeringNotificationID = nil
        guard let oldSession = sessionID else { return }
        projectionRecoveryAttempted = true
        needsHistoryRecovery = true
        // Persist the attempt before replacing the pointer; crashes cannot loop resets.
        do { try saveState() } catch { pause("Could not preserve Muse recovery state. Retry Startup."); return }
        previousSessionIDs.append(oldSession)
        sessionID = nil; activeTurnID = nil; turnIsActive = false
        earlyCompletions.removeAll(); requests.removeAll(); approvalStages.removeAll()
        recoveryPending = true
        update(.starting, "Recovering incompatible Muse context; chat history is preserved")
        startupTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.pause("Muse context recovery timed out. Retry Startup; chat history is preserved.")
        }
        openSession()
    }
    private func pause(_ detail: String) {
        steeringTimeout?.cancel()
        paused = true; stopped = true; running = false; turnIsActive = false
        startupTimeout?.cancel()
        requests.removeAll(); earlyCompletions.removeAll()
        connection?.invalidate(); connection = nil
        trace.finish(.turnFailed)
        update(.failed, detail)
    }
    private func terminated(_ detail: String) {
        steeringTimeout?.cancel()
        guard !stopped else { return }
        let needsRecovery = hasInterruptedWork
        stopped = true; running = false; turnIsActive = false
        startupTimeout?.cancel()
        connection?.invalidate(); connection = nil
        trace.finish(.runtimeDisconnected)
        update(.failed, detail)
        onUnexpectedTermination(self, detail, needsRecovery)
    }
    private func update(_ phase: AgentRuntimePhase, _ detail: String) {
        snapshot = .init(agentID: configuration.id, phase: phase, detail: detail, processIdentifier: pid)
        onSnapshot(snapshot)
    }
}
