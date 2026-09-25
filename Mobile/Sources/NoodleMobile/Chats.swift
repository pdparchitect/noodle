import HubLink
import PhotosUI
import SwiftUI

/// The bots this phone's user keeps on the Hub and their conversations, kept current from the Hub's events.
@MainActor @Observable final class HubChats {
    let pairing: HubPairing
    private(set) var agents: [LinkBot] = []
    private(set) var error: String?
    /// Whether the list is known: from the last sync saved on this phone, or from the Hub itself.
    private(set) var isLoaded = false
    /// Pins belong to this phone alone; the Hub never sees them.
    private var pinned: Set<UUID>
    /// When each conversation was last read on this phone. Nil until the first sync after
    /// installing, which counts everything already there as read.
    private var seen: [UUID: Date]?
    /// Unsent text, by conversation, kept on this phone.
    private var drafts: [UUID: String] = [:]
    private var conversations: [UUID: [LinkMessage]] = [:]
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

    /// Pinned first, then newest conversation first, as in Messages.
    var sortedAgents: [LinkBot] {
        agents.sorted {
            let (lhs, rhs) = (isPinned($0), isPinned($1))
            if lhs != rhs { return lhs }
            return (latestMessage(of: $0)?.createdAt ?? $0.createdAt) > (latestMessage(of: $1)?.createdAt ?? $1.createdAt)
        }
    }

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
                for try await event in try await pairing.subscribe() {
                    switch event {
                    case .botsChanged: try await reload()
                    case .conversationChanged(let id, _):
                        try await load(id)
                        saveCache()
                    // Tools are lent by a Mac; this phone lends none.
                    case .toolCall: break
                    }
                }
            } catch {
                self.error = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(5))
        }
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
                           byteCount: try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
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
}

/// The home screen once paired: the agents, newest conversation first.
struct AgentsView: View {
    @State private var chats: HubChats
    @State private var showingMore = false
    /// What was picked in the … sheet; it opens once that sheet has gone.
    @State private var chosen: MoreChoice?
    @State private var showingProfile = false
    @State private var creating = false

    init(pairing: HubPairing) { _chats = State(initialValue: HubChats(pairing: pairing)) }

    var body: some View {
        NavigationStack {
            List(chats.sortedAgents) { agent in
                NavigationLink(value: agent.id) {
                    AgentRow(agent: agent, latest: chats.latestMessage(of: agent), pinned: chats.isPinned(agent),
                             unread: chats.isUnread(agent))
                }
                // As in Messages: dividers between rows, none above the first.
                .listRowSeparator(agent.id == chats.sortedAgents.first?.id ? .hidden : .visible, edges: .top)
                .swipeActions(edge: .leading) {
                    Button { chats.togglePin(agent) } label: {
                        Label(chats.isPinned(agent) ? "Unpin" : "Pin", systemImage: chats.isPinned(agent) ? "pin.slash.fill" : "pin.fill")
                    }
                    .tint(.orange)
                }
            }
            .listStyle(.plain)
            .overlay {
                if chats.agents.isEmpty {
                    if !chats.isLoaded, chats.error == nil {
                        ProgressView()
                    } else if let error = chats.error {
                        ContentUnavailableView("Not Connected", systemImage: "wifi.exclamationmark", description: Text(error))
                    } else {
                        ContentUnavailableView("No Bots", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in ChatView(chats: chats, agentID: id) }
            .toolbar {
                // A plain button, as in Messages, not the round glass default.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingMore = true } label: { Image(systemName: "ellipsis") }
                        .foregroundStyle(.tint)
                        .accessibilityLabel("More")
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .refreshable { try? await chats.reload() }
            .sheet(isPresented: $showingMore, onDismiss: openChosen) {
                MoreSheet { choice in
                    chosen = choice
                    showingMore = false
                }
            }
            .sheet(isPresented: $showingProfile) { ProfileView(pairing: chats.pairing) }
            .sheet(isPresented: $creating) { AgentEditor(chats: chats, agent: nil) }
        }
        .task { await chats.follow() }
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

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatar(draft: agent.draft, size: 48)
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
    @State private var files: [OutgoingFile] = []
    @State private var problem: String?
    @State private var editing = false
    @State private var pickingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var takingPhoto = false
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

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
                        AgentAvatar(draft: agent.draft, size: 28)
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
                        .background(Color(.secondarySystemFill), in: Circle())
                }
                // A menu otherwise drops the circle and tints the plus.
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel("Add")
                ComposerField(text: $draft, placeholder: "Message") { image in
                    attach { try PickedFiles.store(image.pngData() ?? Data(), named: "Image.png", type: .png) }
                }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .frame(minHeight: Self.controlHeight)
                    .background(RoundedRectangle(cornerRadius: Self.controlHeight / 2, style: .continuous).strokeBorder(.quaternary))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
                        .frame(width: Self.controlHeight, height: Self.controlHeight)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
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

    @ViewBuilder private func content(foreground: Color, background: Color) -> some View {
        ForEach(message.attachments) { attachment in
            AttachmentView(chats: chats, agent: agent, attachment: attachment)
        }
        if showsText {
            text.foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.body }
                }
        }
        if let url = LinkPreview.firstURL(in: message.body) {
            LinkPreviewCard(url: url)
        }
    }

    /// A message of files alone carries a body like "Sent 2 attachments", which the files already show.
    private var showsText: Bool {
        !(message.attachments.count > 0 && message.body.wholeMatch(of: /Sent \d+ attachments?/) != nil)
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
    let chats: HubChats
    /// Nil makes a new agent.
    let agent: LinkBot?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LinkBotDraft
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var problem: String?

    init(chats: HubChats, agent: LinkBot?) {
        self.chats = chats
        self.agent = agent
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
                    VStack(spacing: 16) {
                        AgentAvatar(draft: draft, size: 88)
                        HStack(spacing: 12) {
                            ForEach(0..<AgentAvatar.colourCount, id: \.self) { index in
                                Button { draft.avatarColorIndex = index } label: {
                                    AgentAvatar.swatch(index)
                                        .frame(width: 30, height: 30)
                                        .overlay { if AgentAvatar.colourIndex(draft.avatarColorIndex) == index {
                                            Circle().strokeBorder(.primary, lineWidth: 2).padding(-4)
                                        } }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Colour \(index + 1)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Name", text: $draft.name)
                }
                Section {
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
                if agent != nil {
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
            .task { if chats.pairing.status == nil { await chats.pairing.refresh(quietly: true) } }
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

    static var colourCount: Int { gradients.count }

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
        .accessibilityHidden(true)
    }
}
