import Foundation
import NoodleCore

/// A persistent Antigravity stream-json session: one process per conversation,
/// one line in and one `result` out per turn. The visible response is
/// intentionally ignored: Noodle agents communicate through the Messenger CLI.
@MainActor
public final class AntigravityAgentProcess: AgentRuntimeProcess {
    public let configuration: AgentRecord
    private let executableURL: URL
    private let workspaceURL: URL
    private let extendedAccess: Bool
    private let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    private let onHeartbeat: @MainActor () -> Void
    private let onActivity: @MainActor ([String: Any]) -> Void
    private let onUnexpectedTermination: @MainActor (AntigravityAgentProcess, String, Bool) -> Void
    private var sessionState: AntigravitySessionState
    private var turnRecovery: AgentTurnRecovery

    private var connectionID: UUID?
    private let sleep: @MainActor (Duration) async throws -> Void
    private let makeConnection: @MainActor () throws -> any HarnessRuntimeConnection
    private var connection: (any HarnessRuntimeConnection)?
    private let shutdown = RuntimeShutdown()
    private var running = false
    private var processIdentifier: Int32?
    private var notifications = PendingAgentNotification()
    private var notificationPending: Bool { notifications.isPending }
    private var recoveryPending: Bool
    private var turnIsActive = false
    private var startupTimeout: Task<Void, Never>?
    private var intentionallyStopped = false
    private var terminationReported = false
    private var lastErrorText: String?
    private lazy var trace = RuntimeTrace(agentID: configuration.id, provider: .antigravity, workspace: workspaceURL)

    public private(set) var snapshot: AgentRuntimeSnapshot

    init(
        agent: AgentRecord,
        executableURL: URL,
        workspaceURL: URL,
        extendedAccess: Bool,
        recoverInterruptedWork: Bool,
        onSnapshot: @escaping @MainActor (AgentRuntimeSnapshot) -> Void,
        onHeartbeat: @escaping @MainActor () -> Void,
        onUnexpectedTermination: @escaping @MainActor (AntigravityAgentProcess, String, Bool) -> Void,
        onActivity: @escaping @MainActor ([String: Any]) -> Void = { _ in },
        makeConnection: @escaping @MainActor () throws -> any HarnessRuntimeConnection = { try ExtendedAgentConnection() },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.makeConnection = makeConnection
        self.sleep = sleep
        configuration = agent
        self.executableURL = executableURL
        self.workspaceURL = workspaceURL
        self.extendedAccess = extendedAccess
        self.onSnapshot = onSnapshot
        self.onHeartbeat = onHeartbeat
        self.onActivity = onActivity
        self.onUnexpectedTermination = onUnexpectedTermination
        let stateURL = AgentStorageLayout(workspace: workspaceURL).sessionState(provider: .antigravity, extendedAccess: extendedAccess)
        sessionState = AntigravitySessionState(url: stateURL)
        turnRecovery = AgentTurnRecovery(sessionStateURL: stateURL)
        recoveryPending = recoverInterruptedWork || turnRecovery.hasUnfinishedTurn
        snapshot = AgentRuntimeSnapshot(agentID: agent.id, phase: .offline, detail: "Not started")
    }

    public func start() {
        guard connection == nil, !shutdown.isPending else { return }
        intentionallyStopped = false
        terminationReported = false
        lastErrorText = nil
        update(.starting, "Starting Antigravity")
        trace.runtimeStarting()
        do {
            let connectionID = UUID()
            self.connectionID = connectionID
            let outputReader = JSONLineReader { [weak self] message in
                Task { @MainActor in
                    guard let self, self.connectionID == connectionID else { return }
                    self.handle(message)
                }
            }
            let connection = try makeConnection()
            self.connection = connection
            connection.onData = { [weak self] data, isError in
                Task { @MainActor in
                    guard let self, self.connectionID == connectionID, !self.intentionallyStopped else { return }
                    if isError {
                        let detail = String(decoding: data, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !detail.isEmpty { self.lastErrorText = String(detail.suffix(2_000)) }
                    } else {
                        outputReader.receive(data)
                    }
                }
            }
            connection.onExit = { [weak self] status in
                Task { @MainActor in guard let self, self.connectionID == connectionID else { return }; self.didTerminate(status: status) }
            }
            connection.onFailure = { [weak self] detail in
                Task { @MainActor in guard let self, self.connectionID == connectionID else { return }; self.reportUnexpectedTermination(detail) }
            }
            running = true
            startupTimeout = Task { [weak self] in
                try? await self?.sleep(.seconds(60))
                guard let self, !Task.isCancelled, self.connectionID == connectionID else { return }
                self.reportUnexpectedTermination("Antigravity session startup timed out")
            }
            connection.startHarness(
                provider: .antigravity,
                agentID: configuration.id,
                executablePath: executableURL.path,
                extendedAccess: extendedAccess,
                appsEnabled: false,
                sessionID: sessionState.conversationID,
                resumeSession: sessionState.conversationID != nil,
                modelIdentifier: configuration.modelIdentifier,
                effortIdentifier: nil
            ) { [weak self] pid, error in
                Task { @MainActor in
                    guard let self, self.connectionID == connectionID, !self.intentionallyStopped, !self.terminationReported else { return }
                    if let error { self.reportUnexpectedTermination(error); return }
                    self.startupTimeout?.cancel()
                    self.processIdentifier = pid
                    self.update(.ready, "Antigravity ready")
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

    public func stop(completion: @escaping (Bool) -> Void = { _ in }) {
        trace.finish(.runtimeStopped)
        connectionID = nil
        startupTimeout?.cancel()
        intentionallyStopped = true
        terminationReported = true
        running = false
        turnIsActive = false
        notifications.take()
        processIdentifier = nil
        let connection = connection
        self.connection = nil
        update(.offline, "Stopped")
        shutdown.stop(connection, completion: completion)
    }

    @discardableResult
    public func notify(immediately: Bool = false) -> UUID {
        RuntimeDiagnostics.notificationQueued(agentID: configuration.id, coalesced: notificationPending)
        let notificationID = notifications.enqueue(immediately: immediately)
        if connection == nil { start() }
        sendPendingNotificationIfPossible()
        return notificationID
    }

    public func promoteNotification(_ id: UUID) {
        notifications.promote(id)
        sendPendingNotificationIfPossible()
    }

    public var canReceiveHeartbeat: Bool {
        running && snapshot.phase == .ready && !turnIsActive && !notificationPending
    }

    public var isAlive: Bool { running }

    public var hasInterruptedWork: Bool {
        recoveryPending || turnIsActive || notificationPending || turnRecovery.hasUnfinishedTurn
    }

    public func heartbeat() {
        guard canReceiveHeartbeat else { return }
        startTurn(reason: .heartbeat)
    }

    /// The stream accepts prompts only, and rejects control messages, so a turn
    /// cannot be interrupted. An urgent message starts the next turn instead.
    private func sendPendingNotificationIfPossible() {
        guard notificationPending, running, !turnIsActive, snapshot.phase == .ready else { return }
        notifications.take()
        startTurn(reason: .inboxChanged)
    }

    private func startTurn(reason: AgentWakeReason) {
        guard running, !turnIsActive, let connection else {
            if reason == .inboxChanged { notifications.enqueue() }
            return
        }
        trace.begin(reason: reason)
        do {
            try turnRecovery.begin()
            connection.write(AntigravityProtocol.userMessage(reason.eventText))
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
            if reason == .inboxChanged { notifications.enqueue() }
            reportUnexpectedTermination(error.localizedDescription)
        }
    }

    private func handle(_ message: [String: Any]) {
        guard !intentionallyStopped, running else { return }
        if let conversationID = AntigravityProtocol.conversationID(initialization: message) {
            do { try sessionState.confirm(conversationID: conversationID) }
            catch { reportUnexpectedTermination("Could not save Antigravity session: \(error.localizedDescription)") }
            return
        }
        if turnIsActive, message["event"] as? String == "step_update" {
            trace.outputObserved()
            onActivity(message)
        }
        guard let result = AntigravityProtocol.turnResult(message), turnIsActive else { return }
        trace.outputObserved()
        if let detail = result.detail, AntigravityProtocol.isAuthenticationFailure(detail) {
            // The unfinished turn stays recorded, so signing in and Kick resumes it.
            pauseForSignIn()
            return
        }
        do { try turnRecovery.finish() }
        catch {
            update(.failed, "Could not record finished Antigravity work: \(error.localizedDescription)")
            return
        }
        turnIsActive = false
        trace.finish(result.succeeded ? .turnCompleted : .turnFailed)
        if result.succeeded {
            update(.ready, "Antigravity ready")
        } else {
            update(.ready, result.detail.map { "Antigravity ready — \(String($0.prefix(240)))" } ?? "Antigravity ready — last task failed")
        }
        sendPendingNotificationIfPossible()
    }

    private func didTerminate(status: Int32) {
        if let lastErrorText, AntigravityProtocol.isAuthenticationFailure(lastErrorText) { pauseForSignIn(); return }
        reportUnexpectedTermination(lastErrorText ?? "Antigravity exited with status \(status)")
    }

    /// Restarting cannot sign the user in. Stay paused for an explicit retry.
    private func pauseForSignIn() {
        guard !intentionallyStopped, !terminationReported else { return }
        trace.finish(.turnFailed)
        disconnect()
        update(.failed, "Antigravity needs you to sign in. Run agy in Terminal, then retry.", failure: .authenticationRequired)
    }

    private func reportUnexpectedTermination(_ detail: String) {
        let detail = HarnessVersionPolicy.startupIssue(provider: .antigravity, text: detail) ?? detail
        guard !intentionallyStopped, !terminationReported else { return }
        trace.finish(.runtimeDisconnected)
        let needsRecovery = hasInterruptedWork
        disconnect()
        update(.failed, detail)
        onUnexpectedTermination(self, detail, needsRecovery)
    }

    private func disconnect() {
        connectionID = nil
        startupTimeout?.cancel()
        terminationReported = true
        running = false
        turnIsActive = false
        processIdentifier = nil
        connection?.invalidate()
        connection = nil
    }

    private func update(_ phase: AgentRuntimePhase, _ detail: String, failure: AgentRuntimeFailure? = nil) {
        snapshot = AgentRuntimeSnapshot(
            agentID: configuration.id,
            phase: phase,
            detail: detail,
            processIdentifier: processIdentifier,
            failure: failure
        )
        onSnapshot(snapshot)
    }
}
