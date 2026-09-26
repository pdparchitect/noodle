import BrowserBridge
import Foundation
import HubLink
import NoodleCore
import NoodleRuntime

/// Bots paired devices keep on the Hub. Each belongs to one user, runs on a harness that
/// user's plan lends, and talks only with that user.
@MainActor public final class HubBots {
    /// Where an owner's devices are told that something changed.
    public var onChange: ((_ user: UUID, LinkEvent) -> Void)?

    private let repository: WorkspaceRepository
    private let runtime: AgentRuntimeCoordinator
    private let access: HubAccess
    private let connections: HubConnections
    private let computers: HubComputers
    private let browsers: HubBrowsers
    /// Serves bots the tools their owners assigned them from the Hub's own connections.
    private var toolBroker: ToolBridgeBroker?
    private let messenger: MessengerBroker
    /// Files arriving in pieces, until the last one lands.
    private let uploads: URL
    private var running = false
    private var loop: Task<Void, Never>?
    /// The last seen size and date of each conversation's messages, their count, and the latest reaction change.
    private var transcripts: [UUID: (size: Int, modified: Date, count: Int, reactions: Int)] = [:]
    /// What each bot was last reported doing.
    private var phases: [UUID: AgentRuntimePhase] = [:]

    public init(repository: WorkspaceRepository, runtime: AgentRuntimeCoordinator, access: HubAccess,
                connections: HubConnections, computers: HubComputers, browsers: HubBrowsers, uploads: URL) {
        self.uploads = uploads
        self.repository = repository
        self.runtime = runtime
        self.access = access
        self.connections = connections
        self.computers = computers
        self.browsers = browsers
        messenger = MessengerBroker(repository: repository)
        connections.onAssignmentsChange = { [weak self] in self?.toolBroker?.synchronizeSkills() }
        computers.onAssignmentsChange = { [weak self] in self?.toolBroker?.synchronizeSkills() }
        browsers.onAssignmentsChange = { [weak self] in self?.toolBroker?.synchronizeSkills() }
    }

    /// Runs every bot, the messenger they reply through, and the checks that keep them going.
    public func start() throws {
        guard !running else { return }
        try repository.prepare()
        let agents = try repository.loadAgents()
        try repository.synchronizeAgentWorkspaces(agents)
        try messenger.start(agents: agents)
        let now = Date()
        agents.forEach { runtime.seedHeartbeatActivity(for: $0.id, at: now) }
        runtime.startAll(agents: agents, repository: repository)
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

    public func stop() {
        toolBroker?.stop()
        toolBroker = nil
        loop?.cancel()
        loop = nil
        messenger.stop()
        runtime.stopAll()
        running = false
    }

    public func bots(for user: HubUser) throws -> [LinkBot] {
        let conversations = try repository.loadConversations()
        return try repository.loadAgents()
            .filter { access.owner(ofBot: $0.id) == user.id }
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
        onChange?(user.id, .botsChanged)
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
            avatarImageData: draft.avatarImageData)
        try repository.updateAgentBackstory(updated, backstory: draft.backstory)
        try repository.updateAgentHarnessProfile(updated, profile: draft.profile)
        if running { runtime.restart(agent: updated, repository: repository) }
        onChange?(user.id, .botsChanged)
        return try bot(updated, conversations: try repository.loadConversations()) ?? {
            throw LinkError("The bot was saved but could not be read back.")
        }()
    }

    public func delete(_ id: UUID, for user: HubUser) throws {
        try remove(try owned(id, by: user))
        onChange?(user.id, .botsChanged)
    }

    /// Deletes every bot of a user who is being removed.
    public func removeBots(of user: HubUser) {
        for agent in (try? repository.loadAgents()) ?? [] where access.owner(ofBot: agent.id) == user.id {
            try? remove(agent)
        }
    }

    public func messages(in conversationID: UUID, after position: Int, for user: HubUser) throws -> LinkMessages {
        _ = try ownedConversation(conversationID, by: user)
        let messages = try repository.loadMessages(conversationID: conversationID)
        let files = try attachments(in: conversationID)
        return LinkMessages(messages: messages.dropFirst(max(0, position)).map { Self.message($0, files: files) },
                            count: messages.count)
    }

    /// Keeps one piece of a file; the file joins the conversation when its last piece lands.
    public func receive(_ data: Data, at offset: Int, of attachment: LinkAttachment, in conversationID: UUID,
                        for user: HubUser) throws {
        _ = try ownedConversation(conversationID, by: user)
        if try repository.loadAttachments(conversationID: conversationID).contains(where: { $0.id == attachment.id }) { return }
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let part = uploads.appendingPathComponent("\(attachment.id.uuidString).part")
        if offset == 0 { FileManager.default.createFile(atPath: part.path, contents: nil) }
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
        let agent = try ownedConversation(conversationID, by: user)
        let files = try attachments(in: conversationID)
        if let existing = try repository.loadMessages(conversationID: conversationID).first(where: { $0.id == id }) {
            return Self.message(existing, files: files)
        }
        guard attachmentIDs.allSatisfy({ files[$0] != nil }) else {
            throw LinkError("An attachment has not reached the Hub yet.")
        }
        let profile = try repository.loadAgentHarnessProfile(agent)
        guard let provider = agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:)),
              lends(HubHarness(provider: provider, profile: profile), to: user) else {
            let name = agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:))?.displayName ?? "this harness"
            throw LinkError("Your plan no longer lends \(name).")
        }
        let message = try repository.sendUserMessage(conversationID: conversationID, body: body,
                                                     attachmentIDs: attachmentIDs, id: id)
        if running { runtime.notify([agent], repository: repository) }
        checkForChanges()
        return Self.message(message, files: files)
    }

    private func attachments(in conversationID: UUID) throws -> [UUID: ConversationAttachment] {
        Dictionary(try repository.loadAttachments(conversationID: conversationID).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Tells owners about conversations whose messages changed since the last check.
    public func checkForChanges() {
        guard let agents = try? repository.loadAgents(), let conversations = try? repository.loadConversations() else { return }
        for conversation in conversations where conversation.kind == .direct {
            guard let bot = conversation.participantIDs.first, agents.contains(where: { $0.id == bot }),
                  let owner = access.owner(ofBot: bot) else { continue }
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
                    onChange?(owner, .messageChanged(Self.message(message, files: files)))
                }
            }
        }
        for agent in agents {
            guard let owner = access.owner(ofBot: agent.id) else { continue }
            let phase = runtime.snapshot(for: agent.id).phase
            if let known = phases[agent.id], known != phase, let link = LinkBotPhase(rawValue: phase.rawValue) {
                onChange?(owner, .botPhase(botID: agent.id, phase: link))
            }
            phases[agent.id] = phase
        }
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
        return Self.message(message, files: try attachments(in: change.conversationID))
    }

    private func remove(_ agent: AgentRecord) throws {
        if running { runtime.stop(agentID: agent.id, revokeAccess: false) }
        try repository.deleteAgent(agent)
        if running {
            runtime.stop(agentID: agent.id)
            try? messenger.start(agents: try repository.loadAgents())
        }
        if toolBroker != nil { try? startTools() }
        connections.forget(bot: agent.id)
        computers.forget(bot: agent.id)
        browsers.forget(bot: agent.id)
        access.setOwner(nil, ofBot: agent.id)
    }

    /// Reads the user's current plan, not the one they were on when `user` was read.
    private func lends(_ harness: HubHarness, to user: HubUser) -> Bool {
        guard let current = access.users.first(where: { $0.id == user.id }) else { return false }
        return access.harnesses(for: current).contains(harness)
    }

    private func lent(_ draft: LinkBotDraft, to user: HubUser, verb: String) throws -> HarnessProvider {
        guard let provider = HarnessProvider(rawValue: draft.provider) else {
            throw LinkError("This Noodle Hub does not know the harness \(draft.provider).")
        }
        guard lends(HubHarness(provider: provider, profile: draft.profile), to: user) else {
            throw LinkError("Your plan \(verb) \(provider.displayName).")
        }
        return provider
    }

    private func owned(_ id: UUID, by user: HubUser) throws -> AgentRecord {
        guard access.owner(ofBot: id) == user.id, let agent = try repository.loadAgents().first(where: { $0.id == id }) else {
            throw LinkError("There is no such bot.")
        }
        return agent
    }

    /// The bot of a direct conversation the user owns.
    /// A card a message in one of the user's conversations carries.
    public func card(_ attachmentID: UUID, in conversationID: UUID, for user: HubUser) throws -> ConversationAttachment {
        _ = try ownedConversation(conversationID, by: user)
        guard let card = try attachments(in: conversationID)[attachmentID], card.browser != nil || card.computer != nil else {
            throw LinkError("That is not a browser or computer card in this conversation.")
        }
        return card
    }

    private func ownedConversation(_ id: UUID, by user: HubUser) throws -> AgentRecord {
        guard let conversation = try repository.loadConversations().first(where: { $0.id == id }),
              conversation.kind == .direct, let bot = conversation.participantIDs.first else {
            throw LinkError("There is no such conversation.")
        }
        do { return try owned(bot, by: user) }
        catch { throw LinkError("There is no such conversation.") }
    }

    private func bot(_ agent: AgentRecord, conversations: [BotConversation]) throws -> LinkBot? {
        guard let conversation = conversations.first(where: { $0.kind == .direct && $0.participantIDs == [agent.id] }) else {
            return nil
        }
        let draft = LinkBotDraft(
            name: agent.displayName, provider: agent.harnessIdentifier ?? "", profile: try repository.loadAgentHarnessProfile(agent),
            model: agent.modelIdentifier, reasoningEffort: agent.reasoningEffort, publicDescription: agent.publicDescription ?? "",
            backstory: try repository.loadAgentBackstory(agent), avatarSymbolName: agent.avatarSymbolName,
            avatarColorIndex: agent.avatarColorIndex ?? agent.accentSeed, avatarImageData: agent.avatarImageData)
        return LinkBot(id: agent.id, conversationID: conversation.id, draft: draft, createdAt: agent.createdAt,
                       phase: LinkBotPhase(rawValue: runtime.snapshot(for: agent.id).phase.rawValue))
    }

    private static func message(_ message: ChatMessage, files: [UUID: ConversationAttachment]) -> LinkMessage {
        let author: LinkMessage.Author = switch message.author {
        case .user: .you
        case .agent(let id): .bot(id)
        case .system: .system
        }
        let attachments = (message.attachmentIDs ?? []).compactMap { files[$0] }.map {
            LinkAttachment(id: $0.id, filename: $0.originalFilename, mediaType: $0.mediaType, byteCount: Int($0.byteCount),
                           voice: $0.voice.map { LinkVoice(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform,
                                                           localeIdentifier: $0.localeIdentifier) })
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
