import Foundation
import NoodleCore

/// A persistent Claude Code stream-json session. Claude's visible response is
/// intentionally ignored: Noodle agents communicate through the Messenger CLI.
@MainActor
public final class ClaudeAgentProcess: AgentRuntimeProcess {
    public let configuration: AgentRecord
    private let executableURL: URL
    private let workspaceURL: URL
    private let extendedAccess: Bool
    private let appsEnabled: Bool
    private let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    private let onHeartbeat: @MainActor () -> Void
    private let onActivity: @MainActor ([String: Any]) -> Void
    private let onUnexpectedTermination: @MainActor (ClaudeAgentProcess, String, Bool) -> Void
    private var sessionState: ClaudeSessionState
    private var turnRecovery: AgentTurnRecovery
    private var sessionID: UUID { sessionState.sessionID }

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
    /// Claude Code ends a turn while background tasks keep working, then starts one by itself.
    private var backgroundTaskCount = 0
    private var interruptRequested = false
    private var interruptRequestID: String?
    private var startupTimeout: Task<Void, Never>?
    private var interruptTimeout: Task<Void, Never>?
    private var intentionallyStopped = false
    private var terminationReported = false
    private var lastErrorText: String?
    private var safetyStopped = false
    /// Held for Kick after a safety stop; new messages wait instead of starting Claude again.
    private var paused = false
    private lazy var trace = RuntimeTrace(agentID: configuration.id, provider: .claudeCode, workspace: workspaceURL)


    public private(set) var snapshot: AgentRuntimeSnapshot

    init(
        agent: AgentRecord,
        executableURL: URL,
        workspaceURL: URL,
        extendedAccess: Bool,
        appsEnabled: Bool = false,
        recoverInterruptedWork: Bool,
        onSnapshot: @escaping @MainActor (AgentRuntimeSnapshot) -> Void,
        onHeartbeat: @escaping @MainActor () -> Void,
        onUnexpectedTermination: @escaping @MainActor (ClaudeAgentProcess, String, Bool) -> Void,
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
        self.appsEnabled = appsEnabled
        self.onSnapshot = onSnapshot
        self.onHeartbeat = onHeartbeat
        self.onActivity = onActivity
        self.onUnexpectedTermination = onUnexpectedTermination
        let stateURL = AgentStorageLayout(workspace: workspaceURL).sessionState(provider: .claudeCode, extendedAccess: extendedAccess)
        sessionState = ClaudeSessionState(url: stateURL)
        turnRecovery = AgentTurnRecovery(sessionStateURL: stateURL)
        recoveryPending = recoverInterruptedWork || turnRecovery.hasUnfinishedTurn
        snapshot = AgentRuntimeSnapshot(agentID: agent.id, phase: .offline, detail: "Not started")
    }

    public func start() {
        guard connection == nil, !paused, !shutdown.isPending else { return }
        intentionallyStopped = false
        terminationReported = false
        lastErrorText = nil
        update(.starting, "Starting Claude Code")
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
                self.reportUnexpectedTermination("Claude Code session startup timed out")
            }
            connection.startHarness(
                provider: .claudeCode,
                agentID: configuration.id,
                executablePath: executableURL.path,
                extendedAccess: extendedAccess,
                appsEnabled: appsEnabled,
                sessionID: sessionID,
                resumeSession: sessionState.shouldResume,
                modelIdentifier: configuration.modelIdentifier,
                effortIdentifier: configuration.reasoningEffort
            ) { [weak self] pid, error in
                Task { @MainActor in
                    guard let self, self.connectionID == connectionID, !self.intentionallyStopped, !self.terminationReported else { return }
                    if let error { self.reportUnexpectedTermination(error); return }
                    self.startupTimeout?.cancel()
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

    public func stop(completion: @escaping (Bool) -> Void = { _ in }) {
        trace.finish(.runtimeStopped)
        connectionID = nil
        startupTimeout?.cancel()
        intentionallyStopped = true
        paused = false
        interruptTimeout?.cancel()
        interruptRequestID = nil
        interruptRequested = false
        terminationReported = true
        running = false
        turnIsActive = false
        backgroundTaskCount = 0
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
        guard !paused else { return notificationID }
        if connection == nil { start() }
        sendPendingNotificationIfPossible()
        return notificationID
    }

    public func promoteNotification(_ id: UUID) {
        notifications.promote(id)
        sendPendingNotificationIfPossible()
    }

    public var canReceiveHeartbeat: Bool {
        running && snapshot.phase == .ready && !turnIsActive && !notificationPending && interruptRequestID == nil
    }

    public var isAlive: Bool { running || paused }

    public var hasInterruptedWork: Bool {
        recoveryPending || turnIsActive || notificationPending || turnRecovery.hasUnfinishedTurn
    }

    public func heartbeat() {
        guard canReceiveHeartbeat else { return }
        startTurn(reason: .heartbeat)
    }

    private func sendPendingNotificationIfPossible() {
        guard notificationPending, running, interruptRequestID == nil else { return }
        if turnIsActive {
            guard notifications.isImmediate, !interruptRequested, snapshot.phase == .working, let connection else { return }
            let id = UUID().uuidString
            interruptRequestID = id
            interruptRequested = true
            do {
                let request: [String: Any] = ["type": "control_request", "request_id": id,
                                             "request": ["subtype": "interrupt"]]
                connection.write(try JSONSerialization.data(withJSONObject: request) + Data([10]))
                trace.record(.turnInterruptRequested)
                interruptTimeout = Task { [weak self] in
                    do { try await self?.sleep(.seconds(10)) } catch { return }
                    guard let self, self.interruptRequested || self.interruptRequestID != nil else { return }
                    self.reportUnexpectedTermination("Claude Code did not finish interrupting its turn.")
                }
            } catch { reportUnexpectedTermination(error.localizedDescription) }
            return
        }
        guard snapshot.phase == .ready || backgroundTaskCount > 0 else { return }
        notifications.take()
        startTurn(reason: .inboxChanged)
    }

    private func startTurn(reason: AgentWakeReason) {
        guard running, !turnIsActive, let connection else {
            if reason == .inboxChanged { notifications.enqueue() }
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
            if reason == .inboxChanged { notifications.enqueue() }
            reportUnexpectedTermination(error.localizedDescription)
        }
    }

    private func handle(_ message: [String: Any]) {
        guard !intentionallyStopped, running else { return }
        let type = message["type"] as? String
        let ownSession = (message["session_id"] as? String).flatMap(UUID.init(uuidString:)) == sessionID
        if ownSession, !turnIsActive, !paused, type == "assistant", message["parent_tool_use_id"] as? String == nil {
            beginSelfStartedTurn()
        }
        if ownSession, turnIsActive || backgroundTaskCount > 0 {
            onActivity(message)
        }
        if ownSession, type == "system", message["subtype"] as? String == "background_tasks_changed" {
            backgroundTaskCount = (message["tasks"] as? [Any])?.count ?? 0
            if !turnIsActive, !paused, snapshot.phase == .ready || snapshot.phase == .working { showIdle() }
            return
        }
        if type == "control_response", let response = message["response"] as? [String: Any],
           let id = response["request_id"] as? String, id == interruptRequestID {
            interruptRequestID = nil
            if response["subtype"] as? String != "success" {
                interruptRequested = false
                notifications.deferUntilReady()
            }
            if !interruptRequested { interruptTimeout?.cancel() }
            sendPendingNotificationIfPossible()
            return
        }
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
        // Claude Code continues once after a refusal, so the turn is held only when it ends.
        if type == "assistant", turnIsActive,
           (message["message"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
            safetyStopped = true
        }
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
        let failed = message["is_error"] as? Bool == true
        let detail = failed ? (message["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        if let detail, ClaudeProtocol.isAuthenticationFailure(detail) {
            // The unfinished turn stays recorded, so signing in and Kick resumes it.
            pauseForSignIn()
            return
        }
        do { try turnRecovery.finish() }
        catch {
            update(.failed, "Could not record finished Claude work: \(error.localizedDescription)")
            return
        }
        turnIsActive = false
        if safetyStopped {
            pauseForSafetyStop()
            return
        }
        let wasInterrupted = interruptRequested
        interruptRequested = false
        if interruptRequestID == nil { interruptTimeout?.cancel() }
        trace.finish(wasInterrupted ? .turnInterrupted : (failed ? .turnFailed : .turnCompleted))
        if failed {
            showIdle(detail.flatMap { $0.isEmpty ? nil : "Claude Code ready — \(String($0.prefix(240)))" } ?? "Claude Code ready — last task failed")
        } else {
            showIdle()
        }
        sendPendingNotificationIfPossible()
    }

    private func beginSelfStartedTurn() {
        do { try turnRecovery.begin() }
        catch { reportUnexpectedTermination(error.localizedDescription); return }
        turnIsActive = true
        update(.working, "Following up on background work")
    }

    private func showIdle(_ detail: String = "Claude Code ready") {
        if backgroundTaskCount > 0 {
            update(.working, backgroundTaskCount == 1 ? "1 background task running" : "\(backgroundTaskCount) background tasks running")
        } else {
            update(.ready, detail)
        }
    }

    private func didTerminate(status: Int32) {
        if let lastErrorText, ClaudeProtocol.isAuthenticationFailure(lastErrorText) { pauseForSignIn(); return }
        reportUnexpectedTermination(lastErrorText ?? "Claude Code exited with status \(status)")
    }

    /// Restarting cannot sign the user in. Stay paused for an explicit retry.
    private func pauseForSignIn() {
        guard !intentionallyStopped, !terminationReported else { return }
        trace.finish(.turnFailed)
        disconnect()
        update(.failed, "Claude Code needs you to sign in. Open Harness settings and sign in, then retry.",
               failure: .authenticationRequired)
    }

    private func pauseForSafetyStop() {
        safetyStopped = false
        trace.finish(.turnFailed)
        disconnect()
        paused = true
        update(.failed, "Claude's safeguards stopped a response. Kick to resume or start a new session.",
               failure: .safetyStop)
    }

    private func reportUnexpectedTermination(_ detail: String) {
        let detail = HarnessVersionPolicy.startupIssue(provider: .claudeCode, text: detail) ?? detail
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
        interruptTimeout?.cancel()
        terminationReported = true
        running = false
        turnIsActive = false
        backgroundTaskCount = 0
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
