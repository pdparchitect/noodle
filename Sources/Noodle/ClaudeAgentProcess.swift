import Foundation
import NoodleCore

/// A persistent Claude Code stream-json session. Claude's visible response is
/// intentionally ignored: Noodle agents communicate through the Messenger CLI.
@MainActor
final class ClaudeAgentProcess: AgentRuntimeProcess {
    private struct PersistedState: Codable {
        let version: Int
        let sessionID: UUID
    }

    let configuration: AgentRecord
    private let executableURL: URL
    private let workspaceURL: URL
    private let extendedAccess: Bool
    private let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    private let onHeartbeat: @MainActor () -> Void
    private let onUnexpectedTermination: @MainActor (ClaudeAgentProcess, String, Bool) -> Void
    private let stateURL: URL
    private let sessionID: UUID
    private var resumesSession: Bool

    private var connection: ExtendedAgentConnection?
    private var running = false
    private var processIdentifier: Int32?
    private var notificationPending = false
    private var recoveryPending: Bool
    private var turnIsActive = false
    private var intentionallyStopped = false
    private var terminationReported = false
    private var receivedOutput = false
    private var lastErrorText: String?
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
        recoveryPending = recoverInterruptedWork
        stateURL = workspaceURL.appendingPathComponent(
            extendedAccess ? ".agents/claude-runtime-extended.json" : ".agents/claude-runtime.json"
        )
        let state = Self.loadState(from: stateURL)
        if let state, state.version == Self.runtimeVersion {
            sessionID = state.sessionID
            resumesSession = true
        } else {
            sessionID = UUID()
            resumesSession = false
        }
        snapshot = AgentRuntimeSnapshot(agentID: agent.id, phase: .offline, detail: "Not started")
    }

    func start() {
        guard connection == nil else { return }
        guard extendedAccess else {
            update(.failed, "Claude Code requires Extended access in Settings → Security")
            return
        }
        intentionallyStopped = false
        terminationReported = false
        receivedOutput = false
        lastErrorText = nil
        update(.starting, "Starting Claude Code")
        do {
            try saveState()
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
                        self.receivedOutput = true
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
                resumeSession: resumesSession,
                modelIdentifier: configuration.modelIdentifier,
                effortIdentifier: configuration.reasoningEffort
            ) { [weak self] pid, error in
                Task { @MainActor in
                    guard let self, !self.intentionallyStopped else { return }
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
        recoveryPending || turnIsActive || notificationPending
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
        let object: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": reason.eventText]]
            ]
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
            connection.write(data)
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
            if let rawID = message["session_id"] as? String,
               UUID(uuidString: rawID) != sessionID {
                reportUnexpectedTermination("Claude Code opened an unexpected session.")
                return
            }
            resumesSession = true
            return
        }
        guard type == "result" else { return }
        turnIsActive = false
        resumesSession = true
        let failed = message["is_error"] as? Bool == true
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
        terminationReported = true
        let needsRecovery = recoveryPending || turnIsActive || notificationPending
        if resumesSession && !receivedOutput {
            // A stale session must not trap the supervisor in an endless resume loop.
            try? FileManager.default.removeItem(at: stateURL)
        }
        running = false
        turnIsActive = false
        processIdentifier = nil
        connection?.invalidate()
        connection = nil
        update(.failed, detail)
        onUnexpectedTermination(self, detail, needsRecovery)
    }

    private func saveState() throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(PersistedState(version: Self.runtimeVersion, sessionID: sessionID))
            .write(to: stateURL, options: .atomic)
    }

    private static func loadState(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
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

    private static let runtimeVersion = 1
}
