import Darwin
import Foundation
import Observation
import OSLog
import NoodleCore

/// What the Agent Host reports about a harness the sandboxed app cannot inspect itself.
public struct HarnessHostInspection {
    let executablePath: String?
    let models: [HarnessModel]
    /// Why the harness cannot be used yet, shown beside it in Settings.
    let capabilityError: String?

    public init(executablePath: String?, models: [HarnessModel], capabilityError: String?) {
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

    init(_ result: AntigravityInspectionResult) {
        self.init(executablePath: result.executablePath, models: result.models,
            capabilityError: result.executablePath == nil ? "Antigravity is not installed" : (result.authenticated ? nil : "Run agy in Terminal to sign in, then check again."))
    }

    static let providers: [HarnessProvider] = [.openCode, .grokBuild, .muse, .antigravity]

    @MainActor public static func load(_ provider: HarnessProvider) async throws -> HarnessHostInspection {
        switch provider {
        case .grokBuild: return .init(try await GrokHostProbe.load())
        case .openCode: return .init(try await OpenCodeHostProbe.load())
        case .muse: return .init(try await MuseHostProbe.load())
        case .antigravity: return .init(try await AntigravityHostProbe.load())
        default: throw HarnessSetupError("\(provider.displayName) is not inspected by the Agent Host.")
        }
    }
}

/// A bot running on another profile or harness from Settings because its own login ran out of usage.
/// It uses the selected login, and goes back at an idle point after `returnAfter`.
public struct HarnessFallback: Equatable, Sendable {
    public let primary: HarnessProvider
    public var current: HarnessProvider
    public var profile: UUID?
    var unavailable: Set<HarnessFallbackTarget> = []
    public let returnAfter: Date
    /// How many times in a row the bot's own harness ran out again soon after it came back.
    let flaps: Int
    /// The bot's own login, keyed like SubscriptionUsageStore.
    let primaryKey: String
}

/// A confirmation is valid only for this bot configuration, runtime, and failure.
public struct AgentKickRequest: Identifiable {
    public let id = UUID()
    public let agent: AgentRecord
    public let failure: AgentRuntimeFailure
    fileprivate let runtimeID: UUID?
    fileprivate let lifecycleID: UUID
    fileprivate let extendedAccess: Bool

    public var title: String {
        switch failure {
        case .missingSession: return "Recover \(agent.displayName)?"
        case .usageLimit: return "Usage limit reached"
        case .authenticationRequired: return "Sign in to reconnect \(agent.displayName)"
        case .recoveryFailed: return "Retry recovery?"
        case .safetyStop: return "Safeguards stopped \(agent.displayName)"
        }
    }

    /// The button that agrees.
    public var confirmTitle: String {
        if case .missingSession = failure { return "Recover Bot" }
        if failure == .safetyStop { return "Resume" }
        return "Retry Now"
    }

    /// A safety stop can also be left behind with a fresh session.
    public var offersNewSession: Bool { failure == .safetyStop }

    public var message: String {
        switch failure {
        case .missingSession:
            return "The previous session is unavailable. Noodle can start a replacement and help \(agent.displayName) continue using your conversation history.\n\nYour messages, files, and bot settings will be kept. Details remembered only within the previous session may be lost."
        case .usageLimit:
            return "The harness's usage limit has been reached. The bot resumes by itself once usage is available again. Retry now only if usage is already back. Your session and unfinished work will be kept."
        case .authenticationRequired:
            return "The harness needs you to sign in again. Open Harness settings for sign-in options, then retry. Your session and unfinished work will be kept."
        case .recoveryFailed:
            return "Noodle will retry recovery using your conversation history. Your messages and files will be kept."
        case .safetyStop:
            return "The model's safeguards stopped a response. Resume continues the same session. New Session starts with a fresh context and keeps the workspace, memory and messages."
        }
    }
}

@MainActor
@Observable
public final class AgentRuntimeCoordinator {
    public let activity = AgentActivityStore()
    public private(set) var installations: [HarnessInstallation]
    private(set) var modelsByProvider: [HarnessProvider: [HarnessModel]] = [:]
    public private(set) var capabilityErrors: [HarnessProvider: String] = [:]
    /// Last known answer from the Apple host probe. It survives failed or
    /// skipped probes so Local Models can open without waiting for a new one.
    public private(set) var appleLocalModelsSupported: Bool?
    public private(set) var isLoadingCapabilities = false
    public private(set) var isRefreshingInstallations = false
    private var installationChanges = 0
    public private(set) var installationErrors: [HarnessProvider: String] = [:]
    private(set) var snapshots: [UUID: AgentRuntimeSnapshot] = [:] {
        didSet {
            activity.recordSnapshots(snapshots.filter { oldValue[$0.key] != $0.value })
            // A turn cut short by a restart, stop or crash counts as activity too.
            let leftWork = oldValue.filter { $0.value.phase == .working && snapshots[$0.key]?.phase != .working }
            if !leftWork.isEmpty {
                for id in leftWork.keys { lastActiveDates[id] = now() }
                saveLastActiveDates()
            }
            updateSleepAssertion()
        }
    }
    public private(set) var preventIdleSleepWhileWorking: Bool
    public private(set) var heartbeatConfiguration: AgentHeartbeatConfiguration
    /// When each bot last finished or abandoned a turn, heartbeat turns included.
    public private(set) var lastActiveDates: [UUID: Date]
    @ObservationIgnored private var sessionStartDates: [UUID: Date]
    /// Messages and the turns that answer them; heartbeats do not count.
    @ObservationIgnored private var lastInteractionDates: [UUID: Date]
    @ObservationIgnored private var heartbeatTurns: Set<UUID> = []
    public private(set) var accessConfiguration: AgentAccessConfiguration
    public private(set) var changingAccess: Set<UUID> = []
    @ObservationIgnored private let sleepController = AgentActivitySleepController()
    /// Bots that live on a Noodle Hub. They run there, so they never start here, and one
    /// that was running here stops when it moves.
    public var remoteAgentIDs: Set<UUID> = [] {
        didSet {
            for id in remoteAgentIDs.subtracting(oldValue) {
                if processes[id] != nil { stop(agentID: id, revokeAccess: false) }
                cancelSupervision(for: id)
                snapshots[id] = nil
            }
        }
    }
    /// Archived bots keep everything but never run until they are unarchived.
    public var archivedAgentIDs: Set<UUID> = [] {
        didSet {
            for id in archivedAgentIDs.subtracting(oldValue) {
                if processes[id] != nil { stop(agentID: id, revokeAccess: false) }
                cancelSupervision(for: id)
                snapshots[id] = nil
            }
        }
    }
    /// Hub owners may suspend a user's bots without archiving or deleting them.
    public var suspendedAgentIDs: Set<UUID> = [] {
        didSet {
            for id in suspendedAgentIDs.subtracting(oldValue) {
                stop(agentID: id, revokeAccess: false)
                cancelSupervision(for: id)
            }
        }
    }
    /// Remote, archived, suspended and held bots never start here.
    private func neverStarts(_ id: UUID) -> Bool {
        remoteAgentIDs.contains(id) || archivedAgentIDs.contains(id) || suspendedAgentIDs.contains(id) || heldAgents[id] != nil
    }
    /// Bots that may take no new turn for now, each with why, shown as its status: on a Hub, the bots of
    /// someone who used up their plan's tokens. One at work finishes its turn, then stops; whoever lets
    /// it go starts it again.
    public var heldAgents: [UUID: String] = [:] {
        didSet {
            for (id, reason) in heldAgents where oldValue[id] != reason { hold(id) }
            for id in oldValue.keys where heldAgents[id] == nil && processes[id] == nil { snapshots[id] = nil }
        }
    }

    /// Stops a held bot unless it is at work, keeping what it was doing for when it starts again,
    /// and shows why it waits.
    private func hold(_ id: UUID) {
        guard let reason = heldAgents[id], !remoteAgentIDs.contains(id), !archivedAgentIDs.contains(id) else { return }
        if let process = processes[id] {
            guard process.snapshot.phase != .working else { return }
            runtimeIDs[id] = nil
            cancelSupervision(for: id)
            processes[id] = nil
            if process.hasInterruptedWork { recoveryPending.insert(id) }
            // At once, before the process could take the next message waiting for it.
            process.stop { _ in }
        }
        snapshots[id] = AgentRuntimeSnapshot(agentID: id, phase: .offline, detail: reason)
    }
    /// Receives what each model call cost. Nothing is kept here.
    @ObservationIgnored public var onUsage: (@MainActor (UsageSample) -> Void)?
    /// How much of each signed-in account's plan limits is used, as the harnesses last reported.
    public let subscriptionUsage: SubscriptionUsageStore
    /// What the usage ledger holds for a session, so resumed totals are not counted twice.
    @ObservationIgnored public var recordedUsage: (@MainActor (String) -> [String: UsageTotal])?
    /// Called once when a bot's harness needs the person to sign in again.
    @ObservationIgnored public var onSignInRequired: (@MainActor (UUID) -> Void)?
    /// Called once each time a bot pauses until Kick for a reported failure other than sign-in.
    @ObservationIgnored public var onPaused: (@MainActor (UUID) -> Void)?
    /// Called with the line to show in the bot's conversation when it moves to another harness, or back to its own.
    @ObservationIgnored public var onHarnessSwitch: (@MainActor (UUID, String) -> Void)?
    /// Bots running on another harness because their own ran out of usage. Runtime state only:
    /// agent.json and Edit Bot keep each bot's own harness.
    public private(set) var harnessFallbacks: [UUID: HarnessFallback] = [:]
    /// Logins found out of usage, keyed like SubscriptionUsageStore, and until when.
    private(set) var usageExhaustedUntil: [String: Date] = [:]
    /// When each bot last came back to its own harness, and how many times in a row it ran out again soon after.
    @ObservationIgnored private var fallbackReturns: [UUID: (date: Date, flaps: Int)] = [:]
    /// The shortest stay on a fallback; it doubles each time the bot's own harness runs out again soon after it came back.
    static let fallbackCooldown: TimeInterval = 30 * 60
    static let longestFallbackCooldown: TimeInterval = 8 * 60 * 60
    /// How long a login that did not say when its usage comes back counts as out of usage.
    static let unknownUsageReset: TimeInterval = 60 * 60

    /// The harness a bot runs on instead of its own; nil while it runs on its own.
    public func runningHarness(for agentID: UUID) -> HarnessProvider? { harnessFallbacks[agentID]?.current }
    /// Retries before a turn finishes fail the same way, so they stay quiet.
    @ObservationIgnored private var signInAnnounced: Set<UUID> = []
    /// Whether a bot's harness login works now, asked without starting the bot or a turn;
    /// nil when it could not be told.
    @ObservationIgnored public var checkSignIn: (@MainActor (AgentRecord) async -> Bool?)?
    /// The app's harness logins; the model lists come from the default ones, which bots without a profile use.
    @ObservationIgnored public var harnessProfiles: HarnessProfileStore?
    @ObservationIgnored private var signInChecks: Set<UUID> = []
    @ObservationIgnored private var nextSignInCheck: [UUID: Date] = [:]
    /// Restarts since the bot was last seen signed out or finished a turn.
    @ObservationIgnored private var signInRetries: [UUID: Int] = [:]
    /// When each bot paused on a usage limit, for `retryOnceUsageIsBack`.
    @ObservationIgnored private var usagePausedAt: [UUID: Date] = [:]
    @ObservationIgnored private var usageMeters: [UUID: UsageMeter] = [:]
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
    /// Each bot's soonest scheduled wake, read from its package when it starts or Messenger changes it.
    @ObservationIgnored private var wakeDates: [UUID: Date] = [:]
    /// Wakes taken from storage whose turn could not start, because the bot became busy meanwhile.
    @ObservationIgnored private var owedWakes: Set<UUID> = []
    /// Wake storage is read and written off the main thread, one change per bot at a time.
    @ObservationIgnored private var wakeTasks: [UUID: Task<Void, Never>] = [:]
    private let defaults: UserDefaults
    @ObservationIgnored private lazy var messageDelivery = MessageDeliveryRouter(defaults: defaults)

    private var discovery: HarnessDiscovery
    public let harnesses: HarnessSelection
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
    /// The person's remote-model accounts, offered as Apple harness models.
    public var remoteModels: RemoteModelAccountStore?
    #if NOODLE_DEV_HOOKS
    /// A scenario lists its own models, so its stub harnesses are never run to ask; see Scenario.swift.
    public var scriptedModels: [HarnessProvider: [HarnessModel]]?
    #endif

    private func refreshAppleCapabilities() async {
        guard harnesses.isOn(.apple), discovery.discover(.apple).isAvailable else {
            modelsByProvider[.apple] = []
            return
        }
        do {
            let probed = try await AppleHostProbe.load()
            guard !Task.isCancelled else { return }
            let result = probed.adding(remote: (try? remoteModels?.harnessModels()) ?? [])
            modelsByProvider[.apple] = result.models
            capabilityErrors[.apple] = result.unavailableReason
            appleLocalModelsSupported = result.localModelsSupported == true
        } catch {
            guard !Task.isCancelled else { return }
            modelsByProvider[.apple] = []
            capabilityErrors[.apple] = error.localizedDescription
        }
    }

    public func recordAppleLocalModelsSupport(_ supported: Bool) {
        if appleLocalModelsSupported != supported { appleLocalModelsSupported = supported }
    }

    private func discoveredInstallations() -> [HarnessInstallation] {
        discovery.discover().map { offered(hostInstallations[$0.provider] ?? $0) }
    }

    /// A harness turned off is shown as missing, so nothing offers or starts it.
    private func offered(_ installation: HarnessInstallation) -> HarnessInstallation {
        harnesses.isOn(installation.provider) ? installation : HarnessInstallation(provider: installation.provider, executablePath: nil)
    }

    private func refreshHostCapabilities(_ provider: HarnessProvider) async {
        guard harnesses.isOn(provider), discovery.allowsHostDiscovery(for: provider) else { return }
        do {
            let result = try await inspectHost(provider)
            guard !Task.isCancelled else { return }
            let installation = HarnessInstallation(provider: provider, executablePath: result.executablePath)
            hostInstallations[provider] = installation
            installationErrors[provider] = nil
            installations = installations.map { $0.provider == provider ? offered(installation) : $0 }
            modelsByProvider[provider] = result.models
            capabilityErrors[provider] = result.capabilityError
        } catch {
            guard !Task.isCancelled else { return }
            installationErrors[provider] = error.localizedDescription
            capabilityErrors[provider] = error.localizedDescription
        }
    }

    public init(discovery: HarnessDiscovery = HarnessDiscovery(), defaults: UserDefaults = .standard,
         harnesses: HarnessSelection? = nil,
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
        subscriptionUsage = SubscriptionUsageStore(defaults: defaults)
        self.harnesses = harnesses ?? HarnessSelection()
        preventIdleSleepWhileWorking = defaults.bool(forKey: Self.preventIdleSleepDefaultsKey)
        accessConfiguration = AgentAccessConfiguration.load(from: defaults)
        let configuration = AgentHeartbeatConfiguration.load(from: defaults)
        heartbeatConfiguration = configuration
        heartbeatScheduler = AgentHeartbeatScheduler(
            configuration: configuration,
            lastActivity: Self.loadDates(from: defaults, key: Self.lastActivityDatesKey)
        )
        lastActiveDates = Self.loadDates(from: defaults, key: Self.lastActiveDatesKey)
        sessionStartDates = Self.loadDates(from: defaults, key: Self.sessionStartDatesKey)
        lastInteractionDates = Self.loadDates(from: defaults, key: Self.lastInteractionDatesKey)
        let selection = self.harnesses
        installations = discovery.discover().map { selection.isOn($0.provider) ? $0 : HarnessInstallation(provider: $0.provider, executablePath: nil) }
    }

    public func configurePreventIdleSleepWhileWorking(_ enabled: Bool) {
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

    public func reloadAccess() {
        accessConfiguration = AgentAccessConfiguration.load(from: defaults)
    }

    public func authorizeSelectedHarness(_ agent: AgentRecord) {
        accessConfiguration.authorizeSelectedHarness(for: agent)
        accessConfiguration.save(to: defaults)
    }

    public func setExtendedAccess(_ enabled: Bool, agent: AgentRecord, repository: WorkspaceRepository) {
        let required = HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.supportsRestrictedAccess == false
        guard (!required || enabled), accessConfiguration.isExtended(for: agent) != enabled else { return }
        changeAccess(enabled, agent: agent, repository: repository) { configuration in
            if required { configuration.authorizeSelectedHarness(for: agent) }
            else { configuration.setExtended(enabled, for: agent.id) }
        }
    }

    public func setAppsEnabled(_ enabled: Bool, agent: AgentRecord, repository: WorkspaceRepository) {
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

    public func configureHeartbeats(enabled: Bool? = nil, intervalMinutes: Int? = nil) {
        applyHeartbeatConfiguration(AgentHeartbeatConfiguration(
            isEnabled: enabled ?? heartbeatConfiguration.isEnabled,
            intervalMinutes: intervalMinutes ?? heartbeatConfiguration.intervalMinutes,
            disabledAgentIDs: heartbeatConfiguration.disabledAgentIDs
        ))
    }

    public func setHeartbeatEnabled(_ enabled: Bool, for agentID: UUID) {
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

    public func seedHeartbeatActivity(for agentID: UUID, at date: Date) {
        if heartbeatScheduler.register(agentID, at: date) {
            saveHeartbeatActivityDates()
        }
    }

    public func recordActivity(for agentID: UUID) {
        heartbeatScheduler.recordActivity(for: agentID, at: now())
        saveHeartbeatActivityDates()
    }

    private func recordHeartbeat(for agentID: UUID) {
        heartbeatTurns.insert(agentID)
    }

    private func saveLastActiveDates() {
        defaults.set(
            Dictionary(uniqueKeysWithValues: lastActiveDates.map {
                ($0.key.uuidString, $0.value.timeIntervalSince1970)
            }),
            forKey: Self.lastActiveDatesKey
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

    private func recordInteraction(for agentID: UUID) {
        lastInteractionDates[agentID] = now()
        saveSessionDates()
    }

    private func saveSessionDates() {
        for (key, dates) in [(Self.sessionStartDatesKey, sessionStartDates), (Self.lastInteractionDatesKey, lastInteractionDates)] {
            defaults.set(Dictionary(uniqueKeysWithValues: dates.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) }),
                         forKey: key)
        }
    }

    private static let sessionStartDatesKey = "Noodle.session.startDates"
    private static let lastInteractionDatesKey = "Noodle.session.lastInteractionDates"
    private static let lastActivityDatesKey = "Noodle.heartbeat.lastActivityDates"
    /// Saved heartbeat times seed the dates: a heartbeat turn counts as activity too.
    private static let lastActiveDatesKey = "Noodle.heartbeat.lastDates"

    private static func loadDates(from defaults: UserDefaults, key: String) -> [UUID: Date] {
        guard let stored = defaults.dictionary(forKey: key) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            guard let id = UUID(uuidString: key), let seconds = value as? TimeInterval else { return nil }
            return (id, Date(timeIntervalSince1970: seconds))
        })
    }

    public func checkHeartbeats() {
        let readyIDs = Set(processes.filter { $0.value.canReceiveHeartbeat }.map(\.key))
        let dueIDs = heartbeatScheduler.takeDueHeartbeats(readyAgentIDs: readyIDs, at: now())
        if !dueIDs.isEmpty { saveHeartbeatActivityDates() }
        for id in dueIDs {
            // Do not start offline/failed bots or enqueue a heartbeat behind real work.
            processes[id]?.heartbeat()
        }
    }

    public func refreshWakes(for agentID: UUID, repository: WorkspaceRepository) {
        changeWakes(of: agentID) { _ in
            await Task.detached { repository.nextWakeDate(agentID: agentID) }.value
        }
    }

    /// Wakes a bot with a note from Noodle, listed with its own wakes; a busy bot gets it once free.
    public func wake(_ agentID: UUID, note: String, repository: WorkspaceRepository) {
        let date = now()
        changeWakes(of: agentID) { coordinator in
            let (delivered, next) = await Task.detached {
                ((try? repository.deliverWake(agentID: agentID, note: note, at: date)) != nil, repository.nextWakeDate(agentID: agentID))
            }.value
            if delivered { coordinator.owedWakes.insert(agentID) }
            return next
        }
    }

    /// Wakes bots to introduce themselves in a conversation, once each is ready.
    public func introduce(_ agentIDs: [UUID], in conversationID: UUID, repository: WorkspaceRepository) {
        for id in agentIDs { wake(id, note: AgentWake.introductionNote(in: conversationID), repository: repository) }
    }

    /// Wakes a bot whose scheduled wake is due once it can take a turn; a busy bot keeps it.
    /// Checking only reads dates held in memory, so it can run every second.
    public func checkWakes(repository: WorkspaceRepository) {
        for id in owedWakes {
            guard let process = processes[id], process.canReceiveHeartbeat else { continue }
            owedWakes.remove(id)
            process.wake()
        }
        let date = now()
        for (id, due) in wakeDates where due <= date {
            guard let process = processes[id], process.canReceiveHeartbeat else { continue }
            wakeDates[id] = nil
            changeWakes(of: id) { coordinator in
                let (fired, next) = await Task.detached {
                    ((try? repository.takeDueWakes(agentID: id, at: date)) == true, repository.nextWakeDate(agentID: id))
                }.value
                if fired {
                    if let process = coordinator.processes[id], process.canReceiveHeartbeat { process.wake() }
                    else { coordinator.owedWakes.insert(id) }
                }
                return next
            }
        }
    }

    private func changeWakes(of agentID: UUID, _ change: @escaping @MainActor (AgentRuntimeCoordinator) async -> Date?) {
        let previous = wakeTasks[agentID]
        wakeTasks[agentID] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let next = await change(self)
            // Removing the bot cancels this; its wakes are then no longer tracked.
            if !Task.isCancelled { wakeDates[agentID] = next }
        }
    }

    /// Waits for wake storage changes already started.
    func settleWakes() async {
        for task in wakeTasks.values { await task.value }
    }

    public var availableInstallations: [HarnessInstallation] {
        installations.filter(\.isAvailable)
    }

    public func checkExternalInstallation(_ provider: HarnessProvider) async {
        #if NOODLE_DEV_HOOKS
        discovery.checkExternalInstallationDuringSimulation(provider)
        #endif
        await refreshInstallations()
    }

    /// Discovery is shared by Settings and bot configuration. Refreshing the
    /// catalogue does not restart agents or launch capability-probe processes.
    public func refreshInstallations() async {
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
        let complete = detected.map { offered(hostInstallations[$0.provider] ?? $0) }
        if installations != complete { installations = complete }
    }

    /// Noodle installed or removed this harness itself. Only its files changed,
    /// so the other harnesses need none of the host probes a full refresh runs.
    @discardableResult
    public func refreshInstallation(_ provider: HarnessProvider) -> HarnessInstallation {
        installationChanges += 1
        // What the Agent Host last reported for this harness is now out of date.
        hostInstallations[provider] = nil
        let installation = offered(discovery.discover(provider))
        installations = installations.map { $0.provider == provider ? installation : $0 }
        return installation
    }

    /// Turning a harness on looks for it again and asks for its models; its bots start when next started.
    public func setHarness(_ provider: HarnessProvider, on: Bool) {
        guard harnesses.isOn(provider) != on else { return }
        harnesses.set(provider, on: on)
        installationChanges += 1
        installations = installations.map { $0.provider == provider ? offered(hostInstallations[provider] ?? discovery.discover(provider)) : $0 }
        if on { refreshCapabilities() }
    }

    private func unstartableDetail(_ agent: AgentRecord) -> String {
        guard let provider = agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:)) else {
            return agent.harnessIdentifier == nil ? "Choose a harness in Edit Bot" : "The configured harness is not installed"
        }
        return harnesses.isOn(provider)
            ? "The configured harness is not installed"
            : "\(provider.displayName) is turned off. Turn it on in Settings → Harness."
    }

    public func installation(for agent: AgentRecord) -> HarnessInstallation? {
        guard let identifier = agent.harnessIdentifier,
              let provider = HarnessProvider(rawValue: identifier) else { return nil }
        return installations.first { $0.provider == provider && $0.isAvailable }
    }

    public func models(for harnessIdentifier: String?) -> [HarnessModel] {
        guard let harnessIdentifier,
              let provider = HarnessProvider(rawValue: harnessIdentifier) else { return [] }
        return modelsByProvider[provider, default: []]
    }

    public func snapshot(for agentID: UUID) -> AgentRuntimeSnapshot {
        snapshots[agentID] ?? AgentRuntimeSnapshot(
            agentID: agentID,
            phase: .offline,
            detail: "Not started"
        )
    }

    public func refresh(agents: [AgentRecord], repository: WorkspaceRepository? = nil) {
        installations = discoveredInstallations()
        let liveIDs = Set(agents.map(\.id))
        activity.retainAgents(liveIDs)
        usageMeters = usageMeters.filter { liveIDs.contains($0.key) }
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
            sessionStartDates[id] = nil
            lastInteractionDates[id] = nil
            heartbeatTurns.remove(id)
            signInAnnounced.remove(id)
            forgetSignInRetries(id)
            saveSessionDates()
        }

        harnessFallbacks = harnessFallbacks.filter { liveIDs.contains($0.key) }
        fallbackReturns = fallbackReturns.filter { liveIDs.contains($0.key) }
        for agent in agents {
            // Editing the saved harness or profile replaces the temporary fallback choice.
            if let fallback = harnessFallbacks[agent.id] {
                let profileChanged = repository.map {
                    let target = HarnessFallbackTarget(provider: fallback.primary, profile: try? $0.loadAgentHarnessProfile(agent))
                    return SubscriptionUsageStore.key(fallback.primary, profile: target.profile) != fallback.primaryKey
                } ?? false
                if agent.harnessIdentifier != fallback.primary.rawValue || profileChanged {
                    harnessFallbacks[agent.id] = nil
                }
            }
            if blockedRestarts.contains(agent.id) { continue }
            if blockedRecoveries.contains(agent.id), connectionRecoveryAttempts[agent.id] != nil { continue }
            if heldAgents[agent.id] != nil, processes[agent.id] == nil { hold(agent.id); continue }
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
                    detail: unstartableDetail(agent)
                )
            }
        }
        snapshots = snapshots.filter { liveIDs.contains($0.key) }

        if let repository {
            for agent in agents where processes[agent.id]?.runs(runningAgent(agent)) != true
                && !blockedRestarts.contains(agent.id)
                && !(blockedRecoveries.contains(agent.id) && connectionRecoveryAttempts[agent.id] != nil) {
                restart(agent: agent, repository: repository)
            }
        }
    }

    public func refreshCapabilities() {
        installations = discoveredInstallations()
        #if NOODLE_DEV_HOOKS
        if let scriptedModels { modelsByProvider = scriptedModels; return }
        #endif
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
                    let models = try await FxModelProbe.load(path: path)
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
                    let models = try await FxModelProbe.load(path: executablePath, provider: .codex)
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
        let probe = CodexCapabilityProbe(executableURL: URL(fileURLWithPath: executablePath),
            codexHome: harnessProfiles.flatMap { store in (try? store.defaultProfile(.codex)).map(store.accountHome) })
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

    public func startAll(agents: [AgentRecord], repository: WorkspaceRepository) {
        isStoppingAll = false
        installations = discoveredInstallations()
        for agent in agents {
            start(agent: agent, repository: repository)
        }
    }

    public func start(agent configured: AgentRecord, repository: WorkspaceRepository) {
        let agent = runningAgent(configured)
        if heldAgents[agent.id] != nil { hold(agent.id); return }
        guard !neverStarts(agent.id), processes[agent.id] == nil, !changingAccess.contains(agent.id), !blockedRestarts.contains(agent.id),
              !blockedRecoveries.contains(agent.id) else { return }
        if HarnessProvider(rawValue: agent.harnessIdentifier ?? "")?.supportsRestrictedAccess == false,
           !accessConfiguration.isExtended(for: agent) {
            snapshots[agent.id] = .init(agentID: agent.id, phase: .failed,
                detail: "This harness requires unrestricted access. Allow it in Settings → Bots before starting this bot.")
            return
        }
        do { try repository.synchronizeAgentWorkspace(agent) }
        catch {
            snapshots[agent.id] = AgentRuntimeSnapshot(agentID: agent.id, phase: .failed,
                detail: "Could not prepare the bot's workspace. Check its managed skill directories before retrying.")
            return
        }
        refreshWakes(for: agent.id, repository: repository)
        guard let installation = installation(for: agent),
              let executablePath = installation.executablePath else {
            snapshots[agent.id] = AgentRuntimeSnapshot(
                agentID: agent.id,
                phase: .failed,
                detail: unstartableDetail(agent)
            )
            return
        }

        restartTasks.removeValue(forKey: agent.id)?.cancel()
        let runtimeID = UUID()
        runtimeIDs[agent.id] = runtimeID
        usageMeters[agent.id] = UsageMeter()
        let profile = runningProfile(for: configured, repository: repository)
        let process = makeProcess(AgentRuntimeLaunch(
            agent: agent, provider: installation.provider,
            executableURL: URL(fileURLWithPath: executablePath), workspaceURL: repository.directory(for: agent),
            extendedAccess: accessConfiguration.isExtended(for: agent),
            appsEnabled: accessConfiguration.appsEnabled(for: agent),
            recoverInterruptedWork: recoveryPending.remove(agent.id) != nil,
            onSnapshot: runtimeSnapshotHandler(for: agent.id, runtimeID: runtimeID, agent: configured, repository: repository),
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
                self.recordUsage(message, provider: installation.provider, agent: agent)
                self.recordSubscriptionUsage(message, provider: installation.provider, profile: profile)
            }, profileOverride: harnessFallbacks[agent.id].map { $0.profile ?? HarnessProfileStore.defaultID($0.current) }))
        processes[agent.id] = process
        process.start()
        recoverUnreadMessages(for: agent, process: processes[agent.id], repository: repository)
    }

    private func recordUsage(_ message: [String: Any], provider: HarnessProvider, agent: AgentRecord) {
        guard let onUsage else { return }
        let date = now()
        let readings = usageMeters[agent.id, default: UsageMeter()].readings(message, provider: provider) {
            recordedUsage?($0) ?? [:]
        }
        for reading in readings {
            onUsage(UsageSample(date: date, agentID: agent.id, agentName: agent.displayName, harness: provider.rawValue,
                model: reading.model.isEmpty ? agent.modelIdentifier ?? "" : reading.model,
                tokens: reading.tokens, costUSD: reading.costUSD, session: reading.session))
        }
    }

    /// Usage is charged to the actual login, including a temporary fallback profile.
    private func recordSubscriptionUsage(_ message: [String: Any], provider: HarnessProvider, profile: UUID?) {
        guard SubscriptionUsage.isReport(message, provider: provider) else { return }
        subscriptionUsage.record(message, provider: provider, profile: profile, at: now())
    }

    public func runningProfile(for agent: AgentRecord, repository: WorkspaceRepository) -> UUID? {
        if let fallback = harnessFallbacks[agent.id] { return fallback.profile }
        guard let provider = HarnessProvider(rawValue: agent.harnessIdentifier ?? "") else { return nil }
        return HarnessFallbackTarget(provider: provider, profile: try? repository.loadAgentHarnessProfile(agent)).profile
    }

    /// Organize waits for an idle bot, like a heartbeat, so it never cuts into work.
    public func canOrganize(_ agentID: UUID) -> Bool {
        processes[agentID]?.canReceiveHeartbeat == true && !changingAccess.contains(agentID)
    }

    public func organize(_ agentID: UUID) {
        guard canOrganize(agentID) else { return }
        processes[agentID]?.organize()
    }

    /// Ordinary Kick remains immediate; replacing a missing session requires a
    /// concrete confirmation. Account failures explain the prerequisite first.
    public func kick(agent: AgentRecord, repository: WorkspaceRepository) -> AgentKickRequest? {
        guard !isStoppingAll, !changingAccess.contains(agent.id) else { return nil }
        // Kick takes a bot on a fallback back to its own harness at once; if that is still out
        // of usage, the bot falls back again.
        if let fallback = harnessFallbacks.removeValue(forKey: agent.id) {
            usageExhaustedUntil[fallback.primaryKey] = nil
            connectionRecoveryAttempts[agent.id] = nil
            forgetSignInRetries(agent.id)
            onHarnessSwitch?(agent.id, "Back on \(fallback.primary.displayName)")
            restart(agent: agent, repository: repository, sessionRecovery: nil, retryFailedStop: true)
            return nil
        }
        guard snapshot(for: agent.id).canKick else { return nil }
        connectionRecoveryAttempts[agent.id] = nil
        // Retry Now resets the sign-in retries; until it is chosen, they keep their pace.
        if let failure = snapshot(for: agent.id).failure, failure != .recoveryFailed {
            return AgentKickRequest(agent: agent, failure: failure, runtimeID: runtimeIDs[agent.id],
                lifecycleID: lifecycleID, extendedAccess: accessConfiguration.isExtended(for: agent))
        }
        forgetSignInRetries(agent.id)
        restart(agent: agent, repository: repository,
            sessionRecovery: snapshot(for: agent.id).failure == .recoveryFailed ? sessionRecovery(.retry, for: agent) : nil,
            retryFailedStop: true)
        return nil
    }

    /// Only harnesses with a saved ACP session have recovery to prepare; the rest simply restart.
    private func sessionRecovery(_ recovery: SessionRecovery, for agent: AgentRecord) -> SessionRecovery? {
        let provider = runningAgent(agent).harnessIdentifier.flatMap(HarnessProvider.init(rawValue:))
        return provider == .grokBuild || provider == .openCode ? recovery : nil
    }

    public func confirmKick(_ request: AgentKickRequest, repository: WorkspaceRepository) {
        let agent = request.agent
        // A bot waiting for sign-in may have been started again in the background, and refused, while
        // the alert was open; it still waits, so Retry Now retries. Other requests are for that runtime only.
        guard !isStoppingAll, !changingAccess.contains(agent.id), lifecycleID == request.lifecycleID,
              runtimeIDs[agent.id] == request.runtimeID || request.failure == .authenticationRequired,
              snapshot(for: agent.id).phase == .failed, snapshot(for: agent.id).failure == request.failure,
              processes[agent.id]?.runs(runningAgent(agent)) ?? true,
              accessConfiguration.isExtended(for: agent) == request.extendedAccess else { return }
        forgetSignInRetries(agent.id)
        let recovery: SessionRecovery
        switch request.failure {
        case .missingSession(let sessionID): recovery = .replace(sessionID)
        case .authenticationRequired:
            // The person asked for this try, so the host must not refuse it on a refusal noted earlier.
            if let provider = HarnessProvider(rawValue: runningAgent(agent).harnessIdentifier ?? "") {
                RestrictedHarnessStorage.forgetRefusedLogin(provider: provider, workspace: repository.directory(for: agent))
            }
            recovery = .retry
        case .usageLimit, .recoveryFailed: recovery = .retry
        case .safetyStop:
            restart(agent: agent, repository: repository, sessionRecovery: nil, retryFailedStop: true)
            return
        }
        restart(agent: agent, repository: repository, sessionRecovery: sessionRecovery(recovery, for: agent))
    }

    /// A sign-in in Settings retries at once the bots waiting on that login, as Retry Now would.
    /// `profile` is nil for the harness's Default login.
    public func retryAfterSignIn(provider: HarnessProvider, profile: UUID?, agents: [AgentRecord], repository: WorkspaceRepository) {
        guard !isStoppingAll else { return }
        for agent in agents where snapshot(for: agent.id).phase == .failed && snapshot(for: agent.id).failure == .authenticationRequired {
            guard !changingAccess.contains(agent.id),
                  runningAgent(agent).harnessIdentifier == provider.rawValue,
                  runningProfile(for: agent, repository: repository) == profile else { continue }
            forgetSignInRetries(agent.id)
            RestrictedHarnessStorage.forgetRefusedLogin(provider: provider, workspace: repository.directory(for: agent))
            restart(agent: agent, repository: repository, sessionRecovery: sessionRecovery(.retry, for: agent))
        }
    }

    /// Replaces the bot's harness session with a fresh one, keeping its workspace, memory and messages.
    public func startNewSession(agent: AgentRecord, repository: WorkspaceRepository) {
        guard !neverStarts(agent.id) else { return }
        connectionRecoveryAttempts[agent.id] = nil
        restart(agent: agent, repository: repository, resetThread: true, sessionRecovery: nil, retryFailedStop: true)
    }

    /// Starts a fresh session for idle bots whose session is older than the configured age.
    /// Only a bot that could take a heartbeat is idle: never mid-turn or with work queued.
    private func checkSessionRollovers(agents: [AgentRecord], repository: WorkspaceRepository) {
        guard !isStoppingAll else { return }
        let policy = AgentSessionRollover.load(from: defaults), date = now()
        var seeded = false
        for agent in agents {
            guard let process = processes[agent.id] else { continue }
            let started: Date
            if let known = sessionStartDates[agent.id] { started = known } else {
                // Sessions from before this was tracked count from now.
                started = date
                sessionStartDates[agent.id] = date
                seeded = true
            }
            guard policy.isEnabled, process.canReceiveHeartbeat, !changingAccess.contains(agent.id),
                  !neverStarts(agent.id),
                  policy.isDue(sessionStarted: started, lastInteraction: lastInteractionDates[agent.id] ?? started, at: date)
            else { continue }
            startNewSession(agent: agent, repository: repository)
        }
        if seeded { saveSessionDates() }
    }

    public func restart(
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
            sessionStartDates[agent.id] = now()
            saveSessionDates()
            let running = runningAgent(agent)
            let provider = HarnessProvider(rawValue: running.harnessIdentifier ?? "") ?? .codex
            let state = repository.storage(for: agent.id).sessionState(provider: provider,
                extendedAccess: accessConfiguration.isExtended(for: running))
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
                        let running = self.runningAgent(agent)
                        guard let provider = running.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:)),
                              provider == .grokBuild || provider == .openCode else {
                            throw HarnessSetupError("This harness does not support session recovery through Kick.")
                        }
                        let state = storage.sessionState(provider: provider,
                            extendedAccess: self.accessConfiguration.isExtended(for: running))
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

    public func notify(_ agents: [AgentRecord], repository: WorkspaceRepository) {
        for agent in agents {
            recordActivity(for: agent.id)
            recordInteraction(for: agent.id)
            if processes[agent.id] == nil {
                start(agent: agent, repository: repository)
            }
            if let process = processes[agent.id] { messageDelivery.notify(process, repository: repository) }
        }
    }

    public func startVoiceCall(agentID: UUID, _ request: VoiceCallRequest,
                               events: @escaping @MainActor (VoiceCallEvent) -> Void) throws {
        guard let process = processes[agentID] else { throw VoiceCallUnavailable() }
        try process.startVoiceCall(request, events: events)
        recordActivity(for: agentID)
        recordInteraction(for: agentID)
    }

    public func sendToVoiceCall(agentID: UUID, _ text: String) {
        processes[agentID]?.sendToVoiceCall(text)
    }

    public func endVoiceCall(agentID: UUID) {
        processes[agentID]?.endVoiceCall()
    }

    public func stop(agentID: UUID, revokeAccess: Bool = true) {
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
        harnessFallbacks.removeValue(forKey: agentID)
        fallbackReturns.removeValue(forKey: agentID)
        signInAnnounced.remove(agentID)
        forgetSignInRetries(agentID)
        heartbeatScheduler.remove(agentID)
        saveHeartbeatActivityDates()
        lastActiveDates.removeValue(forKey: agentID)
        saveLastActiveDates()
        wakeDates.removeValue(forKey: agentID)
        owedWakes.remove(agentID)
        wakeTasks.removeValue(forKey: agentID)?.cancel()
    }

    public func stopAll() {
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

    public func reconcile(agents: [AgentRecord], repository: WorkspaceRepository, immediately: Bool = false) {
        guard !isStoppingAll else { return }
        for agent in agents where installation(for: runningAgent(agent)) != nil && !neverStarts(agent.id) {
            // A bot waiting on the person for a reported failure keeps it until Kick; restarting
            // cannot answer a safety stop. A sign-in or usage coming back restarts it by itself.
            if let process = processes[agent.id], process.snapshot.phase == .failed, let failure = process.snapshot.failure {
                if failure == .authenticationRequired { retryOnceSignedIn(agent, repository: repository) }
                if failure == .usageLimit { retryOnceUsageIsBack(agent, snapshot: process.snapshot, repository: repository) }
                continue
            }
            if let process = processes[agent.id], process.isAlive {
                if process.configuration.harnessIdentifier == HarnessProvider.codex.rawValue,
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
        checkSessionRollovers(agents: agents, repository: repository)
        checkFallbackReturns(agents: agents, repository: repository)
    }

    /// A profile switch keeps the bot's model and effort; a harness switch uses the new defaults.
    func runningAgent(_ agent: AgentRecord) -> AgentRecord {
        guard let fallback = harnessFallbacks[agent.id], agent.harnessIdentifier == fallback.primary.rawValue else { return agent }
        var running = agent
        running.harnessIdentifier = fallback.current.rawValue
        if fallback.current != fallback.primary {
            running.modelIdentifier = nil
            running.reasoningEffort = nil
        }
        return running
    }

    /// Try an opted-in login on the current harness first, then the separate ordered fallback list.
    /// A temporary login refused at startup can be skipped too; the bot's own sign-in still waits for the person.
    private func fallBack(_ agent: AgentRecord, repository: WorkspaceRepository, after snapshot: AgentRuntimeSnapshot) -> Bool {
        guard let failure = snapshot.failure,
              failure == .usageLimit || failure == .authenticationRequired && harnessFallbacks[agent.id] != nil,
              !isStoppingAll, !neverStarts(agent.id), !changingAccess.contains(agent.id),
              let primary = HarnessProvider(rawValue: agent.harnessIdentifier ?? "") else { return false }
        let date = now()
        let primaryTarget = HarnessFallbackTarget(provider: primary, profile: try? repository.loadAgentHarnessProfile(agent))
        let primaryKey = SubscriptionUsageStore.key(primary, profile: primaryTarget.profile)
        let current = harnessFallbacks[agent.id].map { HarnessFallbackTarget(provider: $0.current, profile: $0.profile) } ?? primaryTarget
        let currentKey = SubscriptionUsageStore.key(current.provider, profile: current.profile)
        if failure == .usageLimit {
            let reset = (snapshot.usageResetsAt ?? reportedReset(currentKey, at: date)).flatMap { $0 > date ? $0 : nil }
            usageExhaustedUntil[currentKey] = reset ?? date.addingTimeInterval(Self.unknownUsageReset)
        }
        var unavailable = harnessFallbacks[agent.id]?.unavailable ?? []
        // Sign-in refusals stay skipped for this fallback cycle; usage limits expire by account.
        if failure == .authenticationRequired { unavailable.insert(current) }
        guard let next = nextFallback(after: current, primary: primaryTarget, unavailable: unavailable,
                                      agent: agent, repository: repository, at: date) else { return false }
        if var fallback = harnessFallbacks[agent.id] {
            fallback.current = next.provider
            fallback.profile = next.profile
            fallback.unavailable = unavailable
            harnessFallbacks[agent.id] = fallback
        } else {
            // Increase the stay away after a quick repeat failure to avoid flapping between logins.
            let flaps = fallbackReturns[agent.id].map { date.timeIntervalSince($0.date) < Self.fallbackCooldown ? $0.flaps + 1 : 0 } ?? 0
            let cooldown = min(Self.fallbackCooldown * pow(2, Double(flaps)), Self.longestFallbackCooldown)
            let reset = usageExhaustedUntil[primaryKey] ?? date.addingTimeInterval(Self.unknownUsageReset)
            harnessFallbacks[agent.id] = HarnessFallback(primary: primary, current: next.provider, profile: next.profile,
                unavailable: unavailable, returnAfter: max(reset, date.addingTimeInterval(cooldown)), flaps: flaps, primaryKey: primaryKey)
        }
        let reason = failure == .usageLimit ? "is out of usage" : "needs you to sign in"
        onHarnessSwitch?(agent.id, "\(fallbackName(current, repository: repository)) \(reason), continuing on \(fallbackName(next, repository: repository))")
        restart(agent: agent, repository: repository, sessionRecovery: nil)
        return true
    }

    private func fallbackName(_ target: HarnessFallbackTarget, repository: WorkspaceRepository) -> String {
        guard let id = target.profile, let profile = try? repository.harnessProfiles.profile(id) else { return target.provider.displayName }
        return "\(target.provider.displayName) · \(profile.displayName)"
    }

    /// An eligible login on the current harness, then the next usable choice in the ordered fallback list.
    private func nextFallback(after current: HarnessFallbackTarget, primary: HarnessFallbackTarget,
                              unavailable: Set<HarnessFallbackTarget>, agent: AgentRecord,
                              repository: WorkspaceRepository, at date: Date) -> HarnessFallbackTarget? {
        func usable(_ target: HarnessFallbackTarget) -> Bool {
            let provider = target.provider
            guard target != primary, target != current, !unavailable.contains(target), harnesses.isOn(provider),
                  installations.contains(where: { $0.provider == provider && $0.isAvailable }) else { return false }
            if let id = target.profile {
                // Model probes use Default's login. Its failure says nothing about a separate account.
                guard let profile = try? repository.harnessProfiles.validated(id), profile.provider == provider else { return false }
            } else if capabilityErrors[provider] != nil { return false }
            var running = agent
            running.harnessIdentifier = provider.rawValue
            guard provider.supportsRestrictedAccess || accessConfiguration.isExtended(for: running) else { return false }
            return !isOutOfUsage(SubscriptionUsageStore.key(provider, profile: target.profile), at: date)
        }

        // Try profiles in stable creation order, wrapping after the current login. A profile
        // on another harness never enters this pool; Default also requires explicit opt-in.
        let profiles = (try? repository.harnessProfiles.load()) ?? []
        let local = [HarnessFallbackTarget(provider: current.provider)] + profiles
            .filter { $0.provider == current.provider }
            .map { HarnessFallbackTarget(provider: $0.provider, profile: $0.id) }
        let localStart = local.firstIndex(of: current).map { $0 + 1 } ?? 0
        let localOrder = Array(local[localStart...]) + Array(local[..<localStart])
        if let next = localOrder.first(where: { harnesses.allowsUsageRetries($0) && usable($0) }) { return next }

        guard harnesses.fallbackIsOn else { return nil }
        let list = harnesses.fallbackTargets
        let start = list.firstIndex(of: current).map { $0 + 1 } ?? 0
        return (Array(list[start...]) + Array(list[..<start])).first(where: usable)
    }

    /// When this login has usage again; nil while it has usage left.
    public func usageReturns(_ provider: HarnessProvider, profile: UUID? = nil) -> Date? {
        let target = HarnessFallbackTarget(provider: provider, profile: profile)
        let key = SubscriptionUsageStore.key(provider, profile: target.profile), date = now()
        return [usageExhaustedUntil[key].flatMap { $0 > date ? $0 : nil }, reportedReset(key, at: date)].compactMap { $0 }.max()
    }

    private func isOutOfUsage(_ key: String, at date: Date) -> Bool {
        usageExhaustedUntil[key].map { $0 > date } == true || reportedReset(key, at: date) != nil
    }

    /// When a login's used-up plan limit resets, as the harness last reported; nil while none is used up.
    private func reportedReset(_ key: String, at date: Date) -> Date? {
        subscriptionUsage.accounts[key]?.current(at: date).filter { ($0.usedPercent ?? 0) >= 100 }.compactMap(\.resetsAt).max()
    }

    /// Takes bots on a fallback back to their own harness once its usage is back and the cooldown has passed,
    /// only while idle or paused, never in the middle of a turn.
    private func checkFallbackReturns(agents: [AgentRecord], repository: WorkspaceRepository) {
        let date = now()
        for agent in agents {
            guard let fallback = harnessFallbacks[agent.id], date >= fallback.returnAfter,
                  !changingAccess.contains(agent.id), !neverStarts(agent.id), let process = processes[agent.id],
                  process.canReceiveHeartbeat || process.snapshot.phase == .failed && process.snapshot.failure != nil,
                  !isOutOfUsage(fallback.primaryKey, at: date) else { continue }
            harnessFallbacks[agent.id] = nil
            fallbackReturns[agent.id] = (date, fallback.flaps)
            onHarnessSwitch?(agent.id, "Back on \(fallback.primary.displayName)")
            restart(agent: agent, repository: repository, sessionRecovery: nil)
        }
    }

    /// A bot parked on sign-in restarts by itself, as Kick would, once its harness reports a
    /// working login. The check runs no turn. A login that looks valid yet still fails is
    /// retried a few times with growing gaps, then only after the harness was seen signed out.
    /// Where the refusal of a login is noted, the host refuses starts on it until that note
    /// lapses, which spaces out the real tries, so the restarts go on.
    private func retryOnceSignedIn(_ agent: AgentRecord, repository: WorkspaceRepository) {
        guard let checkSignIn, !signInChecks.contains(agent.id), let runtimeID = runtimeIDs[agent.id],
              processes[agent.id]?.runs(runningAgent(agent)) == true else { return }
        if let next = nextSignInCheck[agent.id], now() < next { return }
        nextSignInCheck[agent.id] = now().addingTimeInterval(Self.signInCheckInterval)
        signInChecks.insert(agent.id)
        let lifecycle = lifecycleID, running = runningAgent(agent)
        Task { [weak self] in
            let signedIn = await checkSignIn(running)
            guard let self else { return }
            self.signInChecks.remove(agent.id)
            guard !self.isStoppingAll, self.lifecycleID == lifecycle, self.runtimeIDs[agent.id] == runtimeID,
                  self.snapshot(for: agent.id).failure == .authenticationRequired else { return }
            if signedIn == false { self.signInRetries[agent.id] = nil }
            let retries = self.signInRetries[agent.id, default: 0]
            guard signedIn == true,
                  retries < Self.signInRetryLimit || self.refusedLogin(of: agent, repository: repository) != nil else { return }
            self.signInRetries[agent.id] = retries + 1
            self.nextSignInCheck[agent.id] = self.now().addingTimeInterval(
                Self.signInCheckInterval * pow(2, Double(min(retries, Self.signInRetryLimit - 1))))
            self.restart(agent: agent, repository: repository, sessionRecovery: self.sessionRecovery(.retry, for: agent))
        }
    }

    /// A bot paused on a usage limit restarts by itself, as Kick would, once its usage is back: the
    /// reset its harness reported has passed, or an hour when it said none, and no reading says the
    /// login is still used up; or a reading taken a while after the pause shows usage left, as when
    /// a limit is reset early. A restart that meets the limit again pauses again, with a new reset.
    /// A bot on a fallback harness comes back through `checkFallbackReturns` instead.
    private func retryOnceUsageIsBack(_ agent: AgentRecord, snapshot: AgentRuntimeSnapshot, repository: WorkspaceRepository) {
        guard harnessFallbacks[agent.id] == nil, let paused = usagePausedAt[agent.id],
              let provider = HarnessProvider(rawValue: agent.harnessIdentifier ?? "") else { return }
        let date = now()
        let key = SubscriptionUsageStore.key(provider, profile: try? repository.loadAgentHarnessProfile(agent))
        // The harness's own reading at the pause may not show the limit yet, so only a later one counts.
        let usageLeft = subscriptionUsage.accounts[key].map {
            $0.updatedAt >= paused.addingTimeInterval(Self.usageReadingDelay)
                && !$0.current(at: date).contains { ($0.usedPercent ?? 0) >= 100 }
        } ?? false
        let reset = snapshot.usageResetsAt ?? paused.addingTimeInterval(Self.unknownUsageReset)
        guard usageLeft || date >= reset && reportedReset(key, at: date) == nil else { return }
        usagePausedAt[agent.id] = nil
        restart(agent: agent, repository: repository, sessionRecovery: sessionRecovery(.retry, for: agent))
    }

    private static let usageReadingDelay: TimeInterval = 5 * 60

    /// When the host lets a start on the login the bot's harness refused through again; nil when
    /// none is noted. Only restricted starts are checked.
    private func refusedLogin(of agent: AgentRecord, repository: WorkspaceRepository) -> Date? {
        guard !accessConfiguration.isExtended(for: agent),
              let provider = HarnessProvider(rawValue: runningAgent(agent).harnessIdentifier ?? "") else { return nil }
        return RestrictedHarnessStorage.refusedUntil(provider: provider, workspace: repository.directory(for: agent))
    }

    private static let signInCheckInterval: TimeInterval = 2 * 60
    private static let signInRetryLimit = 4
    /// How often a bot whose starts the host refuses asks again before the refusal lapses,
    /// which notices a new sign-in or another bot's refresh.
    private static let refusedSignInCheckInterval: TimeInterval = 10 * 60

    private func forgetSignInRetries(_ agentID: UUID) {
        nextSignInCheck[agentID] = nil
        signInRetries[agentID] = nil
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
        if heldAgents[agent.id] != nil { hold(agent.id); return }
        guard !isStoppingAll, restartTasks[agent.id] == nil, !neverStarts(agent.id) else { return }
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

    private func runtimeSnapshotHandler(for agentID: UUID, runtimeID: UUID, agent: AgentRecord,
                                        repository: WorkspaceRepository) -> @MainActor (AgentRuntimeSnapshot) -> Void {
        var previousPhase: AgentRuntimePhase?
        return { [weak self] snapshot in
            guard let self, self.runtimeIDs[agentID] == runtimeID, snapshot.agentID == agentID else { return }
            defer { previousPhase = snapshot.phase }
            if previousPhase == .working, snapshot.phase == .ready {
                self.recordActivity(for: agentID)
                if self.heartbeatTurns.remove(agentID) == nil { self.recordInteraction(for: agentID) }
                self.connectionRecoveryAttempts[agentID] = nil
                self.signInAnnounced.remove(agentID)
                self.forgetSignInRetries(agentID)
            }
            // A start the host refused reached no harness, so it is not a try. The bot asks again when
            // the refusal lapses, and before that only every few minutes.
            if snapshot.phase == .failed, snapshot.failure == .authenticationRequired, let until = snapshot.signInRefusedUntil {
                if let retries = self.signInRetries[agentID], retries > 0 { self.signInRetries[agentID] = retries - 1 }
                let wait = min(max(until.timeIntervalSince(self.now()), Self.signInCheckInterval), Self.refusedSignInCheckInterval)
                self.nextSignInCheck[agentID] = self.now().addingTimeInterval(wait)
            }
            let previous = self.snapshots[agentID]
            // A bot that continues on another harness does not pause.
            if snapshot.phase == .failed, previous?.phase != .failed || previous?.failure != snapshot.failure,
               self.fallBack(agent, repository: repository, after: snapshot) { return }
            if snapshot.phase == .failed, snapshot.failure == .authenticationRequired,
               previous?.phase != .failed || previous?.failure != .authenticationRequired {
                HarnessLoginLog.logger.error("sign-in-needed bot=\(agentID.uuidString, privacy: .public) harness=\(self.runningAgent(agent).harnessIdentifier ?? "unknown", privacy: .public) refused-start=\(snapshot.signInRefusedUntil != nil)")
            }
            if snapshot.phase == .failed, snapshot.failure == .usageLimit,
               previous?.phase != .failed || previous?.failure != .usageLimit {
                self.usagePausedAt[agentID] = self.now()
            }
            if snapshot.failure == .authenticationRequired, self.signInAnnounced.insert(agentID).inserted {
                self.onSignInRequired?(agentID)
            }
            self.snapshots[agentID] = snapshot
            // Only failures the runtime keeps until Kick; a plain stop restarts by itself.
            if snapshot.phase == .failed, let failure = snapshot.failure, failure != .authenticationRequired,
               previous?.phase != .failed || previous?.failure != failure {
                self.onPaused?(agentID)
            }
            if snapshot.phase == .ready { self.markStable(agentID: agentID) }
            // A held bot's turn is over: it stops before it takes another.
            if snapshot.phase != .working, self.heldAgents[agentID] != nil { self.hold(agentID) }
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
