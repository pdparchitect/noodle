import Foundation
import HubLink
import NoodleCore
import NoodleRuntime

/// Bots paired devices keep on the Hub. Each belongs to one user, runs on a harness that
/// user's plan lends, and talks only with that user.
@MainActor public final class HubBots {
    /// Where an owner's devices are told that something changed.
    public var onChange: ((_ user: UUID, LinkEvent) -> Void)?
    /// Pushes an event to one device; false when that device has no open stream.
    public var sendToDevice: ((LinkPublicKey, LinkEvent) -> Bool)?

    private let repository: WorkspaceRepository
    private let runtime: AgentRuntimeCoordinator
    private let access: HubAccess
    private let messenger: MessengerBroker
    /// Files arriving in pieces, until the last one lands.
    private let uploads: URL
    /// Takes each bot's tool calls and relays them to the device lending the tools.
    private var toolBroker: ToolBridgeBroker?
    /// The device whose tools each bot uses: the last to publish them.
    private var toolDevices: [UUID: LinkPublicKey] = [:]
    /// Tool calls waiting for their device to answer.
    private var toolCalls: [UUID: (device: LinkPublicKey, reply: CheckedContinuation<Data, Error>)] = [:]
    private var running = false
    private var loop: Task<Void, Never>?
    /// The last seen size and date of each conversation's messages, and their count.
    private var transcripts: [UUID: (size: Int, modified: Date, count: Int)] = [:]

    public init(repository: WorkspaceRepository, runtime: AgentRuntimeCoordinator, access: HubAccess, uploads: URL) {
        self.uploads = uploads
        self.repository = repository
        self.runtime = runtime
        self.access = access
        messenger = MessengerBroker(repository: repository)
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

    /// Lets bots call the tools their owners' devices lend them.
    public func startTools() throws {
        if toolBroker == nil {
            toolBroker = ToolBridgeBroker { [weak self] request, bot in
                guard let self else { throw LinkError("Noodle Hub is stopping.") }
                return try await self.relay(request, for: bot)
            }
        }
        try toolBroker?.start(agents: try repository.loadAgents().map {
            ToolBridgeAgent(id: $0.id, workspace: repository.directory(for: $0))
        })
    }

    public func stop() {
        toolBroker?.stop()
        toolBroker = nil
        for (id, call) in toolCalls { call.reply.resume(throwing: LinkError("Noodle Hub stopped during the tool call. Verify any action before retrying.")); toolCalls[id] = nil }
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
        _ = try repository.importAttachment(from: part, into: conversationID, mediaType: attachment.mediaType,
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
            guard let count = try? repository.loadMessages(conversationID: conversation.id).count else { continue }
            let changed = transcripts[conversation.id].map { $0.count != count } ?? true
            transcripts[conversation.id] = (size, modified, count)
            if changed { onChange?(owner, .conversationChanged(conversationID: conversation.id, count: count)) }
        }
    }

    /// Writes the skills for the tools a device lends one of its user's bots.
    public func publishTools(_ catalogue: Data, for botID: UUID, from device: LinkPublicKey, for user: HubUser) throws {
        let agent = try owned(botID, by: user)
        let listings = try JSONDecoder().decode([ToolProviderListing].self, from: catalogue)
        ToolProviderListing.synchronize(workspace: repository.directory(for: agent), listings: listings)
        try repository.synchronizeAgentWorkspace(agent)
        toolDevices[botID] = device
    }

    /// The answer to a tool call, from the device it was sent to.
    public func finishToolCall(_ id: UUID, result: Data?, error: String?, from device: LinkPublicKey) {
        guard let call = toolCalls[id], call.device == device else { return }
        toolCalls[id] = nil
        if let result { call.reply.resume(returning: result) }
        else { call.reply.resume(throwing: LinkError(error ?? "The tool returned nothing.")) }
    }

    /// Fails the calls a device can no longer answer.
    public func deviceDisconnected(_ device: LinkPublicKey) {
        let name = access.device(for: device)?.name ?? "The device"
        for (id, call) in toolCalls where call.device == device {
            toolCalls[id] = nil
            call.reply.resume(throwing: LinkError("\(name) disconnected during the tool call. Verify any action before retrying."))
        }
    }

    private func relay(_ request: ToolBridgeRequest, for bot: UUID) async throws -> Data {
        guard let device = toolDevices[bot] else {
            throw LinkError("No Mac lends tools to this bot. Open Noodle on the Mac that keeps it.")
        }
        let name = access.device(for: device)?.name ?? "The Mac"
        let payload = try JSONEncoder().encode(request)
        let id = UUID()
        return try await withCheckedThrowingContinuation { reply in
            toolCalls[id] = (device, reply)
            guard sendToDevice?(device, .toolCall(callID: id, botID: bot, request: payload)) == true else {
                toolCalls[id] = nil
                reply.resume(throwing: LinkError("\(name) is not connected to this Hub, so its tools are unavailable."))
                return
            }
        }
    }

    private func remove(_ agent: AgentRecord) throws {
        if running { runtime.stop(agentID: agent.id, revokeAccess: false) }
        try repository.deleteAgent(agent)
        if running {
            runtime.stop(agentID: agent.id)
            try? messenger.start(agents: try repository.loadAgents())
        }
        if toolBroker != nil { try? startTools() }
        toolDevices[agent.id] = nil
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
        return LinkBot(id: agent.id, conversationID: conversation.id, draft: draft, createdAt: agent.createdAt)
    }

    private static func message(_ message: ChatMessage, files: [UUID: ConversationAttachment]) -> LinkMessage {
        let author: LinkMessage.Author = switch message.author {
        case .user: .you
        case .agent(let id): .bot(id)
        case .system: .system
        }
        let attachments = (message.attachmentIDs ?? []).compactMap { files[$0] }.map {
            LinkAttachment(id: $0.id, filename: $0.originalFilename, mediaType: $0.mediaType, byteCount: Int($0.byteCount))
        }
        return LinkMessage(id: message.id, conversationID: message.conversationID, author: author, body: message.body,
                           createdAt: message.createdAt, delivered: message.delivery == .delivered, attachments: attachments)
    }
}
