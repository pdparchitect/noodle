import AppKit
import Foundation
import HubLink
import HubWire
import NoodleBrand
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import Observation
import PionCore
import UniformTypeIdentifiers

/// What Pion's windows show and do. Noodle's workspace and runtime run the agents; PionStore keeps
/// what Pion adds: which groups are Investigations and their case records.
@MainActor @Observable final class PionModel {
    let repository: WorkspaceRepository
    let runtime: AgentRuntimeCoordinator
    let store: PionStore
    let harnessProfiles: HarnessProfilesController
    /// What the agents used, as Noodle keeps it, for the Usage window.
    let usage: UsageHistory
    /// Each agent's spending budget, counted from `usage`, as in Noodle.
    let budgets: BotBudgets
    let connectionsController: ToolConnectionsController

    struct AgentResources {
        var folders: [AgentFolder] = []
        var connections: Set<UUID> = []
        var profile: UUID?
    }

    func resources(for agent: AgentRecord) throws -> AgentResources {
        AgentResources(folders: try repository.loadAgentFolders(agent), connections: connectionsController.selectedIDs(for: agent),
                       profile: try repository.loadAgentHarnessProfile(agent))
    }

    func toolManifests(for agent: UUID) -> [ToolProviderManifest] { tools.manifests(assignments: toolAssignments.assignments(for: agent)) }
    /// A scenario's agents never run; their phases and messages come from its script.
    let isScripted: Bool

    private(set) var agents: [AgentRecord] = []
    /// Every agent, archived ones too, for Settings > Agents to bring one back.
    private(set) var everyAgent: [AgentRecord] = []
    /// Every conversation, archived ones too, for Settings > Groups to bring a group back.
    private(set) var everyConversation: [BotConversation] = []
    private(set) var conversations: [BotConversation] = []
    private(set) var investigations: [Investigation] = []
    private(set) var transcripts: [UUID: [ChatMessage]] = [:]
    /// Bumped whenever a case record or audit log may have changed, so the views showing one read it again.
    private(set) var caseRevision = 0
    /// What the main window shows.
    var selection: UUID?
    /// What is being written in each conversation, with its files, kept as Noodle keeps it.
    var drafts = ConversationDrafts()
    private(set) var attachments: [UUID: [UUID: ConversationAttachment]] = [:]
    /// The last message read in each conversation, so the sidebar can mark the rest as new.
    /// Which conversations wait for the champion, kept where Noodle keeps them.
    private(set) var unread = ConversationUnread()
    /// Whether a conversation is on screen, from Noodle's window registry; without one, the selection.
    @ObservationIgnored var isViewing: ((UUID) -> Bool)?
    private func viewing(_ id: UUID) -> Bool { isViewing?(id) ?? (selection == id) }
    /// Each agent's tasks, as the messenger keeps them.
    private(set) var tasksByAgent: [UUID: [AgentTask]] = [:]
    /// Whether the main window shows the welcome: offered once to someone with no agents, then from Help > Welcome.
    private(set) var showsWelcome = false
    /// How groups notify the champion, kept where Noodle keeps it.
    private(set) var groupNotificationSettings = GroupNotificationSettings()
    /// The number the Dock shows, told whenever it may have changed.
    @ObservationIgnored var onBadge: ((Int) -> Void)?
    @ObservationIgnored private var badge: Int?
    /// Agent replies that notify the champion, as their conversations are set; the app shows them.
    @ObservationIgnored var onMessagesArrived: (([ChatMessage]) -> Void)?
    /// A conversation that notifies less than before, whose shown replies the app takes back.
    @ObservationIgnored var onNotificationsNarrowed: ((UUID) -> Void)?
    /// What the champion sent, with the files' names, for a call in that conversation to hear about.
    @ObservationIgnored var onSent: ((UUID, String, [String]) -> Void)?
    /// Agents were added, archived, brought back or deleted.
    @ObservationIgnored var onAgentsChanged: (() -> Void)?
    /// Conversations were added or deleted.
    @ObservationIgnored var onConversationsChanged: (() -> Void)?
    @ObservationIgnored private let sharedInbox = SharedInboxDelivery()
    var problem: String?
    /// Phases a scenario sets for its agents.
    var scriptedPhases: [UUID: AgentRuntimePhase] = [:]

    private let messenger: MessengerBroker
    private var toolBroker: ToolBridgeBroker?
    private let tools = ToolProviderRegistry()
    private let toolAssignments = ToolAssignmentStore()
    private var loop: Task<Void, Never>?
    private var transcriptRevisions: [UUID: TranscriptRevision] = [:]
    /// Pinned conversations, in the order pinned, kept where Noodle keeps them.
    private(set) var pinnedIDs: [UUID] = []
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Whether the transcripts there at launch were read, so later messages count as new.
    private var launchRead = false
    private var running = false

    /// `hidesInstalledHarnesses` leaves out harnesses installed outside Pion's own storage, as on a Mac that never had any.
    init(root: URL, messenger launcher: URL?, isScripted: Bool = false, hidesInstalledHarnesses: Bool = false,
         harnessDefaults: UserDefaults = .standard) {
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: launcher)
        connectionsController = ToolConnectionsController(repository: repository)
        store = PionStore(root: root.appendingPathComponent("Pion", isDirectory: true))
        var environment = ProcessInfo.processInfo.environment
        if hidesInstalledHarnesses { environment["NOODLE_SIMULATE_NO_HARNESSES"] = "1" }
        let discovery = HarnessDiscovery(managedHarnesses: repository.managedHarnesses, environment: environment)
        if !isScripted { discovery.removeSupersededManagedHarnesses() }
        runtime = AgentRuntimeCoordinator(discovery: discovery,
                                          harnesses: HarnessSelection(defaults: harnessDefaults, onByDefault: PionHarnesses.onByDefault))
        runtime.remoteModels = RemoteModelAccountStore(repository: root)
        usage = UsageHistory(url: root.appendingPathComponent("usage.sqlite"))
        budgets = BotBudgets(usage: usage)
        runtime.onUsage = { [usage, budgets] in
            usage.record($0)
            budgets.check()
        }
        runtime.recordedUsage = { [usage] in usage.recorded(session: $0) }
        runtime.harnessProfiles = repository.harnessProfiles
        harnessProfiles = HarnessProfilesController(store: repository.harnessProfiles)
        harnessProfiles.subscriptionUsage = runtime.subscriptionUsage
        self.isScripted = isScripted
        messenger = MessengerBroker(repository: repository)
        store.onChange = { [weak self] in Task { @MainActor in self?.reloadPion() } }
        messenger.onTasksChanged = { [weak self] id in Task { @MainActor in self?.reloadTasks(of: id) } }
        messenger.onWakesChanged = { [weak self] id in
            Task { @MainActor in guard let self else { return }; self.runtime.refreshWakes(for: id, repository: self.repository) }
        }
        let store = self.store, repository = self.repository
        try? tools.register(CaseToolProvider(store: store, leadOf: { id in
            (try? repository.loadConversations())?.first { $0.id == id }?.lead
        }) { id in
            (try? repository.loadAgents())?.first { $0.id == id }?.displayName
        })
        connectionsController.toolRegistry = tools
        connectionsController.serve(PionAdapters.all)
        connectionsController.onAssignmentsChange = { [weak self, toolAssignments] granted in
            toolAssignments.replace(ConnectionToolProvider.grantKind, with: granted)
            self?.toolBroker?.synchronizeSkills()
        }
    }

    // MARK: Running

    func start() {
        do { try repository.prepare() } catch { problem = error.localizedDescription }
        // Before the first capability check, so Apple Intelligence is offered as ready where the Mac has it.
        if !isScripted { offerAppleModel() }
        reload()
        for conversation in conversations {
            readTranscript(conversation.id)
            // As in Noodle, an annotation not sent yet waits in the draft until a message carries it.
            let saved = (try? repository.loadAttachments(conversationID: conversation.id)) ?? []
            if saved.contains(where: { $0.annotation != nil }) {
                remember(saved)
                drafts.restoreAnnotations(saved, messages: messages(in: conversation.id), conversationID: conversation.id)
            }
        }
        launchRead = true
        guard !isScripted, !running else { return }
        do {
            for id in try repository.synchronizeAgentWorkspaces(agents) {
                runtime.wake(id, note: AgentWake.skillsUpdatedNote, repository: repository)
            }
            try messenger.start(agents: agents)
            let now = Date()
            agents.forEach { runtime.seedHeartbeatActivity(for: $0.id, at: now) }
            runtime.startAll(agents: agents, repository: repository)
            runtime.refreshCapabilities()
            try startTools()
        } catch {
            problem = "Pion could not start its agents: \(error.localizedDescription)"
        }
        running = true
        // As in Noodle: agents that sleep stopped start again as the Mac wakes.
        wakeObserver = runtime.reconcileOnWake(agents: { [weak self] in self?.agents ?? [] }, repository: repository)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// Agents may place calls once something can ring them; without a handler they are told calls are unavailable.
    func handleCallRequests(_ handler: @escaping @Sendable (UUID) -> Void) { messenger.onCallRequested = handler }

    func stop() {
        loop?.cancel()
        loop = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        toolBroker?.stop()
        toolBroker = nil
        messenger.stop()
        runtime.stopAll()
        running = false
    }

    private func startTools() throws {
        connectionsController.start(agents: agents)
        if toolBroker == nil {
            // Every agent has the case tool; the broker refuses conversations it is not in.
            let assignments = toolAssignments
            let broker = ToolBridgeBroker(registry: tools, host: .repository(repository) { assignments.assignments(for: $0) }) {
                assignments.assignments(for: $0)
            }
            broker.onSkillsChanged = { [weak self] id in
                Task { @MainActor in
                    guard let self, let agent = self.agents.first(where: { $0.id == id }) else { return }
                    _ = try? self.repository.synchronizeAgentWorkspace(agent)
                    if self.running && !self.isScripted {
                        self.runtime.wake(id, note: AgentWake.skillsUpdatedNote, repository: self.repository)
                    }
                }
            }
            toolBroker = broker
        }
        try toolBroker?.start(agents: agents.map { ToolBridgeAgent(id: $0.id, workspace: repository.directory(for: $0)) })
    }

    private func tick() {
        let before = agents.map(\.id)
        reloadWorkspace()
        if agents.map(\.id) != before { restartBrokers() }
        runtime.reconcile(agents: agents, repository: repository)
        runtime.checkHeartbeats()
        budgets.checkExpired()
        runtime.checkWakes(repository: repository)
        for conversation in conversations { readTranscript(conversation.id) }
        updateBadge()
    }

    /// Holds suspended agents in the runtime, as Noodle does, and starts those whose suspension ran out.
    /// Holds the agents out of budget and starts again those that may continue, as Noodle does.
    private func applyBudgets() {
        guard !isScripted else { return }
        let released = budgets.applyHolds(to: runtime)
        guard running else { return }
        for agent in agents where released.contains(agent.id) { runtime.start(agent: agent, repository: repository) }
    }

    func setBudget(_ limit: TokenLimit?, for agent: AgentRecord) {
        do { try budgets.setLimit(limit, for: agent, repository: repository) } catch { problem = error.localizedDescription }
    }

    func resetBudget(for agent: AgentRecord) {
        do { try budgets.reset(agent, repository: repository) } catch { problem = error.localizedDescription }
    }

    private func applySuspensions() {
        guard !isScripted else { return }
        let released = runtime.hold(AgentRecord.suspensions(of: agents), for: .suspension)
        guard running else { return }
        for agent in agents where released.contains(agent.id) { runtime.start(agent: agent, repository: repository) }
    }

    /// Suspends the agent until then, or unsuspends it when nil. It finishes a turn under way, then takes no
    /// new one; messages wait for it.
    func setSuspended(until: Date?, agent: AgentRecord) {
        do {
            _ = try repository.setAgentSuspended(until: until, agentID: agent.id)
            reload()
        } catch { problem = error.localizedDescription }
    }

    private func restartBrokers() {
        guard running else { return }
        do {
            try messenger.start(agents: agents)
            try startTools()
        } catch { problem = error.localizedDescription }
    }

    // MARK: Reading

    func reload() {
        reloadWorkspace()
        reloadPion()
        groupNotificationSettings = (try? repository.loadGroupNotifications()) ?? GroupNotificationSettings()
        unread = ConversationUnread(repository: repository, known: Set(everyConversation.map(\.id)))
        let pins = ((try? repository.loadPinnedConversationIDs()) ?? []).filter(Set(conversations.map(\.id)).contains)
        if pins != pinnedIDs { pinnedIDs = pins }
        budgets.onChange = { [weak self] in self?.applyBudgets() }
        budgets.load(everyAgent, repository: repository)
        tasksByAgent = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, (try? repository.currentTasks(agentID: $0.id)) ?? []) })
    }

    private func reloadWorkspace() {
        let allAgents = ((try? repository.loadAgents()) ?? [])
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if allAgents != everyAgent { everyAgent = allAgents }
        let loadedAgents = allAgents.filter { $0.archivedAt == nil }
        if loadedAgents != agents {
            agents = loadedAgents
            onAgentsChanged?()
        }
        applySuspensions()
        let allConversations = (try? repository.loadConversations()) ?? []
        let changedSet = allConversations.map(\.id) != everyConversation.map(\.id)
        if allConversations != everyConversation { everyConversation = allConversations }
        if changedSet { onConversationsChanged?() }
        let loadedConversations = allConversations.filter { $0.archivedAt == nil }
        if loadedConversations != conversations { conversations = loadedConversations }
    }

    private func reloadPion() {
        let loaded = store.investigations()
        if loaded != investigations { investigations = loaded }
        caseRevision += 1
    }

    /// Reads a transcript whose files changed. As in Noodle: bots' new messages make the conversation unread
    /// unless it is on screen, and what bots say and anyone's reactions reach the other members.
    private func readTranscript(_ id: UUID) {
        let revision = TranscriptRevision(of: id, in: repository), previous = transcriptRevisions[id]
        let messagesChanged = transcripts[id] == nil || !revision.hasSameMessages(as: previous)
        let attachmentsChanged = !revision.hasSameAttachments(as: previous)
        guard messagesChanged || attachmentsChanged else { return }
        transcriptRevisions[id] = revision
        if attachmentsChanged {
            attachments[id] = Dictionary(((try? repository.loadAttachments(conversationID: id)) ?? []).map { ($0.id, $0) }) { first, _ in first }
        }
        guard messagesChanged else { return }
        // Only what was there at launch is history; a conversation first seen later is new.
        let firstRead = transcripts[id] == nil && !launchRead
        let before = transcripts[id] ?? []
        transcripts[id] = (try? repository.loadMessages(conversationID: id)) ?? []
        if viewing(id) { markRead(id) }
        guard !firstRead else { return }
        let arrivals = TranscriptArrivals(before: before, after: transcripts[id] ?? [])
        registerUnread(arrivals.messages)
        guard !isScripted, !arrivals.isEmpty else { return }
        let shown = arrivals.messages.filter(notifies)
        if !shown.isEmpty { onMessagesArrived?(shown) }
        do {
            try arrivals.deliver(to: runtime, agents: agents, conversations: conversations, repository: repository)
        } catch { problem = error.localizedDescription }
    }

    /// Reads every changed transcript again, for a scenario that writes messages itself.
    func refresh() {
        reload()
        for conversation in conversations { readTranscript(conversation.id) }
        updateBadge()
    }

    func messages(in id: UUID) -> [ChatMessage] { transcripts[id] ?? [] }

    /// What the sidebar shows while searching, as Noodle searches: Investigations, groups and agents by name,
    /// then each message that says the term.
    struct SidebarSearch {
        var investigations: [BotConversation] = [], groups: [BotConversation] = [], agents: [BotConversation] = []
        var mentions: [LinkMessageMatch] = []
        /// How many more mentions Show All would list.
        var hiddenMentions = 0

        var isEmpty: Bool { investigations.isEmpty && groups.isEmpty && agents.isEmpty && mentions.isEmpty }
    }

    /// Nil while nothing is searched for. Closed Investigations are found too.
    func sidebarSearch(_ text: String, showingAll: Bool) -> SidebarSearch? {
        guard let search = ConversationSearch(text) else { return nil }
        let listed = conversations.sorted { lastActivity(of: $0) > lastActivity(of: $1) }
        let byID = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0) })
        let sections = search.sections(listed.map { conversation in
            let investigation = investigation(conversation.id)
            let agent = conversation.kind == .direct ? agent(conversation.participantIDs.first) : nil
            return ConversationSearch.Candidate(
                id: conversation.id, isGroup: conversation.kind == .group,
                name: investigation.map { "\($0.reference) \($0.title)" } ?? agent?.displayName ?? conversation.displayName,
                about: investigation?.objective ?? agent?.publicDescription ?? conversation.publicDescription ?? "",
                members: conversation.kind == .group ? members(of: conversation).map(\.displayName) : [])
        })
        let groups = sections.groups.compactMap { byID[$0] }
        var result = SidebarSearch(investigations: groups.filter { investigation($0.id) != nil },
                                   groups: groups.filter { investigation($0.id) == nil },
                                   agents: sections.bots.compactMap { byID[$0] })
        let mentions = search.messageMatches(in: listed.map { (id: $0.id, messages: messages(in: $0.id)) })
        (result.mentions, result.hiddenMentions) = search.shown(mentions, besideNames: !sections.isEmpty, showingAll: showingAll)
        return result
    }

    /// When anything was last said, by anyone.
    func lastActivity(of conversation: BotConversation) -> Date {
        messages(in: conversation.id).last?.createdAt ?? conversation.createdAt
    }

    /// As in Noodle, Stop acts on the agent in a direct conversation, never a whole group.
    func stoppableAgent(in conversationID: UUID?) -> AgentRecord? {
        guard let conversation = conversation(conversationID), conversation.kind == .direct,
              let agent = agent(conversation.participantIDs.first),
              isScripted ? phase(of: agent) == .working : runtime.canStopTurn(agent.id) else { return nil }
        return agent
    }

    func stop(in conversationID: UUID?) {
        guard let agent = stoppableAgent(in: conversationID) else { return }
        if isScripted { scriptedPhases[agent.id] = .ready }
        else if !runtime.stopTurn(agent: agent, repository: repository) { return }
        do {
            if let message = try repository.appendStopNotice(agentID: agent.id) {
                readTranscript(message.conversationID)
            }
        } catch { problem = error.localizedDescription }
    }

    func conversation(_ id: UUID?) -> BotConversation? { id.flatMap { id in conversations.first { $0.id == id } } }
    func investigation(_ id: UUID?) -> Investigation? { id.flatMap { id in investigations.first { $0.id == id } } }
    func agent(_ id: UUID?) -> AgentRecord? { id.flatMap { id in agents.first { $0.id == id } } }

    /// The groups Settings > Groups lists, archived ones too; Investigations close rather than archive.
    var groupsInSettings: [BotConversation] {
        everyConversation.filter { $0.kind == .group && investigation($0.id) == nil }
    }

    /// Archives a group, taking it out of the sidebar and the window it was open in, or brings it back.
    func setGroupArchived(_ archived: Bool, id: UUID) {
        do {
            _ = try repository.setConversationArchived(archived, conversationID: id)
            if archived, selection == id { selection = nil }
            reload()
        } catch { problem = error.localizedDescription }
    }

    struct SidebarSections {
        var pinned: [BotConversation] = [], unread: [BotConversation] = []
        var investigations: [BotConversation] = [], groups: [BotConversation] = [], agents: [BotConversation] = []
    }

    /// Noodle's order: pins on top as pinned, an Unread section when chosen, the rest newest message first, with
    /// open Investigations by severity first. Closed ones keep a section of their own.
    func sidebarSections(_ order: ConversationOrder) -> SidebarSections {
        let listed = conversations.filter { investigation($0.id)?.isClosed != true }
        let sections = order.sections(listed, pinned: pinnedIDs,
                                      lastActivity: lastActivity(of:),
                                      isUnread: { self.countsAsUnread($0.id) })
        let rest = sections.rest
        // Most severe first, newest message first within each severity.
        let cases = rest.compactMap { conversation in investigation(conversation.id).map { (conversation, $0.severityRank) } }
            .enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.map(\.element.0)
        return SidebarSections(
            pinned: sections.pinned, unread: sections.unread,
            investigations: order.arranged(cases) { self.countsAsUnread($0.id) },
            groups: rest.filter { $0.kind == .group && investigation($0.id) == nil },
            agents: rest.filter { $0.kind == .direct })
    }

    /// An Investigation's title, an agent's name or a group's.
    func title(of conversation: BotConversation) -> String {
        investigation(conversation.id)?.title
            ?? (conversation.kind == .direct ? agent(conversation.participantIDs.first)?.displayName : nil)
            ?? conversation.displayName
    }

    func isPinned(_ id: UUID) -> Bool { pinnedIDs.contains(id) }

    func setPinned(_ pinned: Bool, conversationID: UUID) {
        guard pinned != isPinned(conversationID) else { return }
        var updated = pinnedIDs.filter { $0 != conversationID }
        if pinned { updated.append(conversationID) }
        do {
            try repository.savePinnedConversationIDs(updated)
            pinnedIDs = updated
        } catch { problem = error.localizedDescription }
    }

    /// The line under a row's name, as Noodle's View > Sidebar Line chooses it.
    func rowDetail(for conversation: BotConversation, showing detail: ConversationRowDetail) -> String {
        let messages = messages(in: conversation.id)
        let agent = conversation.kind == .direct ? agent(conversation.participantIDs.first) : nil
        return detail.line(for: conversation, agent: agent, messages: messages,
                           latestMessage: ConversationRowDetail.latestMessage(in: messages))
    }

    /// The conversation each agent has with the champion alone.
    func directConversation(of agent: AgentRecord) -> BotConversation? {
        conversations.first { $0.kind == .direct && $0.participantIDs == [agent.id] }
    }

    /// Reply, from an agent's profile in a group: the message starts by addressing the agent, as in Noodle.
    func reply(to agent: AgentRecord, in id: UUID) {
        drafts[id].text = ComposerReply.addressing(agent.displayName, draft: drafts[id].text)
    }

    /// Noodle's reason the message field is off, or nil when something can be sent.
    func composerUnavailableReason(for conversation: BotConversation) -> String? {
        let members = conversation.participantIDs.compactMap { id in everyAgent.first { $0.id == id } }
        return ComposerAvailability.unavailableReason(for: conversation, members: members, member: "agent")
    }

    /// Whether a message can go there now, from Forward…, Share or Shortcuts: its message field is on and it isn't
    /// a closed Investigation.
    func takesMessages(_ conversation: BotConversation) -> Bool {
        composerUnavailableReason(for: conversation) == nil && investigation(conversation.id)?.isClosed != true
    }

    func members(of conversation: BotConversation) -> [AgentRecord] {
        let lead = conversation.lead
        return agents.filter { conversation.participantIDs.contains($0.id) }
            .sorted { ($0.id == lead ? 0 : 1, $0.displayName) < ($1.id == lead ? 0 : 1, $1.displayName) }
    }

    func caseRecord(_ id: UUID) -> CaseRecord {
        _ = caseRevision
        return store.caseRecord(id)
    }

    func audit(_ id: UUID) -> [AuditEntry] {
        _ = caseRevision
        return store.audit(id)
    }

    func phase(of agent: AgentRecord) -> AgentRuntimePhase {
        isScripted ? scriptedPhases[agent.id] ?? .ready : runtime.snapshot(for: agent.id).phase
    }

    /// What stops the agent, suspended or paused, which a sidebar row says before anything else.
    func interruption(of agent: AgentRecord) -> String? {
        if isScripted { return nil }
        if agent.isSuspended(), let until = agent.suspendedUntil { return AgentRecord.suspension(until: until) }
        return runtime.snapshot(for: agent.id).pauseSummary
    }

    func phaseDetail(of agent: AgentRecord) -> String? {
        if isScripted { return agent.status }
        if agent.isSuspended(), let until = agent.suspendedUntil { return AgentRecord.suspension(until: until) }
        let snapshot = runtime.snapshot(for: agent.id)
        return snapshot.pauseSummary ?? agent.status
    }

    func isUnread(_ id: UUID) -> Bool { selection != id && unread.unread.contains(id) }

    /// Unread and not a muted group, as Noodle shows it: a muted group's row is not marked.
    func countsAsUnread(_ id: UUID) -> Bool { isUnread(id) && notifications(of: id) != .muted }

    func markRead(_ id: UUID) {
        guard unread.markRead(id) else { return }
        saveUnread()
    }

    private func registerUnread(_ messages: [ChatMessage]) {
        guard !messages.isEmpty else { return }
        let before = unread
        unread.register(messages, isViewing: viewing, mentionName: { _ in champion })
        if unread != before { saveUnread() }
    }

    private func saveUnread() {
        do { try unread.save(to: repository) } catch { problem = error.localizedDescription }
        updateBadge()
    }

    // MARK: Apple Intelligence

    static let appleModelOfferedKey = "PionAppleModel.offered"

    /// Noodle leaves Apple's on-device model out until someone adds it; it is one of Pion's own harnesses, so
    /// Pion adds it once. Someone who removes it in Settings keeps it removed.
    func offerAppleModel(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Self.appleModelOfferedKey) else { return }
        do {
            try AppleLocalModelStore(repository: repository.rootURL).setSystemModelAdded(true)
            defaults.set(true, forKey: Self.appleModelOfferedKey)
        } catch { problem = error.localizedDescription }
    }

    // MARK: Pauses

    /// Why a conversation's agents don't answer for now, as Noodle works it out: Pion runs all its agents, so any
    /// failed one waits for Kick or a sign-in.
    func pause(of conversation: BotConversation) -> ConversationPause? {
        ConversationPause.of(conversation, participants: members(of: conversation), runtime: runtime,
                                    waitsForKick: { _ in true }, canUnsuspend: { _ in true })
    }

    // MARK: Welcome

    static let welcomeDismissedKey = "PionWelcome.dismissed"

    /// The welcome, once, for someone with no agents yet. Afterwards the empty window and Help > Welcome offer it.
    func offerWelcome(defaults: UserDefaults = .standard) {
        guard agents.isEmpty, !defaults.bool(forKey: Self.welcomeDismissedKey) else { return }
        showsWelcome = true
    }

    /// Help > Welcome: the welcome again, agents or not.
    func showWelcome() { showsWelcome = true }

    func finishWelcome(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Self.welcomeDismissedKey)
        showsWelcome = false
    }

    /// The welcome makes the team only for someone with no agents yet; shown again from the Help menu, it only
    /// sets up the account chosen, and returns nil. The team is made on `provider`, in a group they share.
    func createStarterTeamIfFirst(on provider: HarnessProvider) throws -> (team: [AgentRecord], group: BotConversation)? {
        guard agents.isEmpty else { return nil }
        let style = BotNameStyle(rawValue: UserDefaults.standard.string(forKey: Self.agentNameStyleKey) ?? "") ?? Self.defaultAgentNameStyle
        var team: [AgentRecord] = []
        for member in PionStarterTeam.members {
            let name = suggestedAgentName(style: style)
            team.append(try createAgent(name: name, description: member.publicDescription, instructions: member.instructions,
                                        provider: provider, model: nil, symbol: member.symbol, color: member.colorIndex))
        }
        let group = try createGroup(name: PionStarterTeam.groupName, description: PionStarterTeam.groupDescription,
                                    members: Set(team.map(\.id)), lead: team.first?.id)
        return (team, group)
    }

    /// Opens the team's group, where they introduce themselves.
    func introduceStarterTeam(in groupID: UUID) {
        selection = groupID
        guard !isScripted, let group = conversation(groupID) else { return }
        runtime.introduce(group.participantIDs, in: groupID, repository: repository)
    }

    // MARK: Notifications

    /// The unread conversations the Dock counts, as Noodle counts them: a muted group never, a group in Mentions only
    /// once an unread reply names the champion.
    var badgedConversationIDs: Set<UUID> {
        unread.badged(notifications(of:)).subtracting([selection].compactMap { $0 })
    }

    /// Tells the Dock again, as once notifications are allowed and the badge can show.
    func refreshBadge() { badge = nil; updateBadge() }

    private func updateBadge() {
        let count = badgedConversationIDs.count
        guard count != badge else { return }
        badge = count
        onBadge?(count)
    }

    /// How a conversation notifies: a group as set on its own, or else as set for all groups. An agent's own
    /// conversation notifies every reply.
    func notifications(of id: UUID) -> LinkNotifications {
        guard conversations.first(where: { $0.id == id })?.kind == .group else { return .all }
        return LinkNotifications.effective(chosenNotifications(of: id), inGroups: groupNotifications)
    }

    /// How a group was set to notify on its own; nil keeps the default.
    func chosenNotifications(of id: UUID) -> LinkNotifications? {
        groupNotificationSettings.levels[id].map(LinkNotifications.init(rawValue:))
    }

    /// How groups that keep the default notify: every reply, or only those naming the champion.
    var groupNotifications: LinkNotifications {
        get { groupNotificationSettings.inGroups == LinkNotifications.mentions.rawValue ? .mentions : .all }
        set {
            guard newValue == .all || newValue == .mentions, newValue != groupNotifications else { return }
            var updated = groupNotificationSettings
            updated.inGroups = newValue.rawValue
            saveGroupNotifications(updated)
        }
    }

    /// Sets how a group notifies, `default` keeping the level for all groups.
    func setNotifications(_ level: LinkNotifications, conversationID: UUID) {
        guard level != (chosenNotifications(of: conversationID) ?? .default),
              conversations.first(where: { $0.id == conversationID })?.kind == .group else { return }
        var updated = groupNotificationSettings
        updated.levels[conversationID] = level == .default ? nil : level.rawValue
        saveGroupNotifications(updated)
    }

    /// Whether a new reply notifies the champion, as its conversation is set to.
    func notifies(_ message: ChatMessage) -> Bool {
        notifications(of: message.conversationID).notifies(message.body, name: champion)
    }

    /// Groups that now notify less take back what they showed.
    private func saveGroupNotifications(_ updated: GroupNotificationSettings) {
        do {
            try repository.saveGroupNotifications(updated)
            let before = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, notifications(of: $0.id)) })
            groupNotificationSettings = updated
            updateBadge()
            for (id, level) in before where level != notifications(of: id) && notifications(of: id) != .all {
                onNotificationsNarrowed?(id)
            }
        } catch { problem = error.localizedDescription }
    }

    /// The name an author goes by.
    func name(of author: MessageAuthor) -> String {
        switch author {
        case .user: champion
        case .agent(let id): agent(id)?.displayName ?? "Removed agent"
        case .system: "Pion"
        }
    }

    func name(of actor: CaseActor) -> String {
        switch actor {
        case .agent(let id): agent(id)?.displayName ?? "Removed agent"
        case .champion(let name): name
        }
    }

    /// The person using this Mac, who owns the Investigations they open.
    var champion: String {
        let name = NSFullUserName()
        return isScripted ? scriptedChampion : name.isEmpty ? NSUserName() : name
    }
    var scriptedChampion = "Avery Lin"

    var now: Date { isScripted ? ScenarioClock.now : Date() }

    // MARK: Agents

    static let agentNameStyleKey = "PionAgentNameStyle"
    static let defaultAgentNameStyle = BotNameStyle.playful

    func suggestedAgentName(style: BotNameStyle = PionModel.defaultAgentNameStyle, excluding: String? = nil) -> String {
        let taken = Set((agents.map(\.displayName) + [excluding].compactMap { $0 }).map { $0.lowercased() })
        for _ in 0..<64 {
            let candidate = BotNameGenerator.random(style: style, excluding: excluding)
            if !taken.contains(candidate.lowercased()) { return candidate }
        }
        let base = BotNameGenerator.random(style: style)
        var suffix = 2
        while taken.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    func agentInstructions(_ agent: AgentRecord) throws -> String {
        let backstory = try repository.loadAgentBackstory(agent)
        if backstory == AgentPrinciples.text { return "" }
        let suffix = "\n\n" + AgentPrinciples.text
        return backstory.hasSuffix(suffix) ? String(backstory.dropLast(suffix.count)) : backstory
    }

    @discardableResult
    func updateAgent(_ agent: AgentRecord, name: String, description: String?, instructions: String,
                     provider: HarnessProvider?, model: String?, effort: String? = nil,
                     resources: AgentResources? = nil) throws -> AgentRecord {
        let name = try ConversationName.validated(name)
        let resources = try resources.map { try validated($0, provider: provider) }
        guard let current = self.agent(agent.id) else { throw WorkspaceError.missingAgent(agent.id) }
        let previous = try agentInstructions(current)
        let checkpoint = try AgentSettingsCheckpoint(repository: repository, agent: current, conversations: conversations)
        let profile = try repository.loadAgentHarnessProfile(current)
        let updated: AgentRecord
        do {
            let chosenEffort = effort.map { $0.isEmpty ? nil : $0 } ?? current.reasoningEffort
            updated = try repository.updateAgent(current, displayName: name, harnessIdentifier: provider?.rawValue,
                modelIdentifier: model, reasoningEffort: chosenEffort, publicDescription: description,
                avatarSymbolName: current.avatarSymbolName, avatarColorIndex: current.avatarColorIndex,
                avatarImageData: current.avatarImageData, now: now)
            try repository.updateAgentBackstory(updated, backstory: instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                                                + "\n\n" + AgentPrinciples.text)
            if let resources {
                try repository.updateAgentFolders(updated, folders: resources.folders)
                try repository.updateAgentHarnessProfile(updated, profile: resources.profile)
                try connectionsController.assign(resources.connections, to: updated, synchronizeWorkspace: false)
            } else if current.harnessIdentifier != updated.harnessIdentifier, profile != nil {
                // A profile belongs to its harness; a new harness uses its own default login.
                try repository.updateAgentHarnessProfile(updated, profile: nil)
            }
            for var conversation in conversations where conversation.kind == .direct && conversation.participantIDs == [agent.id] {
                conversation.displayName = updated.displayName
                conversation.updatedAt = now
                try repository.updateConversation(conversation)
            }
            try repository.synchronizeAgentWorkspace(updated)
        } catch {
            do { try checkpoint.restore(); try connectionsController.reloadAssignments(); try repository.synchronizeAgentWorkspace(current) }
            catch { throw CaseError("The agent could not be saved or fully restored: \(error.localizedDescription)") }
            throw error
        }
        reload()
        if running && !isScripted {
            runtime.authorizeSelectedHarness(updated)
            runtime.restart(agent: updated, repository: repository,
                            resetThread: previous != instructions.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return updated
    }

    @discardableResult
    func updateGroup(_ group: BotConversation, name: String, description: String?, members: Set<UUID>,
                     folders: [AgentFolder]? = nil, memberTools: [UUID: Set<UUID>] = [:]) throws -> BotConversation {
        guard investigation(group.id) == nil else { throw CaseError("Use the investigation's controls to edit its team.") }
        _ = try ConversationName.validated(name)
        try validateMemberTools(memberTools, members: members)
        let folders = try folders.map { try AgentFolder.validated($0, protecting: AgentFolder.protectedLocations(root: repository.rootURL)) }
        let before = conversation(group.id) ?? group
        let checkpoint = try AgentSettingsCheckpoint(repository: repository)
        let updated: BotConversation
        do {
            try assignMemberTools(memberTools)
            updated = try repository.updateGroup(conversationID: group.id, named: name, publicDescription: description,
                                                  participantIDs: Array(members), existingAgents: agents, folders: folders, now: now)
        } catch { try checkpoint.restore(); try connectionsController.reloadAssignments(); throw error }
        reload()
        readTranscript(group.id)
        synchronizeResourceWorkspaces(restarting: BotConversation.botsWithChangedFolders(from: before, to: updated))
        wakeMembersAfterEdit(from: before, to: updated)
        return updated
    }

    /// As in Noodle: the members hear the group's notice when who is in it or what it is for changed.
    private func wakeMembersAfterEdit(from before: BotConversation, to after: BotConversation) {
        guard !isScripted, BotConversation.editWakesMembers(from: before, to: after) else { return }
        runtime.notify(members(of: after), repository: repository)
    }

    private func validated(_ resources: AgentResources, provider: HarnessProvider?) throws -> AgentResources {
        let folders = try AgentFolder.validated(resources.folders, protecting: AgentFolder.protectedLocations(root: repository.rootURL))
        try connectionsController.validateAssignment(resources.connections)
        if let profile = resources.profile {
            guard let saved = harnessProfiles.profile(profile), saved.provider == provider else {
                throw CaseError("Choose a profile belonging to this harness.")
            }
        }
        return AgentResources(folders: folders, connections: resources.connections, profile: resources.profile)
    }

    private func validateMemberTools(_ assignments: [UUID: Set<UUID>], members: Set<UUID>) throws {
        guard !members.isEmpty, members.isSubset(of: Set(agents.map(\.id))), Set(assignments.keys).isSubset(of: members) else {
            throw CaseError("Choose current team members before assigning tools.")
        }
        for ids in assignments.values { try connectionsController.validateAssignment(ids) }
    }

    private func assignMemberTools(_ assignments: [UUID: Set<UUID>]) throws {
        for (id, connections) in assignments {
            guard let agent = agent(id) else { throw WorkspaceError.missingAgent(id) }
            try connectionsController.assign(connections, to: agent, synchronizeWorkspace: false)
        }
    }

    /// Folder grants are copied into agent configuration and fixed when its sandbox launches.
    /// Tool grants remain per agent and are checked by the broker around every call.
    private func synchronizeResourceWorkspaces(restarting ids: Set<UUID>) {
        do {
            let changed = try repository.synchronizeAgentWorkspaces(agents)
            guard running && !isScripted else { return }
            for agent in agents where ids.contains(agent.id) { runtime.restart(agent: agent, repository: repository) }
            for id in changed where !ids.contains(id) { runtime.wake(id, note: AgentWake.skillsUpdatedNote, repository: repository) }
        } catch { problem = "Settings were saved, but the agents could not be updated: \(error.localizedDescription)" }
    }

    var installedProviders: [HarnessProvider] { runtime.availableInstallations.map(\.provider) }
    func models(for provider: HarnessProvider, profile: UUID? = nil) -> [HarnessModel] { runtime.models(for: provider.rawValue, profile: profile) }

    @discardableResult
    func createAgent(name: String, description: String?, instructions: String, provider: HarnessProvider?, model: String?,
                     effort: String? = nil, symbol: String? = nil, color: Int? = nil,
                     resources: AgentResources = AgentResources(), id: UUID = UUID()) throws -> AgentRecord {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? suggestedAgentName() : name
        let resources = try validated(resources, provider: provider)
        try repository.prepare()
        let checkpoint = try AgentSettingsCheckpoint(repository: repository)
        let created = try repository.createAgent(named: name, harnessIdentifier: provider?.rawValue, modelIdentifier: model,
                                                 reasoningEffort: effort, publicDescription: description,
                                                 avatarSymbolName: symbol, avatarColorIndex: color,
                                                 backstory: instructions + "\n\n" + AgentPrinciples.text, id: id, now: now)
        do {
            try repository.updateAgentFolders(created.agent, folders: resources.folders)
            try repository.updateAgentHarnessProfile(created.agent, profile: resources.profile)
            try connectionsController.assign(resources.connections, to: created.agent, synchronizeWorkspace: false)
            try repository.synchronizeAgentWorkspace(created.agent)
        } catch {
            let failure = error
            try checkpoint.restore(); try connectionsController.reloadAssignments()
            try repository.deleteAgent(created.agent)
            throw failure
        }
        reload()
        if running {
            restartBrokers()
            runtime.start(agent: created.agent, repository: repository)
        }
        return created.agent
    }

    // MARK: Conversations

    func send(_ text: String, in id: UUID) throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let conversation = conversation(id) else { return }
        try personMessage(body, to: conversation)
        onSent?(id, body, [])
    }

    /// Noodle's sending, then the transcript is read again and the conversation read.
    private func personMessage(_ text: String, files: [ConversationAttachment] = [], voice: VoiceMessage? = nil,
                               to conversation: BotConversation) throws {
        try PersonMessage.send(text, files: files, voice: voice, to: conversation, members: members(of: conversation),
                               runtime: isScripted ? nil : runtime, repository: repository, now: now)
        readTranscript(conversation.id)
        markRead(conversation.id)
    }

    /// Wakes a conversation's agents for the champion's message as Noodle does: in a team with a lead, the lead and
    /// anyone the message names at once, the others after the lead's head start.
    /// Send to Pion, as Noodle's Send to Noodle: the conversations something can be sent to, for its picker.
    func publishShareDestinations(to inbox: SharedInbox? = try? SharedInbox.configured()) {
        guard let inbox else { return }
        SharedInboxDelivery.publish(conversations.filter(takesMessages),
                                    to: inbox) { title(of: $0) }
    }

    /// What was sent with Send to Pion, as your messages, which the agents hear as they hear the message field.
    func deliverShared(from inbox: SharedInbox? = try? SharedInbox.configured()) async {
        guard let inbox else { return }
        await sharedInbox.deliver(from: inbox, repository: repository, delivered: { message in
            refresh()
            if let conversation = conversation(message.conversationID) { deliver(message.body, in: conversation) }
        }, problem: { problem = $0 })
    }

    private func deliver(_ body: String, in conversation: BotConversation) {
        if !isScripted { runtime.notify(members(of: conversation), in: conversation, body: body, repository: repository) }
    }

    /// Sends a recording as Noodle does: the audio, with its transcript, attached to a voice message, together
    /// with any files waiting in the composer. The text draft stays as it was.
    func sendVoiceMessage(from url: URL, voice: VoiceMessage, to id: UUID) throws {
        guard let conversation = conversation(id) else { throw WorkspaceError.missingConversation(id) }
        let attachment = try repository.importAttachment(from: url, into: id, mediaType: "audio/x-caf", voice: voice)
        let staged = drafts[id].attachments
        try personMessage("", files: staged + [attachment], voice: voice, to: conversation)
        drafts[id].attachments = []
        onSent?(id, voice.transcript ?? VoiceMessage.messageBody, staged.map(\.originalFilename))
    }

    /// Each conversation's voice recorder, kept while Pion runs so switching away does not lose a recording.
    @ObservationIgnored var voiceRecorders: [UUID: AnyObject] = [:]

    // MARK: Tasks, listed and answered as in Noodle

    func reloadTasks(of id: UUID) { tasksByAgent[id] = (try? repository.currentTasks(agentID: id)) ?? [] }

    func openTasks(waitingOnMeOnly: Bool) -> [(agent: AgentRecord, task: AgentTask)] {
        AgentTask.openList(agents.map { ($0, tasksByAgent[$0.id] ?? []) }, waitingOnMeOnly: waitingOnMeOnly)
    }

    func conversationID(for task: AgentTask, of agentID: UUID) -> UUID? {
        task.conversationID(in: conversations, agentID: agentID)
    }

    /// Sends the champion's words about a task to its conversation, carrying the task so its agent knows which one
    /// to move on. Only the agent changes the task.
    func sendFeedback(_ text: String, on task: AgentTask, of agentID: UUID) throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let id = conversationID(for: task, of: agentID), let conversation = conversation(id) else { return }
        _ = try repository.sendUserMessage(conversationID: id, body: body, task: TaskReference(task, agentID: agentID), now: now)
        readTranscript(id)
        markRead(id)
        if !isScripted { runtime.notify(members(of: conversation), repository: repository) }
    }

    /// The voice an agent speaks with on calls; empty leaves it to the harness.
    func voice(of agent: AgentRecord) -> String { (try? repository.loadAgentVoice(agent)).flatMap { $0 } ?? "" }

    func setVoice(_ voice: String, for agent: AgentRecord) {
        do { try repository.updateAgentVoice(agent, voice: voice.isEmpty ? nil : voice) } catch { problem = error.localizedDescription }
    }

    // MARK: Deleting, as Noodle deletes

    /// Deletes an agent with its workspace and its own conversation, or a group with its messages. Investigations
    /// close rather than go.
    @discardableResult
    func delete(_ conversation: BotConversation) -> Bool {
        let agent = conversation.kind == .direct ? self.agent(conversation.participantIDs.first) : nil
        do {
            try runtime.delete(conversation, agent: agent, agents: agents, repository: repository)
            drafts.clear(conversation.id)
            if selection == conversation.id { selection = nil }
            reload()
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    // MARK: Reactions, through Noodle's own rules

    func toggleReaction(_ emoji: String, on message: ChatMessage) {
        react(message) { try repository.togglePersonReaction(emoji, on: message) }
    }

    func changeReaction(_ emoji: String, to replacement: String, on message: ChatMessage) {
        react(message) { try repository.changePersonReaction(emoji, to: replacement, on: message) }
    }

    func removeReaction(_ emoji: String, on message: ChatMessage) {
        react(message) { try repository.removePersonReaction(emoji, on: message) }
    }

    private func react(_ message: ChatMessage, _ change: () throws -> Void) {
        do {
            try change()
            readTranscript(message.conversationID)
        } catch { problem = error.localizedDescription }
    }

    /// Makes an agent the group's lead, or leaves it without one; the members are told in a notice.
    func setLead(_ agentID: UUID?, of conversation: BotConversation) {
        let investigation = store.investigation(conversation.id)
        guard investigation?.isClosed != true else { problem = "Reopen this investigation before changing its lead."; return }
        guard (self.conversation(conversation.id) ?? conversation).lead != agentID else { return }
        do {
            let updated = try repository.setGroupLead(conversationID: conversation.id, agentID: agentID, existingAgents: agents, now: now)
            if investigation != nil {
                try store.append(AuditEntry(at: now, actor: .champion(champion), event: "lead",
                                            detail: agentID.flatMap { agent($0)?.displayName } ?? "No lead"), to: conversation.id)
            }
            reload()
            readTranscript(conversation.id)
            if !isScripted { runtime.notify(members(of: updated), repository: repository) }
        } catch { problem = error.localizedDescription }
    }

    func sendDraft(to id: UUID) {
        let text = drafts[id].text, files = drafts[id].attachments
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty, let conversation = conversation(id) else { return }
        do {
            try personMessage(text, files: files, to: conversation)
            onSent?(id, text.trimmingCharacters(in: .whitespacesAndNewlines), files.map(\.originalFilename))
            drafts.clear(id)
        } catch { problem = error.localizedDescription }
    }

    /// Shortcuts' Send to Agent: the message and its files go at once, beside whatever waits in the message field.
    func sendFromShortcut(_ text: String, files: [AttachmentTransferPayload], to id: UUID) throws {
        guard let conversation = conversation(id), takesMessages(conversation) else { throw WorkspaceError.missingConversation(id) }
        let attached = try files.map { try repository.importAttachment($0, into: id, now: now) }
        try personMessage(text, files: attached, to: conversation)
        onSent?(id, text.trimmingCharacters(in: .whitespacesAndNewlines), attached.map(\.originalFilename))
    }

    /// Copies files into the conversation, ready to go with the next message.
    func attach(_ urls: [URL], to id: UUID) { attach(urls.map { .file($0) }, to: id) }

    /// Files, pictures or pasted text waiting in the composer, stored as Noodle stores them. True when any was attached.
    @discardableResult
    func attach(_ payloads: [AttachmentTransferPayload], to id: UUID) -> Bool {
        var attached = false
        for payload in payloads {
            do {
                let attachment = try repository.importAttachment(payload, into: id, now: now)
                remember([attachment], pending: attachment)
                attached = true
            } catch { problem = "\(payload.displayName) could not be attached: \(error.localizedDescription)" }
        }
        return attached
    }

    func removePending(_ attachment: ConversationAttachment, from id: UUID) {
        drafts[id].attachments.removeAll { $0.id == attachment.id }
        try? repository.removeAttachment(attachment)
    }

    func attachment(_ id: UUID, in conversation: UUID) -> ConversationAttachment? { attachments[conversation]?[id] }

    func fileURL(_ attachment: ConversationAttachment) -> URL { repository.attachmentFileURL(attachment) }

    /// The files a message carries, in its order.
    func files(of message: ChatMessage) -> [ConversationAttachment] {
        message.attachments.compactMap { attachment($0, in: message.conversationID) }
    }

    /// An annotation on a file, saved beside it as a new attachment for the next message.
    func saveAnnotation(_ annotation: AttachmentAnnotation, content: Data, source: ConversationAttachment) throws {
        let attachment = try repository.importAnnotation(annotation, content: content, on: source)
        remember([attachment], pending: attachment)
    }

    /// An annotation can be changed until a message carries it.
    func canEditAnnotation(_ attachment: ConversationAttachment) -> Bool {
        drafts.canEditAnnotation(attachment, messages: messages(in: attachment.conversationID))
    }

    // MARK: Patch review, as Noodle reviews

    /// Which files of each patch the champion ticked off, kept where Noodle keeps them.
    @ObservationIgnored private lazy var patchReviewState = PatchReviewStore(
        fileURL: repository.rootURL.appendingPathComponent("patch-reviews.json"))

    func viewedPatchFiles(_ attachment: ConversationAttachment) -> Set<String> { patchReviewState.viewed(attachment) }

    func saveViewedPatchFiles(_ paths: Set<String>, for attachment: ConversationAttachment) {
        do { try patchReviewState.save(paths, for: attachment) }
        catch { problem = "Could not save which files you viewed: \(error.localizedDescription)" }
    }

    func attachmentFileURL(_ attachment: ConversationAttachment) -> URL { fileURL(attachment) }

    func patchAnnotations(on attachment: ConversationAttachment) -> [AttachmentAnnotation] {
        (attachments[attachment.conversationID] ?? [:]).values.compactMap(\.annotation)
            .filter { $0.sourceAttachmentID == attachment.id }
    }

    // MARK: Forward…, as Noodle forwards

    /// The other conversations a file can go to, by name, newest first. As in Noodle, only those that take a
    /// message now: not an archived agent's, nor a closed Investigation.
    func forwardTargets(from id: UUID, search: String) -> [BotConversation] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.filter { $0.id != id && takesMessages($0) }
            .filter { term.isEmpty || title(of: $0).localizedStandardContains(term) }
            .sorted { lastActivity(of: $0) > lastActivity(of: $1) }
    }

    /// Sends a file on to another conversation as one message from the champion, with the comment as its words.
    /// What is being written there stays as it is.
    func forward(_ attachment: ConversationAttachment, to id: UUID, comment: String) throws {
        guard let conversation = conversation(id) else { throw WorkspaceError.missingConversation(id) }
        let (copy, _) = try repository.forward(attachment, to: id, comment: comment, now: now)
        remember([copy])
        readTranscript(id)
        deliver(comment.trimmingCharacters(in: .whitespacesAndNewlines), in: conversation)
        onSent?(id, comment.trimmingCharacters(in: .whitespacesAndNewlines), [copy.originalFilename])
    }

    /// Files saved into a conversation outside `attach`, such as captures, annotations and what they mark.
    func remember(_ saved: [ConversationAttachment], pending: ConversationAttachment? = nil) {
        for attachment in saved { attachments[attachment.conversationID, default: [:]][attachment.id] = attachment }
        if let pending {
            if let index = drafts[pending.conversationID].attachments.firstIndex(where: { $0.id == pending.id }) {
                drafts[pending.conversationID].attachments[index] = pending
            } else {
                drafts[pending.conversationID].attachments.append(pending)
            }
        }
    }

    @discardableResult
    func createGroup(name: String, description: String?, members: Set<UUID>, folders: [AgentFolder] = [],
                     memberTools: [UUID: Set<UUID>] = [:], lead: UUID? = nil) throws -> BotConversation {
        _ = try ConversationName.validated(name)
        let folders = try AgentFolder.validated(folders, protecting: AgentFolder.protectedLocations(root: repository.rootURL))
        try validateMemberTools(memberTools, members: members)
        let checkpoint = try AgentSettingsCheckpoint(repository: repository)
        let group: BotConversation
        do {
            try assignMemberTools(memberTools)
            group = try repository.createGroup(named: name, publicDescription: description, participantIDs: Array(members),
                                                existingAgents: agents, folders: folders, leadID: lead, now: now)
        } catch { try checkpoint.restore(); try connectionsController.reloadAssignments(); throw error }
        reload()
        readTranscript(group.id)
        synchronizeResourceWorkspaces(restarting: BotConversation.botsWithChangedFolders(from: nil, to: group))
        return group
    }

    func setMembers(_ ids: Set<UUID>, of conversation: BotConversation) {
        let investigation = store.investigation(conversation.id)
        guard investigation?.isClosed != true else { problem = "Reopen this investigation before changing its team."; return }
        let previous = self.conversation(conversation.id) ?? conversation
        let members = ids
        let before = Set(previous.participantIDs)
        guard members != before, !members.isEmpty else { return }
        do {
            let updated = try repository.updateGroupParticipants(conversationID: conversation.id, participantIDs: Array(members), existingAgents: agents, now: now)
            reload()
            synchronizeResourceWorkspaces(restarting: BotConversation.botsWithChangedFolders(from: previous, to: updated))
            let added = agents.filter { members.subtracting(before).contains($0.id) }.map(\.displayName)
            let removed = agents.filter { before.subtracting(members).contains($0.id) }.map(\.displayName)
            var parts: [String] = []
            if !added.isEmpty { parts.append("added " + added.formatted(.list(type: .and))) }
            if !removed.isEmpty { parts.append("removed " + removed.formatted(.list(type: .and))) }
            if investigation != nil {
                try store.append(AuditEntry(at: now, actor: .champion(champion), event: "staff", detail: parts.joined(separator: "; ")), to: conversation.id)
            }
            try send("I have \(parts.joined(separator: " and ")).", in: conversation.id)
        } catch { problem = error.localizedDescription }
    }

    // MARK: Investigations

    struct Draft {
        var title = ""
        var objective = ""
        /// Chosen by the champion from a member's context menu; nil, the default, leaves the group without a lead.
        var lead: UUID?
        var staff: Set<UUID> = []
        var folders: [AgentFolder] = []
        var memberTools: [UUID: Set<UUID>] = [:]
        /// The lead is always one of them.
        var members: Set<UUID> { staff.union(lead.map { [$0] } ?? []) }
    }

    @discardableResult
    func updateInvestigation(_ investigation: Investigation, draft: Draft) throws -> Investigation {
        guard let current = store.investigation(investigation.id), !current.isClosed else { throw CaseError("Reopen this investigation before editing it.") }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CaseError("Give the investigation a title.") }
        let members = draft.members
        guard !members.isEmpty else { throw CaseError("Add at least one agent.") }
        try validateMemberTools(draft.memberTools, members: members)
        let folders = try AgentFolder.validated(draft.folders, protecting: AgentFolder.protectedLocations(root: repository.rootURL))
        guard let before = conversation(current.id) else { throw WorkspaceError.missingConversation(current.id) }
        let checkpoint = try AgentSettingsCheckpoint(repository: repository)
        let group: BotConversation
        let updated: Investigation
        let toolsChanged = draft.memberTools.contains { id, ids in agent(id).map { connectionsController.selectedIDs(for: $0) != ids } ?? false }
        do {
            try assignMemberTools(draft.memberTools)
            group = try repository.updateGroup(conversationID: current.id, named: Self.groupName(number: current.number, title: title),
                publicDescription: draft.objective, participantIDs: Array(members), existingAgents: agents, folders: folders, now: now)
            updated = try store.update(current.id, by: .champion(champion), now: now) { value in
                var events: [(event: String, detail: String)] = []
                if value.title != title { events.append(("title", title)); value.title = title }
                if value.objective != draft.objective { events.append(("objective", draft.objective)); value.objective = draft.objective }
                if Set(before.participantIDs) != members { events.append(("staff", "Updated the investigation team.")) }
                if (before.folders ?? []) != folders { events.append(("folders", "Updated shared folders (\(folders.count)).")) }
                if toolsChanged { events.append(("tools", "Updated the team's agent tool assignments.")) }
                return events
            }
        } catch { try checkpoint.restore(); try connectionsController.reloadAssignments(); throw error }
        reload()
        readTranscript(group.id)
        synchronizeResourceWorkspaces(restarting: BotConversation.botsWithChangedFolders(from: before, to: group))
        wakeMembersAfterEdit(from: before, to: group)
        if group.lead != draft.lead { setLead(draft.lead, of: group) }
        return updated
    }

    @discardableResult
    func open(_ draft: Draft) throws -> Investigation {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CaseError("Give the Investigation a title.") }
        let members = draft.members
        guard !members.isEmpty else { throw CaseError("Add at least one agent.") }
        let folders = try AgentFolder.validated(draft.folders, protecting: AgentFolder.protectedLocations(root: repository.rootURL))
        try validateMemberTools(draft.memberTools, members: members)
        let number = (investigations.map(\.number).max() ?? 0) + 1
        let group = try createGroup(name: Self.groupName(number: number, title: title), description: draft.objective,
                                    members: members, folders: folders, memberTools: draft.memberTools, lead: draft.lead)
        let investigation = try store.open(id: group.id, title: title, objective: draft.objective,
                                           champion: champion, number: number, now: now)
        reload()
        readTranscript(group.id)
        let leading = draft.lead.flatMap { agent($0)?.displayName }
            .map { "@\($0) leads, and sets the severity once the evidence allows." }
            ?? "There is no lead yet, so the severity stays unassessed until I choose one."
        try send("""
            **\(investigation.reference): \(title)**. \(leading)

            Objective: \(draft.objective.isEmpty ? title : draft.objective)

            Record what you find with the case tool as you go, and recommend any change to me.
            """, in: group.id)
        return investigation
    }

    /// Writes one zip holding everything an Investigation keeps, in a folder named after it: its details, case
    /// record and audit log, and under Conversation its messages and attachments.
    func exportArchive(of investigation: Investigation, to url: URL) throws {
        let files = FileManager.default
        let staging = files.temporaryDirectory.appendingPathComponent("PionExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        let folder = staging.appendingPathComponent(Self.archiveName(of: investigation), isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        try files.copyItem(at: store.folder(investigation.id), to: folder)
        let conversation = repository.conversationDirectory(id: investigation.id)
        if files.fileExists(atPath: conversation.path) {
            try files.copyItem(at: conversation, to: folder.appendingPathComponent("Conversation", isDirectory: true))
        }
        // Reading a folder for upload hands back a zip of it, which works inside the sandbox.
        var coordination: NSError?, copying: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zip in
            do {
                if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
                try files.copyItem(at: zip, to: url)
            } catch { copying = error }
        }
        if let error = coordination ?? copying { throw error }
    }

    /// "INV-0001 Beaconing laptop", without characters a file name cannot hold.
    static func archiveName(of investigation: Investigation) -> String {
        "\(investigation.reference) \(investigation.title)".components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
    }

    /// The group's own name, within the length Noodle's core allows; Pion shows the Investigation's title instead.
    static func groupName(number: Int, title: String) -> String {
        String((String(format: "INV-%04d ", number) + title).prefix(ConversationName.maximumLength))
    }

    func setStatus(_ status: Investigation.Status, of investigation: Investigation, outcome: Investigation.Outcome? = nil, note: String? = nil) {
        do {
            try store.setStatus(status, of: investigation.id, by: .champion(champion), outcome: outcome, note: note, now: now)
            var line = "\(investigation.reference) is now **\(status.title.lowercased())**"
            if let outcome, status == .closed { line += " as \(outcome.title.lowercased())" }
            if let note, !note.isEmpty { line += ": \(note)" }
            try send(line + ".", in: investigation.id)
        } catch { problem = error.localizedDescription }
    }
}

/// The time a scenario says it is; the real time otherwise.
@MainActor enum ScenarioClock {
    static var offset: TimeInterval = 0
    static var now: Date { Date().addingTimeInterval(offset) }
}

private extension AttachmentTransferPayload {
    var displayName: String {
        switch self {
        case .file(let url): url.lastPathComponent
        case .data(_, let name, _): name
        }
    }
}
