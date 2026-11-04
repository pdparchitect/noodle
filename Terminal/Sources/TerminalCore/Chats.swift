import Foundation
import HubLink
import Observation
import UniformTypeIdentifiers

/// A bot's own conversation or a group's, as the list shows it.
public enum HubThread: Equatable, Sendable {
    case bot(LinkBot), group(LinkGroup)

    public var id: UUID {
        switch self {
        case .bot(let bot): bot.id
        case .group(let group): group.id
        }
    }

    /// A group's ID is its conversation's.
    public var conversationID: UUID {
        switch self {
        case .bot(let bot): bot.conversationID
        case .group(let group): group.id
        }
    }

    public var name: String {
        switch self {
        case .bot(let bot): bot.draft.name
        case .group(let group): group.draft.name
        }
    }

    public var about: String {
        switch self {
        case .bot(let bot): bot.draft.publicDescription
        case .group(let group): group.draft.publicDescription
        }
    }

    public var createdAt: Date {
        switch self {
        case .bot(let bot): bot.createdAt
        case .group(let group): group.createdAt
        }
    }

    public var readUpTo: Date? {
        switch self {
        case .bot(let bot): bot.readUpTo
        case .group(let group): group.readUpTo
        }
    }

    /// When its user pinned it on the Hub, for all their devices.
    public var pinnedAt: Date? {
        switch self {
        case .bot(let bot): bot.pinnedAt
        case .group(let group): group.pinnedAt
        }
    }

    public var isArchived: Bool {
        switch self {
        case .bot(let bot): bot.archivedAt != nil
        case .group(let group): group.archivedAt != nil
        }
    }

    public var bot: LinkBot? {
        if case .bot(let bot) = self { bot } else { nil }
    }

    public var group: LinkGroup? {
        if case .group(let group) = self { group } else { nil }
    }
}

/// One Hub's bots, groups and conversations, as this terminal last heard them. Nothing is kept on disk but the
/// pairing itself: each launch asks the Hub again, as a window onto it.
@MainActor @Observable public final class HubChats: Identifiable {
    public let pairing: HubPairing
    public internal(set) var bots: [LinkBot] = []
    public internal(set) var groups: [LinkGroup] = []
    /// This user's tool connections, computers and browsers on the Hub, which bots use when assigned.
    public internal(set) var connections: [LinkConnection] = []
    public internal(set) var computers: [LinkComputer] = []
    public internal(set) var browsers: [LinkBrowser] = []
    /// Each conversation's messages this terminal has, oldest first.
    public internal(set) var conversations: [UUID: [LinkMessage]] = [:]
    /// Where the earliest message here sits in each conversation; above zero, earlier ones wait on the Hub.
    public private(set) var start: [UUID: Int] = [:]
    /// How far each conversation was read, here or on another device.
    public private(set) var readUpTo: [UUID: Date] = [:]
    public private(set) var isLoaded = false
    public private(set) var isConnected = false
    public private(set) var error: String?
    /// Your messages the Hub does not have yet, with why the last try failed, if it did.
    public internal(set) var unsent: [UUID: String?] = [:]
    public private(set) var sending: Set<UUID> = []
    /// The conversation on screen, which loads first when everything syncs.
    @ObservationIgnored public var shownConversation: UUID?
    /// Where the next page of each conversation starts: it stops at a message the bot has not taken yet, so that
    /// message comes again until it shows as delivered.
    @ObservationIgnored private var next: [UUID: Int] = [:]
    @ObservationIgnored private let pause: @Sendable (Duration) async throws -> Void
    @ObservationIgnored var retryPauses: [Duration] = [.zero, .seconds(2), .seconds(5), .seconds(15)]
    static let pageSize = 50

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    public init(pairing: HubPairing, pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.pairing = pairing
        self.pause = pause
    }

    public var hubName: String { pairing.status?.hubName ?? pairing.hub?.name ?? "Hub" }

    public var threads: [HubThread] { bots.map(HubThread.bot) + groups.map(HubThread.group) }

    /// Archived bots and groups are left out until brought back elsewhere.
    public var listedThreads: [HubThread] { threads.filter { !$0.isArchived } }

    public func thread(_ id: UUID) -> HubThread? { threads.first { $0.id == id } }

    public func messages(of thread: HubThread) -> [LinkMessage] { conversations[thread.conversationID] ?? [] }

    public func hasEarlier(_ thread: HubThread) -> Bool { (start[thread.conversationID] ?? 0) > 0 }

    /// When the conversation last moved, or the bot or group was made.
    public func recency(of thread: HubThread) -> Date { messages(of: thread).last?.createdAt ?? thread.createdAt }

    /// Whether a bot has written since the conversation was last read on any of the person's devices.
    public func isUnread(_ thread: HubThread) -> Bool {
        guard let reply = messages(of: thread).last(where: { if case .bot = $0.author { true } else { false } }) else { return false }
        return readUpTo[thread.conversationID].map { reply.createdAt > $0 } ?? true
    }

    /// How a conversation notifies: a group as set on its own or for all groups; a bot's every reply.
    public func notifications(of thread: HubThread) -> LinkNotifications {
        guard let group = thread.group else { return .all }
        return LinkNotifications.effective(group.notifications, inGroups: pairing.status?.groupNotifications ?? .all)
    }

    /// Unread, and not a muted group, whose row only dims its dot.
    public func countsAsUnread(_ thread: HubThread) -> Bool { isUnread(thread) && notifications(of: thread) != .muted }

    /// Why nothing can be sent here, shown in place of the composer's prompt.
    public func composerUnavailableReason(for thread: HubThread) -> String? {
        switch thread {
        case .bot(let bot):
            return bot.archivedAt == nil ? nil : "\(bot.draft.name) is archived"
        case .group(let group):
            if group.archivedAt != nil { return "This group is archived" }
            let members = members(of: group)
            return !members.isEmpty && members.allSatisfy({ $0.archivedAt != nil }) ? "Every bot in this group is archived" : nil
        }
    }

    public func members(of group: LinkGroup) -> [LinkBot] { group.draft.botIDs.compactMap { id in bots.first { $0.id == id } } }

    /// Who wrote a message.
    public func authorName(of message: LinkMessage, in thread: HubThread) -> String {
        switch message.author {
        case .you: "You"
        case .bot(let id): bots.first { $0.id == id }?.draft.name ?? thread.name
        case .system: thread.name
        }
    }

    /// How far your message got.
    public func delivery(of message: LinkMessage) -> String? {
        guard message.author == .you else { return nil }
        if sending.contains(message.id) { return "Sending…" }
        if unsent[message.id] != nil { return "Not delivered" }
        return message.delivered ? nil : "Sent"
    }

    // MARK: Following the Hub

    /// Follows the Hub's changes until cancelled: the live stream opens first and everything loads beside it.
    /// After a failure it waits longer each time.
    public func follow() async {
        var backoff = Backoff()
        while !Task.isCancelled {
            if await listen() { backoff.reset() }
            guard !Task.isCancelled else { return }
            pairing.reconnect()
            try? await pause(backoff.next())
        }
    }

    private func listen() async -> Bool {
        var opened = false
        do {
            let events = try await pairing.subscribe()
            opened = true
            isConnected = true
            Task { await pairing.refresh(quietly: true) }
            var loading = Task { await catchUp() }
            defer { loading.cancel() }
            for try await event in events {
                do {
                    try await apply(event)
                } catch {
                    self.error = error.localizedDescription
                    loading.cancel()
                    loading = Task { await catchUp() }
                }
            }
            if !Task.isCancelled { throw LinkError("The Hub ended the stream.") }
        } catch let error where !Task.isCancelled {
            self.error = error.localizedDescription
        } catch {}
        isConnected = false
        return opened
    }

    /// Loads what changed while this terminal was not listening, trying again until the Hub answers.
    private func catchUp() async {
        var backoff = Backoff()
        while !Task.isCancelled {
            do {
                try await reload()
                return
            } catch let error where !Task.isCancelled {
                self.error = error.localizedDescription
            } catch {
                return
            }
            try? await pause(backoff.next())
        }
    }

    public func apply(_ event: LinkEvent) async throws {
        switch event {
        case .botsChanged:
            try await reload()
        case .groupsChanged:
            let listed = try await listGroups()
            if let failure = await loadConversations(listed.map(\.id)) { throw failure }
        case .conversationChanged(let id, _):
            try await load(id)
        case .messageChanged(let message):
            // Only a message already here; a new one arrives with its conversation's change.
            guard conversations[message.conversationID]?.contains(where: { $0.id == message.id }) == true else { return }
            settle([message])
            merge([message], into: message.conversationID)
        case .botPhase(let id, let phase):
            if let index = bots.firstIndex(where: { $0.id == id }), bots[index].phase != phase { bots[index].phase = phase }
        case .readChanged(let id, let upTo):
            noteRead(id, upTo: upTo)
        case .pinChanged(let id, let pinnedAt):
            if let index = bots.firstIndex(where: { $0.conversationID == id }) { bots[index].pinnedAt = pinnedAt }
            if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].pinnedAt = pinnedAt }
        case .notificationsChanged(let id, let level):
            if let index = groups.firstIndex(where: { $0.id == id }) { groups[index].notifications = level == .default ? nil : level }
        case .groupNotificationsChanged(let level):
            pairing.groupNotificationsChanged(to: level)
        case .connectionsChanged:
            try await loadConnections()
        case .computersChanged:
            try await loadComputers()
        case .browsersChanged:
            try await loadBrowsers()
        // What only the Mac and phone apps show: live views, calls, effects, backgrounds and sign-ins.
        case .signInPage, .computerCreated, .surfaceOpened,
             .surfaceFailed, .surfaceControls, .backgroundChanged, .usersChanged, .effectWaiting, .callRinging, .callStopped:
            return
        }
    }

    /// Loads the bots and groups and what is new in their conversations. One conversation that does not load
    /// is left as it was, to load next time, and says why in `error`; the rest still load.
    public func reload() async throws {
        guard case .bots(let listed) = try await pairing.request(.bots) else { throw LinkError("The Hub sent an unexpected answer.") }
        setBots(pairing.keptPictures(listed))
        // A Hub from before groups does not know the request; it has none to show.
        let listedGroups = (try? await listGroups()) ?? []
        let failure = await loadConversations(listed.map(\.conversationID) + listedGroups.map(\.id))
        try Task.checkCancellation()
        for thread in threads { if let upTo = thread.readUpTo { noteRead(thread.conversationID, upTo: upTo) } }
        let kept = Set(threads.map(\.conversationID))
        for gone in conversations.keys where !kept.contains(gone) {
            conversations[gone] = nil
            start[gone] = nil
            next[gone] = nil
        }
        if !isLoaded { isLoaded = true }
        error = failure?.localizedDescription
        // The Hub answers again: a message that did not go through goes now.
        for id in unsent.keys { await deliver(id, pauses: [.zero]) }
        // Chats work even when the Hub cannot list tools.
        await loadTools()
        // Pictures come after the chats show, each fetched once.
        await pairing.fetchPictures(listed)
        if bots.map(\.id) == listed.map(\.id) { setBots(pairing.keptPictures(bots)) }
    }

    /// Only a list that changed is set, so a sync that brings nothing new draws nothing again.
    func setBots(_ list: [LinkBot]) {
        if list != bots { bots = list }
    }

    private func listGroups() async throws -> [LinkGroup] {
        guard case .groups(let listed) = try await pairing.request(.groups) else { throw LinkError("The Hub sent an unexpected answer.") }
        if groups != listed { groups = listed }
        for group in listed { if let upTo = group.readUpTo { noteRead(group.id, upTo: upTo) } }
        return listed
    }

    private func noteRead(_ conversationID: UUID, upTo: Date) {
        guard (readUpTo[conversationID] ?? .distantPast) < upTo else { return }
        readUpTo[conversationID] = upTo
    }

    /// Tells the Hub the conversation is read up to its latest message, so every device shows it read.
    public func markRead(_ thread: HubThread) {
        let id = thread.conversationID
        guard let latest = messages(of: thread).last(where: { unsent[$0.id] == nil }),
              (readUpTo[id] ?? .distantPast) < latest.createdAt else { return }
        noteRead(id, upTo: latest.createdAt)
        let mark = LinkReadMark(conversationID: id, messageID: latest.id)
        Task { _ = try? await pairing.request(.markRead(mark)) }
    }

    // MARK: Messages

    private func load(_ conversationID: UUID) async throws {
        let (pages, failure) = try await fetch(conversationID)
        apply(pages, to: conversationID)
        if let failure { throw failure }
    }

    private static func isPending(_ message: LinkMessage) -> Bool { message.author == .you && !message.delivered }

    /// The newest page of a conversation not loaded before, or every page from where the last load stopped.
    private func fetch(_ conversationID: UUID) async throws -> (pages: [LinkMessages], failure: (any Error)?) {
        guard var at = next[conversationID] else {
            return ([try await page(LinkMessagePage(conversationID: conversationID, limit: Self.pageSize))], nil)
        }
        var pages: [LinkMessages] = []
        while true {
            let page: LinkMessages
            do {
                page = try await self.page(LinkMessagePage(conversationID: conversationID, after: at, limit: 2 * Self.pageSize))
            } catch {
                if pages.isEmpty { throw error }
                return (pages, error)
            }
            pages.append(page)
            at += page.messages.count
            if page.messages.contains(where: Self.isPending) || page.messages.isEmpty || at >= page.count { return (pages, nil) }
        }
    }

    private func apply(_ pages: [LinkMessages], to conversationID: UUID) {
        for page in pages {
            settle(page.messages)
            merge(page.messages, into: conversationID)
            // The newest page of a conversation loaded for the first time says where it starts.
            var at = next[conversationID] ?? page.start ?? 0
            if next[conversationID] == nil { start[conversationID] = at }
            if let pending = page.messages.firstIndex(where: Self.isPending) {
                next[conversationID] = at + pending
                return
            }
            at += page.messages.count
            next[conversationID] = at
        }
    }

    /// How many conversations load at once when everything syncs.
    static let loadingWidth = 4

    /// Loads what is new in each conversation, the one on screen first. Why the first that did not load failed.
    private func loadConversations(_ ids: [UUID]) async -> Error? {
        var failure: Error?
        var rest = ids[...]
        if let shown = shownConversation, let index = rest.firstIndex(of: shown) {
            rest.remove(at: index)
            do { try await load(shown) } catch { failure = error }
        }
        let results = await withTaskGroup(of: Fetched.self) { group in
            var results: [Fetched] = []
            for _ in 0..<Self.loadingWidth {
                guard let id = rest.popFirst() else { break }
                group.addTask { await self.fetched(id) }
            }
            while let result = await group.next() {
                results.append(result)
                if let id = rest.popFirst() { group.addTask { await self.fetched(id) } }
            }
            return results
        }
        for result in results {
            apply(result.pages, to: result.id)
            if let failed = result.failure { failure = failure ?? failed }
        }
        return failure
    }

    /// What one conversation's load brought, and why it stopped short, if it did.
    private struct Fetched: Sendable {
        let id: UUID
        var pages: [LinkMessages] = []
        var failure: (any Error)?
    }

    private func fetched(_ id: UUID) async -> Fetched {
        do {
            let (pages, failure) = try await fetch(id)
            return Fetched(id: id, pages: pages, failure: failure)
        } catch {
            return Fetched(id: id, failure: error)
        }
    }

    /// Loads the page before the earliest message here.
    public func loadEarlier(_ thread: HubThread) async throws {
        let id = thread.conversationID
        guard let first = start[id], first > 0 else { return }
        let page = try await self.page(LinkMessagePage(conversationID: id, before: first, limit: Self.pageSize))
        settle(page.messages)
        merge(page.messages, into: id)
        start[id] = page.start ?? 0
    }

    private func page(_ request: LinkMessagePage) async throws -> LinkMessages {
        guard case .messages(let page) = try await pairing.request(.messagePage(request)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        return page
    }

    /// Messages arriving in any order keep the conversation's order.
    func merge(_ messages: [LinkMessage], into conversationID: UUID) {
        let before = conversations[conversationID]
        guard !messages.isEmpty || before == nil else { return }
        var list = before ?? []
        for message in messages {
            if let index = list.firstIndex(where: { $0.id == message.id }) { list[index] = message } else { list.append(message) }
        }
        let merged = list.enumerated()
            .sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }
            .map(\.element)
        if merged != before { conversations[conversationID] = merged }
    }

    // MARK: Sending

    /// A message waiting for the Hub, with its files, which go up first.
    private struct Outgoing {
        var message: LinkOutgoingMessage
        var files: [(url: URL, attachment: LinkAttachment)]
    }

    @ObservationIgnored private var outgoing: [UUID: Outgoing] = [:]

    /// Shows the message at once and sends it, files first, trying again after short pauses while nothing newer has
    /// come. A message of files alone says how many, as on the Mac and phone.
    public func send(_ text: String, files: [URL] = [], to thread: HubThread) async throws {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty || !files.isEmpty else { return }
        let attached = try files.map { url in
            (url: url, attachment: LinkAttachment(
                id: UUID(), filename: url.lastPathComponent, mediaType: Self.mediaType(of: url),
                byteCount: try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
                pixelSize: LinkPixelSize(pictureAt: url)))
        }
        let body = !typed.isEmpty ? typed : "Sent \(files.count) attachment\(files.count == 1 ? "" : "s")"
        let message = LinkOutgoingMessage(conversationID: thread.conversationID, id: UUID(), body: body,
                                          attachmentIDs: attached.map(\.attachment.id))
        outgoing[message.id] = Outgoing(message: message, files: attached)
        unsent[message.id] = .some(nil)
        merge([LinkMessage(id: message.id, conversationID: message.conversationID, author: .you, body: body,
                           createdAt: Date(), delivered: false, attachments: attached.map(\.attachment))], into: message.conversationID)
        await deliver(message.id, pauses: retryPauses)
    }

    static func mediaType(of url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Tries a message that did not go through again, if nothing newer has come since.
    public func tryAgain(_ message: LinkMessage) async {
        guard canTryAgain(message) else { return }
        await deliver(message.id, pauses: [.zero])
    }

    /// Only the newest: out of its place, a message may no longer make sense.
    public func canTryAgain(_ message: LinkMessage) -> Bool {
        unsent[message.id] != nil && !sending.contains(message.id) && conversations[message.conversationID]?.last?.id == message.id
    }

    /// Takes back a message that did not go through.
    public func deleteUnsent(_ message: LinkMessage) {
        guard unsent[message.id] != nil, !sending.contains(message.id) else { return }
        unsent[message.id] = nil
        outgoing[message.id] = nil
        conversations[message.conversationID]?.removeAll { $0.id == message.id }
    }

    /// It goes with the same ID each time, so a Hub that took it already keeps the one copy.
    private func deliver(_ id: UUID, pauses: [Duration]) async {
        guard !sending.contains(id) else { return }
        sending.insert(id)
        defer { sending.remove(id) }
        for delay in pauses {
            try? await pause(delay)
            // Out of its place, a message may no longer make sense.
            guard let waiting = outgoing[id], conversations[waiting.message.conversationID]?.last?.id == id else { return }
            let conversationID = waiting.message.conversationID
            do {
                // Files first: the Hub refuses a message that points at a file it lacks.
                for file in waiting.files { try await pairing.upload(file.url, as: file.attachment, to: conversationID) }
                guard case .message(let sent) = try await pairing.request(.send(waiting.message)) else {
                    throw LinkError("The Hub sent an unexpected answer.")
                }
                settle([sent])
                merge([sent], into: conversationID)
                return
            } catch {
                unsent[id] = .some(error.localizedDescription)
            }
        }
    }

    /// Your messages the Hub now has need no sending again.
    private func settle(_ messages: [LinkMessage]) {
        for message in messages where unsent[message.id] != nil {
            unsent[message.id] = nil
            outgoing[message.id] = nil
        }
    }

    // MARK: Search

    /// Each message in the person's conversations on this Hub that says the term, newest first. The Hub
    /// searches, so it finds what this terminal has not fetched.
    public func searchMessages(_ search: ConversationSearch) async throws -> [LinkMessageMatch] {
        guard case .messageMatches(let matches) = try await pairing.request(.searchMessages(LinkMessageSearch(term: search.term))) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        return matches
    }

    public func searchCandidate<ID>(_ thread: HubThread, id: ID) -> ConversationSearch.Candidate<ID> {
        .init(id: id, isGroup: thread.group != nil, name: thread.name, about: thread.about,
              members: thread.group.map { members(of: $0).map(\.draft.name) } ?? [])
    }
}

/// How long to wait before connecting to a Hub again: twice as long after each failure, from a second up to half
/// a minute, each wait cut by a random part.
struct Backoff {
    private var failures = 0

    mutating func next() -> Duration {
        let full = min(Duration.seconds(30), Duration.seconds(1) * (1 << min(failures, 16)))
        failures += 1
        return full * Double.random(in: 0.5...1)
    }

    mutating func reset() { failures = 0 }
}
