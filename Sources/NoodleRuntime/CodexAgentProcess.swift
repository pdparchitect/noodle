import Darwin
import Foundation
import NoodleCore

private let noodleAppVersion = Bundle.main.object(
    forInfoDictionaryKey: "CFBundleShortVersionString"
) as? String ?? "development"

@MainActor
public final class CodexAgentProcess: AgentRuntimeProcess {
    private enum RequestPurpose {
        case initialize
        case startThread
        case resumeThread
        case setThreadName
        case startTurn(AgentWakeReason)
        case steerTurn(UUID, String)
    }

    private struct PersistedState: Codable {
        let version: Int
        let threadID: String
        var needsHistoryRecovery: Bool? = nil
    }

    public let configuration: AgentRecord
    private let executableURL: URL
    private let workspaceURL: URL
    private let extendedAccess: Bool
    private let appsEnabled: Bool
    private var connectionID: UUID?
    private let sleep: @MainActor (Duration) async throws -> Void
    private let now: @MainActor () -> Date
    private let makeConnection: @MainActor () throws -> any HarnessRuntimeConnection
    private var hostConnection: (any HarnessRuntimeConnection)?
    private let shutdown = RuntimeShutdown()
    private var hostRunning = false
    private var hostPID: Int32?
    private let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    private let onHeartbeat: @MainActor () -> Void
    private let onActivity: @MainActor ([String: Any]) -> Void
    private let onUnexpectedTermination: @MainActor (CodexAgentProcess, String, Bool) -> Void
    private let stateURL: URL
    private var turnRecovery: AgentTurnRecovery

    private var nextRequestID = 1
    private var purposes: [Int: RequestPurpose] = [:]
    private var threadID: String?
    private var needsHistoryRecovery = false
    private var turnIsActive = false
    private var activeTurnID: String?
    private var finishedTurnID: String?
    private var threadModel: String?
    private var earlyTurnCompletion: [String: Any]?
    private var earlyTurnError: [String: Any]?
    private var turnErrorDetail: String?
    private var reconnectingSince: Date?
    private var steeringNotificationID: UUID?
    private var startupTimeout: Task<Void, Never>?
    private var steeringTimeout: Task<Void, Never>?
    private var notifications = PendingAgentNotification()
    private var notificationPending: Bool { notifications.isPending }
    private var recoveryPending: Bool
    private var intentionallyStopped = false
    private var terminationReported = false
    private var lastErrorText: String?
    private lazy var trace = RuntimeTrace(agentID: configuration.id, provider: .codex, workspace: workspaceURL)

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
        onUnexpectedTermination: @escaping @MainActor (CodexAgentProcess, String, Bool) -> Void,
        onActivity: @escaping @MainActor ([String: Any]) -> Void = { _ in },
        makeConnection: @escaping @MainActor () throws -> any HarnessRuntimeConnection = { try ExtendedAgentConnection() },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.makeConnection = makeConnection
        self.sleep = sleep
        self.now = now
        configuration = agent
        self.executableURL = executableURL
        self.workspaceURL = workspaceURL
        self.extendedAccess = extendedAccess
        self.appsEnabled = appsEnabled
        self.onSnapshot = onSnapshot
        self.onHeartbeat = onHeartbeat
        self.onActivity = onActivity
        self.onUnexpectedTermination = onUnexpectedTermination
        stateURL = AgentStorageLayout(workspace: workspaceURL).sessionState(provider: .codex, extendedAccess: extendedAccess)
        turnRecovery = AgentTurnRecovery(sessionStateURL: stateURL)
        recoveryPending = recoverInterruptedWork || turnRecovery.hasUnfinishedTurn
        snapshot = AgentRuntimeSnapshot(agentID: agent.id, phase: .offline, detail: "Not started")
        let state = Self.loadState(from: stateURL)
        threadID = state?.version == Self.runtimeVersion ? state?.threadID : nil
        needsHistoryRecovery = state?.needsHistoryRecovery ?? false
    }

    public func start() {
        guard hostConnection == nil, !shutdown.isPending else { return }
        intentionallyStopped = false
        terminationReported = false
        lastErrorText = nil
        update(.starting, "Starting Codex")
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
            hostConnection = connection
            connection.onData = { [weak self] data, isError in
                Task { @MainActor in
                    guard let self, self.connectionID == connectionID, !self.intentionallyStopped else { return }
                    if isError { self.lastErrorText = String(decoding: data, as: UTF8.self) }
                    else { outputReader.receive(data) }
                }
            }
            connection.onExit = { [weak self] status in Task { @MainActor in guard let self, self.connectionID == connectionID else { return }; self.didTerminate(status: status) } }
            connection.onFailure = { [weak self] detail in
                Task { @MainActor in guard let self, self.connectionID == connectionID else { return }; self.reportUnexpectedTermination(detail) }
            }
            hostRunning = true
            startupTimeout = Task { [weak self] in
                try? await self?.sleep(.seconds(60))
                guard let self, !Task.isCancelled, self.connectionID == connectionID else { return }
                self.reportUnexpectedTermination("Codex session startup timed out")
            }
            let started: (Int32, String?) -> Void = { [weak self] pid, error in
                Task { @MainActor in
                    guard let self, self.connectionID == connectionID, !self.intentionallyStopped else { return }
                    if let error { self.reportUnexpectedTermination(error); return }
                    self.hostPID = pid
                    do { try self.initialize() }
                    catch { self.reportUnexpectedTermination(error.localizedDescription) }
                }
            }
            connection.startHarness(provider: .codex, agentID: configuration.id, executablePath: executableURL.path,
                                    extendedAccess: extendedAccess, appsEnabled: appsEnabled, sessionID: nil, resumeSession: false,
                                    modelIdentifier: nil, effortIdentifier: nil, reply: started)
        } catch { reportUnexpectedTermination(error.localizedDescription) }
    }

    private func initialize() throws {
        try request(.initialize, method: "initialize", params: [
            "clientInfo": ["name": "noodle", "title": "Noodle", "version": noodleAppVersion],
            "capabilities": ["experimentalApi": true]
        ])
    }

    public func stop(completion: @escaping (Bool) -> Void = { _ in }) {
        trace.finish(.runtimeStopped)
        connectionID = nil
        startupTimeout?.cancel()
        intentionallyStopped = true
        terminationReported = true
        let connection = hostConnection
        hostRunning = false
        hostConnection = nil
        purposes.removeAll()
        turnIsActive = false
        activeTurnID = nil
        earlyTurnCompletion = nil
        earlyTurnError = nil
        turnErrorDetail = nil
        reconnectingSince = nil
        steeringNotificationID = nil
        steeringTimeout?.cancel()
        notifications.take()
        update(.offline, "Stopped")
        shutdown.stop(connection, completion: completion)
    }

    @discardableResult
    public func notify(immediately: Bool = false) -> UUID {
        RuntimeDiagnostics.notificationQueued(agentID: configuration.id, coalesced: notificationPending)
        let notificationID = notifications.enqueue(immediately: immediately)
        if hostConnection == nil { start() }
        sendPendingNotificationIfPossible()
        return notificationID
    }

    public func promoteNotification(_ id: UUID) {
        notifications.promote(id)
        sendPendingNotificationIfPossible()
    }

    public var canReceiveHeartbeat: Bool {
        hostRunning && snapshot.phase == .ready
            && !turnIsActive && !notificationPending && steeringNotificationID == nil && threadID != nil
    }

    public var isAlive: Bool { hostRunning }

    public var hasInterruptedWork: Bool {
        recoveryPending || turnIsActive || notificationPending || steeringNotificationID != nil || turnRecovery.hasUnfinishedTurn
    }

    public func heartbeat() {
        guard canReceiveHeartbeat else { return }
        startTurn(reason: .heartbeat)
    }

    private func didTerminate(status: Int32) {
        reportUnexpectedTermination(lastErrorText ?? "Codex exited with status \(status)")
    }

    private func reportUnexpectedTermination(_ detail: String) {
        let detail = HarnessVersionPolicy.startupIssue(provider: .codex, text: detail) ?? detail
        guard !intentionallyStopped, !terminationReported else { return }
        trace.finish(.runtimeDisconnected)
        connectionID = nil
        startupTimeout?.cancel()
        terminationReported = true
        steeringTimeout?.cancel()
        let needsRecovery = hasInterruptedWork
        hostRunning = false
        hostConnection?.invalidate()
        hostConnection = nil
        purposes.removeAll()
        turnIsActive = false
        fail(detail)
        onUnexpectedTermination(self, detail, needsRecovery)
    }

    private func handle(_ message: [String: Any]) {
        guard !intentionallyStopped, hostRunning else { return }
        if let request = CodexRuntimeRequest(message: message) {
            let isCurrent = request.params["threadId"] as? String == threadID
                && (request.turnID == nil || (turnIsActive && (activeTurnID == nil || request.turnID == activeTurnID)))
            do { try send(request.response(extendedAccess: extendedAccess, isCurrent: isCurrent)) }
            catch { fail(error.localizedDescription) }
            return
        }
        if message["method"] == nil, let id = Self.integerID(message["id"]),
           let purpose = purposes.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                if case .steerTurn(let notificationID, _) = purpose {
                    steeringTimeout?.cancel()
                    steeringNotificationID = nil
                    notifications.restore(notificationID)
                    trace.record(.inboxSteerRejected)
                    sendPendingNotificationIfPossible()
                    return
                }
                if case .resumeThread = purpose {
                    threadID = nil
                    needsHistoryRecovery = true
                    recoveryPending = true
                    // Keep the old pointer until a new private thread is saved.
                    openThread()
                    return
                }
                if case .setThreadName = purpose {
                    // Naming is presentational. An older Codex installation that
                    // does not support it must not keep the bot from running.
                    finishOpeningThread()
                    return
                }
                fail(error["message"] as? String ?? "Codex request failed")
                return
            }
            let result = message["result"] as? [String: Any] ?? [:]
            switch purpose {
            case .initialize:
                try? sendNotification(method: "initialized", params: [:])
                openThread()
            case .startThread, .resumeThread:
                guard let thread = result["thread"] as? [String: Any],
                      let id = thread["id"] as? String else {
                    fail("Codex did not return a thread identifier")
                    return
                }
                threadID = id
                threadModel = result["model"] as? String
                guard saveState(threadID: id) else { startupTimeout?.cancel(); return }
                setThreadName(id)
            case .setThreadName:
                finishOpeningThread()
            case .startTurn(let reason):
                guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String else {
                    fail("Codex did not return a turn identifier")
                    return
                }
                needsHistoryRecovery = false
                if let threadID, !saveState(threadID: threadID) { return }
                activeTurnID = id
                trace.record(.turnAccepted)
                turnIsActive = true
                update(.working, snapshot.detail)
                if reason == .heartbeat { onHeartbeat() }
                if let error = earlyTurnError {
                    earlyTurnError = nil
                    handle(error)
                }
                if let completion = earlyTurnCompletion {
                    earlyTurnCompletion = nil
                    handle(completion)
                }
                sendPendingNotificationIfPossible()
            case .steerTurn(let notificationID, let expectedTurnID):
                steeringTimeout?.cancel()
                steeringNotificationID = nil
                if result["turnId"] as? String != expectedTurnID {
                    notifications.restore(notificationID)
                    trace.record(.inboxSteerRejected)
                }
                sendPendingNotificationIfPossible()
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        if method.hasPrefix("item/"), turnIsActive,
           let params = message["params"] as? [String: Any],
           params["threadId"] as? String == threadID,
           let reportedTurn = params["turnId"] as? String,
           activeTurnID == nil || reportedTurn == activeTurnID {
            onActivity(message)
        }
        // The last call's usage may arrive after its turn has completed.
        if method == "thread/tokenUsage/updated", var params = message["params"] as? [String: Any],
           params["threadId"] as? String == threadID, let reportedTurn = params["turnId"] as? String,
           reportedTurn == activeTurnID || reportedTurn == finishedTurnID {
            params["model"] = threadModel
            onActivity(["method": method, "params": params])
        }
        if method == "error" {
            guard turnIsActive, let params = message["params"] as? [String: Any],
                  params["threadId"] as? String == threadID,
                  params["turnId"] is String,
                  let error = params["error"] as? [String: Any],
                  let willRetry = params["willRetry"] as? Bool else { return }
            guard let activeTurnID else {
                earlyTurnError = message
                return
            }
            guard params["turnId"] as? String == activeTurnID else { return }
            let detail = Self.turnErrorDescription(error, willRetry: willRetry)
            if turnErrorDetail != detail { trace.record(willRetry ? .turnRetrying : .turnError) }
            turnErrorDetail = detail
            // A retry notification does not finish the turn. Keep its recovery
            // marker and queued messages until Codex reports actual completion.
            if willRetry && Self.isConnectionError(error) {
                if reconnectingSince == nil { reconnectingSince = now() }
                update(.working, "Reconnecting…")
            } else {
                reconnectingSince = nil
                update(.failed, detail)
            }
            return
        }
        if ["item/started", "item/completed", "item/agentMessage/delta",
            "item/reasoning/textDelta", "item/reasoning/summaryTextDelta"].contains(method),
           turnIsActive, let activeTurnID, let params = message["params"] as? [String: Any],
           params["threadId"] as? String == threadID, params["turnId"] as? String == activeTurnID {
            trace.outputObserved()
            if turnErrorDetail != nil {
                turnErrorDetail = nil
                reconnectingSince = nil
                update(.working, "Codex is responding again")
                sendPendingNotificationIfPossible()
            }
        }
        if method == "turn/completed" {
            guard turnIsActive else { return }
            if let reportedThread = (message["params"] as? [String: Any])?["threadId"] as? String,
               reportedThread != threadID { return }
            let reportedTurn = ((message["params"] as? [String: Any])?["turn"] as? [String: Any])?["id"] as? String
            guard let activeTurnID else {
                earlyTurnCompletion = message
                return
            }
            guard reportedTurn == activeTurnID else { return }
            do { try turnRecovery.finish() }
            catch {
                fail("Could not record finished Codex work: \(error.localizedDescription)")
                return
            }
            turnIsActive = false
            finishedTurnID = activeTurnID
            self.activeTurnID = nil
            turnErrorDetail = nil
            reconnectingSince = nil
            let params = message["params"] as? [String: Any]
            let turn = params?["turn"] as? [String: Any]
            let status = turn?["status"] as? String
            let outcome: RuntimeDiagnostics.Event = switch status {
            case "completed": .turnCompleted
            case "failed": .turnFailed
            case "interrupted": .turnInterrupted
            default: .turnEndedUnknown
            }
            trace.finish(outcome)
            if status == "failed" {
                let error = turn?["error"] as? [String: Any]
                fail(error?["message"] as? String ?? "Codex turn failed")
            } else {
                update(.ready, "Codex ready")
                sendPendingNotificationIfPossible()
            }
        }
    }

    private func setThreadName(_ threadID: String) {
        let botName = configuration.displayName
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        let name = botName.isEmpty ? "Noodle · Bot" : "Noodle · \(botName)"
        do {
            try request(
                .setThreadName,
                method: "thread/name/set",
                params: ["threadId": threadID, "name": name]
            )
        } catch {
            finishOpeningThread()
        }
    }

    private static func isConnectionError(_ error: [String: Any]) -> Bool {
        let variants = error["codexErrorInfo"] as? [String: Any] ?? [:]
        return ["httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected",
                "responseTooManyFailedAttempts"].contains { variants[$0] != nil }
    }

    private static func turnErrorDescription(_ error: [String: Any], willRetry: Bool) -> String {
        let info = error["codexErrorInfo"]
        let summary: String
        if isConnectionError(error) {
            summary = "Codex could not maintain its connection to the model service."
        } else {
            summary = switch info as? String {
            case "unauthorized": "Codex sign-in was rejected."
            case "usageLimitExceeded", "sessionBudgetExceeded": "Codex reached its usage limit."
            case "rateLimitExceeded", "serverOverloaded": "The Codex model service is busy."
            case "contextWindowExceeded": "The Codex conversation exceeded its context limit."
            case "sandboxError": "Codex reported a sandbox error."
            default: "Codex reported a turn error."
            }
        }
        return summary + (willRetry ? " Retrying automatically; use Kick to restart if it persists." : " Use Kick to retry.")
    }

    private func finishOpeningThread() {
        startupTimeout?.cancel()
        update(.ready, "Codex ready")
        if recoveryPending {
            recoveryPending = false
            startTurn(reason: .runtimeRecovered)
            return
        }
        sendPendingNotificationIfPossible()
    }

    private func openThread() {
        var params: [String: Any] = [
            "cwd": workspaceURL.path,
            "approvalPolicy": extendedAccess ? "on-request" : "never",
            "sandbox": "workspace-write",
            "serviceName": "noodle",
            "developerInstructions": Self.developerInstructions
        ]
        if let model = configuration.modelIdentifier { params["model"] = model }

        do {
            if let threadID {
                params["threadId"] = threadID
                try request(.resumeThread, method: "thread/resume", params: params)
            } else {
                try request(.startThread, method: "thread/start", params: params)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func sendPendingNotificationIfPossible() {
        guard notificationPending, steeringNotificationID == nil, let threadID else { return }
        if turnIsActive {
            guard notifications.isImmediate, snapshot.phase == .working, reconnectingSince == nil, let activeTurnID,
                  let notificationID = notifications.take() else { return }
            steeringNotificationID = notificationID
            do {
                try request(.steerTurn(notificationID, activeTurnID), method: "turn/steer", params: [
                    "threadId": threadID, "expectedTurnId": activeTurnID,
                    "input": [["type": "text", "text": AgentWakeReason.inboxChanged.eventText]]
                ])
                trace.record(.inboxSteerSubmitted)
                steeringTimeout = Task { [weak self] in
                    do { try await self?.sleep(.seconds(10)) } catch { return }
                    guard let self, self.steeringNotificationID == notificationID else { return }
                    self.reportUnexpectedTermination("Codex did not acknowledge message steering.")
                }
            } catch {
                steeringNotificationID = nil
                notifications.restore(notificationID)
                reportUnexpectedTermination(error.localizedDescription)
            }
            return
        }
        guard snapshot.phase == .ready else { return }
        notifications.take()
        startTurn(reason: .inboxChanged)
    }

    private func startTurn(reason: AgentWakeReason) {
        guard let threadID else { return }
        activeTurnID = nil
        earlyTurnCompletion = nil
        earlyTurnError = nil
        turnErrorDetail = nil
        reconnectingSince = nil
        trace.begin(reason: reason)
        let policy: [String: Any] = extendedAccess ? [
            "type": "workspaceWrite",
            "writableRoots": [workspaceURL.path, workspaceURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Conversations").path],
            "networkAccess": false
        ] : ["type": "externalSandbox", "networkAccess": "restricted"]
        var params: [String: Any] = [
            "threadId": threadID,
            "input": [[
                "type": "text",
                "text": reason.eventText + (needsHistoryRecovery ? "\n\n" + MessengerDocumentation.recoveredModelContext : "")
            ]],
            "cwd": workspaceURL.path,
            "approvalPolicy": extendedAccess ? "on-request" : "never",
            "sandboxPolicy": policy
        ]
        if let model = configuration.modelIdentifier { params["model"] = model }
        if let effort = configuration.reasoningEffort { params["effort"] = effort }

        do {
            try turnRecovery.begin()
            try request(.startTurn(reason), method: "turn/start", params: params)
            trace.record(.wakeSubmitted)
            turnIsActive = true
            let detail = switch reason {
            case .heartbeat: "Heartbeat: checking for follow-up work"
            case .runtimeRecovered: "Recovering interrupted work"
            case .inboxChanged: "Checking for new messages"
            }
            update(.working, detail)
        } catch {
            if reason == .inboxChanged { notifications.enqueue() }
            fail(error.localizedDescription)
        }
    }

    private func request(_ purpose: RequestPurpose, method: String, params: [String: Any]) throws {
        let id = nextRequestID
        nextRequestID += 1
        purposes[id] = purpose
        try send(["method": method, "id": id, "params": params])
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try send(["method": method, "params": params])
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let hostConnection else { throw CocoaError(.fileNoSuchFile) }
        hostConnection.write(data + Data([0x0A]))
    }

    private func saveState(threadID: String) -> Bool {
        do {
            let directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(
                PersistedState(version: Self.runtimeVersion, threadID: threadID, needsHistoryRecovery: needsHistoryRecovery)
            ).write(to: stateURL, options: .atomic)
            return true
        } catch {
            fail("Could not save Codex thread: \(error.localizedDescription)")
            return false
        }
    }

    private static func loadState(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    private func fail(_ detail: String) {
        reconnectingSince = nil
        startupTimeout?.cancel()
        trace.finish(.runtimeFailed)
        update(.failed, detail)
    }

    private func update(_ phase: AgentRuntimePhase, _ detail: String) {
        snapshot = AgentRuntimeSnapshot(
            agentID: configuration.id,
            phase: phase,
            detail: detail,
            processIdentifier: hostPID,
            reconnectingSince: reconnectingSince
        )
        onSnapshot(snapshot)
    }

    fileprivate static func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static var developerInstructions: String { MessengerDocumentation.bootstrapInstructions }

    private static let runtimeVersion = 9
}

@MainActor
public final class CodexCapabilityProbe {
    private let executableURL: URL
    private var process: Process?
    private var input: ProcessInputWriter?
    private var output: FileHandle?
    private var errors: FileHandle?
    private lazy var outputReader = JSONLineReader { [weak self] message in
        Task { @MainActor in self?.handle(message) }
    }
    private var completion: ((Result<[HarnessModel], Error>) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func loadModels(completion: @escaping (Result<[HarnessModel], Error>) -> Void) {
        self.completion = completion
        do {
            let child = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            child.executableURL = executableURL
            child.arguments = CodexLaunch.appServerArguments()
            child.standardInput = inputPipe
            child.standardOutput = outputPipe
            child.standardError = errorPipe
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = HostEnvironment.codexHome.path
            child.environment = environment

            let reader = outputReader
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                reader.receive(data)
            }
            // Readiness callbacks must consume bytes, even when diagnostics are
            // discarded. Otherwise this spins continuously and can fill the pipe,
            // preventing the child from completing initialization.
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty {
                    handle.readabilityHandler = nil
                }
            }
            child.terminationHandler = { [weak self] child in
                Task { @MainActor in
                    guard let self, self.completion != nil else { return }
                    self.finish(.failure(ProbeError("Codex capability check exited with status \(child.terminationStatus)")))
                }
            }

            try child.run()
            process = child
            input = ProcessInputWriter(handle: inputPipe.fileHandleForWriting)
            output = outputPipe.fileHandleForReading
            errors = errorPipe.fileHandleForReading
            try send([
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": ["name": "noodle", "title": "Noodle", "version": noodleAppVersion],
                    "capabilities": [:]
                ]
            ])
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.finish(.failure(ProbeError("Codex did not return its model list")))
                }
            }
        } catch {
            finish(.failure(error))
        }
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        completion = nil
        tearDown()
    }

    private func handle(_ message: [String: Any]) {
        guard completion != nil,
              let id = CodexAgentProcess.integerID(message["id"]) else { return }
        if let error = message["error"] as? [String: Any] {
            finish(.failure(ProbeError(error["message"] as? String ?? "Codex capability check failed")))
            return
        }
        if id == 1 {
            do {
                try send(["method": "initialized", "params": [:]])
                try send([
                    "method": "model/list",
                    "id": 2,
                    "params": ["includeHidden": false, "limit": 100]
                ])
            } catch {
                finish(.failure(error))
            }
        } else if id == 2 {
            let result = message["result"] as? [String: Any]
            let data = result?["data"] as? [[String: Any]] ?? []
            let models = data.compactMap(CodexInspection.model)
            guard !models.isEmpty else {
                finish(.failure(ProbeError("Codex returned no available models")))
                return
            }
            finish(.success(models))
        }
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let input else { throw CocoaError(.fileNoSuchFile) }
        input.write(data + Data([0x0A])) { [weak self] error in
            Task { @MainActor in
                self?.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<[HarnessModel], Error>) {
        guard let completion else { return }
        self.completion = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        tearDown()
        completion(result)
    }

    private func tearDown() {
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        errors = nil
    }

    private struct ProbeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

private enum HostEnvironment {
    static var codexHome: URL {
        if let entry = getpwuid(getuid()), let pointer = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
    }
}
