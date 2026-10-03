import AppletBridge
import BrowserBridge
import Foundation
import HubLink
import NoodleCore
import NoodleRuntime

/// Bots paired devices keep on the Hub. Each belongs to one user, runs on a harness that
/// user's plan lends, and talks only with that user, alone or in groups of their bots.
@MainActor public final class HubBots {
    /// Where an owner's devices are told that something changed.
    public var onChange: ((_ user: UUID, LinkEvent) -> Void)?
    /// Runs when a conversation's owner read further, for whatever else shows it: on the owner's own Mac, Noodle.
    public var onRead: ((_ conversationID: UUID, _ upTo: Date) -> Void)?

    private let repository: WorkspaceRepository
    private let runtime: AgentRuntimeCoordinator
    private let access: HubAccess
    private let connections: HubConnections
    private let computers: HubComputers
    private let browsers: HubBrowsers
    /// Noodle Applet on this Mac, for the Hub's bots' applet tool and for people's devices.
    public let applets: AppletController
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
    /// Bots here that devices never see: on the owner's own Mac, its copies of bots another Hub keeps.
    public var isHidden: (UUID) -> Bool = { _ in false }
    /// The last seen size and date of each conversation's messages, their count, and the latest reaction change.
    private var transcripts: [UUID: (size: Int, modified: Date, count: Int, reactions: Int)] = [:]
    /// What each bot was last reported doing.
    private var phases: [UUID: AgentRuntimePhase] = [:]
    /// Each bot's status when last checked; an absent bot has not been checked yet.
    private var statuses: [UUID: String?] = [:]
    /// The latest Kick a device was asked to confirm, per bot. The runtime refuses it once stale.
    private var kickRequests: [UUID: AgentKickRequest] = [:]
    /// How far each conversation's owner has read it, so all their devices agree.
    private let readMarksURL: URL
    private lazy var readMarks: [UUID: Date] = (try? JSONDecoder().decode([UUID: Date].self, from: Data(contentsOf: readMarksURL))) ?? [:]

    public init(repository: WorkspaceRepository, runtime: AgentRuntimeCoordinator, access: HubAccess,
                connections: HubConnections, computers: HubComputers, browsers: HubBrowsers,
                applets: AppletController, uploads: URL, readMarks: URL) {
        self.uploads = uploads
        readMarksURL = readMarks
        self.repository = repository
        self.runtime = runtime
        self.access = access
        self.connections = connections
        self.computers = computers
        self.browsers = browsers
        self.applets = applets
        messenger = MessengerBroker(repository: repository)
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
        let now = Date()
        agents.forEach { runtime.seedHeartbeatActivity(for: $0.id, at: now) }
        runtime.startAll(agents: agents, repository: repository)
        // Devices are offered the models the Hub finds.
        runtime.refreshCapabilities()
        applets.start(agents: agents)
        try startTools()
        running = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if let agents = try? self.repository.loadAgents() {
                    self.runtime.reconcile(agents: agents, repository: self.repository)
                }
                self.runtime.checkHeartbeats()
                self.checkForChanges()
            }
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
                self.checkForChanges()
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

    /// The models the Hub's own copy of the harness offers.
    public func models(for provider: HarnessProvider) -> [HarnessModel] { runtime.models(for: provider.rawValue) }

    public func bots(for user: HubUser) throws -> [LinkBot] {
        let conversations = try repository.loadConversations()
        return try repository.loadAgents()
            .filter { access.owner(ofBot: $0.id) == user.id && !isHidden($0.id) }
            .compactMap { try bot($0, conversations: conversations) }
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
        let agent = try owned(id, by: user)
        let provider = try lent(draft, to: user, verb: "does not lend")
        let updated = try repository.updateAgent(
            agent, displayName: draft.name, harnessIdentifier: provider.rawValue, modelIdentifier: draft.model,
            reasoningEffort: draft.reasoningEffort, publicDescription: draft.publicDescription,
            avatarSymbolName: draft.avatarSymbolName, avatarColorIndex: draft.avatarColorIndex,
            // A digest without the picture keeps the one the bot has.
            avatarImageData: draft.avatarImageData ?? (draft.avatarImageDigest == nil ? nil : agent.avatarImageData))
        try repository.updateAgentBackstory(updated, backstory: draft.backstory)
        try repository.updateAgentHarnessProfile(updated, profile: draft.profile)
        // As Edit Bot does in Noodle, whose runtime runs the bot when this only watches.
        if running || watching { runtime.restart(agent: updated, repository: repository) }
        onChange?(user.id, .botsChanged)
        onBotsEdited?()
        return try bot(updated, conversations: try repository.loadConversations()) ?? {
            throw LinkError("The bot was saved but could not be read back.")
        }()
    }

    public func picture(ofBot id: UUID, for user: HubUser) throws -> Data? {
        try owned(id, by: user).avatarImageData
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
        let bots = try draft.botIDs.map { try owned($0, by: user) }
        let conversation = try repository.createGroup(named: draft.name, publicDescription: draft.publicDescription,
                                                      participantIDs: bots.map(\.id), existingAgents: bots)
        onChange?(user.id, .groupsChanged)
        onBotsEdited?()
        // As saved, so it matches every later read of the same group.
        return group(try repository.loadConversations().first { $0.id == conversation.id } ?? conversation)
    }

    public func updateGroup(_ id: UUID, with draft: LinkGroupDraft, for user: HubUser) throws -> LinkGroup {
        let before = try ownedGroup(id, by: user)
        let bots = try draft.botIDs.map { try owned($0, by: user) }
        let updated = try repository.updateGroup(conversationID: id, named: draft.name, publicDescription: draft.publicDescription,
                                                 participantIDs: bots.map(\.id), existingAgents: try repository.loadAgents())
        // As Group Info does in Noodle: the bots hear who joined or left, and of a new description.
        if running || watching,
           Set(before.participantIDs) != Set(updated.participantIDs) || before.publicDescription != updated.publicDescription {
            runtime.notify(bots, repository: repository)
        }
        onChange?(user.id, .groupsChanged)
        onBotsEdited?()
        return group(updated)
    }

    /// Deletes a group and its messages. Its bots stay.
    public func deleteGroup(_ id: UUID, for user: HubUser) throws {
        _ = try ownedGroup(id, by: user)
        try repository.deleteConversation(id: id)
        if readMarks.removeValue(forKey: id) != nil { try? saveReadMarks() }
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
        } else {
            _ = try ownedGroup(id, by: user)
            try repository.setConversationArchived(archived, conversationID: id)
            onChange?(user.id, .groupsChanged)
        }
        onBotsEdited?()
    }

    /// Kick, as in Noodle, through whichever runtime runs the bot: on the owner's own Mac, Noodle's.
    /// A failure Noodle would ask about first is kept until the device agrees with `confirmKick`.
    public func kick(_ id: UUID, for user: HubUser) throws -> LinkKickConfirmation? {
        let agent = try owned(id, by: user)
        guard let request = runtime.kick(agent: agent, repository: repository) else { return nil }
        kickRequests[agent.id] = request
        return LinkKickConfirmation(id: request.id, title: request.title, message: request.message,
                                    confirmTitle: request.confirmTitle, offersNewSession: request.offersNewSession)
    }

    public func confirmKick(_ id: UUID, confirmation: UUID, for user: HubUser) throws {
        let agent = try owned(id, by: user)
        guard let request = kickRequests[agent.id], request.id == confirmation else { return }
        kickRequests[agent.id] = nil
        runtime.confirmKick(request, repository: repository)
    }

    public func startNewSession(_ id: UUID, for user: HubUser) throws {
        let agent = try owned(id, by: user)
        kickRequests[agent.id] = nil
        runtime.startNewSession(agent: agent, repository: repository)
    }

    /// Deletes every bot of a user who is being removed.
    public func removeBots(of user: HubUser) {
        for agent in (try? repository.loadAgents()) ?? [] where access.owner(ofBot: agent.id) == user.id {
            _ = try? remove(agent)
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
    public func page(_ request: LinkMessagePage, for user: HubUser) throws -> LinkMessages {
        _ = try ownedConversation(request.conversationID, by: user)
        let messages = try repository.loadMessages(conversationID: request.conversationID)
        let files = try attachments(in: request.conversationID)
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
                let linked = linkMessage(message, files: files, pictures: false)
                guard fits(linked) else { break }
                page.append(linked)
            }
        } else {
            let end = min(max(0, request.before ?? messages.count), messages.count)
            start = end
            for message in messages[..<end].reversed() {
                let linked = linkMessage(message, files: files, pictures: false)
                guard fits(linked) else { break }
                page.insert(linked, at: 0)
                start -= 1
            }
        }
        return LinkMessages(messages: page, count: messages.count, start: start)
    }

    /// Most of the link's message limit, leaving room for what surrounds the page.
    private static let pageBytes = 700_000

    /// Keeps one piece of a file; the file joins the conversation when its last piece lands.
    public func receive(_ data: Data, at offset: Int, of attachment: LinkAttachment, in conversationID: UUID,
                        for user: HubUser) throws {
        _ = try ownedConversation(conversationID, by: user)
        if try repository.loadAttachments(conversationID: conversationID).contains(where: { $0.id == attachment.id }) { return }
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let part = uploads.appendingPathComponent("\(attachment.id.uuidString).part")
        if offset == 0 {
            clearAbandonedUploads()
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.intValue ?? -1
        guard size == offset, offset + data.count <= attachment.byteCount else {
            throw LinkError("A piece of the file arrived out of order. Send the file again.")
        }
        let handle = try FileHandle(forWritingTo: part)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
        guard offset + data.count == attachment.byteCount else { return }
        defer { try? FileManager.default.removeItem(at: part) }
        let filename = URL(fileURLWithPath: attachment.filename).lastPathComponent
        let voice = attachment.voice.map {
            VoiceMessage(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform, localeIdentifier: $0.localeIdentifier)
        }
        _ = try repository.importAttachment(from: part, into: conversationID, mediaType: attachment.mediaType, voice: voice,
                                            id: attachment.id, originalFilename: filename.isEmpty ? "Attachment" : filename)
    }

    /// One piece of a conversation's file.
    public func chunk(of attachmentID: UUID, in conversationID: UUID, at offset: Int, for user: HubUser) throws -> (Data, Int) {
        _ = try ownedConversation(conversationID, by: user)
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
        let bots = try ownedConversation(conversationID, by: user).bots
        let files = try attachments(in: conversationID)
        if let existing = try repository.loadMessages(conversationID: conversationID).first(where: { $0.id == id }) {
            return linkMessage(existing, files: files)
        }
        guard attachmentIDs.allSatisfy({ files[$0] != nil }) else {
            throw LinkError("An attachment has not reached the Hub yet.")
        }
        for agent in bots {
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
        let message = try repository.sendUserMessage(conversationID: conversationID, body: body,
                                                     attachmentIDs: attachmentIDs, id: id)
        if running || watching { runtime.notify(bots, repository: repository) }
        checkForChanges()
        return linkMessage(message, files: files)
    }

    private func attachments(in conversationID: UUID) throws -> [UUID: ConversationAttachment] {
        Dictionary(try repository.loadAttachments(conversationID: conversationID).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Tells owners about conversations whose messages changed since the last check.
    public func checkForChanges() {
        guard let agents = try? repository.loadAgents(), let conversations = try? repository.loadConversations() else { return }
        for conversation in conversations {
            guard let owner = owner(of: conversation, among: agents) else { continue }
            let url = repository.conversationDirectory(id: conversation.id).appendingPathComponent("messages.json")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  let modified = attributes[.modificationDate] as? Date else { continue }
            if let known = transcripts[conversation.id], known.size == size, known.modified == modified { continue }
            guard let messages = try? repository.loadMessages(conversationID: conversation.id) else { continue }
            let latestReaction = messages.flatMap { $0.reactionChanges ?? [] }.map(\.sequence).max() ?? 0
            let known = transcripts[conversation.id]
            transcripts[conversation.id] = (size, modified, messages.count, latestReaction)
            if known.map({ $0.count != messages.count }) ?? true {
                onChange?(owner, .conversationChanged(conversationID: conversation.id, count: messages.count))
            }
            // Reactions change messages already sent, which a device reading on from its count would miss.
            if let known, latestReaction > known.reactions, let files = try? attachments(in: conversation.id) {
                for message in messages where (message.reactionChanges ?? []).contains(where: { $0.sequence > known.reactions }) {
                    onChange?(owner, .messageChanged(linkMessage(message, files: files)))
                }
            }
        }
        var restated: Set<UUID> = []
        for agent in agents {
            guard let owner = access.owner(ofBot: agent.id) else { continue }
            let phase = runtime.snapshot(for: agent.id).phase
            if let known = phases[agent.id], known != phase, let link = LinkBotPhase(rawValue: phase.rawValue) {
                onChange?(owner, .botPhase(botID: agent.id, phase: link))
            }
            phases[agent.id] = phase
            // A bot sets its status through Messenger; devices list the bots again to see it.
            if let known = statuses[agent.id], known != agent.status { restated.insert(owner) }
            statuses[agent.id] = .some(agent.status)
        }
        restated.forEach { onChange?($0, .botsChanged) }
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

    /// Deletes a bot, and any group left without bots. Returns whether it was in a group.
    private func remove(_ agent: AgentRecord) throws -> Bool {
        let joined = (try? repository.loadConversations().filter { $0.participantIDs.contains(agent.id) }) ?? []
        let conversations = joined.filter { $0.kind == .direct || $0.participantIDs == [agent.id] }.map(\.id)
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
        if conversations.contains(where: { readMarks[$0] != nil }) {
            conversations.forEach { readMarks[$0] = nil }
            try? saveReadMarks()
        }
        return joined.contains { $0.kind == .group }
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
        let (link, bot) = try await companionLink(attachmentID, in: conversationID, for: user)
        if case .noodlet(let noodlet) = link {
            var info = AppletRequest(.info)
            info.noodletID = noodlet
            info.owner = bot.uuidString.lowercased()
            info.includePreview = true
            let response = try await applets.companion(info)
            guard let title = response.title else { return nil }
            return LinkCardInfo(title: title, image: response.mediaType == "image/png" ? response.data : nil,
                                symbol: "square.grid.2x2")
        }
        guard let card = try attachments(in: conversationID)[attachmentID]?.card else { return nil }
        return LinkCardInfo(title: card.title, detail: card.detail, image: card.image, symbol: card.symbol,
                            colour: card.colour, icon: card.icon, capturedAt: card.capturedAt)
    }

    /// A conversation the user owns and its bots: one bot's own, or a group of theirs.
    private func ownedConversation(_ id: UUID, by user: HubUser) throws -> (conversation: BotConversation, bots: [AgentRecord]) {
        let agents = try repository.loadAgents()
        guard let conversation = try repository.loadConversations().first(where: { $0.id == id }),
              owner(of: conversation, among: agents) == user.id else {
            throw LinkError("There is no such conversation.")
        }
        return (conversation, conversation.participantIDs.compactMap { id in agents.first { $0.id == id } })
    }

    private func ownedGroup(_ id: UUID, by user: HubUser) throws -> BotConversation {
        guard let conversation = try? ownedConversation(id, by: user).conversation, conversation.kind == .group else {
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

    private func group(_ conversation: BotConversation) -> LinkGroup {
        LinkGroup(id: conversation.id,
                  draft: LinkGroupDraft(name: conversation.displayName, publicDescription: conversation.publicDescription ?? "",
                                        botIDs: conversation.participantIDs),
                  createdAt: conversation.createdAt, readUpTo: readMarks[conversation.id], archivedAt: conversation.archivedAt)
    }

    private func bot(_ agent: AgentRecord, conversations: [BotConversation]) throws -> LinkBot? {
        guard let conversation = conversations.first(where: { $0.kind == .direct && $0.participantIDs == [agent.id] }) else {
            return nil
        }
        var draft = LinkBotDraft(
            name: agent.displayName, provider: agent.harnessIdentifier ?? "", profile: try repository.loadAgentHarnessProfile(agent),
            model: agent.modelIdentifier, reasoningEffort: agent.reasoningEffort, publicDescription: agent.publicDescription ?? "",
            backstory: try repository.loadAgentBackstory(agent), avatarSymbolName: agent.avatarSymbolName,
            avatarColorIndex: agent.avatarColorIndex ?? agent.accentSeed, avatarImageData: agent.avatarImageData)
        draft.avatarImageDigest = agent.avatarImageData.map(LinkPicture.digest)
        return LinkBot(id: agent.id, conversationID: conversation.id, draft: draft, createdAt: agent.createdAt,
                       phase: LinkBotPhase(rawValue: runtime.snapshot(for: agent.id).phase.rawValue), readUpTo: readMarks[conversation.id],
                       status: agent.status, archivedAt: agent.archivedAt)
    }

    /// Pictures' sizes, read once each: a stored file never changes.
    private var pixelSizes: [UUID: LinkPixelSize?] = [:]

    private func pixelSize(of file: ConversationAttachment) -> LinkPixelSize? {
        guard file.mediaType.hasPrefix("image/") else { return nil }
        if let known = pixelSizes[file.id] { return known }
        let size = LinkPixelSize(pictureAt: repository.attachmentFileURL(file))
        pixelSizes[file.id] = size
        return size
    }

    private func linkMessage(_ message: ChatMessage, files: [UUID: ConversationAttachment], pictures: Bool = true) -> LinkMessage {
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
                           pixelSize: pixelSize(of: $0))
        }
        let reactions = (message.reactions ?? []).compactMap { reaction -> LinkReaction? in
            switch reaction.author {
            case .user: LinkReaction(author: .you, emoji: reaction.emoji)
            case .agent(let id): LinkReaction(author: .bot(id), emoji: reaction.emoji)
            case .system: nil
            }
        }
        return LinkMessage(id: message.id, conversationID: message.conversationID, author: author, body: message.body,
                           createdAt: message.createdAt, delivered: message.delivery == .delivered, attachments: attachments,
                           reactions: reactions)
    }
}
