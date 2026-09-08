import Foundation
import NoodleCore

/// A persistent Claude Code stream-json session. Claude's visible response is
/// intentionally ignored: Noodle agents communicate through the Messenger CLI.
@MainActor
final class ClaudeAgentProcess: AgentRuntimeProcess {
    let configuration: AgentRecord
    private let executableURL: URL
    private let workspaceURL: URL
    private let extendedAccess: Bool
    private let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    private let onHeartbeat: @MainActor () -> Void
    private let onUnexpectedTermination: @MainActor (ClaudeAgentProcess, String, Bool) -> Void
    private var sessionState: ClaudeSessionState
    private var turnRecovery: AgentTurnRecovery
    private var sessionID: UUID { sessionState.sessionID }

    private var connection: ExtendedAgentConnection?
    private var running = false
    private var processIdentifier: Int32?
    private var notificationPending = false
    private var recoveryPending: Bool
    private var turnIsActive = false
    private var intentionallyStopped = false
    private var terminationReported = false
    private var lastErrorText: String?
    private lazy var trace = RuntimeTrace(agentID: configuration.id, provider: .claudeCode, workspace: workspaceURL)
    private lazy var outputReader = JSONLineReader { [weak self] message in
        Task { @MainActor in self?.handle(message) }
    }

    private(set) var snapshot: AgentRuntimeSnapshot

    init(
        agent: AgentRecord,
        executableURL: URL,
        workspaceURL: URL,
        extendedAccess: Bool,
        recoverInterruptedWork: Bool,
        onSnapshot: @escaping @MainActor (AgentRuntimeSnapshot) -> Void,
        onHeartbeat: @escaping @MainActor () -> Void,
        onUnexpectedTermination: @escaping @MainActor (ClaudeAgentProcess, String, Bool) -> Void
    ) {
        configuration = agent
        self.executableURL = executableURL
        self.workspaceURL = workspaceURL
        self.extendedAccess = extendedAccess
        self.onSnapshot = onSnapshot
        self.onHeartbeat = onHeartbeat
        self.onUnexpectedTermination = onUnexpectedTermination
        let stateURL = workspaceURL.appendingPathComponent(
            extendedAccess ? ".agents/claude-runtime-extended.json" : ".agents/claude-runtime.json"
        )
        sessionState = ClaudeSessionState(url: stateURL)
        turnRecovery = AgentTurnRecovery(sessionStateURL: stateURL)
        recoveryPending = recoverInterruptedWork || turnRecovery.hasUnfinishedTurn
        snapshot = AgentRuntimeSnapshot(agentID: agent.id, phase: .offline, detail: "Not started")
    }

    func start() {
        guard connection == nil else { return }
        guard extendedAccess else {
            update(.failed, "Claude Code requires autonomous access in Settings → Security")
            return
        }
        intentionallyStopped = false
        terminationReported = false
        lastErrorText = nil
        update(.starting, "Starting Claude Code")
        trace.runtimeStarting()
        do {
            let connection = try ExtendedAgentConnection()
            self.connection = connection
            connection.onData = { [weak self] data, isError in
                Task { @MainActor in
                    guard let self, !self.intentionallyStopped else { return }
                    if isError {
                        let detail = String(decoding: data, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !detail.isEmpty { self.lastErrorText = String(detail.suffix(2_000)) }
                    } else {
                        self.outputReader.receive(data)
                    }
                }
            }
            connection.onExit = { [weak self] status in
                Task { @MainActor in self?.didTerminate(status: status) }
            }
            connection.onFailure = { [weak self] detail in
                Task { @MainActor in self?.reportUnexpectedTermination(detail) }
            }
            running = true
            connection.start(
                provider: .claudeCode,
                agentID: configuration.id,
                executablePath: executableURL.path,
                sessionID: sessionID,
                resumeSession: sessionState.shouldResume,
                modelIdentifier: configuration.modelIdentifier,
                effortIdentifier: configuration.reasoningEffort
            ) { [weak self] pid, error in
                Task { @MainActor in
                    guard let self, !self.intentionallyStopped, !self.terminationReported else { return }
                    if let error { self.reportUnexpectedTermination(error); return }
                    self.processIdentifier = pid
                    self.update(.ready, "Claude Code ready")
                    if self.recoveryPending {
                        self.recoveryPending = false
                        self.startTurn(reason: .runtimeRecovered)
                    } else {
                        self.sendPendingNotificationIfPossible()
                    }
                }
            }
        } catch {
            reportUnexpectedTermination(error.localizedDescription)
        }
    }

    func stop(completion: @escaping (Bool) -> Void = { _ in }) {
        trace.finish(.runtimeStopped)
        intentionallyStopped = true
        terminationReported = true
        running = false
        turnIsActive = false
        notificationPending = false
        processIdentifier = nil
        guard let connection else {
            update(.offline, "Stopped")
            completion(true)
            return
        }
        self.connection = nil
        connection.stop { [weak self] stopped in
            Task { @MainActor in
                self?.update(.offline, "Stopped")
                completion(stopped)
            }
        }
    }

    func notify() {
        RuntimeDiagnostics.notificationQueued(agentID: configuration.id, coalesced: notificationPending)
        notificationPending = true
        if connection == nil { start() }
        sendPendingNotificationIfPossible()
    }

    var canReceiveHeartbeat: Bool {
        running && snapshot.phase == .ready && !turnIsActive && !notificationPending
    }

    // A restricted Claude configuration is deliberately stable (failed), not a
    // crashed process for the supervisor to relaunch repeatedly.
    var isAlive: Bool { running || !extendedAccess }

    var hasInterruptedWork: Bool {
        recoveryPending || turnIsActive || notificationPending || turnRecovery.hasUnfinishedTurn
    }

    func heartbeat() {
        guard canReceiveHeartbeat else { return }
        startTurn(reason: .heartbeat)
    }

    func resolveApproval(
        _ approval: AgentApprovalRequest,
        allow: Bool,
        answers: [String: String]
    ) {
        // Claude runs with the bot's explicit Extended access grant and does not
        // surface harness permission prompts into Noodle.
    }

    private func sendPendingNotificationIfPossible() {
        guard notificationPending, running, snapshot.phase == .ready, !turnIsActive else { return }
        notificationPending = false
        startTurn(reason: .inboxChanged)
    }

    private func startTurn(reason: AgentWakeReason) {
        guard running, !turnIsActive, let connection else {
            if reason == .inboxChanged { notificationPending = true }
            return
        }
        trace.begin(reason: reason)
        let object: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": reason.eventText]]
            ]
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
            try turnRecovery.begin()
            connection.write(data)
            trace.record(.wakeSubmitted)
            turnIsActive = true
            if reason == .heartbeat { onHeartbeat() }
            let detail = switch reason {
            case .heartbeat: "Heartbeat: checking for follow-up work"
            case .runtimeRecovered: "Recovering interrupted work"
            case .inboxChanged: "Checking for new messages"
            }
            update(.working, detail)
        } catch {
            if reason == .inboxChanged { notificationPending = true }
            reportUnexpectedTermination(error.localizedDescription)
        }
    }

    private func handle(_ message: [String: Any]) {
        guard !intentionallyStopped, running else { return }
        let type = message["type"] as? String
        if type == "system", message["subtype"] as? String == "init" {
            guard let rawID = message["session_id"] as? String,
                  let confirmedID = UUID(uuidString: rawID), confirmedID == sessionID else {
                reportUnexpectedTermination("Claude Code opened an unexpected session.")
                return
            }
            do { try sessionState.confirm(sessionID: confirmedID) }
            catch { reportUnexpectedTermination("Could not save Claude session: \(error.localizedDescription)") }
            return
        }
        if type == "assistant" || type == "result" { trace.outputObserved() }
        guard type == "result" else { return }
        if let rawID = message["session_id"] as? String,
           UUID(uuidString: rawID) != sessionID { return }
        do {
            if try sessionState.invalidateMissingSession(from: message) {
                trace.record(.turnFailed)
                reportUnexpectedTermination("Claude's saved session was not found; starting a new session")
                return
            }
        } catch {
            reportUnexpectedTermination("Could not clear missing Claude session: \(error.localizedDescription)")
            return
        }
        guard turnIsActive else { return }
        do { try turnRecovery.finish() }
        catch {
            update(.failed, "Could not record finished Claude work: \(error.localizedDescription)")
            return
        }
        turnIsActive = false
        let failed = message["is_error"] as? Bool == true
        trace.finish(failed ? .turnFailed : .turnCompleted)
        if failed {
            let detail = (message["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            update(.ready, detail.flatMap { $0.isEmpty ? nil : "Claude Code ready — \(String($0.prefix(240)))" } ?? "Claude Code ready — last task failed")
        } else {
            update(.ready, "Claude Code ready")
        }
        sendPendingNotificationIfPossible()
    }

    private func didTerminate(status: Int32) {
        let detail = lastErrorText ?? "Claude Code exited with status \(status)"
        reportUnexpectedTermination(detail)
    }

    private func reportUnexpectedTermination(_ detail: String) {
        guard !intentionallyStopped, !terminationReported else { return }
        trace.finish(.runtimeDisconnected)
        terminationReported = true
        let needsRecovery = hasInterruptedWork
        running = false
        turnIsActive = false
        processIdentifier = nil
        connection?.invalidate()
        connection = nil
        update(.failed, detail)
        onUnexpectedTermination(self, detail, needsRecovery)
    }

    private func update(_ phase: AgentRuntimePhase, _ detail: String) {
        snapshot = AgentRuntimeSnapshot(
            agentID: configuration.id,
            phase: phase,
            detail: detail,
            processIdentifier: processIdentifier
        )
        onSnapshot(snapshot)
    }

}
