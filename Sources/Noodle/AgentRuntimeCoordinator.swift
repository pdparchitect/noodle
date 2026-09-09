import Darwin
import Foundation
import Observation
import NoodleCore

private let noodleAppVersion = Bundle.main.object(
    forInfoDictionaryKey: "CFBundleShortVersionString"
) as? String ?? "development"

@MainActor
protocol AgentRuntimeProcess: AnyObject {
    var configuration: AgentRecord { get }
    var snapshot: AgentRuntimeSnapshot { get }
    var isAlive: Bool { get }
    var hasInterruptedWork: Bool { get }
    var canReceiveHeartbeat: Bool { get }
    func start()
    func stop(completion: @escaping (Bool) -> Void)
    func notify()
    func heartbeat()
    func resolveApproval(_ approval: AgentApprovalRequest, allow: Bool, answers: [String: String])
}

@MainActor
@Observable
final class AgentRuntimeCoordinator {
    private(set) var installations: [HarnessInstallation]
    private(set) var modelsByProvider: [HarnessProvider: [HarnessModel]] = [:]
    private(set) var capabilityErrors: [HarnessProvider: String] = [:]
    private(set) var isLoadingCapabilities = false
    private(set) var isRefreshingInstallations = false
    private(set) var installationErrors: [HarnessProvider: String] = [:]
    private(set) var snapshots: [UUID: AgentRuntimeSnapshot] = [:] {
        didSet { updateSleepAssertion() }
    }
    private(set) var preventIdleSleepWhileWorking: Bool
    private(set) var heartbeatConfiguration: AgentHeartbeatConfiguration
    private(set) var lastHeartbeatDates: [UUID: Date]
    private(set) var accessConfiguration: AgentAccessConfiguration
    private(set) var approvals: [AgentApprovalRequest] = []
    private(set) var changingAccess: Set<UUID> = []
    @ObservationIgnored private let sleepController = AgentActivitySleepController()
    private var lifecycleID = UUID()
    private var blockedRestarts: Set<UUID> = []
    private var restartAttempts: [UUID: Int] = [:]
    @ObservationIgnored private var restartTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var stabilityTasks: [UUID: Task<Void, Never>] = [:]
    private var recoveryPending: Set<UUID> = []
    private var isStoppingAll = false

    @ObservationIgnored private var heartbeatScheduler: AgentHeartbeatScheduler
    private let defaults: UserDefaults

    private var discovery: HarnessDiscovery
    private var processes: [UUID: any AgentRuntimeProcess] = [:]
    private var capabilityProbe: CodexCapabilityProbe?
    private var fxCapabilityTask: Task<Void, Never>?
    private var grokCapabilityTask: Task<Void, Never>?
    private var hostGrokInstallation: HarnessInstallation?

    private func discoveredInstallations() -> [HarnessInstallation] {
        discovery.discover().map { installation in
            installation.provider == .grokBuild ? (hostGrokInstallation ?? installation) : installation
        }
    }

    private func refreshGrokCapabilities() async {
        guard discovery.allowsHostDiscovery(for: .grokBuild) else { return }
        do {
            let result = try await GrokHostProbe().load()
            guard !Task.isCancelled else { return }
            let installation = HarnessInstallation(provider: .grokBuild, executablePath: result.executablePath)
            hostGrokInstallation = installation
            installationErrors[.grokBuild] = nil
            installations = installations.map { $0.provider == .grokBuild ? installation : $0 }
            modelsByProvider[.grokBuild] = result.models
            capabilityErrors[.grokBuild] = result.executablePath == nil ? "Grok Build is not installed" : (result.authenticated ? nil : "Run grok login in Terminal, then check again.")
        } catch {
            guard !Task.isCancelled else { return }
            installationErrors[.grokBuild] = error.localizedDescription
            capabilityErrors[.grokBuild] = error.localizedDescription
        }
    }

    init(discovery: HarnessDiscovery = HarnessDiscovery(), defaults: UserDefaults = .standard) {
        self.discovery = discovery
        self.defaults = defaults
        preventIdleSleepWhileWorking = defaults.bool(forKey: Self.preventIdleSleepDefaultsKey)
        accessConfiguration = AgentAccessConfiguration.load(from: defaults)
        let configuration = AgentHeartbeatConfiguration.load(from: defaults)
        heartbeatConfiguration = configuration
        heartbeatScheduler = AgentHeartbeatScheduler(
            configuration: configuration,
            lastActivity: Self.loadDates(from: defaults, key: Self.lastActivityDatesKey)
        )
        lastHeartbeatDates = Self.loadLastHeartbeatDates(from: defaults)
        installations = discovery.discover()
    }

    func configurePreventIdleSleepWhileWorking(_ enabled: Bool) {
        preventIdleSleepWhileWorking = enabled
        defaults.set(enabled, forKey: Self.preventIdleSleepDefaultsKey)
        updateSleepAssertion()
    }

    private func updateSleepAssertion() {
        sleepController.update(shouldPreventIdleSleep: AgentSleepPolicy.shouldPreventIdleSleep(
            enabled: preventIdleSleepWhileWorking,
            phases: snapshots.values.map(\.phase)
        ))
    }

    private static let preventIdleSleepDefaultsKey = "Noodle.power.preventIdleSleepWhileWorking"

    func prepareAccessForExistingAgents(_ agents: [AgentRecord]) {
        accessConfiguration = AgentAccessConfiguration.migrateExistingAgents(Set(agents.map(\.id)), in: defaults)
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
                self.snapshots[agent.id] = .init(agentID: agent.id, phase: .failed, detail: "Could not confirm that the old runtime stopped. Quit Noodle before restarting this bot.")
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
        saveHeartbeatActivityDates()
    }

    func seedHeartbeatActivity(for agentID: UUID, at date: Date) {
        if heartbeatScheduler.register(agentID, at: date) {
            saveHeartbeatActivityDates()
        }
    }

    func recordActivity(for agentID: UUID) {
        heartbeatScheduler.recordActivity(for: agentID, at: Date())
        saveHeartbeatActivityDates()
    }

    private func recordHeartbeat(for agentID: UUID) {
        lastHeartbeatDates[agentID] = Date()
        saveLastHeartbeatDates()
    }

    private func saveLastHeartbeatDates() {
        defaults.set(
            Dictionary(uniqueKeysWithValues: lastHeartbeatDates.map {
                ($0.key.uuidString, $0.value.timeIntervalSince1970)
            }),
            forKey: Self.lastHeartbeatDatesKey
        )
    }

    private func saveHeartbeatActivityDates() {
        defaults.set(
            Dictionary(uniqueKeysWithValues: heartbeatScheduler.lastActivity.map {
                ($0.key.uuidString, $0.value.timeIntervalSince1970)
            }),
            forKey: Self.lastActivityDatesKey
        )
    }

    private static let lastActivityDatesKey = "Noodle.heartbeat.lastActivityDates"
    private static let lastHeartbeatDatesKey = "Noodle.heartbeat.lastDates"

    private static func loadLastHeartbeatDates(from defaults: UserDefaults) -> [UUID: Date] {
        loadDates(from: defaults, key: lastHeartbeatDatesKey)
    }

    private static func loadDates(from defaults: UserDefaults, key: String) -> [UUID: Date] {
        guard let stored = defaults.dictionary(forKey: key) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            guard let id = UUID(uuidString: key), let seconds = value as? TimeInterval else { return nil }
            return (id, Date(timeIntervalSince1970: seconds))
        })
    }

    func checkHeartbeats() {
        let readyIDs = Set(processes.filter { $0.value.canReceiveHeartbeat }.map(\.key))
        let dueIDs = heartbeatScheduler.takeDueHeartbeats(readyAgentIDs: readyIDs, at: Date())
        if !dueIDs.isEmpty { saveHeartbeatActivityDates() }
        for id in dueIDs {
            // Do not start offline/failed bots or enqueue a heartbeat behind real work.
            processes[id]?.heartbeat()
        }
    }

    var availableInstallations: [HarnessInstallation] {
        installations.filter(\.isAvailable)
    }

    func checkExternalInstallation(_ provider: HarnessProvider) async {
        #if DEBUG
        discovery.checkExternalInstallationDuringSimulation(provider)
        #endif
        await refreshInstallations()
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
        await refreshGrokCapabilities()
        guard !Task.isCancelled else { return }
        let complete = detected.map { installation in
            installation.provider == .grokBuild ? (hostGrokInstallation ?? installation) : installation
        }
        if installations != complete { installations = complete }
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
        installations = discoveredInstallations()
        let liveIDs = Set(agents.map(\.id))
        for id in processes.keys where !liveIDs.contains(id) {
            processes.removeValue(forKey: id)?.stop { _ in }
            cancelSupervision(for: id)
            heartbeatScheduler.remove(id)
            saveHeartbeatActivityDates()
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
                let name = HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.displayName ?? "Harness"
                snapshots[agent.id] = AgentRuntimeSnapshot(
                    agentID: agent.id,
                    phase: .offline,
                    detail: "\(name) is configured"
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
        installations = discoveredInstallations()
        grokCapabilityTask?.cancel()
        grokCapabilityTask = Task { [weak self] in await self?.refreshGrokCapabilities() }
        fxCapabilityTask?.cancel()
        if let path = availableInstallations.first(where: { $0.provider == .fx })?.executablePath {
            fxCapabilityTask = Task { [weak self] in
                do {
                    let models = try await FxModelProbe().load(path: path)
                    guard !Task.isCancelled else { return }
                    self?.modelsByProvider[.fx] = models
                    self?.capabilityErrors[.fx] = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.capabilityErrors[.fx] = error.localizedDescription
                }
            }
        } else { modelsByProvider[.fx] = [] }
        capabilityProbe?.stop()
        capabilityProbe = nil
        capabilityErrors.removeAll()

        if availableInstallations.contains(where: { $0.provider == .claudeCode }) {
            modelsByProvider[.claudeCode] = ClaudeCodeCapabilities.models
        } else {
            modelsByProvider[.claudeCode] = []
            capabilityErrors[.claudeCode] = "Claude Code is not installed"
        }

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
        isStoppingAll = false
        installations = discoveredInstallations()
        for agent in agents {
            start(agent: agent, repository: repository)
        }
    }

    func start(agent: AgentRecord, repository: WorkspaceRepository) {
        guard processes[agent.id] == nil, !changingAccess.contains(agent.id), !blockedRestarts.contains(agent.id) else { return }
        do { try repository.synchronizeAgentWorkspace(agent) }
        catch {
            snapshots[agent.id] = AgentRuntimeSnapshot(agentID: agent.id, phase: .failed,
                detail: "Could not prepare the bot's workspace. Check its managed skill directories before retrying.")
            return
        }
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
        case .fx, .grokBuild:
            restartTasks.removeValue(forKey: agent.id)?.cancel()
            let process = ACPAgentProcess(
                provider: installation.provider, agent: agent, executableURL: URL(fileURLWithPath: executablePath),
                workspaceURL: repository.directory(for: agent),
                extendedAccess: accessConfiguration.isExtended(agent.id),
                recoverInterruptedWork: recoveryPending.remove(agent.id) != nil,
                onSnapshot: runtimeSnapshotHandler(for: agent.id),
                onHeartbeat: { [weak self] in self?.recordHeartbeat(for: agent.id) },
                onUnexpectedTermination: { [weak self] terminated, detail, needsRecovery in
                    self?.runtimeTerminated(terminated, agent: agent, repository: repository, detail: detail, needsRecovery: needsRecovery)
                }
            )
            processes[agent.id] = process
            process.start()
        case .codex:
            restartTasks.removeValue(forKey: agent.id)?.cancel()
            let process = CodexAgentProcess(
                agent: agent,
                executableURL: URL(fileURLWithPath: executablePath),
                workspaceURL: repository.directory(for: agent),
                extendedAccess: accessConfiguration.isExtended(agent.id),
                recoverInterruptedWork: recoveryPending.remove(agent.id) != nil,
                onSnapshot: { [weak self] snapshot in
                    if self?.snapshots[snapshot.agentID]?.phase == .working,
                       snapshot.phase == .ready {
                        self?.recordActivity(for: snapshot.agentID)
                    }
                    self?.snapshots[snapshot.agentID] = snapshot
                    if snapshot.phase == .ready {
                        self?.markStable(agentID: snapshot.agentID)
                    }
                },
                onHeartbeat: { [weak self] in
                    self?.recordHeartbeat(for: agent.id)
                },
                onApprovals: { [weak self] pending in
                    self?.approvals.removeAll { $0.agentID == agent.id }
                    self?.approvals.append(contentsOf: pending)
                },
                onUnexpectedTermination: { [weak self] terminated, detail, needsRecovery in
                    self?.runtimeTerminated(
                        terminated,
                        agent: agent,
                        repository: repository,
                        detail: detail,
                        needsRecovery: needsRecovery
                    )
                }
            )
            processes[agent.id] = process
            process.start()
        case .claudeCode:
            restartTasks.removeValue(forKey: agent.id)?.cancel()
            let process = ClaudeAgentProcess(
                agent: agent,
                executableURL: URL(fileURLWithPath: executablePath),
                workspaceURL: repository.directory(for: agent),
                extendedAccess: accessConfiguration.isExtended(agent.id),
                recoverInterruptedWork: recoveryPending.remove(agent.id) != nil,
                onSnapshot: runtimeSnapshotHandler(for: agent.id),
                onHeartbeat: { [weak self] in self?.recordHeartbeat(for: agent.id) },
                onUnexpectedTermination: { [weak self] terminated, detail, needsRecovery in
                    self?.runtimeTerminated(
                        terminated,
                        agent: agent,
                        repository: repository,
                        detail: detail,
                        needsRecovery: needsRecovery
                    )
                }
            )
            processes[agent.id] = process
            process.start()
        }
        recoverUnreadMessages(for: agent, process: processes[agent.id], repository: repository)
    }

    func restart(
        agent: AgentRecord,
        repository: WorkspaceRepository,
        resetThread: Bool = false
    ) {
        guard !changingAccess.contains(agent.id) else { return }
        cancelSupervision(for: agent.id)
        changingAccess.insert(agent.id)
        let lifecycle = lifecycleID
        let old = processes.removeValue(forKey: agent.id)
        if resetThread {
            let provider = HarnessProvider(rawValue: agent.harnessIdentifier ?? "")
            let prefix = provider == .grokBuild ? "grok-runtime" : (provider == .fx ? "fx-runtime" : (provider == .claudeCode ? "claude-runtime" : "codex-runtime"))
            let filename = accessConfiguration.isExtended(agent.id)
                ? ".agents/\(prefix)-extended.json" : ".agents/\(prefix).json"
            try? FileManager.default.removeItem(at: repository.directory(for: agent).appendingPathComponent(filename))
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
        cancelSupervision(for: agentID)
        recoveryPending.remove(agentID)
        changingAccess.remove(agentID)
        approvals.removeAll { $0.agentID == agentID }
        accessConfiguration.remove(agentID)
        accessConfiguration.save(to: defaults)
        processes.removeValue(forKey: agentID)?.stop { _ in }
        snapshots.removeValue(forKey: agentID)
        heartbeatScheduler.remove(agentID)
        saveHeartbeatActivityDates()
        lastHeartbeatDates.removeValue(forKey: agentID)
        saveLastHeartbeatDates()
    }

    func stopAll() {
        fxCapabilityTask?.cancel()
        grokCapabilityTask?.cancel()
        isStoppingAll = true
        lifecycleID = UUID()
        changingAccess = []
        approvals = []
        capabilityProbe?.stop()
        capabilityProbe = nil
        restartTasks.values.forEach { $0.cancel() }
        restartTasks.removeAll()
        stabilityTasks.values.forEach { $0.cancel() }
        stabilityTasks.removeAll()
        restartAttempts.removeAll()
        recoveryPending.removeAll()
        processes.values.forEach { $0.stop { _ in } }
        processes.removeAll()
        snapshots = snapshots.mapValues {
            AgentRuntimeSnapshot(agentID: $0.agentID, phase: .offline, detail: "Stopped")
        }
    }

    func reconcile(agents: [AgentRecord], repository: WorkspaceRepository, immediately: Bool = false) {
        guard !isStoppingAll else { return }
        for agent in agents where installation(for: agent) != nil {
            if let process = processes[agent.id], process.isAlive { continue }
            if let process = processes.removeValue(forKey: agent.id) {
                if process.hasInterruptedWork {
                    recoveryPending.insert(agent.id)
                }
                process.stop { _ in }
            }
            if immediately {
                restartTasks.removeValue(forKey: agent.id)?.cancel()
            }
            guard restartTasks[agent.id] == nil,
                  !changingAccess.contains(agent.id),
                  !blockedRestarts.contains(agent.id) else { continue }
            scheduleRestart(agent: agent, repository: repository, detail: "Runtime connection was lost", immediately: immediately)
        }
    }

    private func runtimeTerminated(
        _ terminated: any AgentRuntimeProcess,
        agent: AgentRecord,
        repository: WorkspaceRepository,
        detail: String,
        needsRecovery: Bool
    ) {
        guard !isStoppingAll,
              let current = processes[agent.id],
              ObjectIdentifier(current) == ObjectIdentifier(terminated) else { return }
        processes.removeValue(forKey: agent.id)
        approvals.removeAll { $0.agentID == agent.id }
        stabilityTasks.removeValue(forKey: agent.id)?.cancel()
        if needsRecovery { recoveryPending.insert(agent.id) }
        scheduleRestart(agent: agent, repository: repository, detail: detail)
    }

    private func scheduleRestart(
        agent: AgentRecord,
        repository: WorkspaceRepository,
        detail: String,
        immediately: Bool = false
    ) {
        guard !isStoppingAll, restartTasks[agent.id] == nil else { return }
        let attempt = min((restartAttempts[agent.id] ?? 0) + 1, 7)
        restartAttempts[agent.id] = attempt
        let delay = immediately ? 0 : min(pow(2.0, Double(attempt - 1)), 30)
        let delayText = delay == 0 ? "now" : "in \(Int(delay)) seconds"
        snapshots[agent.id] = .init(
            agentID: agent.id,
            phase: .starting,
            detail: "\(detail). Restarting \(delayText)…"
        )
        restartTasks[agent.id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled, !self.isStoppingAll else { return }
            self.restartTasks[agent.id] = nil
            self.start(agent: agent, repository: repository)
        }
    }

    private func markStable(agentID: UUID) {
        guard stabilityTasks[agentID] == nil,
              let process = processes[agentID] else { return }
        stabilityTasks[agentID] = Task { [weak self, weak process] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, let process, !Task.isCancelled,
                  self.processes[agentID].map(ObjectIdentifier.init) == ObjectIdentifier(process),
                  process.isAlive else { return }
            self.restartAttempts[agentID] = nil
            self.stabilityTasks[agentID] = nil
        }
    }

    private func cancelSupervision(for agentID: UUID) {
        restartTasks.removeValue(forKey: agentID)?.cancel()
        stabilityTasks.removeValue(forKey: agentID)?.cancel()
        restartAttempts.removeValue(forKey: agentID)
    }

    private func runtimeSnapshotHandler(for agentID: UUID) -> @MainActor (AgentRuntimeSnapshot) -> Void {
        { [weak self] snapshot in
            if self?.snapshots[snapshot.agentID]?.phase == .working, snapshot.phase == .ready {
                self?.recordActivity(for: snapshot.agentID)
            }
            self?.snapshots[snapshot.agentID] = snapshot
            if snapshot.phase == .ready { self?.markStable(agentID: agentID) }
        }
    }

    private func recoverUnreadMessages(
        for agent: AgentRecord,
        process: (any AgentRuntimeProcess)?,
        repository: WorkspaceRepository
    ) {
        guard let process else { return }
        Task { [weak self, weak process] in
            let hasUnread = await Task.detached {
                (try? repository.latestMessages(for: agent.id, consuming: false).isEmpty == false) ?? false
            }.value
            guard let self, let process,
                  self.processes[agent.id].map(ObjectIdentifier.init) == ObjectIdentifier(process) else { return }
            if hasUnread { process.notify() }
        }
    }

}

@MainActor
final class CodexAgentProcess: AgentRuntimeProcess {
    private enum RequestPurpose {
        case initialize
        case startThread
        case resumeThread
        case setThreadName
        case startTurn(AgentWakeReason)
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
    private let onHeartbeat: @MainActor () -> Void
    private let onUnexpectedTermination: @MainActor (CodexAgentProcess, String, Bool) -> Void
    private let stateURL: URL
    private var turnRecovery: AgentTurnRecovery

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
    private var recoveryPending: Bool
    private var intentionallyStopped = false
    private var terminationReported = false
    private var lastErrorText: String?
    private lazy var trace = RuntimeTrace(agentID: configuration.id, provider: .codex, workspace: workspaceURL)

    private(set) var snapshot: AgentRuntimeSnapshot

    init(
        agent: AgentRecord,
        executableURL: URL,
        workspaceURL: URL,
        extendedAccess: Bool,
        recoverInterruptedWork: Bool,
        onSnapshot: @escaping @MainActor (AgentRuntimeSnapshot) -> Void,
        onHeartbeat: @escaping @MainActor () -> Void,
        onApprovals: @escaping @MainActor ([AgentApprovalRequest]) -> Void,
        onUnexpectedTermination: @escaping @MainActor (CodexAgentProcess, String, Bool) -> Void
    ) {
        configuration = agent
        self.executableURL = executableURL
        self.workspaceURL = workspaceURL
        self.extendedAccess = extendedAccess
        self.onApprovals = onApprovals
        self.onSnapshot = onSnapshot
        self.onHeartbeat = onHeartbeat
        self.onUnexpectedTermination = onUnexpectedTermination
        stateURL = workspaceURL.appendingPathComponent(extendedAccess ? ".agents/codex-runtime-extended.json" : ".agents/codex-runtime.json")
        turnRecovery = AgentTurnRecovery(sessionStateURL: stateURL)
        recoveryPending = recoverInterruptedWork || turnRecovery.hasUnfinishedTurn
        snapshot = AgentRuntimeSnapshot(agentID: agent.id, phase: .offline, detail: "Not started")
        let state = Self.loadState(from: stateURL)
        threadID = state?.version == Self.runtimeVersion ? state?.threadID : nil
    }

    func start() {
        guard process == nil, extendedConnection == nil else { return }
        intentionallyStopped = false
        terminationReported = false
        update(.starting, "Starting Codex")
        trace.runtimeStarting()

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
                connection.onFailure = { [weak self] detail in
                    Task { @MainActor in self?.reportUnexpectedTermination(detail) }
                }
                extendedRunning = true
                connection.start(provider: .codex, agentID: configuration.id, executablePath: executableURL.path) { [weak self] pid, error in
                    Task { @MainActor in
                        guard let self, !self.intentionallyStopped else { return }
                        if let error { self.reportUnexpectedTermination(error); return }
                        self.extendedPID = pid
                        do { try self.initialize() }
                        catch { self.reportUnexpectedTermination(error.localizedDescription) }
                    }
                }
            } catch { reportUnexpectedTermination(error.localizedDescription) }
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
            environment["NOODLE_AGENT_ID"] = configuration.id.uuidString.lowercased()
            environment["NOODLE_WORKSPACE"] = workspaceURL.path
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
        } catch { reportUnexpectedTermination(error.localizedDescription) }
    }

    private func initialize() throws {
        try request(.initialize, method: "initialize", params: [
            "clientInfo": ["name": "noodle", "title": "Noodle", "version": noodleAppVersion],
            "capabilities": ["experimentalApi": true]
        ])
    }

    func stop(completion: @escaping (Bool) -> Void = { _ in }) {
        trace.finish(.runtimeStopped)
        intentionallyStopped = true
        terminationReported = true
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
        RuntimeDiagnostics.notificationQueued(agentID: configuration.id, coalesced: notificationPending)
        notificationPending = true
        if process == nil { start() }
        sendPendingNotificationIfPossible()
    }

    var canReceiveHeartbeat: Bool {
        (process?.isRunning == true || extendedRunning) && snapshot.phase == .ready
            && !turnIsActive && !notificationPending && threadID != nil
    }

    var isAlive: Bool { process?.isRunning == true || extendedRunning }

    var hasInterruptedWork: Bool {
        recoveryPending || turnIsActive || notificationPending || turnRecovery.hasUnfinishedTurn
    }

    func heartbeat() {
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
        terminationReported = true
        let needsRecovery = hasInterruptedWork
        extendedRunning = false
        extendedConnection?.invalidate()
        extendedConnection = nil
        pendingApprovals = []
        onApprovals([])
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
        fail(detail)
        onUnexpectedTermination(self, detail, needsRecovery)
    }

    private func handle(_ message: [String: Any]) {
        guard !intentionallyStopped, process != nil || extendedRunning else { return }
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
            if let response = approval.automaticResponse(extendedAccess: extendedAccess) {
                do { try send(response) }
                catch { fail(error.localizedDescription) }
                return
            }
            if !pendingApprovals.contains(where: { $0.requestID == approval.requestID }) {
                pendingApprovals.append(approval)
                onApprovals(pendingApprovals)
                update(.working, "Waiting for your response")
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
                saveState(threadID: id)
                setThreadName(id)
            case .setThreadName:
                finishOpeningThread()
            case .startTurn(let reason):
                trace.record(.turnAccepted)
                turnIsActive = true
                update(.working, snapshot.detail)
                if reason == .heartbeat { onHeartbeat() }
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
            guard turnIsActive else { return }
            if let reportedThread = (message["params"] as? [String: Any])?["threadId"] as? String,
               reportedThread != threadID { return }
            do { try turnRecovery.finish() }
            catch {
                fail("Could not record finished Codex work: \(error.localizedDescription)")
                return
            }
            approvalItemDetails = [:]
            pendingApprovals = []
            onApprovals([])
            turnIsActive = false
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

    private func finishOpeningThread() {
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
        trace.begin(reason: reason)
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
                self.reportUnexpectedTermination("Could not communicate with Codex: \(error.localizedDescription)")
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
        trace.finish(.runtimeFailed)
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
            update(.working, pendingApprovals.isEmpty ? "Continuing agent work" : "Waiting for your response")
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

    private static var developerInstructions: String { MessengerDocumentation.bootstrapInstructions }

    private var accessInstructions: String {
        let mode = extendedAccess
            ? "This bot has autonomous extended access. Noodle resolves supported runtime permission requests automatically, so continue without asking the user to approve routine commands, file operations, or tool confirmations. Ask the user only when required information or a consequential product decision is missing. Never change your own access mode."
            : "This bot is in restricted mode inside Noodle's macOS App Sandbox. Browser/computer-control runtimes may be unavailable. Do not try to bypass the app sandbox; explain the limitation and direct the user to Settings → Security if the task requires autonomous access."
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
