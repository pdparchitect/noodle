import HubLink
import NoodletRuntime
import NoodleWallpaperCore
import PhotosUI
import SwiftUI

/// A conversation this phone shows: a bot's own, or a group's.
protocol HubConversation: Identifiable where ID == UUID {
    var conversationID: UUID { get }
    var createdAt: Date { get }
    var readUpTo: Date? { get }
    var name: String { get }
    var about: String { get }
}

extension LinkBot: HubConversation {
    var name: String { draft.name }
    var about: String { draft.publicDescription }
}

extension LinkGroup: HubConversation {
    /// A group's ID is its conversation's.
    var conversationID: UUID { id }
    var name: String { draft.name }
    var about: String { draft.publicDescription }
}

/// A row of the list and the conversation it opens.
enum HubThread: HubConversation {
    case bot(LinkBot), group(LinkGroup)

    private var conversation: any HubConversation {
        switch self {
        case .bot(let bot): bot
        case .group(let group): group
        }
    }

    var id: UUID { conversation.id }
    var conversationID: UUID { conversation.conversationID }
    var createdAt: Date { conversation.createdAt }
    var readUpTo: Date? { conversation.readUpTo }
    var name: String { conversation.name }
    var about: String { conversation.about }

    var bot: LinkBot? {
        if case .bot(let bot) = self { bot } else { nil }
    }

    var group: LinkGroup? {
        if case .group(let group) = self { group } else { nil }
    }
}

/// The bots and groups this phone's user keeps on the Hub and their conversations, kept current from the Hub's events.
@MainActor @Observable final class HubChats {
    let pairing: HubPairing
    @ObservationIgnored let linkPreviews: LinkPreviews
    private(set) var agents: [LinkBot] = []
    private(set) var groups: [LinkGroup] = []
    var error: String?
    /// Whether the list is known: from the last sync saved on this phone, or from the Hub itself.
    private(set) var isLoaded = false
    /// Pins belong to this phone alone; the Hub never sees them.
    private var pinned: Set<UUID>
    /// When each conversation was last read on this phone. Nil until the first sync after
    /// installing, which counts everything already there as read.
    private var seen: [UUID: Date]?
    /// Unsent text, by conversation, kept on this phone.
    private var drafts: [UUID: String] = [:]
    /// Each conversation's backdrop. Like on the Mac, only this device's look: the Hub never sees it.
    private var backgrounds: [UUID: ConversationBackground] = [:]
    private var conversations: [UUID: [LinkMessage]] = [:]
    /// This user's tool connections, computers and browsers on the Hub, which bots use when assigned.
    var connections: [LinkConnection] = []
    var computers: [LinkComputer] = []
    var browsers: [LinkBrowser] = []
    /// Computers being made, waiting for the Hub to say they are ready.
    @ObservationIgnored var making: [UUID: CheckedContinuation<LinkComputer, Error>] = [:]
    /// How far each conversation has been read. It stops at a message the bot has not taken yet,
    /// so that message is read again until it shows as delivered.
    @ObservationIgnored private var read: [UUID: Int] = [:]
    /// Where the earliest message this phone has sits in each conversation; earlier ones load as
    /// the person scrolls back. None means it has them all.
    private var start: [UUID: Int] = [:]
    /// Card pictures, fetched as their cards come into view.
    @ObservationIgnored var pictures: [UUID: Data] = [:]
    /// Messages in one page: small enough to come quickly, however long the conversation.
    private static let pageSize = 50

    /// The last sync, shown at launch while the Hub is asked again.
    private struct Cache: Codable {
        var agents: [LinkBot]
        var groups: [LinkGroup]?
        var conversations: [UUID: [LinkMessage]]
        var read: [UUID: Int]
        var start: [UUID: Int]?
    }

    init(pairing: HubPairing) {
        self.pairing = pairing
        linkPreviews = LinkPreviews(folder: pairing.directory.appendingPathComponent("Link Previews", isDirectory: true))
        pinned = Set((try? JSONDecoder().decode([UUID].self, from: Data(contentsOf: pairing.directory.appendingPathComponent("pins.json")))) ?? [])
        seen = try? JSONDecoder().decode([UUID: Date].self, from: Data(contentsOf: seenURL))
        drafts = (try? JSONDecoder().decode([UUID: String].self, from: Data(contentsOf: draftsURL))) ?? [:]
        unsent = (try? JSONDecoder().decode([UUID: UnsentMessage].self, from: Data(contentsOf: unsentURL))) ?? [:]
        backgrounds = (try? JSONDecoder().decode([UUID: ConversationBackground].self,
                                                 from: Data(contentsOf: pairing.directory.appendingPathComponent("backgrounds.json")))) ?? [:]
        if let cache = try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL)) {
            agents = cache.agents
            groups = cache.groups ?? []
            conversations = cache.conversations
            read = cache.read
            start = cache.start ?? [:]
            isLoaded = true
        }
    }

    private var cacheURL: URL { pairing.directory.appendingPathComponent("chats.json") }
    private var seenURL: URL { pairing.directory.appendingPathComponent("read.json") }
    private var draftsURL: URL { pairing.directory.appendingPathComponent("drafts.json") }
    private var unsentURL: URL { pairing.directory.appendingPathComponent("unsent.json") }

    func background(for conversation: some HubConversation) -> ConversationBackground {
        backgrounds[conversation.conversationID] ?? ConversationBackground()
    }

    func backgroundImageURL(for conversation: some HubConversation) -> URL? {
        background(for: conversation).imageFilename.map { backgroundsFolder.appendingPathComponent($0) }
    }

    /// A preset or the default. Any photo the conversation had is removed.
    func setBackground(_ background: ConversationBackground, for conversation: some HubConversation) throws {
        if let old = backgroundImageURL(for: conversation), old.lastPathComponent != background.imageFilename {
            try? FileManager.default.removeItem(at: old)
        }
        backgrounds[conversation.conversationID] = background.isDefault ? nil : background
        try JSONEncoder().encode(backgrounds).write(to: pairing.directory.appendingPathComponent("backgrounds.json"), options: .atomic)
    }

    /// A photo, converted as Noodle converts every still background.
    func setBackground(photo: Data, for conversation: some HubConversation) throws {
        let jpeg = try BackgroundMedia.jpegData(from: photo)
        try FileManager.default.createDirectory(at: backgroundsFolder, withIntermediateDirectories: true)
        // A new name each time, so views showing the old picture reload.
        let name = "\(conversation.conversationID.uuidString)-\(UUID().uuidString).jpg"
        try jpeg.write(to: backgroundsFolder.appendingPathComponent(name), options: .atomic)
        try setBackground(ConversationBackground(imageFilename: name, mediaKind: .image), for: conversation)
    }

    private var backgroundsFolder: URL { pairing.directory.appendingPathComponent("Backgrounds", isDirectory: true) }

    /// A draft of nothing but blank lines or spaces is no draft: the field comes back empty, at its usual size.
    func draft(for conversation: some HubConversation) -> String {
        let draft = drafts[conversation.conversationID] ?? ""
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : draft
    }

    func setDraft(_ text: String, for conversation: some HubConversation) {
        let kept = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard drafts[conversation.conversationID] != kept else { return }
        drafts[conversation.conversationID] = kept
        try? JSONEncoder().encode(drafts).write(to: draftsURL, options: .atomic)
    }

    /// The bot's phase as its dot shows it: offline while its Hub does not answer.
    func phase(of agent: LinkBot) -> LinkBotPhase? { HubConnection(pairing).phase(of: agent.phase) }

    /// Whether a bot has written since the conversation was last opened here.
    func isUnread(_ conversation: some HubConversation) -> Bool {
        guard let seen, let reply = messages(of: conversation).last(where: { if case .bot = $0.author { true } else { false } }) else {
            return false
        }
        return seen[conversation.conversationID].map { reply.createdAt > $0 } ?? true
    }

    /// Also tells the Hub, up to the latest message it has, so the person's other devices show it read.
    func markRead(_ conversation: some HubConversation) {
        let messages = messages(of: conversation)
        guard let latest = messages.last?.createdAt, (seen?[conversation.conversationID] ?? .distantPast) < latest else { return }
        seen = (seen ?? [:]).merging([conversation.conversationID: latest]) { $1 }
        saveSeen()
        Task { await HubNotifications.clearDelivered(conversation: conversation.conversationID) }
        guard let kept = messages.last(where: { unsent[$0.id] == nil }) else { return }
        let mark = LinkReadMark(conversationID: conversation.conversationID, messageID: kept.id)
        // A Hub from before read state was shared does not know the request; this phone keeps its own.
        Task { _ = try? await pairing.request(.markRead(mark)) }
    }

    /// Read as far as the Hub says, on this phone or another device. Never unreads what was read here.
    private func noteRead(_ conversationID: UUID, upTo: Date) {
        guard var seen, (seen[conversationID] ?? .distantPast) < upTo else { return }
        seen[conversationID] = upTo
        self.seen = seen
        saveSeen()
    }

    private func saveSeen() {
        guard let seen else { return }
        try? JSONEncoder().encode(seen).write(to: seenURL, options: .atomic)
    }

    private func saveCache() {
        try? JSONEncoder().encode(Cache(agents: agents, groups: groups, conversations: conversations, read: read, start: start))
            .write(to: cacheURL, options: .atomic)
    }

    var threads: [HubThread] { agents.map(HubThread.bot) + groups.map(HubThread.group) }

    var sortedThreads: [HubThread] { Self.sorted(threads.map { (self, $0) }).map(\.1) }

    /// Pinned first, then newest conversation first, as in Messages, across however many Hubs.
    static func sorted(_ threads: [(HubChats, HubThread)]) -> [(HubChats, HubThread)] {
        threads.sorted { lhs, rhs in
            let (left, right) = (lhs.0.isPinned(lhs.1), rhs.0.isPinned(rhs.1))
            if left != right { return left }
            return lhs.0.recency(of: lhs.1) > rhs.0.recency(of: rhs.1)
        }
    }

    /// As the Mac sidebar searches: the name, the description or anything said that this phone holds,
    /// ignoring case and accents. A blank search matches everything.
    func matches(_ conversation: some HubConversation, search: String) -> Bool {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || conversation.name.localizedStandardContains(term)
            || conversation.about.localizedStandardContains(term)
            || messages(of: conversation).contains { $0.body.localizedStandardContains(term) }
    }

    /// When the conversation last moved, or the bot or group was made.
    private func recency(of conversation: some HubConversation) -> Date {
        latestMessage(of: conversation)?.createdAt ?? conversation.createdAt
    }

    func isPinned(_ conversation: some HubConversation) -> Bool { pinned.contains(conversation.id) }

    func togglePin(_ conversation: some HubConversation) {
        if pinned.remove(conversation.id) == nil { pinned.insert(conversation.id) }
        savePins()
    }

    private func savePins() {
        try? JSONEncoder().encode(pinned.sorted { $0.uuidString < $1.uuidString })
            .write(to: pairing.directory.appendingPathComponent("pins.json"), options: .atomic)
    }

    /// Makes a bot on the Hub, which checks that the user's plan lends its harness.
    func create(_ draft: LinkBotDraft) async throws -> LinkBot {
        guard case .bot(let bot) = try await pairing.request(.createBot(draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        agents.append(bot)
        saveCache()
        return bot
    }

    func update(_ agent: LinkBot) async throws {
        guard case .bot(let bot) = try await pairing.request(.updateBot(id: agent.id, agent.draft.leavingOutKnownPicture)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        if let index = agents.firstIndex(where: { $0.id == bot.id }) { agents[index] = bot }
        saveCache()
    }

    /// Deletes the bot and its conversation on the Hub, for every device.
    func delete(_ agent: LinkBot) async throws {
        guard case .done = try await pairing.request(.deleteBot(id: agent.id)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        agents.removeAll { $0.id == agent.id }
        forget(agent)
        saveCache()
    }

    /// Makes a group of this user's bots on the Hub.
    func createGroup(_ draft: LinkGroupDraft) async throws -> LinkGroup {
        guard case .group(let group) = try await pairing.request(.createGroup(draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        groups.append(group)
        saveCache()
        return group
    }

    func updateGroup(_ group: LinkGroup) async throws {
        guard case .group(let updated) = try await pairing.request(.updateGroup(id: group.id, group.draft)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        if let index = groups.firstIndex(where: { $0.id == updated.id }) { groups[index] = updated }
        saveCache()
    }

    /// Deletes the group and its messages on the Hub, for every device. Its bots stay.
    func deleteGroup(_ group: LinkGroup) async throws {
        guard case .done = try await pairing.request(.deleteGroup(id: group.id)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        groups.removeAll { $0.id == group.id }
        forget(group)
        saveCache()
    }

    /// What this phone keeps of a conversation that is gone.
    private func forget(_ conversation: some HubConversation) {
        conversations[conversation.conversationID] = nil
        read[conversation.conversationID] = nil
        linkPreviews.forget(conversation.conversationID)
        if seen?.removeValue(forKey: conversation.conversationID) != nil { saveSeen() }
        if pinned.remove(conversation.id) != nil { savePins() }
    }

    /// Starts a failed bot again, as Kick does on the Mac: at once, or after the question the Hub returns.
    func kick(_ agent: LinkBot) async throws -> LinkKickConfirmation? {
        switch try await pairing.request(.kick(botID: agent.id)) {
        case .done: return nil
        case .kickConfirmation(let confirmation): return confirmation
        default: throw LinkError("The Hub sent an unexpected answer.")
        }
    }

    func confirmKick(_ confirmation: LinkKickConfirmation, for agent: LinkBot) async throws {
        guard case .done = try await pairing.request(.confirmKick(botID: agent.id, confirmationID: confirmation.id)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
    }

    /// Starts the bot with a fresh context; its workspace, memory and messages are kept.
    func startNewSession(_ agent: LinkBot) async throws {
        guard case .done = try await pairing.request(.newSession(botID: agent.id)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
    }

    func agent(_ id: UUID) -> LinkBot? { agents.first { $0.id == id } }

    func thread(_ id: UUID) -> HubThread? { threads.first { $0.id == id } }

    /// The group's bots this phone knows, in the group's order.
    func members(of group: LinkGroup) -> [LinkBot] { group.draft.botIDs.compactMap(agent) }

    func messages(of conversation: some HubConversation) -> [LinkMessage] { conversations[conversation.conversationID] ?? [] }

    func latestMessage(of conversation: some HubConversation) -> LinkMessage? { messages(of: conversation).last }

    /// What the bubble over a pinned circle says: the start of an unread reply, or else the bot's status.
    func note(for thread: HubThread) -> PinnedNote? {
        if isUnread(thread), let reply = messages(of: thread).last(where: { if case .bot = $0.author { true } else { false } }) {
            let text = reply.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { return .unread(text) }
        }
        return thread.bot?.status.map(PinnedNote.status)
    }

    /// In a group, the bot's name heading each run of its messages, by message.
    static func authorLabels(in messages: [LinkMessage], name: (UUID) -> String?) -> [UUID: String] {
        var labels: [UUID: String] = [:]
        var previous: LinkMessage.Author?
        for message in messages {
            if case .bot(let id) = message.author, message.author != previous, let name = name(id) { labels[message.id] = name }
            previous = message.author
        }
        return labels
    }

    /// In a group, the bot whose picture sits beside the last of each run of its messages, by message.
    static func authorAvatars(in messages: [LinkMessage]) -> [UUID: UUID] {
        var avatars: [UUID: UUID] = [:]
        for (message, next) in zip(messages, messages.dropFirst().map(Optional.some) + [nil]) {
            if case .bot(let id) = message.author, next?.author != message.author { avatars[message.id] = id }
        }
        return avatars
    }

    /// Loads everything, then follows the Hub's changes until cancelled, reconnecting after a pause.
    func follow() async {
        while !Task.isCancelled {
            do {
                try await reload()
                for try await event in try await pairing.subscribe() { try await apply(event) }
            } catch {
                self.error = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func apply(_ event: LinkEvent) async throws {
        switch event {
        case .botsChanged:
            try await reload()
        case .groupsChanged:
            try await loadGroups()
            forgetGone()
        case .conversationChanged(let id, _):
            try await load(id)
        case .messageChanged(let message):
            // Only a message already here; a new one arrives with its conversation's change.
            guard conversations[message.conversationID]?.contains(where: { $0.id == message.id }) == true else { return }
            settle([message])
            merge([message], into: message.conversationID)
        case .botPhase(let id, let phase):
            guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
            agents[index].phase = phase
        case .connectionsChanged:
            try await loadConnections()
        case .computersChanged:
            try await loadComputers()
        case .browsersChanged:
            try await loadBrowsers()
        case .signInPage(let id, let url):
            // The person may take minutes in the browser; other events keep flowing meanwhile.
            Task { await signIn(id, page: url) }
        case .computerCreated(let id, let computer, let error):
            if let computer { making.removeValue(forKey: id)?.resume(returning: computer) }
            else { making.removeValue(forKey: id)?.resume(throwing: LinkError(error ?? "The Hub could not make the computer.")) }
        // Live views have their own channels.
        case .surfaceOpened, .surfaceFailed, .surfaceControls:
            return
        case .readChanged(let id, let upTo):
            noteRead(id, upTo: upTo)
            return
        }
        saveCache()
    }

    /// Adds your reaction, or takes it back if it is there.
    func toggleReaction(_ emoji: String, on message: LinkMessage, in conversation: some HubConversation) async throws {
        let present = !message.reactions.contains(LinkReaction(author: .you, emoji: emoji))
        guard case .message(let changed) = try await pairing.request(.react(LinkReactionChange(
            conversationID: conversation.conversationID, messageID: message.id, emoji: emoji, present: present))) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        merge([changed], into: conversation.conversationID)
        saveCache()
    }

    func reload() async throws {
        guard case .bots(let bots) = try await pairing.request(.bots) else { throw LinkError("The Hub sent an unexpected answer.") }
        agents = pairing.keptPictures(bots)
        for bot in bots { try await load(bot.conversationID) }
        // A Hub from before groups does not know the request; it has none to show.
        try? await loadGroups()
        forgetGone()
        if seen == nil {
            seen = conversations.compactMapValues { $0.last?.createdAt }
            saveSeen()
        }
        for thread in threads { if let upTo = thread.readUpTo { noteRead(thread.conversationID, upTo: upTo) } }
        // Chats work even when the Hub cannot list tools.
        try? await loadTools()
        isLoaded = true
        error = nil
        saveCache()
        // The Hub answers again: a message that did not go through goes now, if nothing newer has come.
        for id in unsent.keys { await deliver(id, pauses: [.zero]) }
        // Pictures come after the chats show, each fetched once.
        await pairing.fetchPictures(bots)
        guard agents.map(\.id) == bots.map(\.id) else { return }
        agents = pairing.keptPictures(agents)
        saveCache()
    }

    private func loadGroups() async throws {
        guard case .groups(let listed) = try await pairing.request(.groups) else { throw LinkError("The Hub sent an unexpected answer.") }
        groups = listed
        for group in listed {
            try await load(group.id)
            if let upTo = group.readUpTo { noteRead(group.id, upTo: upTo) }
        }
    }

    /// Conversations of bots and groups that are gone.
    private func forgetGone() {
        let kept = Set(threads.map(\.conversationID))
        conversations = conversations.filter { kept.contains($0.key) }
        linkPreviews.keep(only: kept)
    }

    /// Your messages the Hub has not confirmed, kept on this phone with their files to send again.
    private var unsent: [UUID: UnsentMessage] = [:]
    /// Messages being sent, or tried again.
    private(set) var sending: Set<UUID> = []
    /// The pauses before each try at sending a message. It is tried again only while nothing newer has come.
    var retryPauses: [Duration] = [.zero, .seconds(2), .seconds(5), .seconds(15)]

    private struct UnsentMessage: Codable {
        var outgoing: LinkOutgoingMessage
        var attachments: [LinkAttachment]
        /// What was typed, without the words a message of files alone gets.
        var typed: String
        /// Why the last try failed.
        var reason: String?
    }

    /// How far your message got, in the Mac's words.
    func delivery(of message: LinkMessage) -> String {
        if sending.contains(message.id) { return "Sending…" }
        if unsent[message.id] != nil { return "Not delivered" }
        return message.delivered ? "Delivered" : "Sent"
    }

    /// Whether the Hub does not have your message yet, while it is sent or after it failed.
    func isUnsent(_ message: LinkMessage) -> Bool { unsent[message.id] != nil }

    /// Whether your message did not go through and nothing is trying it now.
    func hasFailed(_ message: LinkMessage) -> Bool { unsent[message.id] != nil && !sending.contains(message.id) }

    func unsentReason(of message: LinkMessage) -> String? { unsent[message.id]?.reason }

    /// Only while nothing newer has come: out of its place, a message may no longer make sense.
    func canTryAgain(_ message: LinkMessage) -> Bool { hasFailed(message) && isNewest(message) }

    private func isNewest(_ message: LinkMessage) -> Bool { conversations[message.conversationID]?.last?.id == message.id }

    func send(_ body: String, files: [OutgoingFile] = [], to conversation: some HubConversation) async throws {
        let attachments = try files.map { file in
            LinkAttachment(id: file.id, filename: file.filename, mediaType: file.mediaType,
                           byteCount: try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, voice: file.voice,
                           pixelSize: file.mediaType.hasPrefix("image/") ? LinkPixelSize(pictureAt: file.url) : nil)
        }
        // As on the Mac, a message of files alone says how many, and a recording alone what it is.
        let text = !body.isEmpty || files.isEmpty ? body
            : files.count == 1 && files[0].voice != nil ? Self.voiceBody
            : "Sent \(files.count) attachment\(files.count == 1 ? "" : "s")"
        let outgoing = LinkOutgoingMessage(conversationID: conversation.conversationID, id: UUID(), body: text,
                                           attachmentIDs: attachments.map(\.id))
        // Kept first, files included, so a message that does not go through can go later.
        for (file, attachment) in zip(files, attachments) { try keep(file.url, as: attachment) }
        unsent[outgoing.id] = UnsentMessage(outgoing: outgoing, attachments: attachments, typed: body)
        saveUnsent()
        // Shown at once; the Hub's copy replaces it.
        merge([LinkMessage(id: outgoing.id, conversationID: conversation.conversationID, author: .you, body: text,
                           createdAt: Date(), delivered: false, attachments: attachments)], into: conversation.conversationID)
        saveCache()
        await deliver(outgoing.id, pauses: retryPauses)
    }

    func tryAgain(_ message: LinkMessage) async {
        guard canTryAgain(message) else { return }
        await deliver(message.id, pauses: [.zero])
    }

    /// Tries after each pause until the Hub has the message, and stops once something newer has come.
    /// It goes with the same ID each time, so a Hub that took it already keeps the one copy.
    private func deliver(_ id: UUID, pauses: [Duration]) async {
        guard !sending.contains(id) else { return }
        sending.insert(id)
        defer { sending.remove(id) }
        for pause in pauses {
            try? await Task.sleep(for: pause)
            guard let message = unsent[id], let shown = conversations[message.outgoing.conversationID]?.first(where: { $0.id == id }),
                  isNewest(shown) else { return }
            let conversationID = message.outgoing.conversationID
            do {
                // Files first: the Hub refuses a message that points at a file it lacks.
                for attachment in message.attachments {
                    try await pairing.upload(fileURL(for: attachment), as: attachment, to: conversationID)
                }
                guard case .message(let sent) = try await pairing.request(.send(message.outgoing)) else {
                    throw LinkError("The Hub sent an unexpected answer.")
                }
                settle([sent])
                merge([sent], into: conversationID)
                try? await load(conversationID)
                saveCache()
                return
            } catch {
                unsent[id]?.reason = error.localizedDescription
                saveUnsent()
            }
        }
    }

    /// Your messages the Hub now has, as when it took one whose answer was lost, need no sending again.
    private func settle(_ messages: [LinkMessage]) {
        let arrived = messages.map(\.id).filter { unsent[$0] != nil }
        guard !arrived.isEmpty else { return }
        for id in arrived { unsent[id] = nil }
        saveUnsent()
    }

    /// A message that did not go through, taken off the conversation to be edited: what was typed,
    /// and its files as if picked again.
    func takeBack(_ message: LinkMessage, in conversation: some HubConversation) throws -> (text: String, files: [OutgoingFile]) {
        guard let kept = unsent[message.id], hasFailed(message) else { throw LinkError("The message is being sent.") }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let files = try kept.attachments.map { attachment in
            let url = staging.appendingPathComponent(attachment.id.uuidString, isDirectory: true)
                .appendingPathComponent(fileURL(for: attachment).lastPathComponent)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fileURL(for: attachment), to: url)
            return OutgoingFile(url: url, filename: attachment.filename, mediaType: attachment.mediaType, voice: attachment.voice)
        }
        delete(message, in: conversation)
        return (kept.typed, files)
    }

    /// Removes a message that did not go through, and the copies of its files kept to send it.
    func delete(_ message: LinkMessage, in conversation: some HubConversation) {
        guard hasFailed(message), let kept = unsent.removeValue(forKey: message.id) else { return }
        for attachment in kept.attachments { try? FileManager.default.removeItem(at: fileURL(for: attachment).deletingLastPathComponent()) }
        conversations[conversation.conversationID]?.removeAll { $0.id == message.id }
        saveUnsent()
        saveCache()
    }

    private func saveUnsent() {
        try? JSONEncoder().encode(unsent).write(to: unsentURL, options: .atomic)
    }

    /// A recording, sent as the Mac sends one: the audio with its transcript, under "Voice message".
    func sendVoice(_ audio: URL, voice: LinkVoice, to conversation: some HubConversation) async throws {
        try await send("", files: [OutgoingFile(url: audio, filename: "Voice message.caf", mediaType: "audio/x-caf",
                                                            voice: voice)], to: conversation)
    }

    static let voiceBody = "Voice message"

    /// The file on this phone, downloaded from the Hub the first time it is asked for.
    func file(for attachment: LinkAttachment, in conversation: some HubConversation) async throws -> URL {
        let url = fileURL(for: attachment)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await pairing.download(attachment, from: conversation.conversationID, to: staging)
        try keep(staging, as: attachment)
        return url
    }

    /// The file on this phone if it is already downloaded.
    func downloadedFile(for attachment: LinkAttachment) -> URL? {
        let url = fileURL(for: attachment)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Files live under their ID, keeping their name so Quick Look and sharing show it.
    private func fileURL(for attachment: LinkAttachment) -> URL {
        let name = URL(fileURLWithPath: attachment.filename).lastPathComponent
        return pairing.directory.appendingPathComponent("Files", isDirectory: true)
            .appendingPathComponent(attachment.id.uuidString, isDirectory: true)
            .appendingPathComponent(name.isEmpty ? "Attachment" : name)
    }

    private func keep(_ source: URL, as attachment: LinkAttachment) throws {
        let url = fileURL(for: attachment)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: url)
    }

    /// The first time, the newest page only; after that, what is new, a page at a time. A message
    /// the bot has not taken yet is read again until it shows as delivered.
    private func load(_ conversationID: UUID) async throws {
        guard var at = read[conversationID] else {
            let page = try await self.page(LinkMessagePage(conversationID: conversationID, limit: Self.pageSize))
            settle(page.messages)
            merge(page.messages, into: conversationID)
            let first = page.start ?? 0
            start[conversationID] = first
            let pending = page.messages.firstIndex { $0.author == .you && !$0.delivered }
            read[conversationID] = pending.map { first + $0 } ?? page.count
            return
        }
        while true {
            let page = try await self.page(LinkMessagePage(conversationID: conversationID, after: at, limit: 2 * Self.pageSize))
            settle(page.messages)
            merge(page.messages, into: conversationID)
            if let pending = page.messages.firstIndex(where: { $0.author == .you && !$0.delivered }) {
                read[conversationID] = at + pending
                return
            }
            at += page.messages.count
            read[conversationID] = at
            if page.messages.isEmpty || at >= page.count { return }
        }
    }

    /// Whether earlier messages wait on the Hub, to load as the person scrolls back.
    func hasEarlier(_ conversation: some HubConversation) -> Bool { (start[conversation.conversationID] ?? 0) > 0 }

    func loadEarlier(_ conversation: some HubConversation) async throws {
        let id = conversation.conversationID
        guard let first = start[id], first > 0 else { return }
        let page = try await self.page(LinkMessagePage(conversationID: id, before: first, limit: Self.pageSize))
        settle(page.messages)
        let known = Set((conversations[id] ?? []).map(\.id))
        conversations[id] = page.messages.filter { !known.contains($0.id) } + (conversations[id] ?? [])
        start[id] = page.start ?? 0
        saveCache()
    }

    private func page(_ request: LinkMessagePage) async throws -> LinkMessages {
        guard case .messages(let page) = try await pairing.request(.messagePage(request)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        return page
    }

    /// Messages arriving in any order, such as a page landing after one sent from here, keep the
    /// conversation's order.
    private func merge(_ messages: [LinkMessage], into conversationID: UUID) {
        var list = conversations[conversationID] ?? []
        for message in messages {
            if let index = list.firstIndex(where: { $0.id == message.id }) { list[index] = message } else { list.append(message) }
        }
        conversations[conversationID] = list.enumerated()
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }
            .map(\.element)
    }
}

/// A file picked on the phone, waiting to be sent. Its ID becomes the attachment's.
struct OutgoingFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let filename: String
    let mediaType: String
    var voice: LinkVoice?
}

/// The home screen once paired: the bots and groups of the Hubs shown, newest conversation first.
struct AgentsView: View {
    let pairings: [HubPairing]
    /// A tapped notification's conversation, until it opens.
    @Binding var opening: NotificationRoute?
    @Environment(\.scenePhase) private var phase
    @State private var path: [ChatLink] = []
    /// Kept per Hub while it stays shown, so switching the option keeps what each Hub loaded.
    @State private var chats: [HubChats] = []
    @State private var showingMore = false
    /// What was picked in the … sheet; it opens once that sheet has gone.
    @State private var chosen: MoreChoice?
    @State private var showingProfile = false
    @State private var showingSettings = false
    @State private var creating = false
    @State private var creatingGroup = false
    @State private var search = ""
    @State private var editing: Row?

    private struct Row: Identifiable {
        let chats: HubChats
        let thread: HubThread
        let id: ChatLink
    }

    private var rows: [Row] {
        HubChats.sorted(chats.flatMap { hub in hub.threads.map { (hub, $0) } }).map { hub, thread in
            Row(chats: hub, thread: thread, id: ChatLink(hub: CurrentHub.name(of: hub.pairing), thread: thread.id))
        }
    }

    var body: some View {
        let rows = rows
        NavigationStack(path: $path) {
            // As in Messages: pinned bots in circles above the rest, and one plain list of matches while searching.
            let searching = !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let found = rows.filter { $0.chats.matches($0.thread, search: search) }
            let pinned = searching ? [] : found.filter { $0.chats.isPinned($0.thread) }
            let others = searching ? found : found.filter { !$0.chats.isPinned($0.thread) }
            List {
                if !pinned.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                        ForEach(pinned) { row in
                            Button { path = [row.id] } label: {
                                PinnedAgent(chats: row.chats, thread: row.thread, unread: row.chats.isUnread(row.thread))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(for: row) }
                        }
                    }
                    .padding(.vertical, 8)
                    // Room above the first row for its bubbles.
                    .padding(.top, pinned.prefix(3).contains { $0.chats.note(for: $0.thread) != nil } ? 8 : 0)
                    .listRowSeparator(.hidden)
                }
                ForEach(others) { row in
                    NavigationLink(value: row.id) {
                        AgentRow(chats: row.chats, thread: row.thread, latest: row.chats.latestMessage(of: row.thread),
                                 unread: row.chats.isUnread(row.thread), hub: chats.count > 1 ? row.chats.pairing.hubName : nil)
                    }
                    // As in Messages: dividers between rows, none above the first.
                    .listRowSeparator(row.id == others.first?.id ? .hidden : .visible, edges: .top)
                    // Room for the unread dot, as far from the edge as from the picture.
                    .listRowInsets(.leading, AgentRow.dotGap * 2 + AgentRow.dotSize)
                    .swipeActions(edge: .leading) {
                        Button { row.chats.togglePin(row.thread) } label: { Label("Pin", systemImage: "pin.fill") }
                            .tint(.orange)
                    }
                    .contextMenu { menu(for: row) }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Search")
            .overlay {
                if searching && found.isEmpty && !rows.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if rows.isEmpty {
                    if chats.isEmpty || chats.contains(where: { !$0.isLoaded && $0.error == nil }) {
                        ProgressView()
                    } else if let error = chats.lazy.compactMap(\.error).first {
                        ContentUnavailableView("Not Connected", systemImage: "wifi.exclamationmark", description: Text(error))
                    } else {
                        ContentUnavailableView("No Bots", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ChatLink.self) { link in
                if let hub = chats.first(where: { CurrentHub.name(of: $0.pairing) == link.hub }) {
                    ChatView(chats: hub, threadID: link.thread)
                }
            }
            .toolbar {
                // A plain button, as in Messages, not the round glass default.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingMore = true } label: { Image(systemName: "ellipsis") }
                        .foregroundStyle(.tint)
                        .accessibilityLabel("More")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .wordmarkRefreshable {
                for hub in chats { try? await hub.reload() }
            }
            .sheet(isPresented: $showingMore, onDismiss: openChosen) {
                MoreSheet { choice in
                    chosen = choice
                    showingMore = false
                }
            }
            .sheet(isPresented: $showingProfile) { HubsView() }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $creating) {
                if let first = chats.first { AgentEditor(chats: first, agent: nil, hubs: chats) }
            }
            .sheet(isPresented: $creatingGroup) {
                if let first = chats.first { GroupEditor(chats: first, group: nil, hubs: chats) }
            }
            .sheet(item: $editing) { row in ThreadEditor(chats: row.chats, thread: row.thread) }
        }
        .onChange(of: opening, initial: true, open)
        .onChange(of: rows.map(\.id)) { open() }
        // Not while the phone is away, so the Hub knows at once to notify it instead.
        .task(id: FollowKey(hubs: pairings.map(CurrentHub.name), away: phase == .background)) {
            chats = pairings.map { pairing in chats.first { $0.pairing === pairing } ?? HubChats(pairing: pairing) }
            guard phase != .background else { return }
            await withTaskGroup(of: Void.self) { group in
                for hub in chats { group.addTask { await hub.follow() } }
            }
        }
    }

    /// A conversation's touch-and-hold menu, the same for its row and its pinned circle.
    @ViewBuilder
    private func menu(for row: Row) -> some View {
        if row.chats.isPinned(row.thread) {
            Button { row.chats.togglePin(row.thread) } label: { Label("Unpin", systemImage: "pin.slash.fill") }
        } else {
            Button { row.chats.togglePin(row.thread) } label: { Label("Pin", systemImage: "pin.fill") }
        }
        Button { editing = row } label: { Label(row.thread.group == nil ? "Edit Bot…" : "Edit Group…", systemImage: "pencil") }
    }

    /// Opens a tapped notification's conversation once its Hub's bots have loaded.
    private func open() {
        guard let route = opening,
              let row = rows.first(where: { $0.thread.conversationID == route.conversation
                  && PushTopic.topic(for: $0.chats.pairing) == route.topic }) else { return }
        path = [row.id]
        opening = nil
    }

    private func openChosen() {
        switch chosen {
        case .createBot: creating = true
        case .createGroup: creatingGroup = true
        case .profiles: showingProfile = true
        case .settings: showingSettings = true
        case nil: break
        }
        chosen = nil
    }
}

private struct FollowKey: Equatable {
    let hubs: [String]
    let away: Bool
}

/// A conversation in the list: the Hub, by the name of its folder, and the bot or group.
struct ChatLink: Hashable {
    let hub: String
    let thread: UUID
}

enum MoreChoice { case createBot, createGroup, profiles, settings }

/// The rarely used actions, in a short sheet from the bottom.
struct MoreSheet: View {
    let choose: (MoreChoice) -> Void

    var body: some View {
        VStack(spacing: 12) {
            option("New Bot", systemImage: "plus", .createBot)
            option("New Group", systemImage: "person.2", .createGroup)
            option("Profiles", systemImage: "person.crop.circle", .profiles)
            option("Settings", systemImage: "gear", .settings)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(24)
        .presentationDetents([.height(292)])
        .presentationDragIndicator(.visible)
    }

    private func option(_ title: String, systemImage: String, _ choice: MoreChoice) -> some View {
        Button { choose(choice) } label: {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
    }
}

private struct AgentRow: View {
    let chats: HubChats
    let thread: HubThread
    let latest: LinkMessage?
    let unread: Bool
    /// The conversation's Hub, when several are shown together.
    var hub: String?
    static let dotSize: CGFloat = 10, dotGap: CGFloat = 8

    var body: some View {
        HStack(spacing: 12) {
            ThreadAvatar(chats: chats, thread: thread, size: 48)
                // In the margin left of the picture, as in Messages.
                .overlay(alignment: .leading) {
                    if unread {
                        Circle().fill(.tint).frame(width: Self.dotSize, height: Self.dotSize).offset(x: -(Self.dotSize + Self.dotGap))
                            .accessibilityLabel("Unread")
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(thread.name).font(.headline).lineLimit(1)
                    if let hub {
                        Text(hub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let latest {
                        Text(latest.createdAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text(latest?.body ?? thread.about)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

enum PinnedNote: Equatable {
    case unread(String), status(String)
}

/// A pinned bot or group: a large picture with its name beneath, as Messages shows pinned conversations.
private struct PinnedAgent: View {
    let chats: HubChats
    let thread: HubThread
    let unread: Bool

    var body: some View {
        VStack(spacing: 6) {
            ThreadAvatar(chats: chats, thread: thread, size: 76)
                // Over the picture's top, as Instagram shows notes; the circle keeps its place without one.
                .overlay(alignment: .top) {
                    if let note = chats.note(for: thread) { NoteBubble(note: note).offset(y: -14) }
                }
                .overlay(alignment: .topLeading) {
                    if unread {
                        Circle().fill(.tint).frame(width: 14, height: 14)
                            .overlay { Circle().strokeBorder(Color(.systemBackground), lineWidth: 2) }
                            .accessibilityLabel("Unread")
                    }
                }
            Text(thread.name).font(.caption).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// A short line over a pinned circle: an unread reply in bold, or the bot's status.
private struct NoteBubble: View {
    let note: PinnedNote

    var body: some View {
        let (text, unread) = switch note {
        case .unread(let text): (text, true)
        case .status(let text): (text, false)
        }
        Text(text)
            .font(.caption2.weight(unread ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 104)
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .accessibilityLabel(unread ? "Unread: \(text)" : "Status: \(text)")
    }
}

/// Where a conversation moves when a message lands at its end.
enum ConversationScroll {
    /// Your own message always shows, down at the bottom. Anyone else's shows from its top, so a
    /// long reply reads from its start, and only when you were at the bottom: reading further up,
    /// you stay where you are.
    static func target(for message: LinkMessage, wasAtBottom: Bool) -> UnitPoint? {
        if message.author == .you { return .bottom }
        return wasAtBottom ? .top : nil
    }

    /// Whether the end shows above the composer. A conversation shorter than the screen always is.
    static func isAtBottom(contentOffset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat, bottomInset: CGFloat) -> Bool {
        contentOffset + viewportHeight - bottomInset >= contentHeight - 2
    }
}

/// A conversation's scroll view: it opens at the end, and keeps to the end as it grows while the end shows.
/// Its rows carry their messages' IDs.
struct ConversationScrolling: ViewModifier {
    let latest: LinkMessage?
    /// Starts with no place of its own and leaves the opening to the initial-offset anchor: one starting
    /// at the bottom edge lands past the end and to the side, until first scrolled.
    @State private var position = ScrollPosition(idType: UUID.self)
    /// Whether the end of the conversation shows. Only then does it keep to the end as it grows.
    @State private var atBottom = true

    func body(content: Content) -> some View {
        content
            .scrollPosition($position, anchor: .top)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(atBottom ? .bottom : .top, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                ConversationScroll.isAtBottom(contentOffset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height,
                                              viewportHeight: geometry.containerSize.height, bottomInset: geometry.contentInsets.bottom)
            } action: { _, bottom in atBottom = bottom }
            // Read before the new row is laid out, so atBottom still says where the person was.
            .onChange(of: latest?.id) { _, _ in
                guard let latest, let anchor = ConversationScroll.target(for: latest, wasAtBottom: atBottom) else { return }
                withAnimation { position.scrollTo(id: latest.id, anchor: anchor) }
            }
    }
}

/// A bot's or a group's conversation, laid out like Messages.
struct ChatView: View {
    /// The height of a one-line message field, which the buttons beside it match.
    static let controlHeight: CGFloat = 48

    /// How far the composer's bottom sits above the screen's, given the home bar's room under it, none
    /// with the keyboard up: as low as the system's search field, partly over the home bar.
    static func composerGap(homeBar: CGFloat) -> CGFloat { max(8, homeBar - 6) }
    let chats: HubChats
    let threadID: UUID
    @AppStorage(WebLinkPreview.key) private var previewsLinks = true
    @State private var previewing: PreviewedLink?
    @State private var draft = ""
    @State private var caret = 0
    @State private var files: [OutgoingFile] = []
    @State private var problem: String?
    @State private var editing = false
    /// What the Hub asked before a Kick, and whether New Session is being confirmed, as on the Mac.
    @State private var kickConfirmation: LinkKickConfirmation?
    @State private var confirmingNewSession = false
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var importing = false
    /// The live link open full screen. Held here, not by its card: the conversation unloads rows it
    /// lays out again, as on rotating the phone, and a cover presented by a row would close with it.
    @State private var watching: LinkAttachment?
    /// Where the person asked to open the noodlet they are watching, from its card's menu.
    @State private var watchingAt: NoodletManifest.Placement?
    /// The message lifted by a long press, with its reactions and actions.
    @State private var focused: MessageFocus?
    /// Whether the panel of things to attach is open over the conversation.
    @State private var attaching = false
    @Namespace private var attachGlass
    @State private var recorder: VoiceRecorder
    /// The home bar's room under the composer, none with the keyboard up.
    @State private var homeBar: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    init(chats: HubChats, threadID: UUID) {
        self.chats = chats
        self.threadID = threadID
        _recorder = State(initialValue: VoiceRecorder(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("Recordings", isDirectory: true).appendingPathComponent(threadID.uuidString, isDirectory: true)))
    }

    var body: some View {
        Group {
            if let thread = chats.thread(threadID) { conversation(in: thread) }
        }
        // Deleted here or on another device.
        .onChange(of: chats.thread(threadID) == nil) { _, gone in if gone { dismiss() } }
    }

    private func conversation(in thread: HubThread) -> some View {
        let messages = chats.messages(of: thread)
        let bot = thread.bot
        // As in Messages, only your latest message says how far it got.
        let latestOwn = messages.last { $0.author == .you }?.id
        let authors = thread.group == nil ? [:] : HubChats.authorLabels(in: messages) { chats.agent($0)?.draft.name }
        let avatars = thread.group == nil ? [:] : HubChats.authorAvatars(in: messages)
        return ScrollView {
            LazyVStack(spacing: Bubble.rowSpacing) {
                // Reaching the top loads the page before.
                if chats.hasEarlier(thread) {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
                        .task(id: messages.first?.id) { try? await chats.loadEarlier(thread) }
                }
                ForEach(messages) { message in
                    Bubble(chats: chats, thread: thread, message: message, author: authors[message.id],
                           avatar: avatars[message.id].flatMap { chats.agent($0)?.draft }, besideAvatars: thread.group != nil,
                           delivery: message.id == latestOwn || chats.isUnsent(message) ? chats.delivery(of: message) : nil)
                        .id(message.id)
                }
            }
            // Rows keep their place by ID, so earlier messages loading above do not move the one being read.
            .scrollTargetLayout()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .modifier(ConversationScrolling(latest: messages.last))
        .scrollDismissesKeyboard(.interactively)
        .background { ConversationBackdrop(background: chats.background(for: thread), imageURL: chats.backgroundImageURL(for: thread)) }
        // Open means read, including replies that arrive while it is open.
        .onAppear {
            chats.markRead(thread)
            draft = chats.draft(for: thread)
        }
        .onChange(of: draft) { chats.setDraft(draft, for: thread) }
        .onChange(of: messages.last?.id) { chats.markRead(thread) }
        // Behind the attach panel, as in Messages: the conversation blurs, and tapping it closes the panel.
        .overlay {
            if attaching {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    .onTapGesture { setAttaching(false) }
                    .transition(.opacity)
            }
        }
        // The conversation keeps room for a one-line composer at its end. A longer message grows the
        // composer over the conversation, as in Messages, instead of moving it.
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: Self.controlHeight + 8 + Self.composerGap(homeBar: homeBar) - homeBar) }
        .overlay(alignment: .bottom) {
            composer
                .padding(.bottom, Self.composerGap(homeBar: homeBar))
                .ignoresSafeArea(.container, edges: .bottom)
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { homeBar = $0 }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { editing = true } label: {
                    HStack(spacing: 8) {
                        ThreadAvatar(chats: chats, thread: thread, size: 28)
                        Text(thread.name).font(.headline).foregroundStyle(.primary)
                    }
                }
                .accessibilityHint("Edit")
            }
            // As in the Mac's sidebar: Kick only for a failed bot, New Session always. Groups have neither.
            if let bot {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if bot.phase == .failed {
                            Button("Kick", systemImage: "arrow.clockwise") { kick(bot) }
                        }
                        Button("New Session", systemImage: "sparkles") { confirmingNewSession = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .alert("Start a new session for \(thread.name)?", isPresented: $confirmingNewSession) {
            Button("New Session") { run { if let bot { try await chats.startNewSession(bot) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(thread.name) will start with a fresh context. Its workspace, memory and messages are kept.")
        }
        .alert(kickConfirmation?.title ?? "Recover Bot", isPresented: Binding(
            get: { kickConfirmation != nil }, set: { if !$0 { kickConfirmation = nil } }
        ), presenting: kickConfirmation) { confirmation in
            Button(confirmation.confirmTitle) { run { if let bot { try await chats.confirmKick(confirmation, for: bot) } } }
            if confirmation.offersNewSession {
                Button("New Session") { run { if let bot { try await chats.startNewSession(bot) } } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .sheet(isPresented: $editing) { ThreadEditor(chats: chats, thread: thread) }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, maxSelectionCount: 10,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task { await add(items) }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                guard let data = image.jpegData(compressionQuality: 0.9) else { return }
                attach { try PickedFiles.store(data, named: "Photo.jpg", type: .jpeg) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            attach { try result.get().map(PickedFiles.copy) }
        }
        .environment(\.watchLive) { watchingAt = $1; watching = $0 }
        .environment(\.openURL, OpenURLAction { url in
            guard let link = WebLinkPreview.previewed(url, enabled: previewsLinks) else { return .systemAction }
            previewing = PreviewedLink(url: link)
            return .handled
        })
        .sheet(item: $previewing) { WebPreview(url: $0.url).ignoresSafeArea() }
        .environment(\.unsentActions) { unsentActions(for: $0, in: thread) }
        .environment(\.focusMessage) { focus in
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { focused = focus }
        }
        // Over the whole screen, bars included, as in Messages; the overlay animates itself in and out.
        .fullScreenCover(item: $focused) { focus in
            MessageActions(focus: focus, unsent: unsentActions(for: focus.message, in: thread)) { emoji in
                Task { try? await chats.toggleReaction(emoji, on: focus.message, in: thread) }
            } close: {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { focused = nil }
            }
            .presentationBackground(.clear)
        }
        .fullScreenCover(item: $watching) { attachment in
            if attachment.liveKind == .noodlet {
                NoodletScreen(chats: chats, thread: thread, attachment: attachment, requested: watchingAt)
            } else {
                LiveSurfaceScreen(chats: chats, thread: thread, attachment: attachment)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if recorder.phase != .idle, let thread = chats.thread(threadID) {
                VoiceRecordingBar(recorder: recorder) { audio, voice in
                    try await chats.sendVoice(audio, voice: voice, to: thread)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                // A tap that misses a control must not reach the conversation underneath.
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                messageComposer
            }
        }
        .padding(.horizontal, 12).padding(.top, 8)
        // No bar behind the composer: the conversation's background runs to the bottom, as in Messages.
        .onDisappear { Task { await recorder.discard() } }
    }

    private var messageComposer: some View {
        VStack(spacing: 6) {
            mentions
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
                    // It goes by itself; a message that did not go through says so on the message instead.
                    .task(id: problem) {
                        try? await Task.sleep(for: .seconds(6))
                        if !Task.isCancelled { self.problem = nil }
                    }
            }
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(files) { file in
                            PendingFileChip(file: file) { files.removeAll { $0.id == file.id } }
                        }
                    }
                }
            }
            GlassEffectContainer {
                HStack(alignment: .bottom, spacing: 8) {
                    attachButton
                        // Above the field, which the open panel covers.
                        .zIndex(1)
                    messageField
                }
            }
        }
    }

    /// The plus, which grows into the panel of things to attach, as in Messages.
    private var attachButton: some View {
        ZStack(alignment: .bottomLeading) {
            if attaching {
                attachPanel
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .glassEffectID("attach", in: attachGlass)
                    .fixedSize()
            } else {
                Button { setAttaching(true) } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.controlHeight, height: Self.controlHeight)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .glassEffectID("attach", in: attachGlass)
                .accessibilityLabel("Add")
            }
        }
        // The open panel spills over the conversation without moving the field.
        .frame(width: Self.controlHeight, height: Self.controlHeight, alignment: .bottomLeading)
    }

    private var attachPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            if CameraPicker.isAvailable {
                attachOption("Camera", systemImage: "camera.fill", tint: .gray) { takingPhoto = true }
            }
            attachOption("Photos", systemImage: "photo.on.rectangle.angled", tint: .blue) { pickingPhotos = true }
            attachOption("Files", systemImage: "folder.fill", tint: .cyan) { importing = true }
        }
        .padding(8)
        .frame(width: 230, alignment: .leading)
        .accessibilityAction(.escape) { setAttaching(false) }
    }

    private func attachOption(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            setAttaching(false)
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(tint.gradient, in: Circle())
                Text(title).font(.body).foregroundStyle(.primary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func setAttaching(_ open: Bool) {
        // As in Messages, the keyboard goes while the panel is open.
        if open { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        withAnimation(.bouncy(duration: 0.4, extraBounce: 0.05)) { attaching = open }
    }

    /// The field, with the microphone or send button inside it, as in Messages.
    private var messageField: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ComposerField(text: $draft, caret: $caret, placeholder: "Message") { image in
                attach { try PickedFiles.store(image.pngData() ?? Data(), named: "Image.png", type: .png) }
            }
            .padding(.vertical, 13)
            // As in Messages: the microphone until there is something to send.
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty {
                Button { recorder.start() } label: {
                    Image(systemName: "mic").font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: Self.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record Voice Message")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                        .frame(width: 30, height: Self.controlHeight)
                }
                .accessibilityLabel("Send")
            }
        }
        .padding(.leading, 16).padding(.trailing, 5)
        .frame(minHeight: Self.controlHeight)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.controlHeight / 2, style: .continuous))
        // Tapping the field while the panel is open closes the panel first.
        .overlay {
            if attaching {
                Color.clear.contentShape(Rectangle()).onTapGesture { setAttaching(false) }
            }
        }
    }

    /// Bots matching an @ being typed: this bot first, or a group's own bots only.
    @ViewBuilder private var mentions: some View {
        if let request = MentionCompletion.request(in: draft, caret: caret) {
            let group = chats.thread(threadID)?.group
            let bots = request.matches(group.map(chats.members) ?? chats.agents, preferred: threadID)
            if !bots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(bots) { bot in
                            Button {
                                // After the name, and after the space added when it ends the message.
                                let atEnd = NSMaxRange(request.range) == draft.utf16.count
                                caret = request.range.location + bot.draft.name.utf16.count + (atEnd ? 1 : 0)
                                draft = request.replacing(with: bot.draft.name, in: draft)
                            } label: {
                                HStack(spacing: 6) {
                                    AgentAvatar(draft: bot.draft, size: 22)
                                    Text(bot.draft.name).font(.subheadline)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Color(.secondarySystemBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func attach(_ pick: () throws -> OutgoingFile) { attach { [try pick()] } }

    private func attach(_ pick: () throws -> [OutgoingFile]) {
        do { files += try pick() } catch { problem = error.localizedDescription }
    }

    private func add(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                if let file = try await PickedFiles.photo(item, number: files.count + 1) { files.append(file) }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func kick(_ agent: LinkBot) {
        run { kickConfirmation = try await chats.kick(agent) }
    }

    /// Asks the Hub for something, showing what went wrong under the conversation.
    private func run(_ request: @escaping () async throws -> Void) {
        problem = nil
        Task {
            do { try await request() } catch { problem = error.localizedDescription }
        }
    }

    /// A message that did not go through: tried again only while it is the newest, or taken back to edit.
    private func unsentActions(for message: LinkMessage, in thread: HubThread) -> UnsentActions? {
        guard chats.hasFailed(message) else { return nil }
        return UnsentActions(reason: chats.unsentReason(of: message),
                             tryAgain: chats.canTryAgain(message) ? { Task { await chats.tryAgain(message) } } : nil,
                             edit: {
                                 do {
                                     let (text, picked) = try chats.takeBack(message, in: thread)
                                     draft = [text, draft].filter { !$0.isEmpty }.joined(separator: "\n")
                                     files += picked
                                 } catch {
                                     problem = error.localizedDescription
                                 }
                             },
                             delete: { chats.delete(message, in: thread) })
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !files.isEmpty, let thread = chats.thread(threadID) else { return }
        let sending = files
        draft = ""
        files = []
        problem = nil
        Task {
            do { try await chats.send(body, files: sending, to: thread) } catch { problem = error.localizedDescription }
        }
    }
}

/// Long replies fold so they do not take over the conversation. The limits are the Mac's.
enum MessageFolding {
    static let foldedLines = 8

    static func isLong(_ text: String) -> Bool {
        var lines = 1
        for (index, character) in text.enumerated() {
            if index >= 1_200 { return true }
            if character.isNewline {
                lines += 1
                if lines > 12 { return true }
            }
        }
        return false
    }
}

private struct Bubble: View {
    let chats: HubChats
    let thread: HubThread
    let message: LinkMessage
    /// In a group, the bot's name above the first of its messages in a row.
    let author: String?
    /// In a group, the bot's picture beside the last of its messages in a row.
    let avatar: LinkBotDraft?
    /// Whether bot messages keep room for a picture beside them, so a run of them lines up.
    let besideAvatars: Bool
    /// Shown under your latest message, and under any that did not go through.
    let delivery: String?
    @State private var expanded = false
    @State private var pressing = false
    @State private var textFrame = CGRect.zero
    @Environment(\.focusMessage) private var focusMessage
    @Environment(\.unsentActions) private var unsentActions
    @AppStorage(AttachmentLayout.key) private var attachmentLayout = AttachmentLayout.standard.rawValue

    /// The gap between messages in the conversation.
    static let rowSpacing: CGFloat = 6
    /// A bot's picture beside its messages in a group.
    private static let avatarSize: CGFloat = 28
    /// How far a reaction badge hangs above the top of what it marks.
    private static let reactionOverhang: CGFloat = 16

    var body: some View {
        switch message.author {
        case .system:
            Text(message.body).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        case .you:
            let failed = unsentActions(message)
            HStack {
                Spacer(minLength: 48)
                // As in Messages, a message that did not go through has a red mark beside it, offering what to do.
                if let failed {
                    Menu { failed.menu } label: {
                        Image(systemName: "exclamationmark.circle").font(.title2).foregroundStyle(.red)
                    }
                    .accessibilityLabel("Not Delivered")
                }
                VStack(alignment: .trailing, spacing: 4) {
                    content(foreground: .white, background: .accentColor)
                    if let delivery {
                        Text(delivery).font(.caption2).foregroundStyle(failed == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    }
                }
            }
            // As on the Mac, every message keeps the badge's clearance, reactions or not, so
            // reacting never moves the conversation. The row gap covers the rest of it.
            .padding(.top, Self.reactionOverhang - Self.rowSpacing)
        case .bot:
            HStack(alignment: .bottom, spacing: 6) {
                if let avatar {
                    AgentAvatar(draft: avatar, size: Self.avatarSize)
                } else if besideAvatars {
                    Color.clear.frame(width: Self.avatarSize, height: 0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let author {
                        Text(author).font(.caption).foregroundStyle(.secondary).padding(.leading, 12).padding(.top, 4)
                    }
                    content(foreground: .primary, background: Color(.secondarySystemBackground))
                }
                Spacer(minLength: 48)
            }
            .padding(.top, Self.reactionOverhang - Self.rowSpacing)
        }
    }

    private func react(_ emoji: String) {
        Task { try? await chats.toggleReaction(emoji, on: message, in: thread) }
    }

    /// As in Messages: one round badge per emoji over the bubble's top corner, away from the
    /// conversation's edge, with a count when more than one reacted. Yours are tinted, and tapping
    /// one adds or takes back yours.
    @ViewBuilder private var reactions: some View {
        let counts = Dictionary(grouping: message.reactions, by: \.emoji)
        let emojis = message.reactions.map(\.emoji).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        HStack(spacing: -6) {
            ForEach(emojis, id: \.self) { emoji in
                let count = counts[emoji]?.count ?? 0
                let mine = counts[emoji]?.contains { $0.author == .you } == true
                Button { react(emoji) } label: {
                    Text(count > 1 ? "\(emoji) \(count)" : emoji).font(.footnote)
                        .foregroundStyle(mine ? .white : .primary)
                        .padding(.horizontal, 6).frame(minWidth: 28, minHeight: 28)
                        .background(mine ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemBackground)), in: Capsule())
                        .overlay(Capsule().stroke(Color(.systemBackground), lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The text first, then its link and files, as on the Mac. Reactions are on the message, so
    /// they mark its text, and the files only when there is no text to mark.
    @ViewBuilder private func content(foreground: Color, background: Color) -> some View {
        if showsText {
            MessageText(text: message.body, folded: folded, foreground: foreground, background: background) { expanded = true }
                .scaleEffect(pressing ? 0.96 : 1)
                .animation(.spring(duration: 0.25), value: pressing)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { textFrame = $0 }
                .onLongPressGesture(minimumDuration: 0.35) { lift() } onPressingChanged: { pressing = $0 }
                .accessibilityAction(named: "React") { lift() }
                .accessibilityAction(named: "Copy") { UIPasteboard.general.string = message.body }
                .modifier(Reactions(badges: reactions, shown: !message.reactions.isEmpty, trailing: message.author == .you))
        }
        if let url = LinkPreview.firstURL(in: message.body) {
            LinkPreviewCard(url: url, previews: chats.linkPreviews, conversationID: thread.conversationID)
        }
        if !message.attachments.isEmpty {
            MessageAttachments(attachments: message.attachments, mode: AttachmentLayout(rawValue: attachmentLayout) ?? .standard,
                               trailing: message.author == .you) { attachment, compact in
                AttachmentView(chats: chats, thread: thread, attachment: attachment, group: message.attachments, compact: compact)
            }
            .modifier(Reactions(badges: reactions, shown: !showsText && !message.reactions.isEmpty, trailing: message.author == .you))
        }
    }

    /// Hangs the badges over the top corner away from the conversation's edge, into the room every
    /// message keeps above it.
    private struct Reactions<Badges: View>: ViewModifier {
        let badges: Badges
        let shown: Bool
        let trailing: Bool

        func body(content: Content) -> some View {
            content.overlay(alignment: trailing ? .topLeading : .topTrailing) {
                if shown { badges.offset(x: trailing ? -10 : 10, y: -Bubble.reactionOverhang) }
            }
        }
    }

    /// A message of files alone carries a body like "Sent 2 attachments", which the files already show.
    private var showsText: Bool {
        !(message.attachments.count > 0 && message.body.wholeMatch(of: /Sent \d+ attachments?/) != nil)
            && !(message.attachments.contains { $0.voice != nil } && message.body == HubChats.voiceBody)
    }

    private var folded: Bool { !expanded && MessageFolding.isLong(message.body) }

    private func lift() {
        focusMessage(MessageFocus(message: message, frame: textFrame, folded: folded))
    }
}

/// Makes a new agent on the Hub, or edits one: its name, colour and the harness it runs on.
struct AgentEditor: View {
    /// The Hub the agent is on, or is made on.
    @State private var chats: HubChats
    /// Nil makes a new agent.
    let agent: LinkBot?
    /// The Hubs a new agent can be made on.
    private let hubs: [HubChats]
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LinkBotDraft
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var problem: String?

    init(chats: HubChats, agent: LinkBot?, hubs: [HubChats] = []) {
        _chats = State(initialValue: chats)
        self.agent = agent
        self.hubs = hubs
        _draft = State(initialValue: agent?.draft ?? LinkBotDraft(name: "", provider: "", avatarSymbolName: "sparkles",
                                                                  avatarColorIndex: Int.random(in: 0..<AgentAvatar.colourCount)))
    }

    /// What the plan lends, plus the agent's current harness if the plan no longer lends it.
    private var harnesses: [LinkHarness] {
        var lent = chats.pairing.status?.harnesses ?? []
        if let agent, !lent.contains(where: { $0.provider == agent.draft.provider && $0.profile == agent.draft.profile }) {
            // Named as the Hub names it, when it still lends the harness under another profile.
            let name = lent.first { $0.provider == agent.draft.provider }?.providerName ?? agent.draft.provider
            lent.insert(LinkHarness(provider: agent.draft.provider, providerName: name,
                                    profile: agent.draft.profile, profileName: nil), at: 0)
        }
        return lent
    }

    private var hub: Binding<String> {
        Binding {
            CurrentHub.name(of: chats.pairing)
        } set: { name in
            if let hub = hubs.first(where: { CurrentHub.name(of: $0.pairing) == name }) { chats = hub }
        }
    }

    private var harness: Binding<LinkHarness?> {
        Binding {
            harnesses.first { $0.provider == draft.provider && $0.profile == draft.profile }
        } set: { harness in
            draft.provider = harness?.provider ?? ""
            draft.profile = harness?.profile
            draft.reasoningEffort = nil
            draft.setModel(harness?.initialModel, on: harness)
        }
    }

    private var model: Binding<String?> {
        Binding { draft.model } set: { draft.setModel($0, on: harness.wrappedValue) }
    }

    /// The efforts the chosen model offers, plus the agent's current one if the model no longer offers it.
    private var efforts: [LinkEffort] {
        var efforts = models.first { $0.id == draft.model }?.efforts ?? []
        if let effort = draft.reasoningEffort, !efforts.isEmpty, !efforts.contains(where: { $0.id == effort }) {
            efforts.insert(LinkEffort(id: effort, name: effort.capitalized), at: 0)
        }
        return efforts
    }

    /// The models the chosen harness offers, plus the agent's current one if the plan no longer lends it.
    private var models: [LinkModel] {
        var models = harness.wrappedValue?.models ?? []
        if let model = draft.model, !models.contains(where: { $0.id == model }) {
            models.insert(LinkModel(id: model, name: model), at: 0)
        }
        return models
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        BotPictureEditor(draft: $draft)
                    } label: {
                        VStack(spacing: 8) {
                            AgentAvatar(draft: draft, size: 88)
                            Text("Edit").font(.subheadline).foregroundStyle(.tint)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .accessibilityLabel("Edit Picture")
                }
                Section {
                    TextField("Name", text: $draft.name)
                }
                Section {
                    if agent == nil, hubs.count > 1 {
                        Picker("Hub", selection: hub) {
                            ForEach(hubs, id: \.pairing.directory) { hub in
                                Text(hub.pairing.hubName).tag(CurrentHub.name(of: hub.pairing))
                            }
                        }
                    }
                    if harnesses.isEmpty {
                        Text("Your plan lends no harnesses").foregroundStyle(.secondary)
                    } else {
                        Picker(selection: harness) {
                            if harness.wrappedValue == nil { Text("Choose").tag(LinkHarness?.none) }
                            ForEach(harnesses, id: \.self) { harness in
                                // The menu shows a second text as a subtitle, so a long profile name keeps its own line.
                                VStack {
                                    Text(harness.providerName)
                                    if let profile = harness.profileName { Text(profile) }
                                }
                                .tag(LinkHarness?.some(harness))
                            }
                        } label: {
                            Text("Harness")
                        } currentValueLabel: {
                            Text(harness.wrappedValue?.chosenName ?? "Choose")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let lent = harness.wrappedValue, !models.isEmpty {
                            Picker("Model", selection: model) {
                                if !lent.restrictsModels || draft.model == nil {
                                    Text(lent.restrictsModels ? "Choose" : "Default").tag(String?.none)
                                }
                                ForEach(models) { Text($0.name).tag(String?.some($0.id)) }
                            }
                        }
                        if !efforts.isEmpty {
                            Picker("Effort", selection: $draft.reasoningEffort) {
                                Text("Default").tag(String?.none)
                                ForEach(efforts) { Text($0.name).tag(String?.some($0.id)) }
                            }
                        }
                    }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
                if let agent {
                    Section {
                        NavigationLink("Tools") { HubToolsScreen(chats: chats, agent: agent, kind: .connection) }
                        NavigationLink("Computers") { HubToolsScreen(chats: chats, agent: agent, kind: .computer) }
                        NavigationLink("Browsers") { HubToolsScreen(chats: chats, agent: agent, kind: .browser) }
                    }
                    Section {
                        NavigationLink("Background") { BackgroundEditor(chats: chats, thread: .bot(agent)) }
                    }
                    Section {
                        Button("Delete Bot", role: .destructive) { confirmingDelete = true }
                            .disabled(saving)
                    }
                }
            }
            .confirmationDialog("Delete \(agent?.draft.name ?? "")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: delete)
            } message: {
                Text("The bot and its conversation are deleted from the Hub for all your devices.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(agent == nil ? "Create" : "Save", action: save)
                            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.provider.isEmpty
                                      || (harness.wrappedValue?.restrictsModels == true && draft.model == nil))
                    }
                }
            }
            .task(id: CurrentHub.name(of: chats.pairing)) {
                if chats.pairing.status == nil { await chats.pairing.refresh(quietly: true) }
            }
        }
    }

    private func delete() {
        guard let agent else { return }
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                try await chats.delete(agent)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                if var agent {
                    agent.draft = draft
                    try await chats.update(agent)
                } else {
                    _ = try await chats.create(draft)
                }
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// The editor for a bot or a group.
struct ThreadEditor: View {
    let chats: HubChats
    let thread: HubThread

    var body: some View {
        switch thread {
        case .bot(let bot): AgentEditor(chats: chats, agent: bot)
        case .group(let group): GroupEditor(chats: chats, group: group)
        }
    }
}

/// Makes a group of bots on the Hub, or edits one: its name, description and bots.
struct GroupEditor: View {
    /// The Hub the group is on, or is made on. Its bots are the ones to choose from.
    @State private var chats: HubChats
    /// Nil makes a new group.
    let group: LinkGroup?
    /// The Hubs a new group can be made on.
    private let hubs: [HubChats]
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LinkGroupDraft
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var problem: String?

    init(chats: HubChats, group: LinkGroup?, hubs: [HubChats] = []) {
        _chats = State(initialValue: chats)
        self.group = group
        self.hubs = hubs
        _draft = State(initialValue: group?.draft ?? LinkGroupDraft(name: "", botIDs: []))
    }

    /// A group is all one Hub's bots, so choosing another Hub clears the choice.
    private var hub: Binding<String> {
        Binding {
            CurrentHub.name(of: chats.pairing)
        } set: { name in
            guard let hub = hubs.first(where: { CurrentHub.name(of: $0.pairing) == name }), hub !== chats else { return }
            chats = hub
            draft.botIDs = []
        }
    }

    private var bots: [LinkBot] {
        chats.agents.sorted { $0.draft.name.localizedStandardCompare($1.draft.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("Description", text: $draft.publicDescription, axis: .vertical)
                        .lineLimit(2...4)
                }
                if group == nil, hubs.count > 1 {
                    Section {
                        Picker("Hub", selection: hub) {
                            ForEach(hubs, id: \.pairing.directory) { hub in
                                Text(hub.pairing.hubName).tag(CurrentHub.name(of: hub.pairing))
                            }
                        }
                    }
                }
                Section("Members") {
                    if bots.isEmpty {
                        Text("No Bots").foregroundStyle(.secondary)
                    }
                    ForEach(bots) { bot in
                        let chosen = draft.botIDs.contains(bot.id)
                        Button {
                            if chosen { draft.botIDs.removeAll { $0 == bot.id } } else { draft.botIDs.append(bot.id) }
                        } label: {
                            HStack(spacing: 12) {
                                AgentAvatar(draft: bot.draft, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bot.draft.name).foregroundStyle(.primary)
                                    if !bot.about.isEmpty {
                                        Text(bot.about)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                if chosen { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
                if let group {
                    Section {
                        NavigationLink("Background") { BackgroundEditor(chats: chats, thread: .group(group)) }
                    }
                    Section {
                        Button("Delete Group", role: .destructive) { confirmingDelete = true }
                            .disabled(saving)
                    }
                }
            }
            .navigationTitle(group == nil ? "New Group" : "Group Info")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete \(group?.draft.name ?? "")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: delete)
            } message: {
                Text("The group and its messages are deleted from the Hub for all your devices. Its bots stay.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(group == nil ? "Create" : "Save", action: save)
                            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || members.isEmpty)
                    }
                }
            }
        }
    }

    /// The chosen bots still on the Hub; one deleted meanwhile is left out.
    private var members: [UUID] { draft.botIDs.filter { chats.agent($0) != nil } }

    private func delete() {
        guard let group else { return }
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                try await chats.deleteGroup(group)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func save() {
        draft.name = draft.name.trimmingCharacters(in: .whitespaces)
        draft.botIDs = members
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                if var group {
                    group.draft = draft
                    try await chats.updateGroup(group)
                } else {
                    _ = try await chats.createGroup(draft)
                }
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

extension LinkHarness {
    /// One line for the chosen harness: the provider, then the profile when it is not the harness's own login.
    var chosenName: String {
        profileName.map { "\(providerName) · \($0)" } ?? providerName
    }
}

/// A bot's picture, or a group's: its first bots together, as Noodle on the Mac shows a group.
struct ThreadAvatar: View {
    let chats: HubChats
    let thread: HubThread
    let size: CGFloat

    var body: some View {
        switch thread {
        case .bot(let bot):
            AgentAvatar(draft: bot.draft, size: size, phase: chats.phase(of: bot))
        case .group(let group):
            let members = chats.members(of: group)
            if members.count == 1, let bot = members.first {
                // One bot in front of a disc, so it still reads as a group.
                ZStack {
                    Circle().fill(.quaternary).frame(width: size * 0.88, height: size * 0.88)
                        .offset(x: size * 0.06, y: size * 0.06)
                    AgentAvatar(draft: bot.draft, size: size * 0.86)
                        .overlay { Circle().stroke(Color(.systemBackground), lineWidth: 2) }
                        .offset(x: -size * 0.06, y: -size * 0.06)
                }
                .frame(width: size, height: size)
            } else {
                ZStack {
                    Circle().fill(.quaternary)
                    ForEach(Array(members.prefix(3).enumerated()), id: \.element.id) { index, bot in
                        AgentAvatar(draft: bot.draft, size: size * 0.62)
                            .overlay { Circle().stroke(Color(.systemBackground), lineWidth: 2) }
                            .offset(Self.offset(index, size: size))
                    }
                }
                .frame(width: size, height: size)
            }
        }
    }

    private static func offset(_ index: Int, size: CGFloat) -> CGSize {
        switch index {
        case 0: CGSize(width: -size * 0.18, height: -size * 0.14)
        case 1: CGSize(width: size * 0.18, height: -size * 0.14)
        default: CGSize(width: 0, height: size * 0.19)
        }
    }
}

/// The bot's picture, or its symbol on its colour, as Noodle on the Mac shows it.
struct AgentAvatar: View {
    /// The same gradients as the Mac's bot avatars, indexed the same way.
    private static let gradients: [[Color]] = [
        [.blue, .cyan], [.purple, .pink], [.orange, .yellow], [.mint, .teal], [.indigo, .blue], [.pink, .orange],
    ]
    let draft: LinkBotDraft
    let size: CGFloat
    /// Shown as a dot in the corner, as on the Mac. Nil shows none.
    var phase: LinkBotPhase?

    static var colourCount: Int { gradients.count }

    /// The Mac's colours: working blue, failed red, ready green, anything else grey.
    static func colour(of phase: LinkBotPhase) -> Color {
        switch phase {
        case .working: .blue
        case .failed: .red
        case .ready: .green
        case .offline, .starting: .gray
        }
    }

    /// Bots may store any integer; it wraps onto the palette.
    static func colourIndex(_ colour: Int) -> Int { Int(colour.magnitude % UInt(gradients.count)) }

    static func swatch(_ index: Int) -> some View {
        Circle().fill(LinearGradient(colors: gradients[index], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    var body: some View {
        Group {
            if let data = draft.avatarImageData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Self.swatch(Self.colourIndex(draft.avatarColorIndex))
                    .overlay {
                        Image(systemName: draft.avatarSymbolName ?? "sparkles")
                            .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if let phase {
                let dot = max(8, size * 0.24)
                Circle().fill(Self.colour(of: phase))
                    .frame(width: dot, height: dot)
                    .overlay { Circle().strokeBorder(Color(.systemBackground), lineWidth: 2) }
                    .accessibilityLabel(phase.rawValue.capitalized)
            }
        }
        .accessibilityHidden(phase == nil)
    }
}
