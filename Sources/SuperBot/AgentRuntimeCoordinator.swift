import Darwin
import Foundation
import Observation
import SuperBotCore

private let superBotAppVersion = Bundle.main.object(
    forInfoDictionaryKey: "CFBundleShortVersionString"
) as? String ?? "development"

@MainActor
@Observable
final class AgentRuntimeCoordinator {
    private(set) var installations: [HarnessInstallation]
    private(set) var modelsByProvider: [HarnessProvider: [HarnessModel]] = [:]
    private(set) var capabilityErrors: [HarnessProvider: String] = [:]
    private(set) var isLoadingCapabilities = false
    private(set) var isRefreshingInstallations = false
    private(set) var snapshots: [UUID: AgentRuntimeSnapshot] = [:]
    private(set) var heartbeatConfiguration: AgentHeartbeatConfiguration
    private(set) var accessConfiguration: AgentAccessConfiguration
    private(set) var approvals: [AgentApprovalRequest] = []
    private(set) var changingAccess: Set<UUID> = []
    private(set) var accessCheckResult: String?
    private(set) var isCheckingAccess = false
    @ObservationIgnored private var checkConnection: ExtendedAgentConnection?
    private var lifecycleID = UUID()
    private var blockedRestarts: Set<UUID> = []

    @ObservationIgnored private var heartbeatScheduler: AgentHeartbeatScheduler
    private let defaults: UserDefaults

    private let discovery: HarnessDiscovery
    private var processes: [UUID: CodexAgentProcess] = [:]
    private var capabilityProbe: CodexCapabilityProbe?

    init(discovery: HarnessDiscovery = HarnessDiscovery(), defaults: UserDefaults = .standard) {
        self.discovery = discovery
        self.defaults = defaults
        accessConfiguration = AgentAccessConfiguration.load(from: defaults)
        let configuration = AgentHeartbeatConfiguration.load(from: defaults)
        heartbeatConfiguration = configuration
        heartbeatScheduler = AgentHeartbeatScheduler(configuration: configuration)
        installations = discovery.discover()
    }

    func setExtendedAccess(_ enabled: Bool, agent: AgentRecord, repository: WorkspaceRepository) {
        guard !changingAccess.contains(agent.id), !blockedRestarts.contains(agent.id), accessConfiguration.isExtended(agent.id) != enabled else { return }
        changingAccess.insert(agent.id)
        let lifecycle = lifecycleID
        // Persist revocation before stopping so relaunch cannot restore access.
        // Grants are saved only after the previous process has stopped.
        if !enabled {
            accessConfiguration.setExtended(false, for: agent.id)
            accessConfiguration.save(to: defaults)
        }
        let old = processes.removeValue(forKey: agent.id)
        approvals.removeAll { $0.agentID == agent.id }
        snapshots[agent.id] = .init(agentID: agent.id, phase: .starting, detail: "Changing agent access…")
        let finish: (Bool) -> Void = { [weak self] stopped in
            guard let self else { return }
            guard self.lifecycleID == lifecycle, self.changingAccess.contains(agent.id) else { return }
            self.changingAccess.remove(agent.id)
            guard stopped else {
                self.blockedRestarts.insert(agent.id)
                self.snapshots[agent.id] = .init(agentID: agent.id, phase: .failed, detail: "Could not confirm that the old runtime stopped. Quit SuperBot before restarting this bot.")
                return
            }
            self.accessConfiguration.setExtended(enabled, for: agent.id)
            self.accessConfiguration.save(to: self.defaults)
            self.start(agent: agent, repository: repository)
        }
        if let old { old.stop(completion: finish) } else { finish(true) }
    }

    func resolveApproval(_ approval: AgentApprovalRequest, allow: Bool, answers: [String: String] = [:]) {
        guard approvals.contains(where: { $0.id == approval.id }) else { return }
        processes[approval.agentID]?.resolveApproval(approval, allow: allow, answers: answers)
    }

    func checkExtendedRuntime() {
        guard !isCheckingAccess else { return }
        isCheckingAccess = true
        accessCheckResult = nil
        do {
            let connection = try ExtendedAgentConnection()
            checkConnection = connection
            connection.checkCompatibility { [weak self] success, detail in
                Task { @MainActor in
                    guard self?.checkConnection === connection else { return }
                    self?.accessCheckResult = success ? detail : "Runtime check failed: \(detail)"
                    self?.isCheckingAccess = false
                    connection.stop { _ in }
                    self?.checkConnection = nil
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard self?.checkConnection === connection else { return }
                self?.isCheckingAccess = false
                self?.accessCheckResult = "Runtime check timed out. No bot access was changed."
                self?.checkConnection = nil
                connection.stop { _ in }
            }
        } catch { isCheckingAccess = false; accessCheckResult = error.localizedDescription }
    }

    func configureHeartbeats(enabled: Bool? = nil, intervalMinutes: Int? = nil) {
        applyHeartbeatConfiguration(AgentHeartbeatConfiguration(
            isEnabled: enabled ?? heartbeatConfiguration.isEnabled,
            intervalMinutes: intervalMinutes ?? heartbeatConfiguration.intervalMinutes,
            disabledAgentIDs: heartbeatConfiguration.disabledAgentIDs
        ))
    }

    func setHeartbeatEnabled(_ enabled: Bool, for agentID: UUID) {
        var disabled = heartbeatConfiguration.disabledAgentIDs
        if enabled { disabled.remove(agentID) } else { disabled.insert(agentID) }
        applyHeartbeatConfiguration(AgentHeartbeatConfiguration(
            isEnabled: heartbeatConfiguration.isEnabled,
            intervalMinutes: heartbeatConfiguration.intervalMinutes,
            disabledAgentIDs: disabled
        ))
    }

    private func applyHeartbeatConfiguration(_ configuration: AgentHeartbeatConfiguration) {
        heartbeatScheduler.configure(configuration, at: Date())
        heartbeatConfiguration = configuration
        configuration.save(to: defaults)
    }

    func recordActivity(for agentID: UUID) {
        heartbeatScheduler.recordActivity(for: agentID, at: Date())
    }

    func checkHeartbeats() {
        let readyIDs = Set(processes.filter { $0.value.canReceiveHeartbeat }.map(\.key))
        for id in heartbeatScheduler.takeDueHeartbeats(readyAgentIDs: readyIDs, at: Date()) {
            // Do not start offline/failed bots or enqueue a heartbeat behind real work.
            processes[id]?.heartbeat()
        }
    }

    var availableInstallations: [HarnessInstallation] {
        installations.filter(\.isAvailable)
    }

    /// Discovery is shared by Settings and bot configuration. Refreshing the
    /// catalogue does not restart agents or launch capability-probe processes.
    func refreshInstallations() async {
        guard !isRefreshingInstallations else { return }
        isRefreshingInstallations = true
        defer { isRefreshingInstallations = false }
        let discovery = discovery
        let detected = await Task.detached(priority: .utility) {
            discovery.discover()
        }.value
        guard !Task.isCancelled else { return }
        installations = detected
    }

    func installation(for agent: AgentRecord) -> HarnessInstallation? {
        guard let identifier = agent.harnessIdentifier,
              let provider = HarnessProvider(rawValue: identifier) else { return nil }
        return installations.first { $0.provider == provider && $0.isAvailable }
    }

    func models(for harnessIdentifier: String?) -> [HarnessModel] {
        guard let harnessIdentifier,
              let provider = HarnessProvider(rawValue: harnessIdentifier) else { return [] }
        return modelsByProvider[provider, default: []]
    }

    func snapshot(for agentID: UUID) -> AgentRuntimeSnapshot {
        snapshots[agentID] ?? AgentRuntimeSnapshot(
            agentID: agentID,
            phase: .offline,
            detail: "Not started"
        )
    }

    func refresh(agents: [AgentRecord], repository: WorkspaceRepository? = nil) {
        installations = discovery.discover()
        let liveIDs = Set(agents.map(\.id))
        for id in processes.keys where !liveIDs.contains(id) {
            processes.removeValue(forKey: id)?.stop()
            heartbeatScheduler.remove(id)
        }

        for agent in agents {
            if let process = processes[agent.id] {
                snapshots[agent.id] = process.snapshot
            } else if agent.harnessIdentifier == nil {
                snapshots[agent.id] = AgentRuntimeSnapshot(
                    agentID: agent.id,
                    phase: .failed,
                    detail: "Choose a harness in Edit Bot"
                )
            } else if installation(for: agent) != nil {
                snapshots[agent.id] = AgentRuntimeSnapshot(
                    agentID: agent.id,
                    phase: .offline,
                    detail: "Codex is configured"
                )
            } else {
                snapshots[agent.id] = AgentRuntimeSnapshot(
                    agentID: agent.id,
                    phase: .failed,
                    detail: "The configured harness is not installed"
                )
            }
        }
        snapshots = snapshots.filter { liveIDs.contains($0.key) }

        if let repository {
            for agent in agents where processes[agent.id]?.configuration != agent {
                restart(agent: agent, repository: repository)
            }
        }
    }

    func refreshCapabilities() {
        installations = discovery.discover()
        capabilityProbe?.stop()
        capabilityProbe = nil
        capabilityErrors.removeAll()

        guard let installation = availableInstallations.first(where: { $0.provider == .codex }),
              let executablePath = installation.executablePath else {
            modelsByProvider[.codex] = []
            capabilityErrors[.codex] = "Codex is not installed"
            isLoadingCapabilities = false
            return
        }

        isLoadingCapabilities = true
        let probe = CodexCapabilityProbe(executableURL: URL(fileURLWithPath: executablePath))
        capabilityProbe = probe
        probe.loadModels { [weak self, weak probe] result in
            guard let self, self.capabilityProbe === probe else { return }
            self.capabilityProbe = nil
            self.isLoadingCapabilities = false
            switch result {
            case .success(let models):
                self.modelsByProvider[.codex] = models
                self.capabilityErrors[.codex] = nil
            case .failure(let error):
                self.modelsByProvider[.codex] = []
                self.capabilityErrors[.codex] = error.localizedDescription
            }
        }
    }

    func startAll(agents: [AgentRecord], repository: WorkspaceRepository) {
        installations = discovery.discover()
        for agent in agents {
            start(agent: agent, repository: repository)
        }
    }

    func start(agent: AgentRecord, repository: WorkspaceRepository) {
        guard processes[agent.id] == nil, !changingAccess.contains(agent.id), !blockedRestarts.contains(agent.id) else { return }
        guard let installation = installation(for: agent),
              let executablePath = installation.executablePath else {
            snapshots[agent.id] = AgentRuntimeSnapshot(
                agentID: agent.id,
                phase: .failed,
                detail: agent.harnessIdentifier == nil
                    ? "Choose a harness in Edit Bot"
                    : "The configured harness is not installed"
            )
            return
        }

        switch installation.provider {
        case .codex:
            let process = CodexAgentProcess(
                agent: agent,
                executableURL: URL(fileURLWithPath: executablePath),
                workspaceURL: repository.directory(for: agent),
                extendedAccess: accessConfiguration.isExtended(agent.id),
                onSnapshot: { [weak self] snapshot in
                    if self?.snapshots[snapshot.agentID]?.phase != snapshot.phase {
                        self?.recordActivity(for: snapshot.agentID)
                    }
                    self?.snapshots[snapshot.agentID] = snapshot
                },
                onActivity: { [weak self] in
                    self?.recordActivity(for: agent.id)
                },
                onApprovals: { [weak self] pending in
                    self?.approvals.removeAll { $0.agentID == agent.id }
                    self?.approvals.append(contentsOf: pending)
                }
            )
            processes[agent.id] = process
            process.start()
            // Recover notifications lost during an app restart or failed launch.
            // Peek off the main thread; only Messenger may consume the inbox.
            Task { [weak self, weak process] in
                let hasUnread = await Task.detached {
                    (try? repository.latestMessages(for: agent.id, consuming: false).isEmpty == false) ?? false
                }.value
                guard let self, let process, self.processes[agent.id] === process else { return }
                if hasUnread { process.notify() }
            }
        }
    }

    func restart(
        agent: AgentRecord,
        repository: WorkspaceRepository,
        resetThread: Bool = false
    ) {
        guard !changingAccess.contains(agent.id) else { return }
        changingAccess.insert(agent.id)
        let lifecycle = lifecycleID
        let old = processes.removeValue(forKey: agent.id)
        if resetThread {
            let stateURL = repository.directory(for: agent)
                .appendingPathComponent(accessConfiguration.isExtended(agent.id) ? ".agents/codex-runtime-extended.json" : ".agents/codex-runtime.json")
            try? FileManager.default.removeItem(at: stateURL)
        }
        let finish: (Bool) -> Void = { [weak self] stopped in
            guard let self else { return }
            guard self.lifecycleID == lifecycle, self.changingAccess.contains(agent.id) else { return }
            self.changingAccess.remove(agent.id)
            if stopped { self.start(agent: agent, repository: repository) }
            else {
                self.blockedRestarts.insert(agent.id)
                self.snapshots[agent.id] = .init(agentID: agent.id, phase: .failed, detail: "The previous runtime could not be stopped.")
            }
        }
        if let old { old.stop(completion: finish) } else { finish(true) }
    }

    func notify(_ agents: [AgentRecord], repository: WorkspaceRepository) {
        for agent in agents {
            recordActivity(for: agent.id)
            if processes[agent.id] == nil {
                start(agent: agent, repository: repository)
            }
            processes[agent.id]?.notify()
        }
    }

    func stop(agentID: UUID) {
        changingAccess.remove(agentID)
        approvals.removeAll { $0.agentID == agentID }
        accessConfiguration.setExtended(false, for: agentID)
        accessConfiguration.save(to: defaults)
        processes.removeValue(forKey: agentID)?.stop()
        snapshots.removeValue(forKey: agentID)
        heartbeatScheduler.remove(agentID)
    }

    func stopAll() {
        lifecycleID = UUID()
        changingAccess = []
        approvals = []
        capabilityProbe?.stop()
        capabilityProbe = nil
        processes.values.forEach { $0.stop() }
        processes.removeAll()
        heartbeatScheduler = AgentHeartbeatScheduler(configuration: heartbeatConfiguration)
        snapshots = snapshots.mapValues {
            AgentRuntimeSnapshot(agentID: $0.agentID, phase: .offline, detail: "Stopped")
        }
    }
}

@MainActor
private final class CodexAgentProcess {
    private enum RequestPurpose {
        case initialize
        case startThread
        case resumeThread
        case startTurn
    }

    private struct PersistedState: Codable {
        let version: Int
        let threadID: String
    }

    let configuration: AgentRecord
    private let executableURL: URL
    private let workspaceURL: URL
    private let extendedAccess: Bool
    private let onApprovals: @MainActor ([AgentApprovalRequest]) -> Void
    private var pendingApprovals: [AgentApprovalRequest] = []
    private var approvalItemDetails: [String: [String: Any]] = [:]
    private var extendedConnection: ExtendedAgentConnection?
    private var extendedRunning = false
    private var extendedPID: Int32?
    private let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    private let onActivity: @MainActor () -> Void
    private let stateURL: URL

    private var process: Process?
    private var input: ProcessInputWriter?
    private var output: FileHandle?
    private var errors: FileHandle?
    private lazy var outputReader = JSONLineReader { [weak self] message in
        Task { @MainActor in self?.handle(message) }
    }
    private var nextRequestID = 1
    private var purposes: [Int: RequestPurpose] = [:]
    private var threadID: String?
    private var turnIsActive = false
    private var notificationPending = false
    private var intentionallyStopped = false
    private var lastErrorText: String?

    private(set) var snapshot: AgentRuntimeSnapshot

    init(
        agent: AgentRecord,
        executableURL: URL,
        workspaceURL: URL,
        extendedAccess: Bool,
        onSnapshot: @escaping @MainActor (AgentRuntimeSnapshot) -> Void,
        onActivity: @escaping @MainActor () -> Void,
        onApprovals: @escaping @MainActor ([AgentApprovalRequest]) -> Void
    ) {
        configuration = agent
        self.executableURL = executableURL
        self.workspaceURL = workspaceURL
        self.extendedAccess = extendedAccess
        self.onApprovals = onApprovals
        self.onSnapshot = onSnapshot
        self.onActivity = onActivity
        stateURL = workspaceURL.appendingPathComponent(extendedAccess ? ".agents/codex-runtime-extended.json" : ".agents/codex-runtime.json")
        snapshot = AgentRuntimeSnapshot(agentID: agent.id, phase: .offline, detail: "Not started")
        let state = Self.loadState(from: stateURL)
        threadID = state?.version == Self.runtimeVersion ? state?.threadID : nil
    }

    func start() {
        guard process == nil, extendedConnection == nil else { return }
        intentionallyStopped = false
        update(.starting, "Starting Codex")

        if extendedAccess {
            do {
                let connection = try ExtendedAgentConnection()
                extendedConnection = connection
                connection.onData = { [weak self] data, isError in
                    Task { @MainActor in
                        guard let self, !self.intentionallyStopped else { return }
                        if isError { self.lastErrorText = String(decoding: data, as: UTF8.self) }
                        else { self.outputReader.receive(data) }
                    }
                }
                connection.onExit = { [weak self] status in Task { @MainActor in self?.didTerminate(status: status) } }
                connection.onFailure = { [weak self] detail in Task { @MainActor in
                    guard let self, !self.intentionallyStopped else { return }
                    self.extendedRunning = false
                    self.fail(detail)
                } }
                extendedRunning = true
                connection.start(agentID: configuration.id, executablePath: executableURL.path) { [weak self] pid, error in
                    Task { @MainActor in
                        guard let self, !self.intentionallyStopped else { return }
                        if let error { self.extendedRunning = false; self.fail(error); return }
                        self.extendedPID = pid
                        do { try self.initialize() } catch { self.fail(error.localizedDescription) }
                    }
                }
            } catch { fail(error.localizedDescription) }
            return
        }

        do {
            let child = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            child.executableURL = executableURL
            child.arguments = ["app-server"]
            child.currentDirectoryURL = workspaceURL
            child.standardInput = inputPipe
            child.standardOutput = outputPipe
            child.standardError = errorPipe

            var environment = ProcessInfo.processInfo.environment
            environment["SUPERBOT_AGENT_ID"] = configuration.id.uuidString.lowercased()
            environment["SUPERBOT_WORKSPACE"] = workspaceURL.path
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
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                Task { @MainActor in self?.lastErrorText = text }
            }
            child.terminationHandler = { [weak self] terminated in
                Task { @MainActor in self?.didTerminate(status: terminated.terminationStatus) }
            }

            try child.run()
            process = child
            input = ProcessInputWriter(handle: inputPipe.fileHandleForWriting)
            output = outputPipe.fileHandleForReading
            errors = errorPipe.fileHandleForReading
            update(.starting, "Connecting to Codex")
            try initialize()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func initialize() throws {
        try request(.initialize, method: "initialize", params: [
            "clientInfo": ["name": "superbot", "title": "SuperBot", "version": superBotAppVersion],
            "capabilities": ["experimentalApi": true]
        ])
    }

    func stop(completion: @escaping (Bool) -> Void = { _ in }) {
        intentionallyStopped = true
        pendingApprovals = []
        onApprovals([])
        let hadExtendedConnection = extendedConnection != nil
        if let connection = extendedConnection {
            extendedRunning = false
            extendedConnection = nil
            connection.stop { stopped in Task { @MainActor in completion(stopped) } }
        }
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        errors = nil
        purposes.removeAll()
        turnIsActive = false
        notificationPending = false
        update(.offline, "Stopped")
        if !hadExtendedConnection { completion(true) }
    }

    func notify() {
        notificationPending = true
        if process == nil { start() }
        sendPendingNotificationIfPossible()
    }

    var canReceiveHeartbeat: Bool {
        (process?.isRunning == true || extendedRunning) && snapshot.phase == .ready
            && !turnIsActive && !notificationPending && threadID != nil
    }

    func heartbeat() {
        guard canReceiveHeartbeat else { return }
        startTurn(reason: .heartbeat)
    }

    private func didTerminate(status: Int32) {
        guard !intentionallyStopped else { return }
        extendedRunning = false
        pendingApprovals = []
        onApprovals([])
        process = nil
        input = nil
        output = nil
        errors = nil
        purposes.removeAll()
        turnIsActive = false
        if intentionallyStopped {
            update(.offline, "Stopped")
        } else {
            fail(lastErrorText ?? "Codex exited with status \(status)")
        }
    }

    private func handle(_ message: [String: Any]) {
        guard !intentionallyStopped, process != nil || extendedRunning else { return }
        let eventMethod = message["method"] as? String ?? ""
        if message["id"] != nil || eventMethod.hasPrefix("item/")
            || eventMethod.hasPrefix("turn/") || eventMethod == "thread/tokenUsage/updated" {
            onActivity()
        }
        var approvalMessage = message
        if var params = message["params"] as? [String: Any], let itemID = params["itemId"] as? String,
           let item = approvalItemDetails[itemID] {
            for key in ["command", "cwd", "changes"] where params[key] == nil || params[key] is NSNull {
                params[key] = item[key]
            }
            approvalMessage["params"] = params
        }
        if message["method"] != nil, let approval = AgentApprovalRequest(agentID: configuration.id, message: approvalMessage) {
            guard approval.params["threadId"] as? String == threadID else {
                try? send(approval.response(allow: false))
                return
            }
            if !pendingApprovals.contains(where: { $0.requestID == approval.requestID }) {
                pendingApprovals.append(approval)
                onApprovals(pendingApprovals)
                update(.working, "Waiting for your approval")
            }
            return
        }
        if message["method"] == nil, let id = Self.integerID(message["id"]),
           let purpose = purposes.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                if case .resumeThread = purpose {
                    threadID = nil
                    try? FileManager.default.removeItem(at: stateURL)
                    openThread()
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
                saveState(threadID: id)
                update(.ready, "Codex ready")
                sendPendingNotificationIfPossible()
            case .startTurn:
                turnIsActive = true
                update(.working, snapshot.detail)
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        if method == "item/started", let params = message["params"] as? [String: Any],
           let item = params["item"] as? [String: Any], let id = item["id"] as? String,
           ["commandExecution", "fileChange"].contains(item["type"] as? String ?? "") {
            approvalItemDetails[id] = item
        }
        if method == "item/completed", let params = message["params"] as? [String: Any],
           let item = params["item"] as? [String: Any], let id = item["id"] as? String {
            approvalItemDetails.removeValue(forKey: id)
            pendingApprovals.removeAll { $0.params["itemId"] as? String == id }
            onApprovals(pendingApprovals)
        }
        if method == "serverRequest/resolved", let params = message["params"] as? [String: Any],
           let id = RuntimeRequestID(params["requestId"]) {
            pendingApprovals.removeAll { $0.requestID == id }
            onApprovals(pendingApprovals)
        }
        if method == "turn/completed" {
            approvalItemDetails = [:]
            pendingApprovals = []
            onApprovals([])
            turnIsActive = false
            let params = message["params"] as? [String: Any]
            let turn = params?["turn"] as? [String: Any]
            let status = turn?["status"] as? String
            if status == "failed" {
                let error = turn?["error"] as? [String: Any]
                fail(error?["message"] as? String ?? "Codex turn failed")
            } else {
                update(.ready, "Codex ready")
                sendPendingNotificationIfPossible()
            }
        }
    }

    private func openThread() {
        var params: [String: Any] = [
            "cwd": workspaceURL.path,
            "approvalPolicy": extendedAccess ? "on-request" : "never",
            "sandbox": "workspace-write",
            "serviceName": "superbot",
            "developerInstructions": Self.developerInstructions + "\n" + accessInstructions
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
        guard notificationPending, !turnIsActive,
              snapshot.phase == .ready,
              threadID != nil else { return }
        notificationPending = false
        startTurn(reason: .inboxChanged)
    }

    private func startTurn(reason: AgentWakeReason) {
        guard let threadID else { return }
        let policy: [String: Any] = extendedAccess ? [
            "type": "workspaceWrite",
            "writableRoots": [workspaceURL.path, workspaceURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Conversations").path],
            "networkAccess": false
        ] : ["type": "externalSandbox", "networkAccess": "restricted"]
        var params: [String: Any] = [
            "threadId": threadID,
            "input": [[
                "type": "text",
                "text": reason.eventText
            ]],
            "cwd": workspaceURL.path,
            "approvalPolicy": extendedAccess ? "on-request" : "never",
            "sandboxPolicy": policy
        ]
        if let model = configuration.modelIdentifier { params["model"] = model }
        if let effort = configuration.reasoningEffort { params["effort"] = effort }

        do {
            try request(.startTurn, method: "turn/start", params: params)
            turnIsActive = true
            onActivity()
            update(.working, reason == .heartbeat ? "Heartbeat: checking for follow-up work" : "Checking for new messages")
        } catch {
            if reason == .inboxChanged { notificationPending = true }
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
        if let extendedConnection {
            extendedConnection.write(data + Data([0x0A]))
            return
        }
        guard let input else { throw CocoaError(.fileNoSuchFile) }
        input.write(data + Data([0x0A])) { [weak self] error in
            Task { @MainActor in
                guard let self, !self.intentionallyStopped else { return }
                self.fail("Could not communicate with Codex: \(error.localizedDescription)")
            }
        }
    }

    private func saveState(threadID: String) {
        do {
            let directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(
                PersistedState(version: Self.runtimeVersion, threadID: threadID)
            ).write(to: stateURL, options: .atomic)
        } catch {
            fail("Could not save Codex thread: \(error.localizedDescription)")
        }
    }

    private static func loadState(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    private func fail(_ detail: String) {
        pendingApprovals = []
        onApprovals([])
        update(.failed, detail)
    }

    func resolveApproval(_ approval: AgentApprovalRequest, allow: Bool, answers: [String: String]) {
        guard !intentionallyStopped, pendingApprovals.contains(where: { $0.id == approval.id }) else { return }
        do {
            try send(approval.response(allow: allow, answers: answers))
            pendingApprovals.removeAll { $0.id == approval.id }
            onApprovals(pendingApprovals)
            update(.working, pendingApprovals.isEmpty ? "Continuing agent work" : "Waiting for your approval")
        } catch { fail(error.localizedDescription) }
    }

    private func update(_ phase: AgentRuntimePhase, _ detail: String) {
        snapshot = AgentRuntimeSnapshot(
            agentID: configuration.id,
            phase: phase,
            detail: detail,
            processIdentifier: extendedPID ?? process?.processIdentifier
        )
        onSnapshot(snapshot)
    }

    fileprivate static func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static let developerInstructions = """
    \(AgentWakeReason.heartbeatInstructions)
    Messenger also supports `--react --conversation <uuid> --message <message-uuid> --emoji '👀'` and `--unreact` to remove your own emoji. Use reactions when useful for acknowledgement, progress, completion, or feedback, keeping progress indicators accurate. `--list-messages --conversation <uuid>` reads history including your own messages and current reactions without consuming the inbox. Inbox deliveries with `reactionChange` are feedback on the referenced message, not a new instruction to repeat it. The change's `sender` names the reactor; `emoji` and `removed` describe the update. Do not reply to every reaction or create acknowledgement loops.
    You are a continuously running SuperBot agent. An `inbox-changed` event is a notification that your inbox changed; it never contains the user's message. Whenever notified, your first action must be running the bundled Messenger CLI through Codex's programmatic bridge: `const r = await tools.exec_command({cmd: "./.agents/skills/messenger/messenger --get-latest --inline-images", max_output_tokens: 250000}); if (r.exit_code !== 0) throw new Error(r.output); const payload = JSON.parse(r.output); text(payload.deliveries); for (const visual of payload.images) image(visual.dataURL, "original");`. Every delivery explicitly identifies you in `me`, provides a named `participants` roster where your handle is `me`, and annotates the message `sender` with a `user`, `me`, `bot`, or `system` handle. Use these identities instead of guessing from UUIDs. The CLI includes attached images directly as visual inputs, so inspect them without calling a local image viewer. Every attachment also includes its exact `absolutePath` for non-visual file work. Run get-latest only once for each notification because it consumes the inbox. Reply with the Messenger CLI using `--send`, the conversation UUID, and `--body-percent-encoded`; encode a UTF-8 reply with `const encoded = encodeURIComponent(body).replaceAll("'", "%27");` and pass it as a single-quoted command argument. To send files you created, add a repeatable `--attach <file-path>` option; the body is optional when at least one file is attached. Never edit SuperBot's conversation files directly. Do not answer the notification text itself. If the inbox is empty on an `inbox-changed` event, finish quietly. For a `heartbeat` event, follow the heartbeat instructions above.
    """

    private var accessInstructions: String {
        let mode = extendedAccess
            ? "This bot has user-enabled extended access. Codex still enforces command permissions; request additional access through its approval tools when required. An outstanding approval must wait for the user, including during a heartbeat. Never change your own access mode or approve your own requests."
            : "This bot is in restricted mode inside SuperBot's macOS App Sandbox. Browser/computer-control runtimes may be unavailable. Do not try to bypass the app sandbox; explain the limitation and direct the user to Settings → Security if the task requires extended access."
        return mode + " Do not promise browser or connected-tool access merely because a tool is listed. Verify the relevant capability with a safe check before claiming it works; report the actual failure when it does not."
    }

    private static let runtimeVersion = 9
}

@MainActor
private final class CodexCapabilityProbe {
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
            child.arguments = ["app-server"]
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
                    "clientInfo": ["name": "superbot", "title": "SuperBot", "version": superBotAppVersion],
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
            let models = data.compactMap(Self.parseModel)
            guard !models.isEmpty else {
                finish(.failure(ProbeError("Codex returned no available models")))
                return
            }
            finish(.success(models))
        }
    }

    private static func parseModel(_ value: [String: Any]) -> HarnessModel? {
        guard let id = (value["model"] as? String) ?? (value["id"] as? String) else { return nil }
        let effortValues = value["supportedReasoningEfforts"] as? [[String: Any]] ?? []
        let efforts = effortValues.compactMap { effort -> HarnessEffort? in
            guard let id = effort["reasoningEffort"] as? String else { return nil }
            return HarnessEffort(id: id, description: effort["description"] as? String ?? "")
        }
        return HarnessModel(
            id: id,
            displayName: value["displayName"] as? String ?? id,
            description: value["description"] as? String ?? "",
            supportedEfforts: efforts,
            defaultEffort: value["defaultReasoningEffort"] as? String ?? efforts.first?.id ?? "medium",
            isDefault: value["isDefault"] as? Bool ?? false
        )
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
