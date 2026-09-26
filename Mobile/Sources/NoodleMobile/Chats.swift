import HubLink
import NoodleWallpaperCore
import PhotosUI
import SwiftUI

/// The bots this phone's user keeps on the Hub and their conversations, kept current from the Hub's events.
@MainActor @Observable final class HubChats {
    let pairing: HubPairing
    private(set) var agents: [LinkBot] = []
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

    /// The last sync, shown at launch while the Hub is asked again.
    private struct Cache: Codable {
        var agents: [LinkBot]
        var conversations: [UUID: [LinkMessage]]
        var read: [UUID: Int]
    }

    init(pairing: HubPairing) {
        self.pairing = pairing
        pinned = Set((try? JSONDecoder().decode([UUID].self, from: Data(contentsOf: pairing.directory.appendingPathComponent("pins.json")))) ?? [])
        seen = try? JSONDecoder().decode([UUID: Date].self, from: Data(contentsOf: seenURL))
        drafts = (try? JSONDecoder().decode([UUID: String].self, from: Data(contentsOf: draftsURL))) ?? [:]
        backgrounds = (try? JSONDecoder().decode([UUID: ConversationBackground].self,
                                                 from: Data(contentsOf: pairing.directory.appendingPathComponent("backgrounds.json")))) ?? [:]
        if let cache = try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL)) {
            agents = cache.agents
            conversations = cache.conversations
            read = cache.read
            isLoaded = true
        }
    }

    private var cacheURL: URL { pairing.directory.appendingPathComponent("chats.json") }
    private var seenURL: URL { pairing.directory.appendingPathComponent("read.json") }
    private var draftsURL: URL { pairing.directory.appendingPathComponent("drafts.json") }

    func background(for agent: LinkBot) -> ConversationBackground {
        backgrounds[agent.conversationID] ?? ConversationBackground()
    }

    func backgroundImageURL(for agent: LinkBot) -> URL? {
        background(for: agent).imageFilename.map { backgroundsFolder.appendingPathComponent($0) }
    }

    /// A preset or the default. Any photo the conversation had is removed.
    func setBackground(_ background: ConversationBackground, for agent: LinkBot) throws {
        if let old = backgroundImageURL(for: agent), old.lastPathComponent != background.imageFilename {
            try? FileManager.default.removeItem(at: old)
        }
        backgrounds[agent.conversationID] = background.isDefault ? nil : background
        try JSONEncoder().encode(backgrounds).write(to: pairing.directory.appendingPathComponent("backgrounds.json"), options: .atomic)
    }

    /// A photo, converted as Noodle converts every still background.
    func setBackground(photo: Data, for agent: LinkBot) throws {
        let jpeg = try BackgroundMedia.jpegData(from: photo)
        try FileManager.default.createDirectory(at: backgroundsFolder, withIntermediateDirectories: true)
        // A new name each time, so views showing the old picture reload.
        let name = "\(agent.conversationID.uuidString)-\(UUID().uuidString).jpg"
        try jpeg.write(to: backgroundsFolder.appendingPathComponent(name), options: .atomic)
        try setBackground(ConversationBackground(imageFilename: name, mediaKind: .image), for: agent)
    }

    private var backgroundsFolder: URL { pairing.directory.appendingPathComponent("Backgrounds", isDirectory: true) }

    func draft(for agent: LinkBot) -> String { drafts[agent.conversationID] ?? "" }

    func setDraft(_ text: String, for agent: LinkBot) {
        guard drafts[agent.conversationID, default: ""] != text else { return }
        drafts[agent.conversationID] = text.isEmpty ? nil : text
        try? JSONEncoder().encode(drafts).write(to: draftsURL, options: .atomic)
    }

    /// Whether the bot has written since the conversation was last opened here.
    func isUnread(_ agent: LinkBot) -> Bool {
        guard let seen, let reply = messages(of: agent).last(where: { if case .bot = $0.author { true } else { false } }) else {
            return false
        }
        return seen[agent.conversationID].map { reply.createdAt > $0 } ?? true
    }

    func markRead(_ agent: LinkBot) {
        guard let latest = messages(of: agent).last?.createdAt, (seen?[agent.conversationID] ?? .distantPast) < latest else { return }
        seen = (seen ?? [:]).merging([agent.conversationID: latest]) { $1 }
        saveSeen()
    }

    private func saveSeen() {
        guard let seen else { return }
        try? JSONEncoder().encode(seen).write(to: seenURL, options: .atomic)
    }

    private func saveCache() {
        try? JSONEncoder().encode(Cache(agents: agents, conversations: conversations, read: read))
            .write(to: cacheURL, options: .atomic)
    }

    var sortedAgents: [LinkBot] { Self.sorted(agents.map { (self, $0) }).map(\.1) }

    /// Pinned first, then newest conversation first, as in Messages, across however many Hubs.
    static func sorted(_ agents: [(HubChats, LinkBot)]) -> [(HubChats, LinkBot)] {
        agents.sorted { lhs, rhs in
            let (left, right) = (lhs.0.isPinned(lhs.1), rhs.0.isPinned(rhs.1))
            if left != right { return left }
            return lhs.0.recency(of: lhs.1) > rhs.0.recency(of: rhs.1)
        }
    }

    /// When the conversation last moved, or the bot was made.
    private func recency(of agent: LinkBot) -> Date { latestMessage(of: agent)?.createdAt ?? agent.createdAt }

    func isPinned(_ agent: LinkBot) -> Bool { pinned.contains(agent.id) }

    func togglePin(_ agent: LinkBot) {
        if pinned.remove(agent.id) == nil { pinned.insert(agent.id) }
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
        guard case .bot(let bot) = try await pairing.request(.updateBot(id: agent.id, agent.draft)) else {
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
        conversations[agent.conversationID] = nil
        read[agent.conversationID] = nil
        if seen?.removeValue(forKey: agent.conversationID) != nil { saveSeen() }
        if pinned.remove(agent.id) != nil { savePins() }
        saveCache()
    }

    func agent(_ id: UUID) -> LinkBot? { agents.first { $0.id == id } }

    func messages(of agent: LinkBot) -> [LinkMessage] { conversations[agent.conversationID] ?? [] }

    func latestMessage(of agent: LinkBot) -> LinkMessage? { messages(of: agent).last }

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
        case .conversationChanged(let id, _):
            try await load(id)
        case .messageChanged(let message):
            // Only a message already here; a new one arrives with its conversation's change.
            guard conversations[message.conversationID]?.contains(where: { $0.id == message.id }) == true else { return }
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
        case .surfaceOpened:
            return
        }
        saveCache()
    }

    /// Adds your reaction, or takes it back if it is there.
    func toggleReaction(_ emoji: String, on message: LinkMessage, in agent: LinkBot) async throws {
        let present = !message.reactions.contains(LinkReaction(author: .you, emoji: emoji))
        guard case .message(let changed) = try await pairing.request(.react(LinkReactionChange(
            conversationID: agent.conversationID, messageID: message.id, emoji: emoji, present: present))) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        merge([changed], into: agent.conversationID)
        saveCache()
    }

    func reload() async throws {
        guard case .bots(let bots) = try await pairing.request(.bots) else { throw LinkError("The Hub sent an unexpected answer.") }
        agents = bots
        for bot in bots { try await load(bot.conversationID) }
        // Conversations of bots that are gone.
        conversations = conversations.filter { id, _ in bots.contains { $0.conversationID == id } }
        if seen == nil {
            seen = conversations.compactMapValues { $0.last?.createdAt }
            saveSeen()
        }
        // Chats work even when the Hub cannot list tools.
        try? await loadTools()
        isLoaded = true
        error = nil
        saveCache()
    }

    /// Messages shown before the Hub has them, and those it never got.
    private(set) var sending: Set<UUID> = []
    private(set) var undelivered: Set<UUID> = []

    /// How far your message got, in the Mac's words.
    func delivery(of message: LinkMessage) -> String {
        if undelivered.contains(message.id) { return "Not delivered" }
        if sending.contains(message.id) { return "Sending…" }
        return message.delivered ? "Delivered" : "Sent"
    }

    func send(_ body: String, files: [OutgoingFile] = [], to agent: LinkBot) async throws {
        let attachments = try files.map { file in
            LinkAttachment(id: file.id, filename: file.filename, mediaType: file.mediaType,
                           byteCount: try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, voice: file.voice)
        }
        // As on the Mac, a message of files alone says how many.
        let text = body.isEmpty && !files.isEmpty ? "Sent \(files.count) attachment\(files.count == 1 ? "" : "s")" : body
        let outgoing = LinkOutgoingMessage(conversationID: agent.conversationID, id: UUID(), body: text,
                                           attachmentIDs: attachments.map(\.id))
        // Shown at once; the Hub's copy replaces it.
        sending.insert(outgoing.id)
        defer { sending.remove(outgoing.id) }
        merge([LinkMessage(id: outgoing.id, conversationID: agent.conversationID, author: .you, body: text,
                           createdAt: Date(), delivered: false, attachments: attachments)], into: agent.conversationID)
        let sent: LinkMessage
        do {
            // Files first: the Hub refuses a message that points at a file it lacks.
            for (file, attachment) in zip(files, attachments) {
                try keep(file.url, as: attachment)
                try await pairing.upload(file.url, as: attachment, to: agent.conversationID)
            }
            guard case .message(let message) = try await pairing.request(.send(outgoing)) else {
                throw LinkError("The Hub sent an unexpected answer.")
            }
            sent = message
        } catch {
            undelivered.insert(outgoing.id)
            throw error
        }
        merge([sent], into: agent.conversationID)
        try await load(agent.conversationID)
        saveCache()
    }

    /// A recording, sent as the Mac sends one: the audio with its transcript, under "Voice message".
    func sendVoice(_ audio: URL, voice: LinkVoice, to agent: LinkBot) async throws {
        try await send(Self.voiceBody, files: [OutgoingFile(url: audio, filename: "Voice message.caf", mediaType: "audio/x-caf",
                                                            voice: voice)], to: agent)
    }

    static let voiceBody = "Voice message"

    /// The file on this phone, downloaded from the Hub the first time it is asked for.
    func file(for attachment: LinkAttachment, in agent: LinkBot) async throws -> URL {
        let url = fileURL(for: attachment)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await pairing.download(attachment, from: agent.conversationID, to: staging)
        try keep(staging, as: attachment)
        return url
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

    private func load(_ conversationID: UUID) async throws {
        let after = read[conversationID] ?? 0
        guard case .messages(let page) = try await pairing.request(.messages(conversationID: conversationID, after: after)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        merge(page.messages, into: conversationID)
        let pending = page.messages.firstIndex { $0.author == .you && !$0.delivered }
        read[conversationID] = pending.map { after + $0 } ?? page.count
    }

    private func merge(_ messages: [LinkMessage], into conversationID: UUID) {
        var list = conversations[conversationID] ?? []
        for message in messages {
            if let index = list.firstIndex(where: { $0.id == message.id }) { list[index] = message } else { list.append(message) }
        }
        conversations[conversationID] = list
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

/// The home screen once paired: the agents of the Hubs shown, newest conversation first.
struct AgentsView: View {
    let pairings: [HubPairing]
    /// Kept per Hub while it stays shown, so switching the option keeps what each Hub loaded.
    @State private var chats: [HubChats] = []
    @State private var showingMore = false
    /// What was picked in the … sheet; it opens once that sheet has gone.
    @State private var chosen: MoreChoice?
    @State private var showingProfile = false
    @State private var creating = false

    private struct Row: Identifiable {
        let chats: HubChats
        let agent: LinkBot
        let id: ChatLink
    }

    private var rows: [Row] {
        HubChats.sorted(chats.flatMap { hub in hub.agents.map { (hub, $0) } }).map { hub, agent in
            Row(chats: hub, agent: agent, id: ChatLink(hub: CurrentHub.name(of: hub.pairing), agent: agent.id))
        }
    }

    var body: some View {
        let rows = rows
        NavigationStack {
            List(rows) { row in
                NavigationLink(value: row.id) {
                    AgentRow(agent: row.agent, latest: row.chats.latestMessage(of: row.agent), pinned: row.chats.isPinned(row.agent),
                             unread: row.chats.isUnread(row.agent), hub: chats.count > 1 ? row.chats.pairing.hubName : nil)
                }
                // As in Messages: dividers between rows, none above the first.
                .listRowSeparator(row.id == rows.first?.id ? .hidden : .visible, edges: .top)
                .swipeActions(edge: .leading) {
                    let pinned = row.chats.isPinned(row.agent)
                    Button { row.chats.togglePin(row.agent) } label: {
                        Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash.fill" : "pin.fill")
                    }
                    .tint(.orange)
                }
            }
            .listStyle(.plain)
            .overlay {
                if rows.isEmpty {
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
                    ChatView(chats: hub, agentID: link.agent)
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
            .refreshable {
                for hub in chats { try? await hub.reload() }
            }
            .sheet(isPresented: $showingMore, onDismiss: openChosen) {
                MoreSheet { choice in
                    chosen = choice
                    showingMore = false
                }
            }
            .sheet(isPresented: $showingProfile) { HubsView() }
            .sheet(isPresented: $creating) {
                if let first = chats.first { AgentEditor(chats: first, agent: nil, hubs: chats) }
            }
        }
        .task(id: pairings.map(CurrentHub.name)) {
            chats = pairings.map { pairing in chats.first { $0.pairing === pairing } ?? HubChats(pairing: pairing) }
            await withTaskGroup(of: Void.self) { group in
                for hub in chats { group.addTask { await hub.follow() } }
            }
        }
    }

    private func openChosen() {
        switch chosen {
        case .createBot: creating = true
        case .profiles: showingProfile = true
        case nil: break
        }
        chosen = nil
    }
}

/// A conversation in the list: the Hub, by the name of its folder, and the bot.
struct ChatLink: Hashable {
    let hub: String
    let agent: UUID
}

enum MoreChoice { case createBot, profiles }

/// The rarely used actions, in a short sheet from the bottom.
struct MoreSheet: View {
    let choose: (MoreChoice) -> Void

    var body: some View {
        VStack(spacing: 12) {
            option("New Bot", systemImage: "plus", .createBot)
            option("Profiles", systemImage: "person.crop.circle", .profiles)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(24)
        .presentationDetents([.height(170)])
        .presentationDragIndicator(.visible)
    }

    private func option(_ title: String, systemImage: String, _ choice: MoreChoice) -> some View {
        Button { choose(choice) } label: {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity)
        }
    }
}

private struct AgentRow: View {
    let agent: LinkBot
    let latest: LinkMessage?
    let pinned: Bool
    let unread: Bool
    /// The bot's Hub, when several are shown together.
    var hub: String?

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatar(draft: agent.draft, size: 48, phase: agent.phase)
                // In the margin left of the picture, as in Messages.
                .overlay(alignment: .leading) {
                    if unread {
                        Circle().fill(.tint).frame(width: 10, height: 10).offset(x: -16)
                            .accessibilityLabel("Unread")
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(agent.draft.name).font(.headline).lineLimit(1)
                    if let hub {
                        Text(hub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if pinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange).accessibilityLabel("Pinned")
                    }
                    if let latest {
                        Text(latest.createdAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Text(latest?.body ?? agent.draft.publicDescription)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One agent's conversation, laid out like Messages.
struct ChatView: View {
    /// The height of a one-line message field, which the buttons beside it match.
    private static let controlHeight: CGFloat = 36
    let chats: HubChats
    let agentID: UUID
    @State private var draft = ""
    @State private var caret = 0
    @State private var files: [OutgoingFile] = []
    @State private var problem: String?
    @State private var editing = false
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var importing = false
    @State private var recorder: VoiceRecorder
    @Environment(\.dismiss) private var dismiss

    init(chats: HubChats, agentID: UUID) {
        self.chats = chats
        self.agentID = agentID
        _recorder = State(initialValue: VoiceRecorder(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("Recordings", isDirectory: true).appendingPathComponent(agentID.uuidString, isDirectory: true)))
    }

    var body: some View {
        Group {
            if let agent = chats.agent(agentID) { conversation(with: agent) }
        }
        // Deleted here or on another device.
        .onChange(of: chats.agent(agentID) == nil) { _, gone in if gone { dismiss() } }
    }

    private func conversation(with agent: LinkBot) -> some View {
        let messages = chats.messages(of: agent)
        // As in Messages, only your latest message says how far it got.
        let latestOwn = messages.last { $0.author == .you }?.id
        return ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(messages) { message in
                    Bubble(chats: chats, agent: agent, message: message,
                           delivery: message.id == latestOwn ? chats.delivery(of: message) : nil)
                        .id(message.id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .background { ConversationBackdrop(background: chats.background(for: agent), imageURL: chats.backgroundImageURL(for: agent)) }
        // Open means read, including replies that arrive while it is open.
        .onAppear {
            chats.markRead(agent)
            draft = chats.draft(for: agent)
        }
        .onChange(of: draft) { chats.setDraft(draft, for: agent) }
        .onChange(of: messages.last?.id) { chats.markRead(agent) }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { editing = true } label: {
                    HStack(spacing: 8) {
                        AgentAvatar(draft: agent.draft, size: 28, phase: agent.phase)
                        Text(agent.draft.name).font(.headline).foregroundStyle(.primary)
                    }
                }
                .accessibilityHint("Edit")
            }
        }
        .sheet(isPresented: $editing) { AgentEditor(chats: chats, agent: agent) }
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
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if recorder.phase != .idle, let agent = chats.agent(agentID) {
                VoiceRecordingBar(recorder: recorder) { audio, voice in
                    try await chats.sendVoice(audio, voice: voice, to: agent)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                messageComposer
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // No bar behind the composer: the conversation's background runs to the bottom, as in Messages.
        .onDisappear { Task { await recorder.discard() } }
    }

    private var messageComposer: some View {
        VStack(spacing: 6) {
            mentions
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
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
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { pickingPhotos = true }
                    if CameraPicker.isAvailable {
                        Button("Take Photo", systemImage: "camera") { takingPhoto = true }
                    }
                    Button("Files", systemImage: "folder") { importing = true }
                } label: {
                    Image(systemName: "plus").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.controlHeight, height: Self.controlHeight)
                        .glassEffect(.regular.interactive(), in: Circle())
                }
                // A menu otherwise drops the circle and tints the plus.
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("Add")
                ComposerField(text: $draft, caret: $caret, placeholder: "Message") { image in
                    attach { try PickedFiles.store(image.pngData() ?? Data(), named: "Image.png", type: .png) }
                }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: Self.controlHeight)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.controlHeight / 2, style: .continuous))
                // As in Messages: the microphone until there is something to send.
                if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty {
                    Button { recorder.start() } label: {
                        Image(systemName: "mic.fill").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: Self.controlHeight, height: Self.controlHeight)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Record Voice Message")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                            .frame(width: Self.controlHeight, height: Self.controlHeight)
                    }
                    .accessibilityLabel("Send")
                }
            }
        }
    }

    /// Bots matching an @ being typed, this conversation's first.
    @ViewBuilder private var mentions: some View {
        if let request = MentionCompletion.request(in: draft, caret: caret) {
            let bots = request.matches(chats.agents, preferred: agentID)
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

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !files.isEmpty, let agent = chats.agent(agentID) else { return }
        let sending = files
        draft = ""
        files = []
        problem = nil
        Task {
            do { try await chats.send(body, files: sending, to: agent) } catch { problem = error.localizedDescription }
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
    let agent: LinkBot
    let message: LinkMessage
    /// Shown under your latest message only.
    let delivery: String?
    @State private var expanded = false

    var body: some View {
        switch message.author {
        case .system:
            Text(message.body).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        case .you:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 4) {
                    content(foreground: .white, background: .accentColor)
                    if let delivery {
                        Text(delivery).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        case .bot:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    content(foreground: .primary, background: Color(.secondarySystemBackground))
                }
                Spacer(minLength: 48)
            }
        }
    }

    /// The Mac's quick reactions.
    static let quickReactions = [["❤️", "👍", "👎", "😂", "🎉", "❓"], ["👀", "⏳", "✅", "🙏", "🔥", "💡"]]

    private func react(_ emoji: String) {
        Task { try? await chats.toggleReaction(emoji, on: message, in: agent) }
    }

    /// One badge per emoji, with a count; yours are tinted, and tapping one adds or takes back yours.
    @ViewBuilder private var reactions: some View {
        let counts = Dictionary(grouping: message.reactions, by: \.emoji)
        let emojis = message.reactions.map(\.emoji).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !emojis.isEmpty {
            HStack(spacing: 4) {
                ForEach(emojis, id: \.self) { emoji in
                    let mine = counts[emoji]?.contains { $0.author == .you } == true
                    Button { react(emoji) } label: {
                        Text("\(emoji) \(counts[emoji]?.count ?? 0)").font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(mine ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(Color(.secondarySystemBackground)),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func content(foreground: Color, background: Color) -> some View {
        ForEach(message.attachments) { attachment in
            AttachmentView(chats: chats, agent: agent, attachment: attachment)
        }
        if showsText {
            text.foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contextMenu {
                    // One strip across the top of the menu, which scrolls sideways.
                    ControlGroup {
                        ForEach(Self.quickReactions.flatMap { $0 }, id: \.self) { emoji in Button(emoji) { react(emoji) } }
                    }
                    .controlGroupStyle(.palette)
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.body }
                }
        }
        reactions
        if let url = LinkPreview.firstURL(in: message.body) {
            LinkPreviewCard(url: url)
        }
    }

    /// A message of files alone carries a body like "Sent 2 attachments", which the files already show.
    private var showsText: Bool {
        !(message.attachments.count > 0 && message.body.wholeMatch(of: /Sent \d+ attachments?/) != nil)
            && !(message.attachments.contains { $0.voice != nil } && message.body == HubChats.voiceBody)
    }

    private var text: some View {
        let folded = !expanded && MessageFolding.isLong(message.body)
        return VStack(alignment: .leading, spacing: 4) {
            Text(Self.markdown(message.body))
                .lineLimit(folded ? MessageFolding.foldedLines : nil)
                .textSelection(.enabled)
            if folded {
                Button("Read more") { expanded = true }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Inline markdown, with only web and mail links left tappable, as on the Mac.
    static func markdown(_ body: String) -> AttributedString {
        guard var text = try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(body)
        }
        for run in text.runs {
            if let link = run.link, !["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
                text[run.range].link = nil
            }
        }
        return text
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
            lent.insert(LinkHarness(provider: agent.draft.provider, providerName: agent.draft.provider,
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
        }
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
                        Picker("Harness", selection: harness) {
                            if harness.wrappedValue == nil { Text("Choose").tag(LinkHarness?.none) }
                            ForEach(harnesses, id: \.self) { harness in
                                Text(harness.profileName.map { "\(harness.providerName) (\($0))" } ?? harness.providerName)
                                    .tag(LinkHarness?.some(harness))
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
                        NavigationLink("Background") { BackgroundEditor(chats: chats, agent: agent) }
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
                            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.provider.isEmpty)
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
