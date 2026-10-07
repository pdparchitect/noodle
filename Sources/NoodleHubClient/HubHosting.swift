import Foundation
import HubLink
import NoodleCore
import Observation

/// This Mac's own bots, shared through a Noodle Hub with people who talk to them there. The Hub keeps
/// each person's conversation; this Mac keeps a copy under the Hub's IDs, so the bot reads and answers
/// it like any other, and the people see it online only while this Mac is connected.
@MainActor @Observable public final class HubHosting {
    /// One bot shared from here.
    struct Entry: Codable, Equatable {
        var agent: UUID
        /// What the Hub was last told of it, so a change here is sent once.
        var published: Profile?
        var archived: Bool
        var sharedWith: [UUID]
        /// Their names, as the Hub last gave them.
        var sharedNames: [String]?
        var threads: [Thread]
    }

    /// The name, description and picture people see.
    struct Profile: Codable, Equatable {
        var name: String
        var publicDescription: String
        var avatarSymbolName: String?
        var avatarColorIndex: Int?
        var avatarImageDigest: String?

        init(_ agent: AgentRecord) {
            name = agent.displayName
            publicDescription = agent.publicDescription ?? ""
            avatarSymbolName = agent.avatarSymbolName
            avatarColorIndex = agent.avatarColorIndex ?? agent.accentSeed
            avatarImageDigest = agent.avatarImageData.map(LinkPicture.digest)
        }
    }

    /// One person's conversation with the bot, kept here under the Hub's ID.
    struct Thread: Codable, Equatable {
        var conversation: UUID
        /// How many of the Hub's messages are copied here.
        var synced: Int
        /// The bot's messages after this are not on the Hub yet.
        var postedUpTo: Date
    }

    public private(set) var error: String?
    /// Runs with the bots that have new messages to read.
    @ObservationIgnored public var onMessages: (([UUID]) -> Void)?
    /// What a bot is doing here, for the people it is shared with.
    @ObservationIgnored public var phase: (UUID) -> AgentRuntimePhase? = { _ in nil }
    /// Runs when the bots shared from here, or whom with, changed.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Whether the Hub is being followed, which `run` waits for.
    @ObservationIgnored public var isConnected = false {
        didSet {
            guard isConnected != oldValue else { return }
            // What the Hub showed while this Mac was away is told again.
            reported = [:]
            if isConnected { needsFullSync = true }
        }
    }

    @ObservationIgnored private let pairing: HubPairing
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let url: URL
    private var entries: [Entry] = []
    /// The person's messages the Hub still shows as not taken, by conversation.
    @ObservationIgnored private var waiting: [UUID: Set<UUID>] = [:]
    /// What each bot was last said to be doing.
    @ObservationIgnored private var reported: [UUID: LinkBotPhase] = [:]
    @ObservationIgnored private var needsFullSync = true
    @ObservationIgnored private var botsChanged = true
    @ObservationIgnored private var changedConversations: Set<UUID> = []
    /// The work in progress, so the next waits for it: each reads and writes the copies here.
    @ObservationIgnored private var queue: Task<Void, Never>?

    public init(pairing: HubPairing, repository: WorkspaceRepository, directory: URL) {
        self.pairing = pairing
        self.repository = repository
        url = directory.appendingPathComponent("hosted.json")
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
    }

    public var hostedAgentIDs: Set<UUID> { Set(entries.map(\.agent)) }

    /// Whom a bot here is shared with on the Hub.
    public func sharedWith(agent id: UUID) -> [UUID] { entries.first { $0.agent == id }?.sharedWith ?? [] }

    /// The names of the people a bot here is shared with on the Hub.
    public func sharedNames(agent id: UUID) -> [String] { entries.first { $0.agent == id }?.sharedNames ?? [] }

    /// Whether a conversation here is the copy of one on this Hub.
    public func owns(conversation id: UUID) -> Bool { entries.contains { $0.threads.contains { $0.conversation == id } } }

    /// Shares a bot here with exactly `people` on the Hub; with nobody, the Hub keeps nothing of it.
    public func share(_ agent: AgentRecord, with people: [UUID]) async throws {
        try await serially {
            if people.isEmpty {
                try await self.unpublish(agent.id)
            } else {
                try await self.publish(agent)
                guard case .bot(let bot) = try await self.pairing.request(.shareBot(id: agent.id, people: people)) else {
                    throw LinkError("The Hub sent an unexpected answer.")
                }
                self.update(agent.id) { $0.sharedWith = bot.sharedWith }
                try await self.syncBots()
            }
            self.onChange?()
        }
    }

    /// Follows what the Hub pushes: whom the bots are shared with, and new messages.
    public func heard(_ event: LinkEvent) {
        switch event {
        case .botsChanged: botsChanged = true
        case .conversationChanged(let id, _) where owns(conversation: id): changedConversations.insert(id)
        default: break
        }
    }

    /// Everything again: the bots, each conversation, and what waits here for the Hub.
    public func sync() async {
        needsFullSync = true
        await step()
    }

    /// What changed since the last step, both ways.
    public func step() async {
        try? await serially { await self.work() }
    }

    /// Takes part while the Hub is followed, until cancelled.
    public func run() async {
        while !Task.isCancelled {
            if isConnected { await step() }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Deletes the copies here, as when leaving the Hub, which drops the bots with this Mac.
    public func forgetLocalCopies() {
        for entry in entries { deleteCopies(of: entry) }
        entries = []
        try? FileManager.default.removeItem(at: url)
        onChange?()
    }

    private func work() async {
        let full = needsFullSync
        let bots = full || botsChanged
        let conversations = full ? Set(entries.flatMap { $0.threads.map(\.conversation) }) : changedConversations
        needsFullSync = false
        botsChanged = false
        changedConversations = []
        do {
            try await removeDeletedHere()
            if bots { try await syncBots() }
            // Conversations new to this Mac are read in full.
            let read = full || bots ? Set(entries.flatMap { $0.threads.map(\.conversation) }) : conversations
            for id in read { try await syncMessages(id) }
            try await publishChanges()
            try await sendReplies()
            try await sendDelivered()
            try await sendPhases()
            error = nil
        } catch {
            needsFullSync = needsFullSync || full
            botsChanged = botsChanged || bots
            changedConversations.formUnion(conversations)
            self.error = error.localizedDescription
        }
    }

    private func serially<T>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queue
        let task = Task { @MainActor in
            await previous?.value
            return try await body()
        }
        queue = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: Bots

    private func draft(_ agent: AgentRecord) -> LinkBotDraft {
        var draft = LinkBotDraft(name: agent.displayName, provider: "", publicDescription: agent.publicDescription ?? "",
                                 avatarSymbolName: agent.avatarSymbolName, avatarColorIndex: agent.avatarColorIndex ?? agent.accentSeed,
                                 avatarImageData: agent.avatarImageData)
        draft.avatarImageDigest = agent.avatarImageData.map(LinkPicture.digest)
        return draft
    }

    private func publish(_ agent: AgentRecord) async throws {
        guard case .hostedBot = try await pairing.request(.host(.publish(id: agent.id, draft(agent)))) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        if !entries.contains(where: { $0.agent == agent.id }) {
            entries.append(Entry(agent: agent.id, archived: false, sharedWith: [], threads: []))
        }
        update(agent.id) { $0.published = Profile(agent) }
        try await sendArchived(agent)
    }

    private func sendArchived(_ agent: AgentRecord) async throws {
        let archived = agent.archivedAt != nil
        guard let entry = entries.first(where: { $0.agent == agent.id }), entry.archived != archived else { return }
        _ = try await pairing.request(.archive(LinkArchiveChange(id: agent.id, archived: archived)))
        update(agent.id) { $0.archived = archived }
    }

    /// Takes a bot off the Hub, with its conversations there and here.
    private func unpublish(_ id: UUID) async throws {
        do {
            _ = try await pairing.request(.deleteBot(id: id))
        } catch let failure as LinkError where failure.message == "There is no such bot." {
            // Already gone from the Hub.
        }
        if let entry = entries.first(where: { $0.agent == id }) { forget(entry) }
    }

    /// Bots deleted here leave the Hub too.
    private func removeDeletedHere() async throws {
        let agents = Set(try repository.loadAgents().map(\.id))
        for entry in entries where !agents.contains(entry.agent) {
            try await unpublish(entry.agent)
            onChange?()
        }
    }

    /// Makes the copies here match the Hub: a conversation for each person a bot is shared with.
    private func syncBots() async throws {
        guard case .hostedBots(let bots) = try await pairing.request(.host(.bots)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        let agents = try repository.loadAgents()
        var changed = false
        for bot in bots {
            guard let agent = agents.first(where: { $0.id == bot.id }) else {
                // Deleted here while the Hub was away.
                try await unpublish(bot.id)
                continue
            }
            if !entries.contains(where: { $0.agent == bot.id }) {
                entries.append(Entry(agent: bot.id, archived: agent.archivedAt != nil, sharedWith: [], threads: []))
            }
            let conversations = try repository.loadConversations()
            for guest in bot.conversations {
                if var copy = conversations.first(where: { $0.id == guest.id }) {
                    // So the bot knows the person by their current name.
                    if copy.guest?.name != guest.name {
                        copy.guest = ConversationGuest(id: guest.person, name: guest.name)
                        try repository.updateConversation(copy)
                    }
                } else {
                    _ = try repository.createGuestConversation(with: agent, guest: ConversationGuest(id: guest.person, name: guest.name),
                                                               id: guest.id)
                }
                if !(entries.first { $0.agent == bot.id }?.threads.contains { $0.conversation == guest.id } ?? false) {
                    update(bot.id) { $0.threads.append(Thread(conversation: guest.id, synced: 0, postedUpTo: .distantPast)) }
                    changed = true
                }
            }
            let kept = Set(bot.conversations.map(\.id))
            for thread in entries.first(where: { $0.agent == bot.id })?.threads ?? [] where !kept.contains(thread.conversation) {
                deleteCopy(thread.conversation)
                update(bot.id) { $0.threads.removeAll { $0.conversation == thread.conversation } }
                changed = true
            }
            let people = bot.conversations.map(\.person), names = bot.conversations.map(\.name).sorted()
            if Set(people) != Set(entries.first { $0.agent == bot.id }?.sharedWith ?? []) {
                update(bot.id) { $0.sharedWith = people }
                changed = true
            }
            if names != entries.first(where: { $0.agent == bot.id })?.sharedNames {
                update(bot.id) { $0.sharedNames = names }
                changed = true
            }
        }
        for entry in entries where !bots.contains(where: { $0.id == entry.agent }) {
            forget(entry)
            changed = true
        }
        if changed { onChange?() }
    }

    /// Sends a new name, description or picture, and whether the bot is archived.
    private func publishChanges() async throws {
        let agents = try repository.loadAgents()
        for entry in entries {
            guard let agent = agents.first(where: { $0.id == entry.agent }) else { continue }
            if entry.published != Profile(agent) { try await publish(agent) }
            try await sendArchived(agent)
        }
    }

    private func sendPhases() async throws {
        for entry in entries where !entry.archived {
            guard let phase = phase(entry.agent).flatMap({ LinkBotPhase(rawValue: $0.rawValue) }), reported[entry.agent] != phase else {
                continue
            }
            _ = try await pairing.request(.host(.phase(botID: entry.agent, phase: phase)))
            reported[entry.agent] = phase
        }
    }

    // MARK: Messages

    private func thread(_ conversation: UUID) -> (agent: UUID, thread: Thread)? {
        for entry in entries {
            if let thread = entry.threads.first(where: { $0.conversation == conversation }) { return (entry.agent, thread) }
        }
        return nil
    }

    /// Copies what the person wrote, a page at a time, and wakes the bot for it.
    private func syncMessages(_ conversation: UUID) async throws {
        var woke = false
        while let found = thread(conversation) {
            let agent = found.agent, thread = found.thread
            guard case .messages(let page) = try await pairing.request(.host(.messagePage(LinkMessagePage(
                conversationID: conversation, after: thread.synced, limit: 100)))) else {
                throw LinkError("The Hub sent an unexpected answer.")
            }
            var known = Set(try repository.loadMessages(conversationID: conversation).map(\.id))
            for message in page.messages {
                if message.author == .you, !message.delivered { waiting[conversation, default: []].insert(message.id) }
                if message.author == .you, message.delivered { waiting[conversation]?.remove(message.id) }
                guard !known.contains(message.id), message.call == nil else { continue }
                try await fetchMissing(message.attachments, in: conversation)
                let author: MessageAuthor = switch message.author {
                case .you: .user
                // Its own, from before this Mac lost its copy.
                case .bot: .agent(agent)
                case .system: .system
                }
                try repository.append(ChatMessage(id: message.id, conversationID: conversation, author: author, body: message.body,
                                                  createdAt: message.createdAt,
                                                  delivery: message.author == .you && !message.delivered ? .queued : .delivered,
                                                  attachmentIDs: message.attachments.map(\.id)))
                known.insert(message.id)
                if message.author == .you { woke = true }
            }
            if let latest = page.messages.last?.createdAt, var copy = try repository.loadConversations().first(where: { $0.id == conversation }) {
                copy.updatedAt = max(copy.updatedAt, latest)
                try repository.updateConversation(copy)
            }
            // Until the bot takes it, the person's message is read again, so the Hub hears once it is taken.
            let pendingFrom = page.messages.firstIndex { $0.author == .you && !$0.delivered }
            let synced = pendingFrom.map { thread.synced + $0 } ?? thread.synced + page.messages.count
            setThread(conversation) { $0.synced = synced }
            guard page.messages.count > 0, synced > thread.synced, synced < page.count else { break }
        }
        if woke, let agent = thread(conversation)?.agent { onMessages?([agent]) }
    }

    /// Downloads the files of the person's message that this copy lacks, keeping their IDs.
    private func fetchMissing(_ attachments: [LinkAttachment], in conversation: UUID) async throws {
        guard !attachments.isEmpty else { return }
        let present = Set(try repository.loadAttachments(conversationID: conversation).map(\.id))
        for attachment in attachments where !present.contains(attachment.id) {
            if let url = attachment.url {
                _ = try repository.importLinkAttachment(url, into: conversation, id: attachment.id)
                continue
            }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hosted-\(attachment.id.uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try await pairing.download(attachment, fromHosted: conversation, to: staging)
            let name = URL(fileURLWithPath: attachment.filename).lastPathComponent
            let voice = attachment.voice.map {
                VoiceMessage(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform, localeIdentifier: $0.localeIdentifier)
            }
            _ = try repository.importAttachment(from: staging, into: conversation, mediaType: attachment.mediaType, voice: voice,
                                                id: attachment.id, originalFilename: name.isEmpty ? "Attachment" : name)
        }
    }

    /// Sends the bot's new messages, with their files, in order.
    private func sendReplies() async throws {
        // The Hub takes nothing from an archived bot; what it wrote meanwhile goes once it is back.
        for entry in entries where !entry.archived {
            for thread in entry.threads {
                let messages = try repository.loadMessages(conversationID: thread.conversation)
                    .filter { $0.author == .agent(entry.agent) && $0.createdAt > thread.postedUpTo }
                guard !messages.isEmpty else { continue }
                let files = Dictionary(try repository.loadAttachments(conversationID: thread.conversation).map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
                for message in messages {
                    var attachmentIDs: [UUID] = [], links: [LinkAttachment] = [], keptHere: [String] = []
                    for id in message.attachmentIDs ?? [] {
                        guard let file = files[id] else { continue }
                        let attachment = LinkAttachment(
                            id: file.id, filename: file.originalFilename, mediaType: file.mediaType, byteCount: Int(file.byteCount),
                            voice: file.voice.map { LinkVoice(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform,
                                                              localeIdentifier: $0.localeIdentifier) },
                            url: file.url)
                        if let url = file.url {
                            // What opens live opens on this Mac's companions, which people on the Hub cannot reach.
                            if CompanionLink(url) == nil { links.append(attachment) } else { keptHere.append(liveName(file)) }
                        } else {
                            try await pairing.upload(repository.attachmentFileURL(file), as: attachment, toHosted: thread.conversation)
                            attachmentIDs.append(file.id)
                        }
                    }
                    // So the person knows what the bot shared that only its owner can open.
                    let owner = pairing.hub?.userName ?? "its owner"
                    let body = ([message.body] + keptHere.map { "\($0) opens only on \(owner)'s Mac." }).joined(separator: "\n\n")
                    _ = try await pairing.request(.host(.reply(LinkHostedReply(
                        conversationID: thread.conversation, id: message.id, body: body, attachmentIDs: attachmentIDs, links: links))))
                    setThread(thread.conversation) { $0.postedUpTo = message.createdAt }
                }
            }
        }
    }

    /// What a live link is called: its card's title, or else the kind of thing it opens.
    private func liveName(_ file: ConversationAttachment) -> String {
        if let title = file.card?.title, !title.isEmpty { return title }
        let name = (file.originalFilename as NSString).deletingPathExtension
        return name.isEmpty ? "A live link" : name
    }

    /// Tells the Hub which of the person's messages the bot has taken.
    private func sendDelivered() async throws {
        for (conversation, ids) in waiting where !ids.isEmpty {
            let taken = try repository.loadMessages(conversationID: conversation)
                .filter { ids.contains($0.id) && $0.author == .user && $0.delivery == .delivered }.map(\.id)
            guard !taken.isEmpty else { continue }
            _ = try await pairing.request(.host(.delivered(conversationID: conversation, messageIDs: taken)))
            waiting[conversation]?.subtract(taken)
        }
    }

    // MARK: Storage

    private func update(_ agent: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.agent == agent }) else { return }
        let before = entries[index]
        change(&entries[index])
        if entries[index] != before { save() }
    }

    private func setThread(_ conversation: UUID, _ change: (inout Thread) -> Void) {
        guard let index = entries.firstIndex(where: { $0.threads.contains { $0.conversation == conversation } }),
              let thread = entries[index].threads.firstIndex(where: { $0.conversation == conversation }) else { return }
        let before = entries[index]
        change(&entries[index].threads[thread])
        if entries[index] != before { save() }
    }

    private func forget(_ entry: Entry) {
        deleteCopies(of: entry)
        entries.removeAll { $0.agent == entry.agent }
        reported[entry.agent] = nil
        save()
    }

    private func deleteCopies(of entry: Entry) {
        entry.threads.forEach { deleteCopy($0.conversation) }
    }

    private func deleteCopy(_ conversation: UUID) {
        waiting[conversation] = nil
        if FileManager.default.fileExists(atPath: repository.conversationDirectory(id: conversation).path) {
            try? repository.deleteConversation(id: conversation)
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
