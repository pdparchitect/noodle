import Foundation
import NoodleBrand
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import Observation
import PionCore
import UniformTypeIdentifiers

/// What Pion's windows show and do. Noodle's workspace and runtime run the agents; PionStore keeps
/// what Pion adds: which groups are Investigations, their case records and the action policy.
@MainActor @Observable final class PionModel {
    let repository: WorkspaceRepository
    let runtime: AgentRuntimeCoordinator
    let store: PionStore
    let harnessProfiles: HarnessProfilesController
    let mcp: MCPController

    struct AgentResources {
        var folders: [AgentFolder] = []
        var connections: Set<UUID> = []
        var profile: UUID?
    }

    func resources(for agent: AgentRecord) throws -> AgentResources {
        AgentResources(folders: try repository.loadAgentFolders(agent), connections: mcp.selectedIDs(for: agent),
                       profile: try repository.loadAgentHarnessProfile(agent))
    }

    func toolManifests(for agent: UUID) -> [ToolProviderManifest] { tools.manifests(assignments: toolAssignments.assignments(for: agent)) }
    /// A scenario's agents never run; their phases and messages come from its script.
    let isScripted: Bool

    private(set) var agents: [AgentRecord] = []
    private(set) var conversations: [BotConversation] = []
    private(set) var investigations: [Investigation] = []
    private(set) var policy: ActionPolicy = .standard
    private(set) var transcripts: [UUID: [ChatMessage]] = [:]
    /// Bumped whenever a case record or audit log may have changed, so the views showing one read it again.
    private(set) var caseRevision = 0
    /// What the main window shows.
    var selection: UUID?
    var drafts: [UUID: String] = [:]
    /// Files added to a conversation's composer and not sent yet.
    var pendingAttachments: [UUID: [ConversationAttachment]] = [:]
    private(set) var attachments: [UUID: [UUID: ConversationAttachment]] = [:]
    /// The last message read in each conversation, so the sidebar can mark the rest as new.
    private(set) var readUpTo: [UUID: UUID] = [:]
    var problem: String?
    /// Phases a scenario sets for its agents.
    var scriptedPhases: [UUID: AgentRuntimePhase] = [:]

    private let messenger: MessengerBroker
    private var toolBroker: ToolBridgeBroker?
    private let tools = ToolProviderRegistry()
    private let toolAssignments = ToolAssignmentStore()
    private var loop: Task<Void, Never>?
    private var transcriptDates: [UUID: Date] = [:]
    private var running = false

    init(root: URL, messenger launcher: URL?, isScripted: Bool = false) {
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: launcher)
        mcp = MCPController(repository: repository)
        store = PionStore(root: root.appendingPathComponent("Pion", isDirectory: true))
        let discovery = HarnessDiscovery(managedHarnesses: repository.managedHarnesses)
        if !isScripted { discovery.removeSupersededManagedHarnesses() }
        runtime = AgentRuntimeCoordinator(discovery: discovery, harnesses: HarnessSelection(defaults: .standard))
        runtime.remoteModels = RemoteModelAccountStore(repository: root)
        runtime.harnessProfiles = repository.harnessProfiles
        harnessProfiles = HarnessProfilesController(store: repository.harnessProfiles)
        harnessProfiles.subscriptionUsage = runtime.subscriptionUsage
        self.isScripted = isScripted
        messenger = MessengerBroker(repository: repository)
        readUpTo = (UserDefaults.standard.dictionary(forKey: Self.readKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { result, pair in
                if let conversation = UUID(uuidString: pair.key), let message = UUID(uuidString: pair.value) { result[conversation] = message }
            }
        store.onChange = { [weak self] in Task { @MainActor in self?.reloadPion() } }
        messenger.onWakesChanged = { [weak self] id in
            Task { @MainActor in guard let self else { return }; self.runtime.refreshWakes(for: id, repository: self.repository) }
        }
        let store = self.store, repository = self.repository
        try? tools.register(CaseToolProvider(store: store) { id in
            (try? repository.loadAgents())?.first { $0.id == id }?.displayName
        })
        mcp.toolRegistry = tools
        mcp.onAssignmentsChange = { [weak self, toolAssignments] granted in
            toolAssignments.replace(ConnectionToolProvider.grantKind, with: granted)
            self?.toolBroker?.synchronizeSkills()
        }
    }

    // MARK: Running

    func start() {
        do { try repository.prepare() } catch { problem = error.localizedDescription }
        reload()
        for conversation in conversations { readTranscript(conversation.id, notifying: false) }
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
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        toolBroker?.stop()
        toolBroker = nil
        messenger.stop()
        runtime.stopAll()
        running = false
    }

    private func startTools() throws {
        mcp.start(agents: agents)
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
        runtime.checkWakes(repository: repository)
        for conversation in conversations { readTranscript(conversation.id, notifying: true) }
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
    }

    private func reloadWorkspace() {
        let loadedAgents = ((try? repository.loadAgents()) ?? []).filter { $0.archivedAt == nil }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if loadedAgents != agents { agents = loadedAgents }
        let loadedConversations = ((try? repository.loadConversations()) ?? []).filter { $0.archivedAt == nil }
        if loadedConversations != conversations { conversations = loadedConversations }
    }

    private func reloadPion() {
        let loaded = store.investigations()
        if loaded != investigations { investigations = loaded }
        let loadedPolicy = store.policy()
        if loadedPolicy != policy { policy = loadedPolicy }
        caseRevision += 1
    }

    /// Reads a transcript whose file changed. New messages from agents reach the other agents in a group.
    private func readTranscript(_ id: UUID, notifying: Bool) {
        let file = repository.conversationDirectory(id: id).appendingPathComponent("messages.json")
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != transcriptDates[id] || transcripts[id] == nil else { return }
        transcriptDates[id] = modified
        let messages = (try? repository.loadMessages(conversationID: id)) ?? []
        let known = Set((transcripts[id] ?? []).map(\.id))
        transcripts[id] = messages
        if messages.contains(where: { !$0.attachments.isEmpty }) {
            attachments[id] = Dictionary(((try? repository.loadAttachments(conversationID: id)) ?? []).map { ($0.id, $0) }) { first, _ in first }
        }
        if selection == id { markRead(id) }
        guard notifying, !isScripted else { return }
        let arrived = messages.filter { !known.contains($0.id) && $0.author != .user }
        guard !arrived.isEmpty, let recipients = try? repository.notificationRecipientIDs(for: arrived) else { return }
        let reached = agents.filter { recipients.contains($0.id) }
        if !reached.isEmpty { runtime.notify(reached, repository: repository) }
    }

    /// Reads every changed transcript again, for a scenario that writes messages itself.
    func refresh() {
        reload()
        for conversation in conversations { readTranscript(conversation.id, notifying: false) }
    }

    func messages(in id: UUID) -> [ChatMessage] { transcripts[id] ?? [] }

    /// Search every conversation, including closed cases, without changing the sidebar's selection.
    func searchConversations(_ query: String) -> [BotConversation] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.filter { conversation in
            guard !query.isEmpty else { return true }
            let investigation = investigation(conversation.id)
            let agent = conversation.kind == .direct ? agent(conversation.participantIDs.first) : nil
            let fields = [conversation.displayName, conversation.publicDescription, agent?.displayName,
                          agent?.publicDescription, investigation?.reference, investigation?.title, investigation?.objective]
            return fields.compactMap { $0 }.contains { $0.localizedStandardContains(query) }
                || messages(in: conversation.id).contains { $0.body.localizedStandardContains(query) }
        }.sorted {
            let left = investigation($0.id)?.title ?? $0.displayName
            let right = investigation($1.id)?.title ?? $1.displayName
            return left.localizedStandardCompare(right) == .orderedAscending
        }
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
                readTranscript(message.conversationID, notifying: false)
            }
        } catch { problem = error.localizedDescription }
    }

    func conversation(_ id: UUID?) -> BotConversation? { id.flatMap { id in conversations.first { $0.id == id } } }
    func investigation(_ id: UUID?) -> Investigation? { id.flatMap { id in investigations.first { $0.id == id } } }
    func agent(_ id: UUID?) -> AgentRecord? { id.flatMap { id in agents.first { $0.id == id } } }

    /// Groups that are not Investigations: the teams.
    var groups: [BotConversation] {
        let claimed = Set(investigations.map(\.id))
        return conversations.filter { $0.kind == .group && !claimed.contains($0.id) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// The conversation each agent has with the champion alone.
    func directConversation(of agent: AgentRecord) -> BotConversation? {
        conversations.first { $0.kind == .direct && $0.participantIDs == [agent.id] }
    }

    func members(of conversation: BotConversation) -> [AgentRecord] {
        let lead = investigation(conversation.id)?.leadAgentID
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

    func pendingCount(_ id: UUID) -> Int { caseRecord(id).pendingActions.count }

    func phase(of agent: AgentRecord) -> AgentRuntimePhase {
        isScripted ? scriptedPhases[agent.id] ?? .ready : runtime.snapshot(for: agent.id).phase
    }

    func phaseDetail(of agent: AgentRecord) -> String? {
        if isScripted { return agent.status }
        let snapshot = runtime.snapshot(for: agent.id)
        return snapshot.pauseSummary ?? agent.status
    }

    func isUnread(_ id: UUID) -> Bool {
        guard selection != id, let last = messages(in: id).last, last.author != .user else { return false }
        return readUpTo[id] != last.id
    }

    func markRead(_ id: UUID) {
        guard let last = messages(in: id).last, readUpTo[id] != last.id else { return }
        readUpTo[id] = last.id
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: readUpTo.map { ($0.key.uuidString, $0.value.uuidString) }), forKey: Self.readKey)
    }

    private static let readKey = "PionReadUpTo"

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
        case .policy: "Policy"
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
        if backstory == AgentRole.principles { return "" }
        let suffix = "\n\n" + AgentRole.principles
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
                                                + "\n\n" + AgentRole.principles)
            if let resources {
                try repository.updateAgentFolders(updated, folders: resources.folders)
                try repository.updateAgentHarnessProfile(updated, profile: resources.profile)
                try mcp.assign(resources.connections, to: updated, synchronizeWorkspace: false)
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
            do { try checkpoint.restore(); try mcp.reloadAssignments(); try repository.synchronizeAgentWorkspace(current) }
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
        } catch { try checkpoint.restore(); try mcp.reloadAssignments(); throw error }
        reload()
        readTranscript(group.id, notifying: true)
        synchronizeResourceWorkspaces(restarting: BotConversation.botsWithChangedFolders(from: before, to: updated))
        return updated
    }

    private func validated(_ resources: AgentResources, provider: HarnessProvider?) throws -> AgentResources {
        let folders = try AgentFolder.validated(resources.folders, protecting: AgentFolder.protectedLocations(root: repository.rootURL))
        try mcp.validateAssignment(resources.connections)
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
        for ids in assignments.values { try mcp.validateAssignment(ids) }
    }

    private func assignMemberTools(_ assignments: [UUID: Set<UUID>]) throws {
        for (id, connections) in assignments {
            guard let agent = agent(id) else { throw WorkspaceError.missingAgent(id) }
            try mcp.assign(connections, to: agent, synchronizeWorkspace: false)
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
                     resources: AgentResources = AgentResources()) throws -> AgentRecord {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? suggestedAgentName() : name
        let resources = try validated(resources, provider: provider)
        try repository.prepare()
        let checkpoint = try AgentSettingsCheckpoint(repository: repository)
        let created = try repository.createAgent(named: name, harnessIdentifier: provider?.rawValue, modelIdentifier: model,
                                                 reasoningEffort: effort, publicDescription: description,
                                                 avatarSymbolName: symbol, avatarColorIndex: color,
                                                 backstory: instructions + "\n\n" + AgentRole.principles, now: now)
        do {
            try repository.updateAgentFolders(created.agent, folders: resources.folders)
            try repository.updateAgentHarnessProfile(created.agent, profile: resources.profile)
            try mcp.assign(resources.connections, to: created.agent, synchronizeWorkspace: false)
            try repository.synchronizeAgentWorkspace(created.agent)
        } catch {
            let failure = error
            try checkpoint.restore(); try mcp.reloadAssignments()
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
        _ = try repository.sendUserMessage(conversationID: id, body: body, now: now)
        readTranscript(id, notifying: false)
        markRead(id)
        if !isScripted { runtime.notify(members(of: conversation), repository: repository) }
    }

    func sendDraft(to id: UUID) {
        let text = drafts[id] ?? "", files = pendingAttachments[id] ?? []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty, let conversation = conversation(id) else { return }
        do {
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try repository.sendUserMessage(conversationID: id, body: body.isEmpty ? files.map(\.originalFilename).joined(separator: ", ") : body,
                                               attachmentIDs: files.map(\.id), now: now)
            drafts[id] = ""
            pendingAttachments[id] = []
            readTranscript(id, notifying: false)
            markRead(id)
            if !isScripted { runtime.notify(members(of: conversation), repository: repository) }
        } catch { problem = error.localizedDescription }
    }

    /// Copies files into the conversation, ready to go with the next message.
    func attach(_ urls: [URL], to id: UUID) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredMIMEType ?? "application/octet-stream"
                pendingAttachments[id, default: []].append(try repository.importAttachment(from: url, into: id, mediaType: type, now: now))
            } catch { problem = "\(url.lastPathComponent) could not be attached: \(error.localizedDescription)" }
        }
    }

    func removePending(_ attachment: ConversationAttachment, from id: UUID) {
        pendingAttachments[id]?.removeAll { $0.id == attachment.id }
        try? repository.removeAttachment(attachment)
    }

    func attachment(_ id: UUID, in conversation: UUID) -> ConversationAttachment? { attachments[conversation]?[id] }

    @discardableResult
    func createGroup(name: String, description: String?, members: Set<UUID>, folders: [AgentFolder] = [],
                     memberTools: [UUID: Set<UUID>] = [:]) throws -> BotConversation {
        _ = try ConversationName.validated(name)
        let folders = try AgentFolder.validated(folders, protecting: AgentFolder.protectedLocations(root: repository.rootURL))
        try validateMemberTools(memberTools, members: members)
        let checkpoint = try AgentSettingsCheckpoint(repository: repository)
        let group: BotConversation
        do {
            try assignMemberTools(memberTools)
            group = try repository.createGroup(named: name, publicDescription: description, participantIDs: Array(members),
                                                existingAgents: agents, folders: folders, now: now)
        } catch { try checkpoint.restore(); try mcp.reloadAssignments(); throw error }
        reload()
        readTranscript(group.id, notifying: false)
        synchronizeResourceWorkspaces(restarting: BotConversation.botsWithChangedFolders(from: nil, to: group))
        return group
    }

    func setMembers(_ ids: Set<UUID>, of conversation: BotConversation) {
        let investigation = store.investigation(conversation.id)
        guard investigation?.isClosed != true else { problem = "Reopen this investigation before changing its team."; return }
        let previous = self.conversation(conversation.id) ?? conversation
        let lead = investigation?.leadAgentID.map { Set([$0]) } ?? []
        let members = ids.union(lead)
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
        var scope = ""
        var severity = Investigation.Severity.medium
        var lead: UUID?
        var staff: Set<UUID> = []
        var folders: [AgentFolder] = []
        var memberTools: [UUID: Set<UUID>] = [:]
    }

    @discardableResult
    func updateInvestigation(_ investigation: Investigation, draft: Draft) throws -> Investigation {
        guard let current = store.investigation(investigation.id), !current.isClosed else { throw CaseError("Reopen this investigation before editing it.") }
        guard let lead = draft.lead else { throw CaseError("Choose a lead agent.") }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CaseError("Give the investigation a title.") }
        let members = draft.staff.union([lead])
        try validateMemberTools(draft.memberTools, members: members)
        let folders = try AgentFolder.validated(draft.folders, protecting: AgentFolder.protectedLocations(root: repository.rootURL))
        guard let before = conversation(current.id) else { throw WorkspaceError.missingConversation(current.id) }
        let checkpoint = try AgentSettingsCheckpoint(repository: repository)
        let group: BotConversation
        let updated: Investigation
        let toolsChanged = draft.memberTools.contains { id, ids in agent(id).map { mcp.selectedIDs(for: $0) != ids } ?? false }
        do {
            try assignMemberTools(draft.memberTools)
            group = try repository.updateGroup(conversationID: current.id, named: Self.groupName(number: current.number, title: title),
                publicDescription: draft.objective, participantIDs: Array(members), existingAgents: agents, folders: folders, now: now)
            updated = try store.update(current.id, by: .champion(champion), now: now) { value in
                var events: [(event: String, detail: String)] = []
                if value.title != title { events.append(("title", title)); value.title = title }
                if value.objective != draft.objective { events.append(("objective", draft.objective)); value.objective = draft.objective }
                let scope = Investigation.scope(from: draft.scope)
                if value.scope != scope { events.append(("scope", scope.joined(separator: ", "))); value.scope = scope }
                if value.severity != draft.severity { events.append(("severity", draft.severity.title)); value.severity = draft.severity }
                if value.leadAgentID != lead { events.append(("lead", agent(lead)?.displayName ?? lead.uuidString)); value.leadAgentID = lead }
                if Set(before.participantIDs) != members { events.append(("staff", "Updated the investigation team.")) }
                if (before.folders ?? []) != folders { events.append(("folders", "Updated shared folders (\(folders.count)).")) }
                if toolsChanged { events.append(("tools", "Updated the team's agent tool assignments.")) }
                return events
            }
        } catch { try checkpoint.restore(); try mcp.reloadAssignments(); throw error }
        reload()
        readTranscript(group.id, notifying: true)
        synchronizeResourceWorkspaces(restarting: BotConversation.botsWithChangedFolders(from: before, to: group))
        return updated
    }

    @discardableResult
    func open(_ draft: Draft) throws -> Investigation {
        guard let lead = draft.lead else { throw CaseError("Choose a lead agent.") }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw CaseError("Give the Investigation a title.") }
        let scope = Investigation.scope(from: draft.scope)
        let members = draft.staff.union([lead])
        let folders = try AgentFolder.validated(draft.folders, protecting: AgentFolder.protectedLocations(root: repository.rootURL))
        try validateMemberTools(draft.memberTools, members: members)
        let number = (investigations.map(\.number).max() ?? 0) + 1
        let group = try createGroup(name: Self.groupName(number: number, title: title), description: draft.objective,
                                    members: members, folders: folders, memberTools: draft.memberTools)
        let investigation = try store.open(id: group.id, title: title, objective: draft.objective, scope: scope, severity: draft.severity,
                                           champion: champion, leadAgentID: lead, playbookID: nil, number: number, now: now)
        reload()
        readTranscript(group.id, notifying: false)
        let leadName = agent(lead)?.displayName ?? "the lead"
        try send("""
            **\(investigation.reference): \(title)**, severity \(draft.severity.title.lowercased()). @\(leadName) leads.

            Objective: \(draft.objective.isEmpty ? title : draft.objective)

            Scope: \(scope.isEmpty ? "nothing yet. Ask me before touching anything." : scope.joined(separator: ", "))

            Record what you find with the case tool as you go, and propose any change through it.
            """, in: group.id)
        return investigation
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

    func setSeverity(_ severity: Investigation.Severity, of investigation: Investigation) {
        do {
            try store.update(investigation.id, by: .champion(champion), now: now) { value in
                guard value.severity != severity else { return [] }
                let from = value.severity
                value.severity = severity
                return [("severity", "\(from.title) → \(severity.title)")]
            }
        } catch { problem = error.localizedDescription }
    }

    func setScope(_ text: String, of investigation: Investigation) {
        let scope = Investigation.scope(from: text)
        guard scope != investigation.scope else { return }
        do {
            try store.update(investigation.id, by: .champion(champion), now: now) { value in
                value.scope = scope
                return [("scope", scope.joined(separator: ", "))]
            }
            try send("Scope of \(investigation.reference) is now: \(scope.isEmpty ? "nothing" : scope.joined(separator: ", ")).", in: investigation.id)
        } catch { problem = error.localizedDescription }
    }

    /// The champion's decision, posted in the Investigation so every agent in it hears it.
    func decide(_ action: CaseRecord.ProposedAction, in investigation: Investigation, approve: Bool, note: String?) {
        do {
            try store.decide(action.id, in: investigation.id, approve: approve, note: note, by: champion, now: now)
            var line = "**\(approve ? "Approved" : "Denied") \(action.id)**: \(action.operation) on \(action.targets.joined(separator: ", "))"
            if let note, !note.isEmpty { line += ". \(note)" }
            try send(line + ".", in: investigation.id)
        } catch { problem = error.localizedDescription }
    }

    func markDone(_ action: CaseRecord.ProposedAction, in investigation: Investigation) {
        do {
            try store.markDone(action.id, in: investigation.id, note: nil, by: champion, now: now)
            try send("\(action.id) \(action.operation) on \(action.targets.joined(separator: ", ")) is done.", in: investigation.id)
        } catch { problem = error.localizedDescription }
    }
}

/// The time a scenario says it is; the real time otherwise.
@MainActor enum ScenarioClock {
    static var offset: TimeInterval = 0
    static var now: Date { Date().addingTimeInterval(offset) }
}
