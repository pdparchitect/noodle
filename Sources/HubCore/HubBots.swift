import AppletBridge
import AVFoundation
import BrowserBridge
import Foundation
import ImageIO
import HubLink
import NoodleCore
import NoodleRuntime
import NoodleVoicePeer

/// Bots paired devices keep on the Hub. Each belongs to one user, runs on a harness that
/// user's plan lends, and talks with that user, alone or in groups of their bots, and with
/// whoever else they share it with, each in a conversation of their own.
@MainActor public final class HubBots {
    /// Where an owner's devices are told that something changed.
    public var onChange: ((_ user: UUID, LinkEvent) -> Void)?
    /// Runs when a conversation's owner read further, for whatever else shows it: on the owner's own Mac, Noodle.
    public var onRead: ((_ conversationID: UUID, _ upTo: Date) -> Void)?
    /// Runs when a conversation's background changed, for whatever else shows it: on the owner's own Mac, Noodle.
    public var onBackgroundChanged: ((_ conversationID: UUID) -> Void)?
    /// Runs when someone a bot is shared with can no longer open their conversation with it: no
    /// longer shared, archived, deleted, or they left the Hub. What they still have open of it closes.
    public var onClosed: ((_ conversationID: UUID, _ user: UUID) -> Void)?

    private let repository: WorkspaceRepository
    private let runtime: AgentRuntimeCoordinator
    private let access: HubAccess
    private let connections: HubConnections
    private let computers: HubComputers
    private let browsers: HubBrowsers
    /// Noodle Applet on this Mac, for the Hub's bots' applet tool and for people's devices.
    public let applets: AppletController
    /// The image models and which bots may use them, kept where the bots run: the Hub, or Noodle for This Mac.
    public var imageGeneration: ImageGenerationController?
    /// The default image model's name, which devices show beside the tool. Nil while none is downloaded.
    public var imageModel: String? { imageGeneration?.currentModel?.name }
    /// Serves bots the tools their owners assigned them from the Hub's own connections.
    private var toolBroker: ToolBridgeBroker?
    private let messenger: MessengerBroker
    /// Files arriving in pieces, until the last one lands.
    private let uploads: URL
    private var running = false
    /// Following bots that something else runs, as Noodle does its own.
    private var watching = false
    private var loop: Task<Void, Never>?
    /// Runs after a device made, changed or deleted a bot or group, for whatever runs the bots.
    public var onBotsEdited: (() -> Void)?
    /// Where the device that hosts a bot is told that one of its conversations changed.
    public var onHostChange: ((_ device: UUID, LinkEvent) -> Void)?
    /// Whether a device is following the Hub now, so the bots it hosts can take part.
    public var isHostConnected: (UUID) -> Bool = { _ in false }
    /// What each hosted bot's device last said it is doing, while that device stays connected.
    private var hostedPhases: [UUID: LinkBotPhase] = [:]
    /// Bots here that devices never see: on the owner's own Mac, its copies of bots another Hub keeps.
    public var isHidden: (UUID) -> Bool = { _ in false }
    /// The last seen size and date of each conversation's messages, their count, and the latest reaction change.
    private var transcripts: [UUID: (size: Int, modified: Date, count: Int, reactions: Int)] = [:]
    /// Each conversation's request lines as last told, by message, to tell when one changes.
    private var requestLines: [UUID: [UUID: BotRequestLine]] = [:]
    /// When each conversation's chat effects last changed, as last checked.
    private var effectsChanged: [UUID: Date] = [:]
    /// Each conversation's background when last checked.
    private var backgrounds: [UUID: ConversationBackground] = [:]
    /// What each bot was last reported doing.
    private var phases: [UUID: AgentRuntimePhase] = [:]
    /// Each bot's status when last checked; an absent bot has not been checked yet.
    private var statuses: [UUID: String?] = [:]
    /// How many checks have been applied, so a check read in the background yields to one made meanwhile.
    private var checks = 0
    /// The latest Kick a device was asked to confirm, per bot. The runtime refuses it once stale.
    private var kickRequests: [UUID: AgentKickRequest] = [:]
    /// How far each conversation's owner has read it, so all their devices agree.
    private let readMarksURL: URL
    private lazy var readMarks: [UUID: Date] = (try? JSONDecoder().decode([UUID: Date].self, from: Data(contentsOf: readMarksURL))) ?? [:]
    /// When each conversation's owner pinned it, so all their devices show the same pins. Nil for This Mac
    /// as a Hub, whose pins are Noodle's own, in the order they were pinned.
    private let pinsURL: URL?
    private lazy var pins: [UUID: Date] = loadPins()
    /// Runs when a device changed pins kept in Noodle's own file, so Noodle reads them again.
    public var onPinsEdited: (() -> Void)?

    public init(repository: WorkspaceRepository, runtime: AgentRuntimeCoordinator, access: HubAccess,
                connections: HubConnections, computers: HubComputers, browsers: HubBrowsers,
                applets: AppletController, uploads: URL, readMarks: URL, pins: URL?) {
        self.uploads = uploads
        readMarksURL = readMarks
        pinsURL = pins
        self.repository = repository
        self.runtime = runtime
        self.access = access
        self.connections = connections
        self.computers = computers
        self.browsers = browsers
        self.applets = applets
        messenger = MessengerBroker(repository: repository)
        messenger.noodletHasPreview = { [applets] url in await applets.hasPreview(url) }
        messenger.onWakesChanged = { [weak self] id in
            Task { @MainActor in guard let self else { return }; self.runtime.refreshWakes(for: id, repository: self.repository) }
        }
        connections.onAssignmentsChange = { [weak self] in self?.toolBroker?.synchronizeSkills() }
        computers.onAssignmentsChange = { [weak self] in self?.toolBroker?.synchronizeSkills() }
        browsers.onAssignmentsChange = { [weak self] in self?.toolBroker?.synchronizeSkills() }
        clearAbandonedUploads()
    }

    /// How long a file's pieces wait for the next one. Each piece touches the file, so one quiet
    /// for longer is no longer arriving; its device starts again from the first piece.
    static let abandonedUpload: TimeInterval = 3600

    /// Deletes the pieces of files no longer arriving: at launch, and whenever another file starts.
    private func clearAbandonedUploads(now: Date = Date()) {
        let parts = (try? FileManager.default.contentsOfDirectory(at: uploads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for part in parts where part.pathExtension == "part" {
            let touched = (try? part.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(touched) > Self.abandonedUpload { try? FileManager.default.removeItem(at: part) }
        }
    }

    /// Runs every bot, the messenger they reply through, and the checks that keep them going.
    public func start() throws {
        guard !running else { return }
        try repository.prepare()
        let agents = try repository.loadAgents()
        try repository.synchronizeAgentWorkspaces(agents)
        try messenger.start(agents: agents)
        runtime.archivedAgentIDs = Set(agents.filter { $0.archivedAt != nil }.map(\.id))
        runtime.remoteAgentIDs.formUnion(agents.map(\.id).filter { access.host(ofBot: $0) != nil })
        let now = Date()
        agents.forEach { runtime.seedHeartbeatActivity(for: $0.id, at: now) }
        runtime.startAll(agents: agents, repository: repository)
        // Devices are offered the models the Hub finds.
        runtime.refreshCapabilities()
        applets.start(agents: agents)
        try startTools()
        running = true
        loop = Task { [weak self] in
            var round = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                round += 1
                if round.isMultiple(of: 60) { await self.checkIdleComputers() }
                if let agents = try? self.repository.loadAgents() {
                    self.runtime.reconcile(agents: agents, repository: self.repository)
                }
                self.runtime.checkHeartbeats()
                self.runtime.checkWakes(repository: self.repository)
                await self.checkForChangesInBackground()
            }
        }
    }

    /// Asks each bot to stop a computer it started and then left running unused.
    public func checkIdleComputers() async {
        for notice in await computers.idle() {
            guard let agent = notice.agentID else { continue }
            runtime.wake(agent, note: notice.note, repository: repository)
        }
    }

    /// Tells devices what changes, for bots something else runs: Noodle, serving its own owner.
    /// A message from a device wakes its bot through that runtime.
    public func watch() {
        guard !running, !watching else { return }
        watching = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.checkForChangesInBackground()
            }
        }
    }

    public func stopWatching() {
        loop?.cancel()
        loop = nil
        watching = false
    }

    /// Names each bot's owner in its agent.json, for Noodle Applet to list its noodlets under them.
    /// A personal Mac's bots are Noodle's own and name nobody.
    public func synchronizeOwners() {
        guard !access.isPersonal else { return }
        for agent in (try? repository.loadAgents()) ?? [] {
            let user = access.owner(ofBot: agent.id).flatMap { id in access.users.first { $0.id == id } }
            try? repository.updateAgentOwner(agent, owner: user.map { AgentOwner(id: $0.id, name: $0.name) })
        }
        // So a bot knows the people it is shared with by their current names.
        for var conversation in (try? repository.loadConversations()) ?? [] {
            guard let guest = conversation.guest, let user = access.users.first(where: { $0.id == guest.id }),
                  user.name != guest.name else { continue }
            conversation.guest?.name = user.name
            try? repository.updateConversation(conversation)
        }
    }

    /// Lets bots call the tools assigned to them.
    public func startTools() throws {
        if toolBroker == nil {
            let assignments = connections.assignments
            // Tools post into the bot's conversations here and read its files, as in Noodle.
            let host = ToolHostServices.repository(repository, revoked: { [weak self] kind, id, agent in
                guard kind == "computer", let computer = UUID(uuidString: id) else { return }
                Task { @MainActor in self?.computers.revoke(computer: computer, agent: agent) }
            }) { assignments.assignments(for: $0) }
            let broker = ToolBridgeBroker(registry: connections.tools, host: host) { assignments.assignments(for: $0) }
            // A bot's AGENTS.md lists its tool skills once they are written.
            broker.onSkillsChanged = { [weak self] id in
                Task { @MainActor in
                    guard let self, let agent = try? self.repository.loadAgents().first(where: { $0.id == id }) else { return }
                    try? self.repository.synchronizeAgentWorkspace(agent)
                }
            }
            toolBroker = broker
        }
        try toolBroker?.start(agents: try repository.loadAgents().map {
            ToolBridgeAgent(id: $0.id, workspace: repository.directory(for: $0))
        })
    }

    /// Writes the bots' tool skills again, after a grant changed outside the assignments this watches.
    public func synchronizeToolSkills() { toolBroker?.synchronizeSkills() }

    public func stop() {
        applets.start(agents: [])
        toolBroker?.stop()
        toolBroker = nil
        loop?.cancel()
        loop = nil
        messenger.stop()
        runtime.stopAll()
        running = false
    }

    /// The harnesses installed here, as the Mac's bot editor offers them.
    public var installedProviders: [HarnessProvider] { runtime.availableInstallations.map(\.provider) }

    public func isOn(_ provider: HarnessProvider) -> Bool { runtime.harnesses.isOn(provider) }

    /// The models the Hub's own copy of the harness offers.
    public func models(for provider: HarnessProvider) -> [HarnessModel] { runtime.models(for: provider.rawValue) }

    /// The user's own bots, then those shared with them.
    public func bots(for user: HubUser) throws -> [LinkBot] {
        let conversations = try repository.loadConversations()
        let agents = try repository.loadAgents().filter { !isHidden($0.id) }
        // A bot one of their devices hosts is that device's to show.
        let owned = try agents.filter { access.owner(ofBot: $0.id) == user.id && access.host(ofBot: $0.id) == nil }
            .compactMap { try bot($0, conversations: conversations) }
        // An archived bot is its owner's alone until they bring it back.
        let shared = conversations.compactMap { conversation -> LinkBot? in
            guard conversation.guest?.id == user.id, let agent = agents.first(where: { conversation.participantIDs == [$0.id] }),
                  agent.archivedAt == nil else {
                return nil
            }
            return sharedBot(agent, in: conversation)
        }
        return owned + shared
    }

    /// The other people on the Hub, to share a bot with.
    public func people(for user: HubUser) throws -> [LinkPerson] {
        guard !access.isPersonal else { return [] }
        return access.users.filter { $0.id != user.id }.map { LinkPerson(id: $0.id, name: $0.name, avatar: $0.avatar) }
    }

    /// Shares one of the user's bots with exactly `people`. Each gets a conversation of their own
    /// with it; whoever it is no longer shared with loses theirs, with its messages.
    public func share(_ id: UUID, with people: [UUID], for user: HubUser) throws -> LinkBot {
        let agent = try owned(id, by: user)
        let people = Set(people)
        if access.isPersonal {
            guard people.isEmpty else { throw LinkError("This Mac is only yours; nobody else can be added.") }
            // Its conversations with people are those of another Hub it is shared through, Noodle's to keep.
            return try bot(agent, conversations: try repository.loadConversations()) ?? { throw LinkError("There is no such bot.") }()
        }
        let guests = try people.map { id in
            guard id != user.id, let person = access.users.first(where: { $0.id == id }) else {
                throw LinkError("There is no such person on this Hub.")
            }
            return ConversationGuest(id: person.id, name: person.name)
        }
        let conversations = try guestConversations(of: agent.id)
        var changed: Set<UUID> = []
        for guest in guests.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        where !conversations.contains(where: { $0.guest?.id == guest.id }) {
            _ = try repository.createGuestConversation(with: agent, guest: guest)
            changed.insert(guest.id)
            access.note("Shared \(agent.displayName) with \(guest.name)", about: [guest.id])
        }
        for conversation in conversations where !people.contains(conversation.guest!.id) {
            try repository.deleteConversation(id: conversation.id)
            forgetMarks(of: [conversation.id])
            changed.insert(conversation.guest!.id)
            onClosed?(conversation.id, conversation.guest!.id)
            access.note("Stopped sharing \(agent.displayName) with \(conversation.guest!.name)", about: [conversation.guest!.id])
        }
        changed.forEach { onChange?($0, .botsChanged) }
        onChange?(user.id, .botsChanged)
        return try bot(agent, conversations: try repository.loadConversations()) ?? {
            throw LinkError("The bot was shared but could not be read back.")
        }()
    }

    /// A bot's name, for Activity.
    public func name(ofBot id: UUID) -> String? {
        (try? repository.loadAgents())?.first { $0.id == id && !isHidden($0.id) }?.displayName
    }

    /// Tells the people a bot is shared with that it changed: its name, picture or description, or that it was archived.
    private func tellGuests(of bot: UUID) {
        ((try? guestConversations(of: bot)) ?? []).compactMap(\.guest?.id).forEach { onChange?($0, .botsChanged) }
    }

    private func guestConversations(of bot: UUID) throws -> [BotConversation] {
        try repository.loadConversations().filter { $0.guest != nil && $0.kind == .direct && $0.participantIDs == [bot] }
    }

    public func create(_ draft: LinkBotDraft, for user: HubUser) throws -> LinkBot {
        let provider = try lent(draft, to: user, verb: "does not lend")
        let created = try repository.createAgent(
            named: draft.name, harnessIdentifier: provider.rawValue, modelIdentifier: draft.model,
            reasoningEffort: draft.reasoningEffort, publicDescription: draft.publicDescription,
            avatarSymbolName: draft.avatarSymbolName, avatarColorIndex: draft.avatarColorIndex,
            avatarImageData: draft.avatarImageData, backstory: draft.backstory)
        do {
            if let profile = draft.profile { try repository.updateAgentHarnessProfile(created.agent, profile: profile) }
            if let voice = validVoice(draft.voice, on: provider) { try repository.updateAgentVoice(created.agent, voice: voice) }
            if draft.imageGeneration { try imageGeneration?.assign(true, to: created.agent.id) }
            access.setOwner(user, ofBot: created.agent.id)
        } catch {
            try? repository.deleteAgent(created.agent)
            throw error
        }
        if running {
            try? messenger.start(agents: try repository.loadAgents())
            runtime.refresh(agents: try repository.loadAgents())
            runtime.start(agent: created.agent, repository: repository)
        }
        if toolBroker != nil { try? startTools() }
        if running { applets.start(agents: (try? repository.loadAgents()) ?? []) }
        onChange?(user.id, .botsChanged)
        onBotsEdited?()
        // As saved, so it matches every later read of the same bot.
        guard let saved = try repository.loadAgents().first(where: { $0.id == created.agent.id }),
              let bot = try bot(saved, conversations: [created.conversation]) else {
            throw LinkError("The bot was created but could not be read back.")
        }
        return bot
    }

    public func update(_ id: UUID, with draft: LinkBotDraft, for user: HubUser) throws -> LinkBot {
        let agent = try runHere(id, by: user)
        let provider = try lent(draft, to: user, verb: "does not lend")
        let updated = try repository.updateAgent(
            agent, displayName: draft.name, harnessIdentifier: provider.rawValue, modelIdentifier: draft.model,
            reasoningEffort: draft.reasoningEffort, publicDescription: draft.publicDescription,
            avatarSymbolName: draft.avatarSymbolName, avatarColorIndex: draft.avatarColorIndex,
            // A digest without the picture keeps the one the bot has.
            avatarImageData: draft.avatarImageData ?? (draft.avatarImageDigest == nil ? nil : agent.avatarImageData))
        try repository.updateAgentBackstory(updated, backstory: draft.backstory)
        try repository.updateAgentHarnessProfile(updated, profile: draft.profile)
        // A device from before voices sends none, which keeps the one the bot has.
        if draft.voice != nil { try repository.updateAgentVoice(updated, voice: validVoice(draft.voice, on: provider)) }
        try imageGeneration?.assign(draft.imageGeneration, to: updated.id)
        // As Edit Bot does in Noodle, whose runtime runs the bot when this only watches.
        if running || watching { runtime.restart(agent: updated, repository: repository) }
        onChange?(user.id, .botsChanged)
        tellGuests(of: id)
        onBotsEdited?()
        return try bot(updated, conversations: try repository.loadConversations()) ?? {
            throw LinkError("The bot was saved but could not be read back.")
        }()
    }

    public func picture(ofBot id: UUID, for user: HubUser) throws -> Data? {
        if try guestConversations(of: id).contains(where: { $0.guest?.id == user.id }),
           let agent = try repository.loadAgents().first(where: { $0.id == id && !isHidden($0.id) }) {
            return agent.avatarImageData
        }
        return try owned(id, by: user).avatarImageData
    }

    public func delete(_ id: UUID, for user: HubUser) throws {
        let leftGroups = try remove(try owned(id, by: user))
        onChange?(user.id, .botsChanged)
        if leftGroups { onChange?(user.id, .groupsChanged) }
        onBotsEdited?()
    }

    public func groups(for user: HubUser) throws -> [LinkGroup] {
        let agents = try repository.loadAgents()
        return try repository.loadConversations()
            .filter { $0.kind == .group && owner(of: $0, among: agents) == user.id }
            .map(group)
    }

    public func createGroup(_ draft: LinkGroupDraft, for user: HubUser) throws -> LinkGroup {
        let bots = try draft.botIDs.map { try runHere($0, by: user) }
        let conversation = try repository.createGroup(named: draft.name, publicDescription: draft.publicDescription,
                                                      participantIDs: bots.map(\.id), existingAgents: bots)
        onChange?(user.id, .groupsChanged)
        onBotsEdited?()
        // As saved, so it matches every later read of the same group.
        return group(try repository.loadConversations().first { $0.id == conversation.id } ?? conversation)
    }

    public func updateGroup(_ id: UUID, with draft: LinkGroupDraft, for user: HubUser) throws -> LinkGroup {
        let before = try ownedGroup(id, by: user)
        let bots = try draft.botIDs.map { try runHere($0, by: user) }
        let updated = try repository.updateGroup(conversationID: id, named: draft.name, publicDescription: draft.publicDescription,
                                                 participantIDs: bots.map(\.id), existingAgents: try repository.loadAgents())
        // As Group Info does in Noodle: the bots hear who joined or left, and of a new description.
        if running || watching,
           Set(before.participantIDs) != Set(updated.participantIDs) || before.publicDescription != updated.publicDescription {
            runtime.notify(bots, repository: repository)
        }
        try restartBots(BotConversation.botsWithChangedFolders(from: before, to: updated))
        onChange?(user.id, .groupsChanged)
        onBotsEdited?()
        return group(updated)
    }

    /// As in Noodle: a group's folders reach its bots' sandbox only when they launch.
    private func restartBots(_ ids: Set<UUID>) throws {
        guard running || watching, !ids.isEmpty else { return }
        for agent in try repository.loadAgents() where ids.contains(agent.id) {
            runtime.restart(agent: agent, repository: repository)
        }
    }

    /// Deletes a group and its messages. Its bots stay.
    public func deleteGroup(_ id: UUID, for user: HubUser) throws {
        let group = try ownedGroup(id, by: user)
        try repository.deleteConversation(id: id)
        try restartBots(BotConversation.botsWithChangedFolders(from: group, to: nil))
        forgetMarks(of: [id])
        onChange?(user.id, .groupsChanged)
        onBotsEdited?()
    }

    /// Archives or brings back one of the user's bots or groups. Everything is kept; an archived bot
    /// stops, whichever runtime runs it, and neither takes messages until brought back.
    public func setArchived(_ archived: Bool, id: UUID, for user: HubUser) throws {
        if access.owner(ofBot: id) == user.id {
            _ = try owned(id, by: user)
            try repository.setAgentArchived(archived, agentID: id)
            runtime.archivedAgentIDs = Set(try repository.loadAgents().filter { $0.archivedAt != nil }.map(\.id))
            onChange?(user.id, .botsChanged)
            tellGuests(of: id)
            if archived {
                for conversation in try guestConversations(of: id) { onClosed?(conversation.id, conversation.guest!.id) }
            }
        } else {
            let before = try ownedGroup(id, by: user)
            let after = try repository.setConversationArchived(archived, conversationID: id)
            try restartBots(BotConversation.botsWithChangedFolders(from: before, to: after))
            onChange?(user.id, .groupsChanged)
        }
        onBotsEdited?()
    }

    /// The same, as whoever keeps the Hub does it in Settings, for the bot's or group's owner.
    public func setArchived(_ archived: Bool, id: UUID) throws {
        let owner = try access.owner(ofBot: id) ?? everyGroup().first { $0.conversation.id == id }?.owner
        guard let owner, let user = access.users.first(where: { $0.id == owner }) else {
            throw LinkError("There is no such bot or group.")
        }
        try setArchived(archived, id: id, for: user)
    }

    /// Every group on the Hub that devices see, and whose it is, for Settings.
    public func everyGroup() throws -> [(conversation: BotConversation, owner: UUID?)] {
        let agents = try repository.loadAgents()
        return try repository.loadConversations()
            .filter { $0.kind == .group && $0.participantIDs.allSatisfy { !isHidden($0) } }
            .map { ($0, owner(of: $0, among: agents)) }
    }

    /// Kick, as in Noodle, through whichever runtime runs the bot: on the owner's own Mac, Noodle's.
    /// A failure Noodle would ask about first is kept until the device agrees with `confirmKick`.
    public func kick(_ id: UUID, for user: HubUser) throws -> LinkKickConfirmation? {
        let agent = try runHere(id, by: user)
        guard let request = runtime.kick(agent: agent, repository: repository) else { return nil }
        kickRequests[agent.id] = request
        return LinkKickConfirmation(id: request.id, title: request.title, message: request.message,
                                    confirmTitle: request.confirmTitle, offersNewSession: request.offersNewSession)
    }

    public func confirmKick(_ id: UUID, confirmation: UUID, for user: HubUser) throws {
        let agent = try runHere(id, by: user)
        guard let request = kickRequests[agent.id], request.id == confirmation else { return }
        kickRequests[agent.id] = nil
        runtime.confirmKick(request, repository: repository)
    }

    public func startNewSession(_ id: UUID, for user: HubUser) throws {
        let agent = try runHere(id, by: user)
        kickRequests[agent.id] = nil
        runtime.startNewSession(agent: agent, repository: repository)
    }

    public func organize(_ id: UUID, for user: HubUser) throws {
        let agent = try runHere(id, by: user)
        guard runtime.canOrganize(agent.id) else { throw LinkError("\(agent.displayName) is busy. Try again when it is idle.") }
        runtime.organize(agent.id)
    }

    /// Only the user's own bots that run here; bots shared with them are left alone.
    public func introduce(in conversationID: UUID, for user: HubUser) throws {
        let bots = try ownedConversation(conversationID, by: user).bots
            .filter { access.owner(ofBot: $0.id) == user.id && access.host(ofBot: $0.id) == nil }
        runtime.introduce(bots.map(\.id), in: conversationID, repository: repository)
    }

    /// Deletes every bot of a user who is being removed, and their conversations with bots shared with them.
    public func removeBots(of user: HubUser) {
        for agent in (try? repository.loadAgents()) ?? [] where access.owner(ofBot: agent.id) == user.id {
            _ = try? remove(agent)
        }
        for conversation in (try? repository.loadConversations()) ?? [] where conversation.guest?.id == user.id {
            try? repository.deleteConversation(id: conversation.id)
            onClosed?(conversation.id, user.id)
            forgetMarks(of: [conversation.id])
            if let owner = conversation.participantIDs.first.flatMap(access.owner(ofBot:)) { onChange?(owner, .botsChanged) }
        }
    }

    public func messages(in conversationID: UUID, after position: Int, for user: HubUser) throws -> LinkMessages {
        _ = try ownedConversation(conversationID, by: user)
        let messages = try repository.loadMessages(conversationID: conversationID)
        let files = try attachments(in: conversationID)
        return LinkMessages(messages: messages.dropFirst(max(0, position)).map { linkMessage($0, files: files) },
                            count: messages.count)
    }

    /// Part of a conversation, small enough for the link however long its messages are. Card
    /// pictures are left out: devices ask for each as its card comes into view.
    /// Read off the main actor: a device opening the app pages every conversation at once.
    public func page(_ request: LinkMessagePage, for user: HubUser) async throws -> LinkMessages {
        _ = try ownedConversation(request.conversationID, by: user)
        let repository = repository, known = pixelSizes
        let (page, measured) = try await Task.detached(priority: .userInitiated) {
            var sizes = known
            return (try Self.page(request, from: repository, pixelSizes: &sizes), sizes)
        }.value
        pixelSizes.merge(measured) { _, new in new }
        return page
    }

    private func page(_ request: LinkMessagePage) throws -> LinkMessages {
        try Self.page(request, from: repository, pixelSizes: &pixelSizes)
    }

    nonisolated private static func page(_ request: LinkMessagePage, from repository: WorkspaceRepository,
                                         pixelSizes: inout [UUID: LinkPixelSize?]) throws -> LinkMessages {
        let messages = try repository.loadMessages(conversationID: request.conversationID)
        let files = Dictionary(try repository.loadAttachments(conversationID: request.conversationID).map { ($0.id, $0) },
                               uniquingKeysWith: { first, _ in first })
        let guest = isGuest(request.conversationID, in: repository)
        let limit = min(max(1, request.limit), 200)
        let encoder = JSONEncoder()
        var page: [LinkMessage] = [], bytes = 0
        func fits(_ message: LinkMessage) -> Bool {
            let size = (try? encoder.encode(message).count) ?? 0
            guard page.isEmpty || (page.count < limit && bytes + size <= Self.pageBytes) else { return false }
            bytes += size
            return true
        }
        var start: Int
        if let after = request.after {
            start = min(max(0, after), messages.count)
            for message in messages[start...] {
                let linked = linkMessage(message, files: files, pictures: false, guest: guest) {
                    pixelSize(of: $0, in: repository, sizes: &pixelSizes)
                }
                guard fits(linked) else { break }
                page.append(linked)
            }
        } else {
            let end = min(max(0, request.before ?? messages.count), messages.count)
            start = end
            for message in messages[..<end].reversed() {
                let linked = linkMessage(message, files: files, pictures: false, guest: guest) {
                    pixelSize(of: $0, in: repository, sizes: &pixelSizes)
                }
                guard fits(linked) else { break }
                page.insert(linked, at: 0)
                start -= 1
            }
        }
        return LinkMessages(messages: page, count: messages.count, start: start)
    }

    /// Most of the link's message limit, leaving room for what surrounds the page.
    nonisolated private static let pageBytes = 700_000

    /// Keeps one piece of a file; the file joins the conversation when its last piece lands.
    public func receive(_ data: Data, at offset: Int, of attachment: LinkAttachment, in conversationID: UUID,
                        for user: HubUser) throws {
        _ = try ownedConversation(conversationID, by: user)
        try receive(data, at: offset, of: attachment, in: conversationID)
    }

    private func receive(_ data: Data, at offset: Int, of attachment: LinkAttachment, in conversationID: UUID) throws {
        if try repository.loadAttachments(conversationID: conversationID).contains(where: { $0.id == attachment.id }) { return }
        guard let part = try keep(data, at: offset, of: attachment.byteCount, as: attachment.id) else { return }
        defer { try? FileManager.default.removeItem(at: part) }
        let filename = URL(fileURLWithPath: attachment.filename).lastPathComponent
        let voice = attachment.voice.map {
            VoiceMessage(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform, localeIdentifier: $0.localeIdentifier)
        }
        _ = try repository.importAttachment(from: part, into: conversationID, mediaType: attachment.mediaType, voice: voice,
                                            id: attachment.id, originalFilename: filename.isEmpty ? "Attachment" : filename)
    }

    /// Adds a piece to the file arriving as `id`, and returns the file once its last piece landed.
    private func keep(_ data: Data, at offset: Int, of byteCount: Int, as id: UUID) throws -> URL? {
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let part = uploads.appendingPathComponent("\(id.uuidString).part")
        if offset == 0 {
            clearAbandonedUploads()
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.intValue ?? -1
        guard size == offset, offset + data.count <= byteCount else {
            throw LinkError("A piece of the file arrived out of order. Send the file again.")
        }
        let handle = try FileHandle(forWritingTo: part)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
        return offset + data.count == byteCount ? part : nil
    }

    /// A conversation's background, as devices see it.
    public func background(of conversationID: UUID) -> LinkBackground {
        let background = (try? repository.loadBackground(conversationID: conversationID)) ?? ConversationBackground()
        // A name that is not the Hub's own kind is no file to show.
        let media = repository.backgroundImageURL(background, conversationID: conversationID) == nil ? nil : background.imageFilename
        return LinkBackground(preset: background.preset?.rawValue, media: media,
                              mediaKind: media == nil ? nil : (background.mediaKind ?? .image).rawValue)
    }

    /// Sets one of the user's conversations to a gradient, or to none.
    public func setBackground(_ choice: LinkBackgroundChoice, for user: HubUser) throws -> LinkBackground {
        _ = try ownedConversation(choice.conversationID, by: user)
        let preset = try choice.preset.map {
            guard let preset = ConversationBackgroundPreset(rawValue: $0) else { throw LinkError("This Noodle Hub does not know that background.") }
            return preset
        }
        try repository.setBackground(conversationID: choice.conversationID, preset: preset)
        checkForChanges()
        return background(of: choice.conversationID)
    }

    /// Keeps one piece of a picture or video; it becomes the conversation's background when its last
    /// piece lands, checked and converted as Noodle does a file a person picks.
    public func receiveBackground(_ piece: LinkBackgroundPiece, for user: HubUser) async throws -> LinkBackground? {
        _ = try ownedConversation(piece.conversationID, by: user)
        guard let part = try keep(piece.data, at: piece.offset, of: piece.byteCount, as: piece.upload) else { return nil }
        let kind = URL(fileURLWithPath: piece.filename).pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        let file = uploads.appendingPathComponent("\(piece.upload.uuidString).\(kind)")
        defer { try? FileManager.default.removeItem(at: part); try? FileManager.default.removeItem(at: file) }
        try FileManager.default.moveItem(at: part, to: file)
        let prepared = try await PreparedBackgroundFile.prepare(file)
        _ = try ownedConversation(piece.conversationID, by: user)
        try repository.setBackground(conversationID: piece.conversationID, file: prepared)
        checkForChanges()
        return background(of: piece.conversationID)
    }

    /// One piece of a conversation's background file, or of the small copy made for phones the first time one asks.
    public func backgroundChunk(_ fetch: LinkBackgroundFetch, for user: HubUser) async throws -> (Data, Int) {
        _ = try ownedConversation(fetch.conversationID, by: user)
        let background = try repository.loadBackground(conversationID: fetch.conversationID)
        guard background.imageFilename == fetch.media,
              let original = repository.backgroundImageURL(background, conversationID: fetch.conversationID),
              let url = fetch.compact ? repository.compactBackgroundURL(background, conversationID: fetch.conversationID) : original else {
            throw LinkError("This background has changed.")
        }
        guard repository.isOwnBackgroundFile(original, conversationID: fetch.conversationID) else { throw LinkError("This background has changed.") }
        if !FileManager.default.fileExists(atPath: url.path) {
            try await BackgroundMedia.writeCompactCopy(of: original, kind: background.mediaKind ?? .image, to: url)
        }
        guard repository.isOwnBackgroundFile(url, conversationID: fetch.conversationID) else { throw LinkError("This background has changed.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = Int(try handle.seekToEnd())
        try handle.seek(toOffset: UInt64(min(max(0, fetch.offset), total)))
        return (try handle.read(upToCount: LinkProtocol.chunkSize) ?? Data(), total)
    }

    /// One piece of a conversation's file.
    public func chunk(of attachmentID: UUID, in conversationID: UUID, at offset: Int, for user: HubUser) throws -> (Data, Int) {
        _ = try ownedConversation(conversationID, by: user)
        return try chunk(of: attachmentID, in: conversationID, at: offset)
    }

    /// A small picture of a conversation's file, so a device shows it without downloading the file.
    /// Made once per size and kept beside the file; nil for a file with nothing to show.
    public func preview(of attachmentID: UUID, in conversationID: UUID, pixels: Int, for user: HubUser) async throws -> Data? {
        _ = try ownedConversation(conversationID, by: user)
        guard let attachment = try attachments(in: conversationID)[attachmentID] else { throw LinkError("There is no such file.") }
        let size = AttachmentPreview.size(for: pixels)
        let kept = repository.attachmentPreviewURL(attachment, pixels: size)
        if let data = try? Data(contentsOf: kept) { return data }
        guard let data = await AttachmentPreview.make(of: repository.attachmentFileURL(attachment), mediaType: attachment.mediaType,
                                                      pixels: size) else { return nil }
        try? FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: kept, options: .atomic)
        return data
    }

    private func chunk(of attachmentID: UUID, in conversationID: UUID, at offset: Int) throws -> (Data, Int) {
        guard let attachment = try repository.loadAttachments(conversationID: conversationID).first(where: { $0.id == attachmentID }) else {
            throw LinkError("There is no such file.")
        }
        let handle = try FileHandle(forReadingFrom: repository.attachmentFileURL(attachment))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        return (try handle.read(upToCount: LinkProtocol.chunkSize) ?? Data(), Int(attachment.byteCount))
    }

    public func send(_ body: String, id: UUID, attachmentIDs: [UUID] = [], in conversationID: UUID,
                     for user: HubUser) throws -> LinkMessage {
        let (conversation, bots) = try ownedConversation(conversationID, by: user)
        let files = try attachments(in: conversationID)
        if let existing = try repository.loadMessages(conversationID: conversationID).first(where: { $0.id == id }) {
            return linkMessage(existing, files: files)
        }
        guard attachmentIDs.allSatisfy({ files[$0] != nil }) else {
            throw LinkError("An attachment has not reached the Hub yet.")
        }
        for agent in bots {
            // Someone a bot is shared with talks with it on its owner's plan.
            if conversation.guest != nil {
                // A bot its owner's Mac hosts runs on no plan here.
                guard let owner = access.owner(ofBot: agent.id).flatMap({ id in access.users.first { $0.id == id } }),
                      access.host(ofBot: agent.id) != nil || lendsBot(agent, to: owner) else {
                    throw LinkError("\(agent.displayName) cannot take messages right now.")
                }
                continue
            }
            try requireLends(agent, to: user)
        }
        let message = try repository.sendUserMessage(conversationID: conversationID, body: body,
                                                     attachmentIDs: attachmentIDs, id: id)
        if running || watching { runtime.notify(bots, repository: repository) }
        // The bot reads it from its inbox; the call hears about it here.
        if let call = calls[conversationID] {
            runtime.sendToVoiceCall(agentID: call.agentID, VoiceCallDocumentation.typedMessage(
                body: body, attachmentNames: attachmentIDs.compactMap { files[$0]?.originalFilename }))
        }
        checkForChanges()
        return linkMessage(message, files: files)
    }

    /// Whether the owner's plan still lends what the bot runs on.
    private func requireLends(_ agent: AgentRecord, to user: HubUser) throws {
        let profile = try repository.loadAgentHarnessProfile(agent)
        // On the owner's own Mac, a bot runs on whatever Noodle gives it.
        guard access.isPersonal || agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:)).map({
            lends(HubHarness(provider: $0, profile: profile), to: user)
        }) == true else {
            let name = agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:))?.displayName ?? "this harness"
            throw LinkError("Your plan no longer lends \(name).")
        }
        if let provider = agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:)),
           !access.lends(HubHarness(provider: provider, profile: profile), model: agent.modelIdentifier, to: user) {
            throw LinkError(agent.modelIdentifier.map { "Your plan no longer lends \($0) on \(provider.displayName)." }
                            ?? "Your plan needs a model chosen for \(provider.displayName).")
        }
    }

    // MARK: Bots hosted on their owners' devices

    /// What a bot is doing: one its owner's device hosts only while that device is connected, as it says.
    public func phase(of bot: UUID) -> AgentRuntimePhase {
        guard let host = access.host(ofBot: bot) else { return runtime.snapshot(for: bot).phase }
        guard isHostConnected(host), let phase = hostedPhases[bot] else { return .offline }
        return AgentRuntimePhase(rawValue: phase.rawValue) ?? .offline
    }

    /// Keeps a bot that runs on the user's device here, or changes its name, description and picture.
    /// The people it is shared with talk to it here; nothing of it runs here.
    public func publish(_ id: UUID, _ draft: LinkBotDraft, for user: HubUser, on device: HubDevice) throws -> LinkHostedBot {
        guard !access.isPersonal else { throw LinkError("This Mac is only yours; nobody else can talk to your bots on it.") }
        let agents = try repository.loadAgents()
        if let agent = agents.first(where: { $0.id == id }) {
            guard access.host(ofBot: id) == device.id, access.owner(ofBot: id) == user.id else { throw LinkError("There is no such bot.") }
            _ = try repository.updateAgent(
                agent, displayName: draft.name, harnessIdentifier: nil, modelIdentifier: nil, reasoningEffort: nil,
                publicDescription: draft.publicDescription, avatarSymbolName: draft.avatarSymbolName,
                avatarColorIndex: draft.avatarColorIndex,
                // A digest without the picture keeps the one the bot has.
                avatarImageData: draft.avatarImageData ?? (draft.avatarImageDigest == nil ? nil : agent.avatarImageData))
            tellGuests(of: id)
        } else {
            guard !FileManager.default.fileExists(atPath: repository.storage(for: id).package.path) else {
                throw LinkError("There is no such bot.")
            }
            let created = try repository.createAgent(
                named: draft.name, publicDescription: draft.publicDescription, avatarSymbolName: draft.avatarSymbolName,
                avatarColorIndex: draft.avatarColorIndex, avatarImageData: draft.avatarImageData, id: id)
            runtime.remoteAgentIDs.insert(created.agent.id)
            access.setHost(device, ofBot: id)
            access.setOwner(user, ofBot: id)
            onBotsEdited?()
        }
        return hostedBot(id)
    }

    /// The bots the device hosts, each with its conversations with the people it is shared with.
    public func hostedBots(on device: HubDevice) throws -> [LinkHostedBot] {
        try repository.loadAgents().filter { access.host(ofBot: $0.id) == device.id }.map { hostedBot($0.id) }
    }

    private func hostedBot(_ id: UUID) -> LinkHostedBot {
        let conversations = ((try? guestConversations(of: id)) ?? []).compactMap { conversation in
            conversation.guest.map { LinkGuestConversation(id: conversation.id, person: $0.id, name: $0.name) }
        }
        return LinkHostedBot(id: id, conversations: conversations.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    /// A conversation of a bot the device hosts with someone it is shared with, and that bot.
    private func hostedConversation(_ id: UUID, on device: HubDevice) throws -> AgentRecord {
        guard let conversation = try repository.loadConversations().first(where: { $0.id == id }), conversation.guest != nil,
              conversation.kind == .direct, let bot = conversation.participantIDs.first, conversation.participantIDs.count == 1,
              access.host(ofBot: bot) == device.id, let agent = try repository.loadAgents().first(where: { $0.id == bot }) else {
            throw LinkError("There is no such conversation.")
        }
        return agent
    }

    public func hostedPage(_ request: LinkMessagePage, on device: HubDevice) throws -> LinkMessages {
        _ = try hostedConversation(request.conversationID, on: device)
        return try page(request)
    }

    public func hostedChunk(of attachmentID: UUID, in conversationID: UUID, at offset: Int, on device: HubDevice) throws -> (Data, Int) {
        _ = try hostedConversation(conversationID, on: device)
        return try chunk(of: attachmentID, in: conversationID, at: offset)
    }

    public func hostedReceive(_ data: Data, at offset: Int, of attachment: LinkAttachment, in conversationID: UUID,
                              on device: HubDevice) throws {
        _ = try hostedConversation(conversationID, on: device)
        try receive(data, at: offset, of: attachment, in: conversationID)
    }

    /// Keeps the bot's reply, once however often it comes. Its files arrived first; its links come with it.
    public func hostedReply(_ reply: LinkHostedReply, on device: HubDevice) throws -> LinkMessage {
        let agent = try hostedConversation(reply.conversationID, on: device)
        if let existing = try repository.loadMessages(conversationID: reply.conversationID).first(where: { $0.id == reply.id }) {
            return linkMessage(existing, files: try attachments(in: reply.conversationID))
        }
        // What opens live would open on the Hub's own computers, browsers and noodlets, not the Mac's.
        let links = try reply.links.map { link in
            guard let url = link.url else { throw LinkError("A link arrived without its address.") }
            guard CompanionLink(url) == nil else { throw LinkError("Links that open live on the Mac cannot be sent.") }
            return (link, url)
        }
        let present = Set(try repository.loadAttachments(conversationID: reply.conversationID).map(\.id))
        // Only what opens live has a card.
        for (link, url) in links where !present.contains(link.id) {
            _ = try repository.importLinkAttachment(url, into: reply.conversationID, id: link.id)
        }
        let message = try repository.sendAgentMessage(agentID: agent.id, conversationID: reply.conversationID, body: reply.body,
                                                      attachmentIDs: reply.attachmentIDs + reply.links.map(\.id), id: reply.id)
        checkForChanges()
        return linkMessage(message, files: try attachments(in: reply.conversationID))
    }

    public func hostedDelivered(_ messageIDs: [UUID], in conversationID: UUID, on device: HubDevice) throws {
        _ = try hostedConversation(conversationID, on: device)
        try repository.markDelivered(conversationID: conversationID, messageIDs: Set(messageIDs))
    }

    /// The bot's reaction to a message in one of its conversations, or taking it back.
    public func hostedReact(_ change: LinkReactionChange, on device: HubDevice) throws -> LinkMessage {
        let agent = try hostedConversation(change.conversationID, on: device)
        let message: ChatMessage
        do {
            message = try repository.setReaction(conversationID: change.conversationID, messageID: change.messageID,
                                                 author: .agent(agent.id), emoji: change.emoji, present: change.present)
        } catch WorkspaceError.invalidReaction {
            throw LinkError("Reactions are a single emoji.")
        } catch WorkspaceError.missingMessage(_) {
            throw LinkError("There is no such message.")
        }
        checkForChanges()
        return linkMessage(message, files: try attachments(in: change.conversationID))
    }

    /// A chat effect the bot sent on the Mac, kept once however often it comes, to wait for the person to see it.
    public func hostedEffect(_ kind: String, id: UUID, in conversationID: UUID, on device: HubDevice) throws {
        let agent = try hostedConversation(conversationID, on: device)
        do {
            _ = try repository.sendEffect(agentID: agent.id, conversationID: conversationID, kind: kind, requestID: id)
        } catch let error as ConversationEffectError {
            throw LinkError(error.localizedDescription)
        }
        checkForChanges()
    }

    public func setHostedPhase(_ phase: LinkBotPhase, of bot: UUID, on device: HubDevice) throws {
        guard access.host(ofBot: bot) == device.id else { throw LinkError("There is no such bot.") }
        hostedPhases[bot] = phase
        checkForChanges()
    }

    /// A device connected or went: what it said its bots were doing no longer holds once it is gone.
    public func hostsChanged() {
        for bot in hostedPhases.keys where !(access.host(ofBot: bot).map(isHostConnected) ?? false) { hostedPhases[bot] = nil }
        checkForChanges()
    }

    /// Deletes the bots of devices no longer paired, which nothing can run any more.
    public func removeBotsOfUnpairedHosts() {
        let devices = Set(access.devices.map(\.id))
        for agent in (try? repository.loadAgents()) ?? [] {
            guard let host = access.host(ofBot: agent.id), !devices.contains(host) else { continue }
            let owner = access.owner(ofBot: agent.id)
            _ = try? remove(agent)
            if let owner { onChange?(owner, .botsChanged) }
        }
    }

    // MARK: Voice calls

    private final class Call {
        let agentID: UUID
        let conversationID: UUID
        let peer: any VoiceCallPeering
        var cardID: UUID?
        var lines: [VoiceCallLine] = []
        init(agentID: UUID, conversationID: UUID, peer: any VoiceCallPeering) {
            self.agentID = agentID
            self.conversationID = conversationID
            self.peer = peer
        }
    }

    /// Calls in progress, by conversation. The Hub keeps their cards and passes them what is typed.
    private var calls: [UUID: Call] = [:]
    /// Picks a voice for a bot without one from its name; tests pass their own.
    public var voiceGuesser: any VoicePresentationGuessing = AppleVoicePresentationGuesser()
    /// Connects a call to the bot's voice service; tests pass their own.
    public var makeCallPeer: @MainActor () -> any VoiceCallPeering = { VoiceCallPeer() }

    /// Starts a call with the bot of one of the user's conversations: their own bot, or one shared
    /// with them, who calls it as they talk with it, on its owner's plan. The bot need not be
    /// running. The Hub holds the call's connection to the bot's voice: the device's audio frames go
    /// to the returned call's `hear`, and the bot's come back through `sendAudio`. `send` gets the
    /// events, ending with `ended`.
    public func startCall(_ start: LinkCallStart, for user: HubUser, send: @escaping @MainActor (LinkCallEvent) -> Void,
                          sendAudio: @escaping @Sendable (Data) -> Void) async throws -> HubCall {
        let (conversation, bots) = try ownedConversation(start.conversationID, by: user)
        guard conversation.kind == .direct, let agent = bots.first, agent.archivedAt == nil,
              agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:))?.voices.isEmpty == false else {
            throw LinkError("This bot cannot take calls.")
        }
        guard running || watching else { throw LinkError("This Hub is not running bots right now.") }
        if conversation.guest != nil {
            guard let owner = access.owner(ofBot: agent.id).flatMap({ id in access.users.first { $0.id == id } }),
                  lendsBot(agent, to: owner) else {
                throw LinkError("\(agent.displayName) cannot take calls right now.")
            }
        } else {
            try requireLends(agent, to: user)
        }
        let recentLines = try repository.loadMessages(conversationID: conversation.id).suffix(12).compactMap { message -> VoiceCallLine? in
            switch message.author {
            case .user: .init(.person, message.body)
            case .agent: .init(.bot, message.body)
            case .system: nil
            }
        }
        let voice = await BotVoice.forCall(agent, repository: repository, guesser: voiceGuesser)
        let identity = (try? repository.loadAgentBackstory(agent)).map {
            VoiceCallIdentity(name: agent.displayName, description: agent.publicDescription, backstory: $0)
        }
        if let previous = calls[conversation.id] { finish(previous, failure: nil, hangingUp: true) }
        runtime.start(agent: agent, repository: repository)
        let peer = makeCallPeer()
        let audio = try HubCallAudio(peer: peer, send: sendAudio)
        let call = Call(agentID: agent.id, conversationID: conversation.id, peer: peer)
        calls[conversation.id] = call
        peer.onFailure = { [weak self, weak call] in
            guard let self, let call, self.calls[call.conversationID] === call else { return }
            let lost = "The call connection was lost."
            self.finish(call, failure: lost, hangingUp: true)
            send(.ended(lost))
        }
        do {
            try await peer.place({ [runtime] offer, events in
                try runtime.startVoiceCall(agentID: agent.id, VoiceCallRequest(
                    offer: offer, voice: voice, conversationID: conversation.id,
                    personName: user.name, identity: identity, recentLines: Array(recentLines)
                ), events: events)
            }) { [weak self, weak call] event in
                guard let self, let call, self.calls[call.conversationID] === call else { return }
                switch event {
                case .answer:
                    break
                case .started:
                    // Only a call that connected gets its card in the conversation.
                    if call.cardID == nil {
                        call.cardID = try? self.repository.recordVoiceCall(agentID: call.agentID, conversationID: call.conversationID).id
                        self.checkForChanges()
                    }
                    send(.started)
                case .line(var line):
                    line.at = line.at ?? Date()
                    call.lines.append(line)
                    send(.line(LinkCallLine(speaker: line.speaker == .person ? .you : .bot, text: line.text, at: line.at)))
                case .ended(let detail):
                    self.finish(call, failure: detail, hangingUp: false)
                    send(.ended(detail))
                }
            }
        } catch {
            if calls[conversation.id] === call { calls[conversation.id] = nil }
            peer.close()
            throw error
        }
        return HubCall(hear: audio.receive) { [weak self, weak call] in
            guard let self, let call, self.calls[call.conversationID] === call else { return }
            self.finish(call, failure: nil, hangingUp: true)
        }
    }

    private func finish(_ call: Call, failure: String?, hangingUp: Bool) {
        calls[call.conversationID] = nil
        call.peer.onFailure = nil
        call.peer.close()
        if hangingUp { runtime.endVoiceCall(agentID: call.agentID) }
        guard let cardID = call.cardID,
              let card = try? repository.finishVoiceCall(messageID: cardID, conversationID: call.conversationID,
                                                         lines: call.lines, endedAt: Date()) else { return }
        // Finishing changes a message already sent, which a device reading on from its count would miss.
        if let agents = try? repository.loadAgents(),
           let conversation = try? repository.loadConversations().first(where: { $0.id == call.conversationID }),
           let person = person(of: conversation, among: agents), let files = try? attachments(in: call.conversationID) {
            onChange?(person, .messageChanged(linkMessage(card, files: files)))
        }
    }

    private func attachments(in conversationID: UUID) throws -> [UUID: ConversationAttachment] {
        Dictionary(try repository.loadAttachments(conversationID: conversationID).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Tells owners about conversations whose messages changed since the last check.
    public func checkForChanges() {
        guard let agents = try? repository.loadAgents(), let conversations = try? repository.loadConversations() else { return }
        let owned = owned(conversations, among: agents)
        let transcripts = transcripts, effectsChanged = effectsChanged
        apply(agents: agents, conversations: conversations, reads: owned.map { conversation, owner in
            (conversation, owner, Self.read(conversation, from: repository, transcript: transcripts[conversation.id],
                                            effectsChanged: effectsChanged[conversation.id]))
        })
    }

    /// The same check for the loops, which read the files off the main actor. A check made
    /// meanwhile wins; this one is left to the next pass.
    public func checkForChangesInBackground() async {
        let repository = repository, checks = checks
        guard let (agents, conversations) = try? await Task.detached(priority: .utility, operation: {
            (try repository.loadAgents(), try repository.loadConversations())
        }).value, checks == self.checks else { return }
        let owned = owned(conversations, among: agents)
        let transcripts = transcripts, effectsChanged = effectsChanged
        let reads = await Task.detached(priority: .utility) {
            owned.map { conversation, owner in
                (conversation, owner, Self.read(conversation, from: repository, transcript: transcripts[conversation.id],
                                                effectsChanged: effectsChanged[conversation.id]))
            }
        }.value
        guard checks == self.checks else { return }
        apply(agents: agents, conversations: conversations, reads: reads)
    }

    private func owned(_ conversations: [BotConversation], among agents: [AgentRecord]) -> [(BotConversation, UUID)] {
        conversations.compactMap { conversation in person(of: conversation, among: agents).map { (conversation, $0) } }
    }

    /// What a check reads of one conversation. Messages are read only when their file changed
    /// since the last check, and attachments only when a reaction came with them.
    private struct ConversationRead: Sendable {
        var background: ConversationBackground
        var effects: Date?
        var effectWaiting = false
        var transcript: (size: Int, modified: Date)?
        var messages: [ChatMessage]?
        var attachments: [UUID: ConversationAttachment]?
    }

    nonisolated private static func read(
        _ conversation: BotConversation, from repository: WorkspaceRepository,
        transcript known: (size: Int, modified: Date, count: Int, reactions: Int)?, effectsChanged: Date?
    ) -> ConversationRead {
        let directory = repository.conversationDirectory(id: conversation.id)
        var read = ConversationRead(background: (try? repository.loadBackground(conversationID: conversation.id)) ?? ConversationBackground())
        read.effects = (try? directory.appendingPathComponent("effects.json")
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let effects = read.effects, effects != effectsChanged {
            read.effectWaiting = (try? repository.hasPendingEffect(conversationID: conversation.id)) == true
        }
        let url = directory.appendingPathComponent("messages.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return read }
        read.transcript = (size, modified)
        if let known, known.size == size, known.modified == modified { return read }
        guard let messages = try? repository.loadMessages(conversationID: conversation.id) else { return read }
        read.messages = messages
        let latestReaction = messages.flatMap { $0.reactionChanges ?? [] }.map(\.sequence).max() ?? 0
        if let known, latestReaction > known.reactions, let files = try? repository.loadAttachments(conversationID: conversation.id) {
            read.attachments = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return read
    }

    private func apply(agents: [AgentRecord], conversations: [BotConversation], reads: [(BotConversation, UUID, ConversationRead)]) {
        checks += 1
        for (conversation, owner, read) in reads {
            if let known = backgrounds[conversation.id], known != read.background {
                onChange?(owner, .backgroundChanged(conversationID: conversation.id, background: self.background(of: conversation.id)))
                onBackgroundChanged?(conversation.id)
            }
            backgrounds[conversation.id] = read.background
            // A device that shows the conversation takes the effect waiting there.
            if let effects = read.effects, effects != effectsChanged[conversation.id] {
                effectsChanged[conversation.id] = effects
                if read.effectWaiting {
                    onChange?(owner, .effectWaiting(conversationID: conversation.id))
                }
            }
            guard let (size, modified) = read.transcript else { continue }
            if let known = transcripts[conversation.id], known.size == size, known.modified == modified { continue }
            guard let messages = read.messages else { continue }
            let latestReaction = messages.flatMap { $0.reactionChanges ?? [] }.map(\.sequence).max() ?? 0
            let known = transcripts[conversation.id]
            transcripts[conversation.id] = (size, modified, messages.count, latestReaction)
            if known.map({ $0.count != messages.count }) ?? true {
                onChange?(owner, .conversationChanged(conversationID: conversation.id, count: messages.count))
                if conversation.guest != nil, let bot = conversation.participantIDs.first, let host = access.host(ofBot: bot) {
                    onHostChange?(host, .conversationChanged(conversationID: conversation.id, count: messages.count))
                }
            }
            // A request's line changes as the request goes on, which a device reading on from its count would miss.
            let lines = Dictionary(messages.compactMap { message in message.request.map { (message.id, $0) } },
                                   uniquingKeysWith: { first, _ in first })
            if let before = requestLines[conversation.id] {
                let changed = messages.filter { message in before[message.id].map { $0 != message.request } ?? false }
                if !changed.isEmpty {
                    let files = (try? attachments(in: conversation.id)) ?? [:]
                    for message in changed { onChange?(owner, .messageChanged(linkMessage(message, files: files))) }
                }
            }
            requestLines[conversation.id] = lines
            // Reactions change messages already sent, which a device reading on from its count would miss.
            if let known, latestReaction > known.reactions, let files = read.attachments {
                let host = conversation.guest == nil ? nil : conversation.participantIDs.first.flatMap(access.host(ofBot:))
                for message in messages where (message.reactionChanges ?? []).contains(where: { $0.sequence > known.reactions }) {
                    onChange?(owner, .messageChanged(linkMessage(message, files: files)))
                    // The Mac hosting the bot passes the person's reactions on to it.
                    if let host { onHostChange?(host, .messageChanged(linkMessage(message, files: files))) }
                }
            }
        }
        var restated: Set<UUID> = []
        for agent in agents {
            guard let owner = access.owner(ofBot: agent.id) else { continue }
            let phase = self.phase(of: agent.id)
            if let known = phases[agent.id], known != phase, let link = LinkBotPhase(rawValue: phase.rawValue) {
                // Whether it is working reaches the people it is shared with too; the status it sets does not.
                let guests = conversations.filter { $0.participantIDs == [agent.id] }.compactMap(\.guest?.id)
                for person in [owner] + guests { onChange?(person, .botPhase(botID: agent.id, phase: link)) }
            }
            phases[agent.id] = phase
            // A bot sets its status through Messenger; devices list the bots again to see it.
            if let known = statuses[agent.id], known != agent.status { restated.insert(owner) }
            statuses[agent.id] = .some(agent.status)
        }
        restated.forEach { onChange?($0, .botsChanged) }
    }

    /// The chat effect waiting in one of the user's conversations, taken by the device that shows it, so it plays once.
    public func takeEffect(in conversationID: UUID, for user: HubUser) throws -> LinkEffect? {
        _ = try ownedConversation(conversationID, by: user)
        return try repository.takePendingEffect(conversationID: conversationID).map { LinkEffect(id: $0.id, kind: $0.kind) }
    }

    /// Adds or removes the owner's reaction to a message in one of their bots' conversations.
    public func react(_ change: LinkReactionChange, for user: HubUser) throws -> LinkMessage {
        _ = try ownedConversation(change.conversationID, by: user)
        let message: ChatMessage
        do {
            message = try repository.setReaction(conversationID: change.conversationID, messageID: change.messageID,
                                                 author: .user, emoji: change.emoji, present: change.present)
        } catch WorkspaceError.invalidReaction {
            throw LinkError("Reactions are a single emoji.")
        }
        checkForChanges()
        return linkMessage(message, files: try attachments(in: change.conversationID))
    }

    /// Moves how far the owner has read a conversation on, never back, and tells their devices.
    public func markRead(_ mark: LinkReadMark, for user: HubUser) throws {
        _ = try ownedConversation(mark.conversationID, by: user)
        guard let upTo = try repository.loadMessages(conversationID: mark.conversationID)
            .first(where: { $0.id == mark.messageID })?.createdAt else {
            throw LinkError("There is no such message.")
        }
        guard readMarks[mark.conversationID].map({ $0 < upTo }) ?? true else { return }
        readMarks[mark.conversationID] = upTo
        try saveReadMarks()
        onChange?(user.id, .readChanged(conversationID: mark.conversationID, upTo: upTo))
        onRead?(mark.conversationID, upTo)
    }

    /// How many of the bot's replies its owner has not read.
    public func unread(in conversationID: UUID) throws -> Int {
        let mark = readMarks[conversationID] ?? .distantPast
        return try repository.loadMessages(conversationID: conversationID).filter {
            if case .agent = $0.author { $0.createdAt > mark } else { false }
        }.count
    }

    private func saveReadMarks() throws {
        try FileManager.default.createDirectory(at: readMarksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(readMarks).write(to: readMarksURL, options: .atomic)
    }

    /// Pins or unpins one of the user's conversations and tells their devices. Pinning again keeps its place.
    public func setPinned(_ pinned: Bool, conversation id: UUID, for user: HubUser) throws {
        _ = try ownedConversation(id, by: user)
        guard (pins[id] != nil) != pinned else { return }
        guard pinsURL != nil else {
            var ids = try repository.loadPinnedConversationIDs().filter { $0 != id }
            if pinned { ids.append(id) }
            try repository.savePinnedConversationIDs(ids)
            pinsChanged(for: user)
            onPinsEdited?()
            return
        }
        pins[id] = pinned ? Date() : nil
        try savePins()
        onChange?(user.id, .pinChanged(conversationID: id, pinnedAt: pins[id]))
    }

    /// Noodle's own pins changed: tells the user's devices each pin that came, went or moved.
    public func pinsChanged(for user: HubUser) {
        let before = pins
        pins = loadPins()
        for id in Set(before.keys).union(pins.keys) where before[id] != pins[id] {
            onChange?(user.id, .pinChanged(conversationID: id, pinnedAt: pins[id]))
        }
    }

    private func loadPins() -> [UUID: Date] {
        guard let pinsURL else {
            // Their order, as the dates devices sort pins by.
            let ids = (try? repository.loadPinnedConversationIDs()) ?? []
            return Dictionary(ids.enumerated().map { ($1, Date(timeIntervalSinceReferenceDate: Double($0))) }) { first, _ in first }
        }
        return (try? JSONDecoder().decode([UUID: Date].self, from: Data(contentsOf: pinsURL))) ?? [:]
    }

    private func savePins() throws {
        guard let pinsURL else { return }
        try FileManager.default.createDirectory(at: pinsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pins).write(to: pinsURL, options: .atomic)
    }

    /// Drops how far deleted conversations were read and whether they were pinned.
    private func forgetMarks(of conversations: [UUID]) {
        if conversations.contains(where: { readMarks[$0] != nil }) {
            conversations.forEach { readMarks[$0] = nil }
            try? saveReadMarks()
        }
        // Noodle drops its own pins of conversations that are gone.
        if pinsURL != nil, conversations.contains(where: { pins[$0] != nil }) {
            conversations.forEach { pins[$0] = nil }
            try? savePins()
        }
    }

    /// Deletes a bot, and any group left without bots. Returns whether it was in a group.
    private func remove(_ agent: AgentRecord) throws -> Bool {
        try? imageGeneration?.assign(false, to: agent.id)
        let joined = (try? repository.loadConversations().filter { $0.participantIDs.contains(agent.id) }) ?? []
        let conversations = joined.filter { $0.kind == .direct || $0.participantIDs == [agent.id] }.map(\.id)
        defer {
            for conversation in joined {
                guard let guest = conversation.guest?.id else { continue }
                onClosed?(conversation.id, guest)
                onChange?(guest, .botsChanged)
            }
        }
        if running { runtime.stop(agentID: agent.id, revokeAccess: false) }
        try repository.deleteAgent(agent)
        // Nobody would see a group without bots again.
        for group in joined where group.kind == .group && group.participantIDs == [agent.id] {
            try? repository.deleteConversation(id: group.id)
        }
        if running {
            runtime.stop(agentID: agent.id)
            try? messenger.start(agents: try repository.loadAgents())
        }
        if toolBroker != nil { try? startTools() }
        connections.forget(bot: agent.id)
        computers.forget(bot: agent.id)
        browsers.forget(bot: agent.id)
        if running { applets.start(agents: (try? repository.loadAgents()) ?? []) }
        access.setOwner(nil, ofBot: agent.id)
        if access.host(ofBot: agent.id) != nil {
            access.setHost(nil, ofBot: agent.id)
            hostedPhases[agent.id] = nil
            runtime.remoteAgentIDs.remove(agent.id)
        }
        forgetMarks(of: conversations)
        return joined.contains { $0.kind == .group }
    }

    /// Whether the user's plan lends the harness and model the bot runs on.
    private func lendsBot(_ agent: AgentRecord, to user: HubUser) -> Bool {
        guard !access.isPersonal else { return true }
        guard let provider = agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:)) else { return false }
        let profile: UUID?
        do { profile = try repository.loadAgentHarnessProfile(agent) } catch { return false }
        return access.lends(HubHarness(provider: provider, profile: profile), model: agent.modelIdentifier, to: user)
    }

    /// Reads the user's current plan, not the one they were on when `user` was read.
    private func lends(_ harness: HubHarness, to user: HubUser) -> Bool { access.lends(harness, to: user) }

    private func lent(_ draft: LinkBotDraft, to user: HubUser, verb: String) throws -> HarnessProvider {
        guard let provider = HarnessProvider(rawValue: draft.provider) else {
            throw LinkError("This Noodle Hub does not know the harness \(draft.provider).")
        }
        let harness = HubHarness(provider: provider, profile: draft.profile)
        guard lends(harness, to: user) else {
            throw LinkError("Your plan \(verb) \(provider.displayName).")
        }
        guard access.lends(harness, model: draft.model, to: user) else {
            throw LinkError(draft.model.map { "Your plan \(verb) \($0) on \(provider.displayName)." }
                            ?? "Your plan needs a model chosen for \(provider.displayName).")
        }
        return provider
    }

    private func validVoice(_ voice: String?, on provider: HarnessProvider) -> String? {
        guard let voice, provider.voices.contains(where: { $0.id == voice }) else { return nil }
        return voice
    }

    /// One of the user's bots that runs here, rather than on one of their devices.
    private func runHere(_ id: UUID, by user: HubUser) throws -> AgentRecord {
        let agent = try owned(id, by: user)
        guard access.host(ofBot: id) == nil else { throw LinkError("\(agent.displayName) runs on your Mac. Change it there.") }
        return agent
    }

    private func owned(_ id: UUID, by user: HubUser) throws -> AgentRecord {
        guard access.owner(ofBot: id) == user.id, !isHidden(id), let agent = try repository.loadAgents().first(where: { $0.id == id }) else {
            throw LinkError("There is no such bot.")
        }
        return agent
    }

    /// The browser tab, computer or noodlet a link in the user's conversation names, and the bot
    /// that posted it. Only a link one of the conversation's bots posted counts, and a noodlet only
    /// if it came from that bot's folder. Anything else opens nothing.
    public func companionLink(_ attachmentID: UUID, in conversationID: UUID, for user: HubUser) async throws -> (link: CompanionLink, bot: UUID) {
        let bots = try ownedConversation(conversationID, by: user).bots
        let poster = try repository.loadMessages(conversationID: conversationID)
            .first { ($0.attachmentIDs ?? []).contains(attachmentID) }
            .flatMap { message in bots.first { message.author == .agent($0.id) } }
        guard let link = try attachments(in: conversationID)[attachmentID]?.companion, let bot = poster else {
            throw LinkError("That is not something this bot shared.")
        }
        if case .noodlet(let noodlet) = link {
            // A noodlet is the bot's whose folder it came from; Applet says which folder, and asked
            // for the bot, checks that too.
            var info = AppletRequest(.info)
            info.noodletID = noodlet
            info.owner = bot.id.uuidString.lowercased()
            let workspace = repository.directory(for: bot).resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let source = try await applets.companion(info).sourcePath.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.pathComponents
            }
            guard let source, source.count > workspace.count, Array(source.prefix(workspace.count)) == workspace else {
                throw LinkError("That noodlet is not this bot's.")
            }
        }
        return (link, bot.id)
    }

    /// The latest picture of what a link points at, by the same rule as opening it: a noodlet's
    /// from Noodle Applet, anything else the one its card carries.
    public func picture(of attachmentID: UUID, in conversationID: UUID, for user: HubUser) async throws -> Data? {
        let (link, _) = try await companionLink(attachmentID, in: conversationID, for: user)
        guard case .noodlet(let noodlet) = link else { return try attachments(in: conversationID)[attachmentID]?.card?.image }
        var info = AppletRequest(.info)
        info.noodletID = noodlet
        info.includePreview = true
        let response = try await applets.companion(info)
        return response.mediaType == "image/png" ? response.data : nil
    }

    /// The title and preview of a live attachment, without opening it.
    public func card(of attachmentID: UUID, in conversationID: UUID, for user: HubUser) async throws -> LinkCardInfo? {
        let (link, _) = try await companionLink(attachmentID, in: conversationID, for: user)
        if case .noodlet(let noodlet) = link {
            // Asked for as the Hub, as its picture is: Noodle Applet keeps pictures from requests made for a bot.
            var info = AppletRequest(.info)
            info.noodletID = noodlet
            info.includePreview = true
            let response = try await applets.companion(info)
            guard let title = response.title else { return nil }
            return LinkCardInfo(title: title, image: response.mediaType == "image/png" ? response.data : nil,
                                symbol: "square.grid.2x2", isGame: response.controls != nil || response.category == "games")
        }
        guard let card = try attachments(in: conversationID)[attachmentID]?.card else { return nil }
        return LinkCardInfo(title: card.title, detail: card.detail, image: card.image, symbol: card.symbol,
                            colour: card.colour, icon: card.icon, capturedAt: card.capturedAt)
    }

    /// A conversation the user has and its bots: one bot's own, a group of theirs, or theirs with a bot shared with them.
    private func ownedConversation(_ id: UUID, by user: HubUser) throws -> (conversation: BotConversation, bots: [AgentRecord]) {
        let agents = try repository.loadAgents()
        guard let conversation = try repository.loadConversations().first(where: { $0.id == id }),
              person(of: conversation, among: agents) == user.id else {
            throw LinkError("There is no such conversation.")
        }
        let bots = conversation.participantIDs.compactMap { id in agents.first { $0.id == id } }
        // An archived bot is its owner's alone until they bring it back.
        if conversation.guest != nil, bots.contains(where: { $0.archivedAt != nil }) { throw LinkError("There is no such conversation.") }
        return (conversation, bots)
    }

    /// Whether the user can open a conversation now, for what they opened of it earlier.
    public func canOpen(_ conversationID: UUID, for user: UUID) -> Bool {
        guard let user = access.users.first(where: { $0.id == user }) else { return false }
        return (try? ownedConversation(conversationID, by: user)) != nil
    }

    private func ownedGroup(_ id: UUID, by user: HubUser) throws -> BotConversation {
        guard let conversation = try? ownedConversation(id, by: user).conversation, conversation.kind == .group,
              conversation.guest == nil else {
            throw LinkError("There is no such group.")
        }
        return conversation
    }

    /// The user all of a conversation's bots belong to, when they are one user's and shown to devices.
    private func owner(of conversation: BotConversation, among agents: [AgentRecord]) -> UUID? {
        let bots = conversation.participantIDs
        guard !bots.isEmpty, conversation.kind == .group || bots.count == 1,
              bots.allSatisfy({ id in !isHidden(id) && agents.contains { $0.id == id } }) else { return nil }
        let owners = Set(bots.map(access.owner(ofBot:)))
        guard owners.count == 1, let owner = owners.first ?? nil else { return nil }
        return owner
    }

    /// Whom a conversation devices see is with: someone its bot is shared with, or the user its bots belong to.
    private func person(of conversation: BotConversation, among agents: [AgentRecord]) -> UUID? {
        guard let owner = owner(of: conversation, among: agents) else { return nil }
        return conversation.guest?.id ?? owner
    }

    private func group(_ conversation: BotConversation) -> LinkGroup {
        LinkGroup(id: conversation.id,
                  draft: LinkGroupDraft(name: conversation.displayName, publicDescription: conversation.publicDescription ?? "",
                                        botIDs: conversation.participantIDs),
                  createdAt: conversation.createdAt, readUpTo: readMarks[conversation.id], archivedAt: conversation.archivedAt,
                  background: background(of: conversation.id), pinnedAt: pins[conversation.id])
    }

    private func bot(_ agent: AgentRecord, conversations: [BotConversation]) throws -> LinkBot? {
        let direct = conversations.filter { $0.kind == .direct && $0.participantIDs == [agent.id] }
        guard let conversation = direct.first(where: { $0.guest == nil }) else { return nil }
        var draft = LinkBotDraft(
            name: agent.displayName, provider: agent.harnessIdentifier ?? "", profile: try repository.loadAgentHarnessProfile(agent),
            model: agent.modelIdentifier, reasoningEffort: agent.reasoningEffort, publicDescription: agent.publicDescription ?? "",
            backstory: try repository.loadAgentBackstory(agent), avatarSymbolName: agent.avatarSymbolName,
            avatarColorIndex: agent.avatarColorIndex ?? agent.accentSeed, avatarImageData: agent.avatarImageData)
        draft.avatarImageDigest = agent.avatarImageData.map(LinkPicture.digest)
        draft.voice = try repository.loadAgentVoice(agent)
        draft.imageGeneration = imageGeneration?.isAssigned(agent.id) ?? false
        return LinkBot(id: agent.id, conversationID: conversation.id, draft: draft, createdAt: agent.createdAt,
                       phase: LinkBotPhase(rawValue: phase(of: agent.id).rawValue), readUpTo: readMarks[conversation.id],
                       status: agent.status, archivedAt: agent.archivedAt, background: background(of: conversation.id),
                       // On the owner's own Mac, those are people on another Hub.
                       sharedWith: access.isPersonal ? [] : direct.compactMap(\.guest?.id),
                       canCall: agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:))?.voices.isEmpty == false,
                       pinnedAt: pins[conversation.id])
    }

    /// A bot as someone it is shared with sees it: whose it is and whether it is working, nothing of how it works.
    private func sharedBot(_ agent: AgentRecord, in conversation: BotConversation) -> LinkBot? {
        guard let owner = access.owner(ofBot: agent.id).flatMap({ id in access.users.first { $0.id == id } }) else { return nil }
        var draft = LinkBotDraft(name: agent.displayName, provider: "", publicDescription: agent.publicDescription ?? "",
                                 avatarSymbolName: agent.avatarSymbolName, avatarColorIndex: agent.avatarColorIndex ?? agent.accentSeed,
                                 avatarImageData: agent.avatarImageData)
        draft.avatarImageDigest = agent.avatarImageData.map(LinkPicture.digest)
        return LinkBot(id: agent.id, conversationID: conversation.id, draft: draft, createdAt: agent.createdAt,
                       phase: LinkBotPhase(rawValue: phase(of: agent.id).rawValue),
                       readUpTo: readMarks[conversation.id], background: background(of: conversation.id), owner: owner.name,
                       canCall: agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:))?.voices.isEmpty == false,
                       pinnedAt: pins[conversation.id])
    }

    /// Pictures' sizes, read once each: a stored file never changes.
    private var pixelSizes: [UUID: LinkPixelSize?] = [:]

    private func pixelSize(of file: ConversationAttachment) -> LinkPixelSize? {
        Self.pixelSize(of: file, in: repository, sizes: &pixelSizes)
    }

    nonisolated private static func pixelSize(of file: ConversationAttachment, in repository: WorkspaceRepository,
                                              sizes: inout [UUID: LinkPixelSize?]) -> LinkPixelSize? {
        guard file.mediaType.hasPrefix("image/") else { return nil }
        if let known = sizes[file.id] { return known }
        let size = LinkPixelSize(pictureAt: repository.attachmentFileURL(file))
        sizes[file.id] = size
        return size
    }

    private func linkMessage(_ message: ChatMessage, files: [UUID: ConversationAttachment], pictures: Bool = true) -> LinkMessage {
        Self.linkMessage(message, files: files, pictures: pictures, guest: Self.isGuest(message.conversationID, in: repository)) {
            pixelSize(of: $0)
        }
    }

    nonisolated private static func isGuest(_ conversationID: UUID, in repository: WorkspaceRepository) -> Bool {
        (try? repository.loadConversations().first { $0.id == conversationID })?.guest != nil
    }

    /// Someone a bot is shared with sees only how its requests went, not what it asked or was told.
    nonisolated private static func linkMessage(_ message: ChatMessage, files: [UUID: ConversationAttachment], pictures: Bool,
                                                guest: Bool, pixelSize: (ConversationAttachment) -> LinkPixelSize?) -> LinkMessage {
        let author: LinkMessage.Author = switch message.author {
        case .user: .you
        case .agent(let id): .bot(id)
        case .system: .system
        }
        let attachments = (message.attachmentIDs ?? []).compactMap { files[$0] }.map {
            LinkAttachment(id: $0.id, filename: $0.originalFilename, mediaType: $0.mediaType, byteCount: Int($0.byteCount),
                           voice: $0.voice.map { LinkVoice(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform,
                                                           localeIdentifier: $0.localeIdentifier) },
                           url: $0.url,
                           card: $0.card.map { LinkCardInfo(title: $0.title, detail: $0.detail, image: pictures ? $0.image : nil, symbol: $0.symbol,
                                                            colour: $0.colour, icon: $0.icon, capturedAt: $0.capturedAt) },
                           pixelSize: pixelSize($0))
        }
        let reactions = (message.reactions ?? []).compactMap { reaction -> LinkReaction? in
            switch reaction.author {
            case .user: LinkReaction(author: .you, emoji: reaction.emoji)
            case .agent(let id): LinkReaction(author: .bot(id), emoji: reaction.emoji)
            case .system: nil
            }
        }
        let call = message.call.map { record in
            LinkCallRecord(botID: record.agentID, endedAt: record.endedAt, lines: record.lines.map {
                LinkCallLine(speaker: $0.speaker == .person ? .you : .bot, text: $0.text, at: $0.at)
            })
        }
        let request = message.request.flatMap { line in
            LinkRequestLine.Status(rawValue: line.status.rawValue).map {
                guest ? LinkRequestLine(helperName: line.helperName, status: $0)
                    : LinkRequestLine(helperName: line.helperName, status: $0, text: line.text, answer: line.answer)
            }
        }
        return LinkMessage(id: message.id, conversationID: message.conversationID, author: author, body: message.body,
                           createdAt: message.createdAt, delivered: message.delivery == .delivered, attachments: attachments,
                           reactions: reactions, call: call, request: request)
    }
}

/// Small pictures of conversation files for devices: a picture scaled down, a video's first frame or
/// a PDF's first page, as JPEG, or PNG where the picture is see-through.
enum AttachmentPreview {
    /// The sizes made, so a few copies serve every device: the smallest as big as asked, else the largest.
    static let sizes = [360, 720, 1440, 2048]

    static func size(for pixels: Int) -> Int { sizes.first { $0 >= pixels } ?? sizes[sizes.count - 1] }

    static func make(of file: URL, mediaType: String, pixels: Int) async -> Data? {
        let image: CGImage?
        if mediaType.hasPrefix("image/") {
            image = picture(file, pixels: pixels)
        } else if mediaType.hasPrefix("video/") {
            image = await frame(file, pixels: pixels)
        } else if mediaType == "application/pdf" {
            image = page(file, pixels: pixels)
        } else {
            return nil
        }
        return image.flatMap(encoded)
    }

    private static func picture(_ file: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary)
    }

    private static func frame(_ file: URL, pixels: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        return try? await generator.image(at: .zero).image
    }

    private static func page(_ file: URL, pixels: Int) -> CGImage? {
        guard let page = CGPDFDocument(file as CFURL)?.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(pixels) / max(box.width, box.height)
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private static func encoded(_ image: CGImage) -> Data? {
        let seeThrough = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (seeThrough ? "public.png" : "public.jpeg") as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

/// A call the Hub holds for a device.
public struct HubCall: Sendable {
    /// Takes the frames the device sends up the call's channel.
    public let hear: @Sendable (Data) -> Void
    public let hangUp: @MainActor () -> Void
}

/// Carries a call's audio between the device, as packets on the call's channel, and the bot's
/// voice. Frames come in one at a time from the channel and the voice from the peer's own thread,
/// so each direction has its own codec.
final class HubCallAudio: @unchecked Sendable {
    private let peer: any VoiceCallPeering
    private let decoder: LinkCallDecoder

    init(peer: any VoiceCallPeering, send: @escaping @Sendable (Data) -> Void) throws {
        self.peer = peer
        decoder = try LinkCallDecoder()
        let encoder = try LinkCallEncoder()
        peer.onVoice = { samples in
            for packet in (try? encoder.encode(samples)) ?? [] { send(LinkCallAudio.frame(packet)) }
        }
    }

    func receive(_ frame: Data) {
        guard let packet = LinkCallAudio.packet(in: frame), let samples = try? decoder.decode(packet) else { return }
        peer.hear(samples)
    }
}
