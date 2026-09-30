import Foundation
import HubLink
import NoodleCore
import Observation

/// This Mac's copy of the bots it keeps on one Noodle Hub. The Hub runs the bots and holds
/// their conversations; the copy lets Noodle show and send like any other bot. Message IDs
/// are the Hub's, so nothing is doubled however often the two are compared.
@MainActor @Observable public final class HubMirror {
    /// One bot on the Hub and its local stand-in.
    struct Entry: Codable, Equatable {
        var remote: UUID
        var remoteConversation: UUID
        var agent: UUID
        var conversation: UUID
        /// How many of the Hub's messages this copy has.
        var synced: Int
        /// The Hub's profile for the harness, which means nothing on this Mac.
        var profile: UUID?
    }

    /// A group of bots on the Hub and its local copy.
    struct GroupEntry: Codable, Equatable {
        var remote: UUID
        var conversation: UUID
        var synced: Int
    }

    /// A conversation on the Hub, a bot's own or a group's, and its local copy.
    private struct Thread {
        var remote: UUID
        var local: UUID
        var synced: Int
    }

    public private(set) var isConnected = false
    public private(set) var error: String?
    /// Runs when bots here were added, removed or changed, so the app can reload them.
    /// New messages need no call: they land in the conversation files the app already watches.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Runs with how far this Mac's user has read a conversation here, as the Hub keeps it: read on
    /// another device, or as the Hub had it when this Mac connected.
    @ObservationIgnored public var onRead: ((_ conversation: UUID, _ upTo: Date) -> Void)?
    /// This Mac's user's tool connections on the Hub, as last listed.
    public private(set) var connections: [LinkConnection] = []
    /// This Mac's user's computers on the Hub, as last listed.
    public private(set) var computers: [LinkComputer] = []
    /// This Mac's user's browsers on the Hub, as last listed.
    public private(set) var browsers: [LinkBrowser] = []
    /// What each bot is doing on the Hub, by its stand-in here.
    private var phases: [UUID: AgentRuntimePhase] = [:]
    /// Computers being made, waiting for the Hub to say they are done.
    @ObservationIgnored private var making: [UUID: CheckedContinuation<LinkComputer, Error>] = [:]
    /// Opens a connection's sign-in page in the browser and returns the address it came back to.
    @ObservationIgnored public var onSignInPage: ((LinkConnection, URL) async throws -> URL)?


    public let pairing: HubPairing
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let url: URL
    private var entries: [Entry] = []
    @ObservationIgnored private let groupsURL: URL
    private var groups: [GroupEntry] = []
    /// Local messages the Hub already has, so they are not sent again.
    @ObservationIgnored private var acknowledged: Set<UUID> = []

    public init(pairing: HubPairing, repository: WorkspaceRepository, directory: URL) {
        self.pairing = pairing
        self.repository = repository
        url = directory.appendingPathComponent("mirror.json")
        groupsURL = directory.appendingPathComponent("groups.json")
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
        groups = (try? JSONDecoder().decode([GroupEntry].self, from: Data(contentsOf: groupsURL))) ?? []
    }

    public var localAgentIDs: Set<UUID> { Set(entries.map(\.agent)) }

    public func owns(conversation id: UUID) -> Bool { thread(local: id) != nil }

    private var threads: [Thread] {
        entries.map { Thread(remote: $0.remoteConversation, local: $0.conversation, synced: $0.synced) }
            + groups.map { Thread(remote: $0.remote, local: $0.conversation, synced: $0.synced) }
    }

    private func thread(remote id: UUID) -> Thread? { threads.first { $0.remote == id } }

    private func thread(local id: UUID) -> Thread? { threads.first { $0.local == id } }

    /// What the bot a stand-in here keeps on the Hub is doing there, as last heard.
    public func phase(ofAgent id: UUID) -> AgentRuntimePhase? { phases[id] }

    private func record(_ phase: LinkBotPhase?, ofBot remote: UUID) {
        guard let agent = entries.first(where: { $0.remote == remote })?.agent else { return }
        phases[agent] = phase.flatMap { AgentRuntimePhase(rawValue: $0.rawValue) }
    }

    /// Opens the live view of what a link in a conversation here points at, kept on the Hub. Video
    /// comes down the channel as `LinkSurface` messages; send the viewer's controls up it with `LinkSurface.control`.
    public func openSurface(attachment: UUID, in conversation: UUID) async throws -> LinkChannel {
        guard let thread = thread(local: conversation) else { throw LinkError("That conversation is not on this Hub.") }
        return try await pairing.channel(.openSurface(conversationID: thread.remote, attachmentID: attachment))
    }

    /// Readies a noodlet a bot shared in a conversation here to run on this Mac.
    public func readyNoodlet(attachment: UUID, in conversation: UUID) async throws -> LinkNoodlet {
        guard let thread = thread(local: conversation) else { throw LinkError("That conversation is not on this Hub.") }
        guard case .noodlet(let readied) = try await pairing.request(.noodlet(conversationID: thread.remote, attachmentID: attachment))
        else { throw LinkError("The Hub sent an unexpected answer.") }
        return readied
    }

    /// A piece of a readied noodlet's files, from `offset`.
    public func noodletArchive(_ grant: UUID, from offset: Int) async throws -> Data {
        guard case .chunk(let data, _) = try await pairing.request(.noodletArchive(grant: grant, offset: offset))
        else { throw LinkError("The Hub sent an unexpected answer.") }
        return data
    }

    /// Sends a piece of a noodlet's call on its data and secrets; the last one answers.
    public func noodletCall(_ piece: LinkNoodletCall) async throws -> Data? {
        switch try await pairing.request(.noodletCall(piece)) {
        case .done: return nil
        case .noodletAnswer(let answer): return answer
        default: throw LinkError("The Hub sent an unexpected answer.")
        }
    }

    /// Where this Hub's noodlets are kept on this Mac.
    public var noodletCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noodlets/\(pairing.directory.lastPathComponent)")
    }

    /// The Hub harness a local stand-in runs on.
    public func harness(ofAgent id: UUID) -> HubHarnessChoice? {
        guard let entry = entries.first(where: { $0.agent == id }),
              let agent = try? repository.loadAgents().first(where: { $0.id == id }) else { return nil }
        return HubHarnessChoice(hub: pairing.hub?.key, provider: agent.harnessIdentifier ?? "", profile: entry.profile)
    }

    /// Deletes the local stand-ins, as when leaving the Hub. The bots stay on the Hub.
    public func forgetLocalCopies() {
        for group in groups { try? forget(group) }
        for entry in entries { try? forget(entry) }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: groupsURL)
        onChange?()
    }

    public func createBot(_ draft: LinkBotDraft) async throws -> AgentRecord {
        guard case .bot(let bot) = try await pairing.request(.createBot(draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        let agent = try adopt(bot)
        onChange?()
        return agent
    }

    public func updateBot(localAgentID: UUID, with draft: LinkBotDraft) async throws {
        guard let entry = entries.first(where: { $0.agent == localAgentID }) else { throw LinkError("This bot is not on the Hub.") }
        guard case .bot(let bot) = try await pairing.request(.updateBot(id: entry.remote, draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try apply(bot, to: entry)
        onChange?()
    }

    public func deleteBot(localAgentID: UUID) async throws {
        guard let entry = entries.first(where: { $0.agent == localAgentID }) else { throw LinkError("This bot is not on the Hub.") }
        _ = try await pairing.request(.deleteBot(id: entry.remote))
        try forget(entry)
        onChange?()
    }

    /// Makes a group on the Hub of bots kept there, by their local stand-ins, and its local copy.
    public func createGroup(named name: String, publicDescription: String, agentIDs: [UUID]) async throws -> BotConversation {
        let draft = LinkGroupDraft(name: name, publicDescription: publicDescription, botIDs: try remoteBots(agentIDs))
        guard case .group(let group) = try await pairing.request(.createGroup(draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        let conversation = try adopt(group)
        onChange?()
        return conversation
    }

    public func updateGroup(_ conversation: UUID, named name: String, publicDescription: String, agentIDs: [UUID]) async throws {
        guard let entry = groups.first(where: { $0.conversation == conversation }) else { throw LinkError("This group is not on the Hub.") }
        let draft = LinkGroupDraft(name: name, publicDescription: publicDescription, botIDs: try remoteBots(agentIDs))
        guard case .group(let group) = try await pairing.request(.updateGroup(id: entry.remote, draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try apply(group, to: entry)
        onChange?()
    }

    /// Deletes a group here and on the Hub. Its bots stay.
    public func deleteGroup(_ conversation: UUID) async throws {
        guard let entry = groups.first(where: { $0.conversation == conversation }) else { throw LinkError("This group is not on the Hub.") }
        _ = try await pairing.request(.deleteGroup(id: entry.remote))
        try forget(entry)
        onChange?()
    }

    private func remoteBots(_ agentIDs: [UUID]) throws -> [UUID] {
        try agentIDs.map { id in
            guard let remote = entries.first(where: { $0.agent == id })?.remote else { throw LinkError("A bot in this group is not on this Hub.") }
            return remote
        }
    }

    /// Adds a connection on the Hub, or changes one. It reaches no bot until assigned.
    @discardableResult public func saveConnection(_ draft: LinkConnectionDraft) async throws -> LinkConnection {
        guard case .connection(let saved) = try await pairing.request(.saveConnection(draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try await syncConnections()
        return saved
    }

    public func deleteConnection(_ id: UUID) async throws {
        _ = try await pairing.request(.deleteConnection(id: id))
        try await syncConnections()
    }

    /// The Hub connections a bot kept there may use, by its local stand-in.
    public func connectionIDs(forAgent id: UUID) -> Set<UUID> {
        guard let entry = entries.first(where: { $0.agent == id }) else { return [] }
        return Set(connections.filter { $0.botIDs.contains(entry.remote) }.map(\.id))
    }

    public func assignConnections(_ ids: Set<UUID>, toAgent id: UUID) async throws {
        guard let entry = entries.first(where: { $0.agent == id }) else { throw LinkError("That bot is not on this Hub.") }
        _ = try await pairing.request(.assignConnections(botID: entry.remote, connectionIDs: ids.sorted { $0.uuidString < $1.uuidString }))
        try await syncConnections()
    }

    /// Asks the Hub to sign a connection in; its page opens through `onSignInPage`.
    public func signIn(_ id: UUID, redirect: URL) async throws {
        try await pairing.signIn(connectionID: id, redirect: redirect)
    }

    public func computerTemplates() async throws -> [LinkComputerTemplate] {
        guard case .computerTemplates(let templates) = try await pairing.request(.computerTemplates) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        return templates
    }

    /// Makes a computer on the Hub, which may first download its image. Needs `run` to be
    /// following the Hub, which says when the computer is ready.
    public func createComputer(_ draft: LinkComputerDraft) async throws -> LinkComputer {
        let id = UUID()
        let made = try await withCheckedThrowingContinuation { continuation in
            making[id] = continuation
            Task {
                do { _ = try await pairing.request(.createComputer(requestID: id, draft)) }
                catch { making.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }
        try await syncComputers()
        return made
    }

    public func updateComputer(_ id: UUID, with draft: LinkComputerDraft) async throws -> LinkComputer {
        guard case .computer(let changed) = try await pairing.request(.updateComputer(id: id, draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try await syncComputers()
        return changed
    }

    public func deleteComputer(_ id: UUID) async throws {
        _ = try await pairing.request(.deleteComputer(id: id))
        try await syncComputers()
    }

    /// The Hub computers a bot kept there may use, by its local stand-in.
    public func computerIDs(forAgent id: UUID) -> Set<UUID> {
        guard let entry = entries.first(where: { $0.agent == id }) else { return [] }
        return Set(computers.filter { $0.botIDs.contains(entry.remote) }.map(\.id))
    }

    public func assignComputers(_ ids: Set<UUID>, toAgent id: UUID) async throws {
        guard let entry = entries.first(where: { $0.agent == id }) else { throw LinkError("That bot is not on this Hub.") }
        _ = try await pairing.request(.assignComputers(botID: entry.remote, computerIDs: ids.sorted { $0.uuidString < $1.uuidString }))
        try await syncComputers()
    }

    public func createBrowser(_ draft: LinkBrowserDraft) async throws -> LinkBrowser {
        guard case .browser(let made) = try await pairing.request(.createBrowser(draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        try await syncBrowsers()
        return made
    }

    public func deleteBrowser(_ id: UUID) async throws {
        _ = try await pairing.request(.deleteBrowser(id: id))
        try await syncBrowsers()
    }

    /// The Hub browsers a bot kept there may use, by its local stand-in.
    public func browserIDs(forAgent id: UUID) -> Set<UUID> {
        guard let entry = entries.first(where: { $0.agent == id }) else { return [] }
        return Set(browsers.filter { $0.botIDs.contains(entry.remote) }.map(\.id))
    }

    public func assignBrowsers(_ ids: Set<UUID>, toAgent id: UUID) async throws {
        guard let entry = entries.first(where: { $0.agent == id }) else { throw LinkError("That bot is not on this Hub.") }
        _ = try await pairing.request(.assignBrowsers(botID: entry.remote, browserIDs: ids.sorted { $0.uuidString < $1.uuidString }))
        try await syncBrowsers()
    }

    private func syncBrowsers() async throws {
        guard case .browsers(let listed) = try await pairing.request(.browsers) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        await pairing.fetchPictures(listed)
        browsers = pairing.keptPictures(listed)
    }

    private func syncComputers() async throws {
        guard case .computers(let listed) = try await pairing.request(.computers) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        await pairing.fetchPictures(listed)
        computers = pairing.keptPictures(listed)
    }

    private func syncConnections() async throws {
        guard case .connections(let listed) = try await pairing.request(.connections) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        await pairing.fetchPictures(listed)
        connections = pairing.keptPictures(listed)
    }

    private func openSignInPage(_ id: UUID, url: URL) async {
        do {
            guard pairing.takeSignInPage(for: id, url: url) else {
                throw LinkError("Noodle did not open a sign-in page it had not asked for.")
            }
            guard let connection = connections.first(where: { $0.id == id }), let onSignInPage else {
                throw LinkError("This Mac cannot open that sign-in.")
            }
            let callback = try await onSignInPage(connection, url)
            _ = try await pairing.request(.finishSignIn(connectionID: id, callback: callback))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Brings bots and messages up to date with the Hub, and sends what is waiting here.
    public func sync() async {
        do {
            try await syncBots()
            do { try await syncGroups() } catch {
                // A Hub from before groups says it does not know the request; it has none to copy.
            }
            try await syncConnections()
            try await syncComputers()
            try await syncBrowsers()
            for thread in threads { try await syncMessages(thread.remote) }
            try await sendPending()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Sends messages written here that the Hub does not have yet.
    public func pushPending() async {
        do {
            try await sendPending()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Keeps a stream open to the Hub and follows what it pushes, reconnecting until cancelled.
    public func run() async {
        var delay: Duration = .seconds(1)
        while !Task.isCancelled {
            do {
                let events = try await pairing.subscribe()
                isConnected = true
                delay = .seconds(1)
                await sync()
                for try await event in events {
                    switch event {
                    case .botsChanged:
                        try await syncBots()
                    case .groupsChanged:
                        try await syncGroups()
                    case .conversationChanged(let id, _):
                        try await syncMessages(id)
                    case .connectionsChanged:
                        try await syncConnections()
                    case .computersChanged:
                        try await syncComputers()
                    case .browsersChanged:
                        try await syncBrowsers()
                    // Surfaces have their own streams.
                    case .surfaceOpened, .surfaceFailed, .surfaceControls:
                        break
                    case .computerCreated(let id, let computer, let error):
                        if let computer { making.removeValue(forKey: id)?.resume(returning: computer) }
                        else { making.removeValue(forKey: id)?.resume(throwing: LinkError(error ?? "The Hub could not make the computer.")) }
                    case .signInPage(let id, let url):
                        // The person may take minutes in the browser; other events keep flowing meanwhile.
                        Task { await openSignInPage(id, url: url) }
                    case .botPhase(let bot, let phase):
                        record(phase, ofBot: bot)
                    // Reactions made on the Hub are not shown on the Mac yet.
                    case .messageChanged:
                        break
                    case .readChanged(let id, let upTo):
                        if let thread = thread(remote: id) { onRead?(thread.local, upTo) }
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
            isConnected = false
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(60))
        }
        isConnected = false
    }

    private func syncBots() async throws {
        guard case .bots(let listed) = try await pairing.request(.bots) else { throw LinkError("The Hub sent an unexpected answer.") }
        await pairing.fetchPictures(listed)
        let bots = pairing.keptPictures(listed)
        var changed = false
        for bot in bots {
            if let entry = entries.first(where: { $0.remote == bot.id }) {
                try apply(bot, to: entry)
            } else {
                _ = try adopt(bot)
                changed = true
            }
        }
        for entry in entries where !bots.contains(where: { $0.id == entry.remote }) {
            try forget(entry)
            changed = true
        }
        for bot in bots { record(bot.phase, ofBot: bot.id) }
        if changed { onChange?() }
        for bot in bots {
            if let upTo = bot.readUpTo, let entry = entries.first(where: { $0.remote == bot.id }) { onRead?(entry.conversation, upTo) }
        }
    }

    private func syncGroups() async throws {
        guard case .groups(let listed) = try await pairing.request(.groups) else { throw LinkError("The Hub sent an unexpected answer.") }
        var changed = false
        for group in listed {
            if let entry = groups.first(where: { $0.remote == group.id }) {
                if try apply(group, to: entry) { changed = true }
            } else {
                _ = try adopt(group)
                changed = true
            }
        }
        for entry in groups where !listed.contains(where: { $0.id == entry.remote }) {
            try forget(entry)
            changed = true
        }
        if changed { onChange?() }
        for group in listed {
            if let upTo = group.readUpTo, let entry = groups.first(where: { $0.remote == group.id }) { onRead?(entry.conversation, upTo) }
        }
    }

    /// This Mac's user read a conversation here, up to its latest message the Hub has; their other devices show it read.
    public func markRead(conversation id: UUID) async {
        guard let thread = thread(local: id),
              let latest = try? repository.loadMessages(conversationID: id)
                .last(where: { $0.author != .user || $0.delivery != .queued || acknowledged.contains($0.id) }) else { return }
        do {
            _ = try await pairing.request(.markRead(LinkReadMark(conversationID: thread.remote, messageID: latest.id)))
        } catch {
            // A Hub from before read state was shared says it does not know the request; the Mac keeps its own.
        }
    }

    /// Copies what is new on the Hub a page at a time, so no answer grows with the conversation.
    private func syncMessages(_ remote: UUID) async throws {
        guard var thread = thread(remote: remote) else { return }
        while true {
            let page = try await syncPage(thread)
            guard let next = self.thread(remote: remote),
                  next.synced > thread.synced, next.synced < page.count, page.messages.count > 0 else { return }
            thread = next
        }
    }

    private func syncPage(_ thread: Thread) async throws -> LinkMessages {
        guard case .messages(let page) = try await pairing.request(.messagePage(LinkMessagePage(
            conversationID: thread.remote, after: thread.synced, limit: 100))) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        var known = Set(try repository.loadMessages(conversationID: thread.local).map(\.id))
        var delivered: Set<UUID> = []
        var latest: Date?
        for message in page.messages {
            acknowledged.insert(message.id)
            if message.author == .you, message.delivered { delivered.insert(message.id) }
            guard !known.contains(message.id) else { continue }
            try await fetchMissing(message.attachments, into: thread)
            let author: MessageAuthor = switch message.author {
            case .you: .user
            // A bot since deleted on the Hub keeps its ID, as a deleted bot's messages do here.
            case .bot(let bot): .agent(entries.first { $0.remote == bot }?.agent ?? bot)
            case .system: .system
            }
            try repository.append(ChatMessage(id: message.id, conversationID: thread.local, author: author, body: message.body,
                                              createdAt: message.createdAt, delivery: message.delivered ? .delivered : .queued,
                                              attachmentIDs: message.attachments.map(\.id)))
            known.insert(message.id)
            latest = message.createdAt
        }
        if !delivered.isEmpty { try repository.markDelivered(conversationID: thread.local, messageIDs: delivered) }
        if let latest, var conversation = try repository.loadConversations().first(where: { $0.id == thread.local }) {
            conversation.updatedAt = max(conversation.updatedAt, latest)
            try repository.updateConversation(conversation)
        }
        // Delivery changes after the first read, so the last user message is read again until the bot takes it.
        let pendingFrom = page.messages.firstIndex { $0.author == .you && !$0.delivered }
        setSynced(pendingFrom.map { thread.synced + $0 } ?? thread.synced + page.messages.count, in: thread.remote)
        return page
    }

    private func setSynced(_ count: Int, in remote: UUID) {
        if let entry = entries.first(where: { $0.remoteConversation == remote }) {
            update(entry.remote) { $0.synced = count }
        } else if let index = groups.firstIndex(where: { $0.remote == remote }), groups[index].synced != count {
            groups[index].synced = count
            saveGroups()
        }
    }

    private func sendPending() async throws {
        for thread in threads {
            let waiting = try repository.loadMessages(conversationID: thread.local)
                .filter { $0.author == .user && $0.delivery == .queued && !acknowledged.contains($0.id) }
            guard !waiting.isEmpty else { continue }
            let files = Dictionary(try repository.loadAttachments(conversationID: thread.local).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
            for message in waiting {
                // Files first: the Hub refuses a message that points at a file it lacks.
                for id in message.attachmentIDs ?? [] {
                    guard let file = files[id], file.url == nil else { continue }
                    try await pairing.upload(repository.attachmentFileURL(file), as: LinkAttachment(
                        id: file.id, filename: file.originalFilename, mediaType: file.mediaType, byteCount: Int(file.byteCount),
                        voice: file.voice.map { LinkVoice(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform,
                                                          localeIdentifier: $0.localeIdentifier) }),
                        to: thread.remote)
                }
                let sent = (message.attachmentIDs ?? []).filter { files[$0]?.url == nil }
                _ = try await pairing.request(.send(LinkOutgoingMessage(conversationID: thread.remote, id: message.id, body: message.body,
                                                    attachmentIDs: sent)))
                acknowledged.insert(message.id)
            }
        }
    }

    /// Downloads the files of an incoming message that this copy lacks, keeping their IDs.
    private func fetchMissing(_ attachments: [LinkAttachment], into thread: Thread) async throws {
        guard !attachments.isEmpty else { return }
        let present = Set(try repository.loadAttachments(conversationID: thread.local).map(\.id))
        for attachment in attachments where !present.contains(attachment.id) {
            // A link travels as its address; one to something live keeps its card, and opens live here.
            if let url = attachment.url {
                // Pages leave card pictures out; each comes on its own.
                var image = attachment.card?.image
                if image == nil, attachment.card != nil,
                   case .picture(let picture)? = try? await pairing.request(.linkPreview(conversationID: thread.remote,
                                                                                         attachmentID: attachment.id)) {
                    image = picture
                }
                _ = try repository.importLinkAttachment(url, into: thread.local, card: attachment.card.map {
                    LinkCard(title: $0.title, detail: $0.detail, image: image, symbol: $0.symbol, colour: $0.colour,
                             icon: $0.icon, capturedAt: $0.capturedAt)
                }, id: attachment.id)
                continue
            }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-\(attachment.id.uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try await pairing.download(attachment, from: thread.remote, to: staging)
            let name = URL(fileURLWithPath: attachment.filename).lastPathComponent
            let voice = attachment.voice.map {
                VoiceMessage(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform, localeIdentifier: $0.localeIdentifier)
            }
            let filename = name.isEmpty ? "Attachment" : name
            _ = try repository.importAttachment(from: staging, into: thread.local, mediaType: attachment.mediaType,
                                                voice: voice, id: attachment.id, originalFilename: filename)
        }
    }

    /// Makes the local stand-in for a bot on the Hub.
    private func adopt(_ bot: LinkBot) throws -> AgentRecord {
        let draft = bot.draft
        let created = try repository.createAgent(
            named: draft.name, harnessIdentifier: draft.provider, modelIdentifier: draft.model,
            reasoningEffort: draft.reasoningEffort, publicDescription: draft.publicDescription,
            avatarSymbolName: draft.avatarSymbolName, avatarColorIndex: draft.avatarColorIndex,
            avatarImageData: draft.avatarImageData, backstory: draft.backstory)
        entries.append(Entry(remote: bot.id, remoteConversation: bot.conversationID, agent: created.agent.id,
                             conversation: created.conversation.id, synced: 0, profile: draft.profile))
        save()
        // The Hub checked it when the bot set it.
        guard let status = bot.status, let agent = try? repository.setAgentStatus(status, agentID: created.agent.id) else {
            return created.agent
        }
        return agent
    }

    private func apply(_ bot: LinkBot, to entry: Entry) throws {
        guard let agent = try repository.loadAgents().first(where: { $0.id == entry.agent }) else { return }
        if agent.status != bot.status, (try? repository.setAgentStatus(bot.status, agentID: agent.id)) != nil { onChange?() }
        var draft = bot.draft
        // A picture that could not be fetched yet keeps the one here.
        if draft.avatarImageData == nil, draft.avatarImageDigest != nil { draft.avatarImageData = agent.avatarImageData }
        update(entry.remote) { $0.profile = draft.profile }
        let unchanged = agent.displayName == draft.name && agent.harnessIdentifier == draft.provider
            && agent.modelIdentifier == draft.model && agent.reasoningEffort == draft.reasoningEffort
            && (agent.publicDescription ?? "") == draft.publicDescription && agent.avatarSymbolName == draft.avatarSymbolName
            && agent.avatarColorIndex == draft.avatarColorIndex && agent.avatarImageData == draft.avatarImageData
        if !unchanged {
            _ = try repository.updateAgent(
                agent, displayName: draft.name, harnessIdentifier: draft.provider, modelIdentifier: draft.model,
                reasoningEffort: draft.reasoningEffort, publicDescription: draft.publicDescription,
                avatarSymbolName: draft.avatarSymbolName, avatarColorIndex: draft.avatarColorIndex,
                avatarImageData: draft.avatarImageData)
            onChange?()
        }
        if try repository.loadAgentBackstory(agent) != draft.backstory {
            try repository.updateAgentBackstory(agent, backstory: draft.backstory)
        }
    }

    private func forget(_ entry: Entry) throws {
        if let agent = try repository.loadAgents().first(where: { $0.id == entry.agent }) {
            try repository.deleteAgent(agent)
        }
        entries.removeAll { $0.remote == entry.remote }
        save()
    }

    /// Makes the local copy of a group on the Hub, of its bots' stand-ins here.
    private func adopt(_ group: LinkGroup) throws -> BotConversation {
        let conversation = try repository.createGroup(named: group.draft.name, publicDescription: group.draft.publicDescription,
                                                      participantIDs: localAgents(group.draft.botIDs),
                                                      existingAgents: try repository.loadAgents())
        groups.append(GroupEntry(remote: group.id, conversation: conversation.id, synced: 0))
        saveGroups()
        return conversation
    }

    /// Copies a group's name, description and bots. The notice Group Info leaves comes from the Hub with its messages.
    @discardableResult private func apply(_ group: LinkGroup, to entry: GroupEntry) throws -> Bool {
        guard var conversation = try repository.loadConversations().first(where: { $0.id == entry.conversation }) else { return false }
        let bots = localAgents(group.draft.botIDs).sorted { $0.uuidString < $1.uuidString }
        let description = group.draft.publicDescription.isEmpty ? nil : group.draft.publicDescription
        guard conversation.displayName != group.draft.name || conversation.publicDescription != description
                || conversation.participantIDs != bots else { return false }
        conversation.displayName = group.draft.name
        conversation.publicDescription = description
        conversation.participantIDs = bots
        try repository.updateConversation(conversation)
        return true
    }

    private func localAgents(_ bots: [UUID]) -> [UUID] {
        bots.compactMap { id in entries.first { $0.remote == id }?.agent }
    }

    private func forget(_ group: GroupEntry) throws {
        if FileManager.default.fileExists(atPath: repository.conversationDirectory(id: group.conversation).path) {
            try repository.deleteConversation(id: group.conversation)
        }
        groups.removeAll { $0.remote == group.remote }
        saveGroups()
    }

    private func saveGroups() {
        try? FileManager.default.createDirectory(at: groupsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(groups).write(to: groupsURL, options: .atomic)
    }

    private func update(_ remote: UUID, _ change: (inout Entry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.remote == remote }) else { return }
        let before = entries[index]
        change(&entries[index])
        if entries[index] != before { save() }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}

/// A harness a joined Hub lends, as the bot editor's harness selection holds it.
public struct HubHarnessChoice: Equatable, Sendable {
    private static let prefix = "hub|"

    public var hub: LinkPublicKey?
    public var provider: String
    public var profile: UUID?

    public init(hub: LinkPublicKey?, provider: String, profile: UUID?) {
        self.hub = hub
        self.provider = provider
        self.profile = profile
    }

    public var identifier: String {
        Self.prefix + [hub?.x963.base64EncodedString() ?? "", provider, profile?.uuidString ?? ""].joined(separator: "|")
    }

    public init?(identifier: String) {
        guard identifier.hasPrefix(Self.prefix) else { return nil }
        let parts = identifier.dropFirst(Self.prefix.count).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let key = Data(base64Encoded: parts[0]), let hub = try? LinkPublicKey(x963: key) else { return nil }
        self.init(hub: hub, provider: parts[1], profile: UUID(uuidString: parts[2]))
    }
}

extension LinkConnection {
    /// As this Mac shows a connection, with the Hub's icon.
    public var record: MCPConnectionRecord? {
        var record = try? MCPConnectionRecord(id: draft.id, name: draft.name, endpoint: draft.endpoint,
                                              description: draft.description, instructions: draft.instructions)
        record?.iconData = iconData
        return record
    }
}

extension LinkConnectionDraft {
    public init(_ record: MCPConnectionRecord) {
        self.init(id: record.id, name: record.name, endpoint: record.endpoint,
                  description: record.description, instructions: record.instructions)
    }
}
