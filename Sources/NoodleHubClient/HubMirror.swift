import BrowserBridge
import ComputerBridge
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

    public private(set) var isConnected = false
    public private(set) var error: String?
    /// Runs when bots here were added, removed or changed, so the app can reload them.
    /// New messages need no call: they land in the conversation files the app already watches.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// This Mac's user's tool connections on the Hub, as last listed.
    public private(set) var connections: [LinkConnection] = []
    /// This Mac's user's computers on the Hub, as last listed.
    public private(set) var computers: [LinkComputer] = []
    /// This Mac's user's browsers on the Hub, as last listed.
    public private(set) var browsers: [LinkBrowser] = []
    /// Computers being made, waiting for the Hub to say they are done.
    @ObservationIgnored private var making: [UUID: CheckedContinuation<LinkComputer, Error>] = [:]
    /// Opens a connection's sign-in page in the browser and returns the address it came back to.
    @ObservationIgnored public var onSignInPage: ((LinkConnection, URL) async throws -> URL)?


    public let pairing: HubPairing
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let url: URL
    private var entries: [Entry] = []
    /// Local messages the Hub already has, so they are not sent again.
    @ObservationIgnored private var acknowledged: Set<UUID> = []

    public init(pairing: HubPairing, repository: WorkspaceRepository, directory: URL) {
        self.pairing = pairing
        self.repository = repository
        url = directory.appendingPathComponent("mirror.json")
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
    }

    public var localAgentIDs: Set<UUID> { Set(entries.map(\.agent)) }

    public func owns(conversation id: UUID) -> Bool { entries.contains { $0.conversation == id } }

    /// Opens the live view of what a card in a conversation here points at, kept on the Hub.
    public func openSurface(attachment: UUID, in conversation: UUID) async throws -> AsyncThrowingStream<LinkEvent, Error> {
        guard let entry = entries.first(where: { $0.conversation == conversation }) else { throw LinkError("That conversation is not on this Hub.") }
        return try await pairing.stream(.openSurface(conversationID: entry.remoteConversation, attachmentID: attachment))
    }

    public func sendSurfaceInput(_ input: SurfaceInput, session: UUID) async throws {
        _ = try await pairing.request(.surfaceInput(sessionID: session, input))
    }

    /// The Hub harness a local stand-in runs on.
    public func harness(ofAgent id: UUID) -> HubHarnessChoice? {
        guard let entry = entries.first(where: { $0.agent == id }),
              let agent = try? repository.loadAgents().first(where: { $0.id == id }) else { return nil }
        return HubHarnessChoice(hub: pairing.hub?.key, provider: agent.harnessIdentifier ?? "", profile: entry.profile)
    }

    /// Deletes the local stand-ins, as when leaving the Hub. The bots stay on the Hub.
    public func forgetLocalCopies() {
        for entry in entries { try? forget(entry) }
        try? FileManager.default.removeItem(at: url)
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
        try apply(bot.draft, to: entry)
        onChange?()
    }

    public func deleteBot(localAgentID: UUID) async throws {
        guard let entry = entries.first(where: { $0.agent == localAgentID }) else { throw LinkError("This bot is not on the Hub.") }
        _ = try await pairing.request(.deleteBot(id: entry.remote))
        try forget(entry)
        onChange?()
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
        _ = try await pairing.request(.signIn(connectionID: id, redirect: redirect))
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
        browsers = listed
    }

    private func syncComputers() async throws {
        guard case .computers(let listed) = try await pairing.request(.computers) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        computers = listed
    }

    private func syncConnections() async throws {
        guard case .connections(let listed) = try await pairing.request(.connections) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        connections = listed
    }

    private func openSignInPage(_ id: UUID, url: URL) async {
        do {
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
            try await syncConnections()
            try await syncComputers()
            try await syncBrowsers()
            for entry in entries { try await syncMessages(entry) }
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
                    case .conversationChanged(let id, _):
                        if let entry = entries.first(where: { $0.remoteConversation == id }) { try await syncMessages(entry) }
                    case .connectionsChanged:
                        try await syncConnections()
                    case .computersChanged:
                        try await syncComputers()
                    case .browsersChanged:
                        try await syncBrowsers()
                    // Surfaces have their own streams.
                    case .surfaceOpened, .surfaceFrame:
                        break
                    case .computerCreated(let id, let computer, let error):
                        if let computer { making.removeValue(forKey: id)?.resume(returning: computer) }
                        else { making.removeValue(forKey: id)?.resume(throwing: LinkError(error ?? "The Hub could not make the computer.")) }
                    case .signInPage(let id, let url):
                        // The person may take minutes in the browser; other events keep flowing meanwhile.
                        Task { await openSignInPage(id, url: url) }
                    // Hub reactions and bot status are not shown on the Mac yet.
                    case .messageChanged, .botPhase:
                        break
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
        guard case .bots(let bots) = try await pairing.request(.bots) else { throw LinkError("The Hub sent an unexpected answer.") }
        var changed = false
        for bot in bots {
            if let entry = entries.first(where: { $0.remote == bot.id }) {
                try apply(bot.draft, to: entry)
            } else {
                _ = try adopt(bot)
                changed = true
            }
        }
        for entry in entries where !bots.contains(where: { $0.id == entry.remote }) {
            try forget(entry)
            changed = true
        }
        if changed { onChange?() }
    }

    private func syncMessages(_ entry: Entry) async throws {
        guard case .messages(let page) = try await pairing.request(.messages(conversationID: entry.remoteConversation, after: entry.synced)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        var known = Set(try repository.loadMessages(conversationID: entry.conversation).map(\.id))
        var delivered: Set<UUID> = []
        var latest: Date?
        for message in page.messages {
            acknowledged.insert(message.id)
            if message.author == .you, message.delivered { delivered.insert(message.id) }
            guard !known.contains(message.id) else { continue }
            try await fetchMissing(message.attachments, into: entry)
            let author: MessageAuthor = switch message.author {
            case .you: .user
            case .bot: .agent(entry.agent)
            case .system: .system
            }
            try repository.append(ChatMessage(id: message.id, conversationID: entry.conversation, author: author, body: message.body,
                                              createdAt: message.createdAt, delivery: message.delivered ? .delivered : .queued,
                                              attachmentIDs: message.attachments.map(\.id)))
            known.insert(message.id)
            latest = message.createdAt
        }
        if !delivered.isEmpty { try repository.markDelivered(conversationID: entry.conversation, messageIDs: delivered) }
        if let latest, var conversation = try repository.loadConversations().first(where: { $0.id == entry.conversation }) {
            conversation.updatedAt = max(conversation.updatedAt, latest)
            try repository.updateConversation(conversation)
        }
        // Delivery changes after the first read, so the last user message is read again until the bot takes it.
        let pendingFrom = page.messages.firstIndex { $0.author == .you && !$0.delivered }
        update(entry.remote) { $0.synced = pendingFrom.map { entry.synced + $0 } ?? page.count }
    }

    private func sendPending() async throws {
        for entry in entries {
            let waiting = try repository.loadMessages(conversationID: entry.conversation)
                .filter { $0.author == .user && $0.delivery == .queued && !acknowledged.contains($0.id) }
            guard !waiting.isEmpty else { continue }
            let files = Dictionary(try repository.loadAttachments(conversationID: entry.conversation).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
            for message in waiting {
                // Files first: the Hub refuses a message that points at a file it lacks.
                for id in message.attachmentIDs ?? [] {
                    guard let file = files[id], file.url == nil else { continue }
                    try await pairing.upload(repository.attachmentFileURL(file), as: LinkAttachment(
                        id: file.id, filename: file.originalFilename, mediaType: file.mediaType, byteCount: Int(file.byteCount),
                        voice: file.voice.map { LinkVoice(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform,
                                                          localeIdentifier: $0.localeIdentifier) }),
                        to: entry.remoteConversation)
                }
                let sent = (message.attachmentIDs ?? []).filter { files[$0]?.url == nil }
                _ = try await pairing.request(.send(LinkOutgoingMessage(conversationID: entry.remoteConversation, id: message.id, body: message.body,
                                                    attachmentIDs: sent)))
                acknowledged.insert(message.id)
            }
        }
    }

    /// Downloads the files of an incoming message that this copy lacks, keeping their IDs.
    private func fetchMissing(_ attachments: [LinkAttachment], into entry: Entry) async throws {
        guard !attachments.isEmpty else { return }
        let present = Set(try repository.loadAttachments(conversationID: entry.conversation).map(\.id))
        for attachment in attachments where !present.contains(attachment.id) {
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-\(attachment.id.uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try await pairing.download(attachment, from: entry.remoteConversation, to: staging)
            let name = URL(fileURLWithPath: attachment.filename).lastPathComponent
            let voice = attachment.voice.map {
                VoiceMessage(transcript: $0.transcript, duration: $0.duration, waveform: $0.waveform, localeIdentifier: $0.localeIdentifier)
            }
            let filename = name.isEmpty ? "Attachment" : name
            // Cards stay cards here, presented by this bot's stand-in, so they show and open as they do on the Hub.
            if attachment.mediaType == BrowserReference.mediaType, let data = try? Data(contentsOf: staging),
               let reference = try? BrowserReference.decode(data) {
                _ = try repository.importAttachment(data: data, originalFilename: filename, into: entry.conversation,
                                                    mediaType: attachment.mediaType,
                                                    browser: BrowserCard(reference: reference, agentID: entry.agent), id: attachment.id)
            } else if attachment.mediaType == ComputerCard.mediaType, let data = try? Data(contentsOf: staging),
                      let reference = try? JSONDecoder().decode(ComputerReference.self, from: data) {
                var card = ComputerCard(computer: reference.computer, agentID: entry.agent, terminalID: reference.terminalID,
                                        terminalPreview: reference.terminalPreview, view: reference.view, previewImage: reference.previewImage)
                card.capturedAt = reference.capturedAt
                _ = try repository.importAttachment(data: data, originalFilename: filename, into: entry.conversation,
                                                    mediaType: attachment.mediaType, computer: card, id: attachment.id)
            } else {
                _ = try repository.importAttachment(from: staging, into: entry.conversation, mediaType: attachment.mediaType,
                                                    voice: voice, id: attachment.id, originalFilename: filename)
            }
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
        return created.agent
    }

    private func apply(_ draft: LinkBotDraft, to entry: Entry) throws {
        guard let agent = try repository.loadAgents().first(where: { $0.id == entry.agent }) else { return }
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
