import Darwin
import Foundation
import Observation
import NoodleCore

/// What the Agent Host reports about a harness the sandboxed app cannot inspect itself.
struct HarnessHostInspection {
    let executablePath: String?
    let models: [HarnessModel]
    /// Why the harness cannot be used yet, shown beside it in Settings.
    let capabilityError: String?

    init(executablePath: String?, models: [HarnessModel], capabilityError: String?) {
        self.executablePath = executablePath
        self.models = models
        self.capabilityError = capabilityError
    }

    init(_ result: GrokInspectionResult) {
        self.init(executablePath: result.executablePath, models: result.models,
            capabilityError: result.executablePath == nil ? "Grok Build is not installed" : (result.authenticated ? nil : "Sign in to Grok Build in Settings → Harness."))
    }

    init(_ result: OpenCodeInspectionResult) {
        self.init(executablePath: result.executablePath, models: result.models,
            capabilityError: result.executablePath == nil ? "OpenCode is not installed" : (result.authenticated || !result.models.isEmpty ? nil : "Run opencode auth login in Terminal, then check again."))
    }

    init(_ result: MuseInspectionResult) {
        self.init(executablePath: result.executablePath, models: result.models,
            capabilityError: result.executablePath == nil ? "Muse Code is not installed" : nil)
    }

    static let providers: [HarnessProvider] = [.openCode, .grokBuild, .muse]

    @MainActor static func load(_ provider: HarnessProvider) async throws -> HarnessHostInspection {
        switch provider {
        case .grokBuild: return .init(try await GrokHostProbe().load())
        case .openCode: return .init(try await OpenCodeHostProbe().load())
        case .muse: return .init(try await MuseHostProbe().load())
        default: throw HarnessSetupError("\(provider.displayName) is not inspected by the Agent Host.")
        }
    }
}

/// A confirmation is valid only for this bot configuration, runtime, and failure.
struct AgentKickRequest: Identifiable {
    let id = UUID()
    let agent: AgentRecord
    let failure: AgentRuntimeFailure
    fileprivate let runtimeID: UUID?
    fileprivate let lifecycleID: UUID
    fileprivate let extendedAccess: Bool

    var title: String {
        switch failure {
        case .missingSession: return "Recover \(agent.displayName)?"
        case .usageLimit: return "Usage limit reached"
        case .authenticationRequired: return "Sign in to reconnect \(agent.displayName)"
        case .recoveryFailed: return "Retry recovery?"
        }
    }

    var message: String {
        switch failure {
        case .missingSession:
            return "The previous session is unavailable. Noodle can start a replacement and help \(agent.displayName) continue using your conversation history.\n\nYour messages, files, and bot settings will be kept. Details remembered only within the previous session may be lost."
        case .usageLimit:
            return "The harness's usage limit has been reached. Once usage is available again, retry to continue. Restarting cannot restore usage. Your session and unfinished work will be kept."
        case .authenticationRequired:
            return "The harness needs you to sign in again. Open Harness settings for sign-in options, then retry. Your session and unfinished work will be kept."
        case .recoveryFailed:
            return "Noodle will retry recovery using your conversation history. Your messages and files will be kept."
        }
    }
}

@MainActor
@Observable
final class AgentRuntimeCoordinator {
    let activity = AgentActivityStore()
    private(set) var installations: [HarnessInstallation]
    private(set) var modelsByProvider: [HarnessProvider: [HarnessModel]] = [:]
    private(set) var capabilityErrors: [HarnessProvider: String] = [:]
    /// Last known answer from the Apple host probe. It survives failed or
    /// skipped probes so Local Models can open without waiting for a new one.
    private(set) var appleLocalModelsSupported: Bool?
    private(set) var isLoadingCapabilities = false
    private(set) var isRefreshingInstallations = false
    private var installationChanges = 0
    private(set) var installationErrors: [HarnessProvider: String] = [:]
    private(set) var snapshots: [UUID: AgentRuntimeSnapshot] = [:] {
        didSet {
            activity.recordSnapshots(snapshots.filter { oldValue[$0.key] != $0.value })
            updateSleepAssertion()
        }
    }
    private(set) var preventIdleSleepWhileWorking: Bool
    private(set) var heartbeatConfiguration: AgentHeartbeatConfiguration
    private(set) var lastHeartbeatDates: [UUID: Date]
    private(set) var accessConfiguration: AgentAccessConfiguration
    private(set) var changingAccess: Set<UUID> = []
    @ObservationIgnored private let sleepController = AgentActivitySleepController()
    private var lifecycleID = UUID()
    private var transitionIDs: [UUID: UUID] = [:]
    private var blockedRestarts: Set<UUID> = []
    private var failedStops: [UUID: any AgentRuntimeProcess] = [:]
    private var restartAttempts: [UUID: Int] = [:]
    // Startup success alone does not reset this budget: a turn must finish,
    // or the user must explicitly retry.
    private var connectionRecoveryAttempts: [UUID: Int] = [:]
    @ObservationIgnored private var restartTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var stabilityTasks: [UUID: Task<Void, Never>] = [:]
    private var recoveryPending: Set<UUID> = []
    private var blockedRecoveries: Set<UUID> = []
    private var isStoppingAll = false

    @ObservationIgnored private var heartbeatScheduler: AgentHeartbeatScheduler
    private let defaults: UserDefaults
    @ObservationIgnored private lazy var messageDelivery = MessageDeliveryRouter(defaults: defaults)

    private var discovery: HarnessDiscovery
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private let makeProcess: @MainActor (AgentRuntimeLaunch) -> any AgentRuntimeProcess
    @ObservationIgnored private let inspectHost: @MainActor (HarnessProvider) async throws -> HarnessHostInspection
    private var processes: [UUID: any AgentRuntimeProcess] = [:]
    private var runtimeIDs: [UUID: UUID] = [:]
    private var capabilityProbe: CodexCapabilityProbe?
    private var fxCapabilityTask: Task<Void, Never>?
    private var codexCapabilityTask: Task<Void, Never>?
    private var hostCapabilityTasks: [HarnessProvider: Task<Void, Never>] = [:]
    /// What the Agent Host last reported, which outranks the app's own discovery.
    private var hostInstallations: [HarnessProvider: HarnessInstallation] = [:]
    private var appleCapabilityTask: Task<Void, Never>?

    private func refreshAppleCapabilities() async {
        guard discovery.discover(.apple).isAvailable else {
            modelsByProvider[.apple] = []
            return
        }
        do {
            let result = try await AppleHostProbe().load()
            guard !Task.isCancelled else { return }
            modelsByProvider[.apple] = result.models
            capabilityErrors[.apple] = result.unavailableReason
            appleLocalModelsSupported = result.localModelsSupported == true
        } catch {
            guard !Task.isCancelled else { return }
            modelsByProvider[.apple] = []
            capabilityErrors[.apple] = error.localizedDescription
        }
    }

    func recordAppleLocalModelsSupport(_ supported: Bool) {
        if appleLocalModelsSupported != supported { appleLocalModelsSupported = supported }
    }

    private func discoveredInstallations() -> [HarnessInstallation] {
        discovery.discover().map { hostInstallations[$0.provider] ?? $0 }
    }

    private func refreshHostCapabilities(_ provider: HarnessProvider) async {
        guard discovery.allowsHostDiscovery(for: provider) else { return }
        do {
            let result = try await inspectHost(provider)
            guard !Task.isCancelled else { return }
            let installation = HarnessInstallation(provider: provider, executablePath: result.executablePath)
            hostInstallations[provider] = installation
            installationErrors[provider] = nil
            installations = installations.map { $0.provider == provider ? installation : $0 }
            modelsByProvider[provider] = result.models
            capabilityErrors[provider] = result.capabilityError
        } catch {
            guard !Task.isCancelled else { return }
            installationErrors[provider] = error.localizedDescription
            capabilityErrors[provider] = error.localizedDescription
        }
    }

    init(discovery: HarnessDiscovery = HarnessDiscovery(), defaults: UserDefaults = .standard,
         makeProcess: @escaping @MainActor (AgentRuntimeLaunch) -> any AgentRuntimeProcess = { $0.makeProcess() },
         inspectHost: @escaping @MainActor (HarnessProvider) async throws -> HarnessHostInspection = { try await HarnessHostInspection.load($0) },
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @MainActor () -> Date = Date.init) {
        self.now = now
        self.sleep = sleep
        self.makeProcess = makeProcess
        self.inspectHost = inspectHost
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

    /// No bot receives access implicitly: a first launch records an empty grant list, later launches load what was saved.
    func prepareAccessForExistingAgents() {
        accessConfiguration = AgentAccessConfiguration.migrateExistingAgents([], in: defaults)
        accessConfiguration.migrateRequiredHarnessGrants([], in: defaults)
    }

    func authorizeSelectedHarness(_ agent: AgentRecord) {
        accessConfiguration.authorizeSelectedHarness(for: agent)
        accessConfiguration.save(to: defaults)
    }

    func setExtendedAccess(_ enabled: Bool, agent: AgentRecord, repository: WorkspaceRepository) {
        let required = HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.supportsRestrictedAccess == false
        guard (!required || enabled), accessConfiguration.isExtended(for: agent) != enabled else { return }
        changeAccess(enabled, agent: agent, repository: repository) { configuration in
            if required { configuration.authorizeSelectedHarness(for: agent) }
            else { configuration.setExtended(enabled, for: agent.id) }
        }
    }

    func setAppsEnabled(_ enabled: Bool, agent: AgentRecord, repository: WorkspaceRepository) {
        guard HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.supportsAccountApps == true,
              accessConfiguration.appsEnabled(for: agent) != enabled else { return }
        changeAccess(enabled, agent: agent, repository: repository) { $0.setAppsEnabled(enabled, for: agent) }
    }

    private func changeAccess(_ enabled: Bool, agent: AgentRecord, repository: WorkspaceRepository,
                              apply: @escaping (inout AgentAccessConfiguration) -> Void) {
        guard !changingAccess.contains(agent.id), !blockedRestarts.contains(agent.id) else { return }
        cancelSupervision(for: agent.id)
        changingAccess.insert(agent.id)
        let transitionID = UUID()
        transitionIDs[agent.id] = transitionID
        let lifecycle = lifecycleID
        // Persist revocation before stopping so relaunch cannot restore access.
        // Grants are saved only after the previous process has stopped.
        if !enabled {
            apply(&accessConfiguration)
            accessConfiguration.save(to: defaults)
        }
        runtimeIDs[agent.id] = nil
        let old = processes.removeValue(forKey: agent.id)
        snapshots[agent.id] = .init(agentID: agent.id, phase: .starting, detail: "Changing agent access…")
        let finish: (Bool) -> Void = { [weak self] stopped in
            guard let self else { return }
            guard self.lifecycleID == lifecycle, self.transitionIDs[agent.id] == transitionID else { return }
            self.changingAccess.remove(agent.id)
            self.transitionIDs[agent.id] = nil
            guard stopped else {
                self.failedStops[agent.id] = old
                self.blockedRestarts.insert(agent.id)
                self.snapshots[agent.id] = .init(agentID: agent.id, phase: .failed, detail: "Could not confirm that the old runtime stopped. Use Kick to retry.")
                return
            }
            apply(&self.accessConfiguration)
            self.accessConfiguration.save(to: self.defaults)
            self.start(agent: agent, repository: repository)
        }
        if let old { old.stop(completion: finish) } else { finish(true) }
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
        heartbeatScheduler.configure(configuration, at: now())
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
        heartbeatScheduler.recordActivity(for: agentID, at: now())
        saveHeartbeatActivityDates()
    }

    private func recordHeartbeat(for agentID: UUID) {
        lastHeartbeatDates[agentID] = now()
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
        let dueIDs = heartbeatScheduler.takeDueHeartbeats(readyAgentIDs: readyIDs, at: now())
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
        for provider in HarnessHostInspection.providers { await refreshHostCapabilities(provider) }
        await refreshAppleCapabilities()
        guard !Task.isCancelled else { return }
        // Look after the slow host probes, and again if Noodle installed or removed
        // a harness meanwhile: an earlier snapshot would undo that change.
        let discovery = discovery
        var detected: [HarnessInstallation]
        var changes: Int
        repeat {
            changes = installationChanges
            detected = await Task.detached(priority: .utility) { discovery.discover() }.value
            guard !Task.isCancelled else { return }
        } while changes != installationChanges
        let complete = detected.map { hostInstallations[$0.provider] ?? $0 }
        if installations != complete { installations = complete }
    }

    /// Noodle installed or removed this harness itself. Only its files changed,
    /// so the other harnesses need none of the host probes a full refresh runs.
    @discardableResult
    func refreshInstallation(_ provider: HarnessProvider) -> HarnessInstallation {
        installationChanges += 1
        // What the Agent Host last reported for this harness is now out of date.
        hostInstallations[provider] = nil
        let installation = discovery.discover(provider)
        installations = installations.map { $0.provider == provider ? installation : $0 }
        return installation
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
        activity.retainAgents(liveIDs)
        let trackedIDs = Set(processes.keys).union(restartTasks.keys).union(stabilityTasks.keys)
            .union(changingAccess).union(recoveryPending).union(blockedRecoveries).union(blockedRestarts)
        for id in trackedIDs where !liveIDs.contains(id) {
            runtimeIDs[id] = nil
            processes.removeValue(forKey: id)?.stop { _ in }
            failedStops.removeValue(forKey: id)?.stop { _ in }
            blockedRestarts.remove(id)
            cancelSupervision(for: id)
            connectionRecoveryAttempts[id] = nil
            changingAccess.remove(id)
            transitionIDs[id] = nil
            recoveryPending.remove(id)
            blockedRecoveries.remove(id)
            heartbeatScheduler.remove(id)
            saveHeartbeatActivityDates()
        }

        for agent in agents {
            if blockedRestarts.contains(agent.id) { continue }
            if blockedRecoveries.contains(agent.id), connectionRecoveryAttempts[agent.id] != nil { continue }
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
            for agent in agents where processes[agent.id]?.configuration != agent
                && !blockedRestarts.contains(agent.id)
                && !(blockedRecoveries.contains(agent.id) && connectionRecoveryAttempts[agent.id] != nil) {
                restart(agent: agent, repository: repository)
            }
        }
    }

    func refreshCapabilities() {
        installations = discoveredInstallations()
        appleCapabilityTask?.cancel()
        appleCapabilityTask = Task { [weak self] in await self?.refreshAppleCapabilities() }
        for provider in HarnessHostInspection.providers {
            hostCapabilityTasks[provider]?.cancel()
            hostCapabilityTasks[provider] = Task { [weak self] in await self?.refreshHostCapabilities(provider) }
        }
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
        codexCapabilityTask?.cancel()
        codexCapabilityTask = nil
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            // A Codex that Noodle installed sits in the app's container, where the
            // sandbox lets only the Agent Host run it.
            codexCapabilityTask = Task { [weak self] in
                do {
                    let models = try await FxModelProbe().load(path: executablePath, provider: .codex)
                    guard !Task.isCancelled else { return }
                    self?.modelsByProvider[.codex] = models
                    self?.capabilityErrors[.codex] = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.modelsByProvider[.codex] = []
                    self?.capabilityErrors[.codex] = error.localizedDescription
                }
                self?.isLoadingCapabilities = false
            }
            return
        }
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
        guard processes[agent.id] == nil, !changingAccess.contains(agent.id), !blockedRestarts.contains(agent.id),
              !blockedRecoveries.contains(agent.id) else { return }
        if HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.supportsRestrictedAccess == false,
           !accessConfiguration.isExtended(for: agent) {
            snapshots[agent.id] = .init(agentID: agent.id, phase: .failed,
                detail: "This harness requires unrestricted access. Allow it in Settings → Sandbox before starting this bot.")
            return
        }
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

        restartTasks.removeValue(forKey: agent.id)?.cancel()
        let runtimeID = UUID()
        runtimeIDs[agent.id] = runtimeID
        let process = makeProcess(AgentRuntimeLaunch(
            agent: agent, provider: installation.provider,
            executableURL: URL(fileURLWithPath: executablePath), workspaceURL: repository.directory(for: agent),
            extendedAccess: accessConfiguration.isExtended(for: agent),
            appsEnabled: accessConfiguration.appsEnabled(for: agent),
            recoverInterruptedWork: recoveryPending.remove(agent.id) != nil,
            onSnapshot: runtimeSnapshotHandler(for: agent.id, runtimeID: runtimeID),
            onHeartbeat: { [weak self] in
                guard let self, self.runtimeIDs[agent.id] == runtimeID else { return }
                self.recordHeartbeat(for: agent.id)
            },
            onUnexpectedTermination: { [weak self] terminated, detail, needsRecovery in
                self?.runtimeTerminated(terminated, agent: agent, repository: repository,
                    detail: detail, needsRecovery: needsRecovery)
            },
            onActivity: { [weak self] message in
                guard let self, self.runtimeIDs[agent.id] == runtimeID else { return }
                self.activity.record(message, provider: installation.provider, agentID: agent.id)
            }))
        processes[agent.id] = process
        process.start()
        recoverUnreadMessages(for: agent, process: processes[agent.id], repository: repository)
    }

    /// Ordinary Kick remains immediate; replacing a missing session requires a
    /// concrete confirmation. Account failures explain the prerequisite first.
    func kick(agent: AgentRecord, repository: WorkspaceRepository) -> AgentKickRequest? {
        guard !isStoppingAll, !changingAccess.contains(agent.id), snapshot(for: agent.id).canKick else { return nil }
        connectionRecoveryAttempts[agent.id] = nil
        if let failure = snapshot(for: agent.id).failure, failure != .recoveryFailed {
            return AgentKickRequest(agent: agent, failure: failure, runtimeID: runtimeIDs[agent.id],
                lifecycleID: lifecycleID, extendedAccess: accessConfiguration.isExtended(for: agent))
        }
        restart(agent: agent, repository: repository,
            sessionRecovery: snapshot(for: agent.id).failure == .recoveryFailed ? .retry : nil,
            retryFailedStop: true)
        return nil
    }

    func confirmKick(_ request: AgentKickRequest, repository: WorkspaceRepository) {
        let agent = request.agent
        guard !isStoppingAll, !changingAccess.contains(agent.id),
              lifecycleID == request.lifecycleID, runtimeIDs[agent.id] == request.runtimeID,
              snapshot(for: agent.id).phase == .failed, snapshot(for: agent.id).failure == request.failure,
              processes[agent.id].map({ $0.configuration == agent }) ?? true,
              accessConfiguration.isExtended(for: agent) == request.extendedAccess else { return }
        let recovery: SessionRecovery
        switch request.failure {
        case .missingSession(let sessionID): recovery = .replace(sessionID)
        case .usageLimit, .authenticationRequired, .recoveryFailed: recovery = .retry
        }
        restart(agent: agent, repository: repository, sessionRecovery: recovery)
    }

    func restart(
        agent: AgentRecord,
        repository: WorkspaceRepository,
        resetThread: Bool = false
    ) {
        guard !changingAccess.contains(agent.id) else { return }
        connectionRecoveryAttempts[agent.id] = nil
        restart(agent: agent, repository: repository, resetThread: resetThread, sessionRecovery: nil)
    }

    private enum SessionRecovery { case replace(String), retry }

    private func restart(
        agent: AgentRecord,
        repository: WorkspaceRepository,
        resetThread: Bool = false,
        sessionRecovery: SessionRecovery?,
        pauseAfterStop: Bool = false,
        retryFailedStop: Bool = false
    ) {
        guard !isStoppingAll, !changingAccess.contains(agent.id),
              !blockedRestarts.contains(agent.id) || retryFailedStop else { return }
        blockedRecoveries.remove(agent.id)
        if pauseAfterStop { blockedRecoveries.insert(agent.id) }
        cancelSupervision(for: agent.id)
        changingAccess.insert(agent.id)
        let transitionID = UUID()
        transitionIDs[agent.id] = transitionID
        let lifecycle = lifecycleID
        runtimeIDs[agent.id] = nil
        let old = processes.removeValue(forKey: agent.id) ?? failedStops[agent.id]
        if !resetThread, old?.hasInterruptedWork == true { recoveryPending.insert(agent.id) }
        if resetThread {
            recoveryPending.remove(agent.id)
            let provider = HarnessProvider(rawValue: agent.harnessIdentifier ?? "") ?? .codex
            let state = repository.storage(for: agent.id).sessionState(provider: provider,
                extendedAccess: accessConfiguration.isExtended(for: agent))
            try? FileManager.default.removeItem(at: state)
            try? FileManager.default.removeItem(at: state.appendingPathExtension("unfinished"))
        }
        let finish: (Bool) -> Void = { [weak self] stopped in
            guard let self else { return }
            guard self.lifecycleID == lifecycle, self.transitionIDs[agent.id] == transitionID else { return }
            self.changingAccess.remove(agent.id)
            self.transitionIDs[agent.id] = nil
            if stopped {
                self.failedStops[agent.id] = nil
                self.blockedRestarts.remove(agent.id)
                if pauseAfterStop {
                    self.snapshots[agent.id] = .init(agentID: agent.id, phase: .failed,
                        detail: "Codex could not reconnect after two automatic restarts. Use Kick to retry. Unfinished work is preserved.")
                    return
                }
                if let sessionRecovery {
                    do {
                        let storage = repository.storage(for: agent.id)
                        try storage.validate()
                        guard let provider = agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:)),
                              provider == .grokBuild || provider == .openCode else {
                            throw HarnessSetupError("This harness does not support session recovery through Kick.")
                        }
                        let state = storage.sessionState(provider: provider,
                            extendedAccess: self.accessConfiguration.isExtended(for: agent))
                        switch sessionRecovery {
                        case .replace(let sessionID): try ACPSessionState.prepareRecovery(at: state, replacing: sessionID)
                        case .retry: try ACPSessionState.allowRecoveryRetry(at: state)
                        }
                    } catch {
                        self.blockedRecoveries.insert(agent.id)
                        self.snapshots[agent.id] = .init(agentID: agent.id, phase: .failed,
                            detail: "Could not prepare recovery. Your messages and files are preserved. Choose Kick to check again.",
                            failure: .recoveryFailed)
                        return
                    }
                }
                self.start(agent: agent, repository: repository)
            }
            else {
                self.failedStops[agent.id] = old
                self.blockedRestarts.insert(agent.id)
                self.snapshots[agent.id] = .init(agentID: agent.id, phase: .failed, detail: "The previous runtime could not be stopped. Use Kick to retry.")
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
            if let process = processes[agent.id] { messageDelivery.notify(process, repository: repository) }
        }
    }

    func stop(agentID: UUID, revokeAccess: Bool = true) {
        connectionRecoveryAttempts[agentID] = nil
        blockedRecoveries.remove(agentID)
        runtimeIDs[agentID] = nil
        cancelSupervision(for: agentID)
        recoveryPending.remove(agentID)
        changingAccess.remove(agentID)
        transitionIDs[agentID] = nil
        if revokeAccess {
            accessConfiguration.remove(agentID)
            accessConfiguration.save(to: defaults)
        }
        processes.removeValue(forKey: agentID)?.stop { _ in }
        failedStops.removeValue(forKey: agentID)?.stop { _ in }
        blockedRestarts.remove(agentID)
        snapshots.removeValue(forKey: agentID)
        heartbeatScheduler.remove(agentID)
        saveHeartbeatActivityDates()
        lastHeartbeatDates.removeValue(forKey: agentID)
        saveLastHeartbeatDates()
    }

    func stopAll() {
        messageDelivery.cancelAll()
        fxCapabilityTask?.cancel()
        hostCapabilityTasks.values.forEach { $0.cancel() }
        isStoppingAll = true
        lifecycleID = UUID()
        runtimeIDs.removeAll()
        changingAccess = []
        transitionIDs.removeAll()
        capabilityProbe?.stop()
        capabilityProbe = nil
        restartTasks.values.forEach { $0.cancel() }
        restartTasks.removeAll()
        stabilityTasks.values.forEach { $0.cancel() }
        stabilityTasks.removeAll()
        restartAttempts.removeAll()
        connectionRecoveryAttempts.removeAll()
        recoveryPending.removeAll()
        blockedRecoveries.removeAll()
        processes.values.forEach { $0.stop { _ in } }
        processes.removeAll()
        for (id, process) in failedStops {
            process.stop { [weak self] stopped in
                guard let self, stopped, self.failedStops[id] === process else { return }
                self.failedStops[id] = nil
                self.blockedRestarts.remove(id)
            }
        }
        snapshots = snapshots.mapValues {
            AgentRuntimeSnapshot(agentID: $0.agentID, phase: .offline, detail: "Stopped")
        }
    }

    func reconcile(agents: [AgentRecord], repository: WorkspaceRepository, immediately: Bool = false) {
        guard !isStoppingAll else { return }
        for agent in agents where installation(for: agent) != nil {
            if let process = processes[agent.id], process.isAlive {
                if agent.harnessIdentifier == HarnessProvider.codex.rawValue,
                   process.snapshot.phase == .working,
                   let since = process.snapshot.reconnectingSince,
                   now().timeIntervalSince(since) >= 10 * 60,
                   !changingAccess.contains(agent.id), !blockedRecoveries.contains(agent.id) {
                    let attempts = connectionRecoveryAttempts[agent.id] ?? 0
                    connectionRecoveryAttempts[agent.id] = attempts + 1
                    restart(agent: agent, repository: repository, resetThread: false, sessionRecovery: nil,
                            pauseAfterStop: attempts >= 2)
                }
                continue
            }
            if let process = processes.removeValue(forKey: agent.id) {
                runtimeIDs[agent.id] = nil
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
                  !blockedRestarts.contains(agent.id), !blockedRecoveries.contains(agent.id) else { continue }
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
        runtimeIDs[agent.id] = nil
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
        restartTasks[agent.id] = Task { [weak self, sleep] in
            if delay > 0 { try? await sleep(.seconds(delay)) }
            guard let self, !Task.isCancelled, !self.isStoppingAll else { return }
            self.restartTasks[agent.id] = nil
            self.start(agent: agent, repository: repository)
        }
    }

    private func markStable(agentID: UUID) {
        guard stabilityTasks[agentID] == nil,
              let process = processes[agentID] else { return }
        stabilityTasks[agentID] = Task { [weak self, weak process, sleep] in
            try? await sleep(.seconds(60))
            guard let self, let process, !Task.isCancelled,
                  self.processes[agentID].map(ObjectIdentifier.init) == ObjectIdentifier(process),
                  process.isAlive else { return }
            self.restartAttempts[agentID] = nil
            self.stabilityTasks[agentID] = nil
        }
    }

    private func cancelSupervision(for agentID: UUID) {
        messageDelivery.cancel(for: agentID)
        restartTasks.removeValue(forKey: agentID)?.cancel()
        stabilityTasks.removeValue(forKey: agentID)?.cancel()
        restartAttempts.removeValue(forKey: agentID)
    }

    private func runtimeSnapshotHandler(for agentID: UUID, runtimeID: UUID) -> @MainActor (AgentRuntimeSnapshot) -> Void {
        var previousPhase: AgentRuntimePhase?
        return { [weak self] snapshot in
            guard let self, self.runtimeIDs[agentID] == runtimeID, snapshot.agentID == agentID else { return }
            defer { previousPhase = snapshot.phase }
            if previousPhase == .working, snapshot.phase == .ready {
                self.recordActivity(for: agentID)
                self.connectionRecoveryAttempts[agentID] = nil
            }
            self.snapshots[agentID] = snapshot
            if snapshot.phase == .ready { self.markStable(agentID: agentID) }
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
