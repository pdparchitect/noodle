import HubLink
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
        if let cache = try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL)) {
            agents = cache.agents
            conversations = cache.conversations
            read = cache.read
            isLoaded = true
        }
    }

    private var cacheURL: URL { pairing.directory.appendingPathComponent("chats.json") }

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
        isLoaded = true
        error = nil
        saveCache()
    }

    func send(_ body: String, to agent: LinkBot) async throws {
        let outgoing = LinkOutgoingMessage(conversationID: agent.conversationID, id: UUID(), body: body)
        // Shown at once; the Hub's copy replaces it.
        merge([LinkMessage(id: outgoing.id, conversationID: agent.conversationID, author: .you, body: body,
                           createdAt: Date(), delivered: false)], into: agent.conversationID)
        guard case .message(let sent) = try await pairing.request(.send(outgoing)) else {
            throw LinkError("The Hub sent an unexpected answer.")
        }
        merge([sent], into: agent.conversationID)
        try await load(agent.conversationID)
        saveCache()
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
                    AgentRow(agent: agent, latest: chats.latestMessage(of: agent), pinned: chats.isPinned(agent))
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

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatar(draft: agent.draft, size: 48)
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
    let chats: HubChats
    let agentID: UUID
    @State private var draft = ""
    @State private var problem: String?
    @State private var editing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let agent = chats.agent(agentID) { conversation(with: agent) }
        }
        // Deleted here or on another device.
        .onChange(of: chats.agent(agentID) == nil) { _, gone in if gone { dismiss() } }
    }

    private func conversation(with agent: LinkBot) -> some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(chats.messages(of: agent)) { message in
                    Bubble(message: message).id(message.id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
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
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().strokeBorder(.quaternary))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let agent = chats.agent(agentID) else { return }
        draft = ""
        problem = nil
        Task {
            do { try await chats.send(body, to: agent) } catch { problem = error.localizedDescription }
        }
    }
}

private struct Bubble: View {
    let message: LinkMessage

    var body: some View {
        switch message.author {
        case .system:
            Text(message.body).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        case .you:
            HStack {
                Spacer(minLength: 48)
                text.foregroundStyle(.white).background(Color.accentColor, in: shape)
                    .opacity(message.delivered ? 1 : 0.6)
            }
        case .bot:
            HStack {
                text.background(Color(.secondarySystemBackground), in: shape)
                Spacer(minLength: 48)
            }
        }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    private var text: some View {
        Text((try? AttributedString(markdown: message.body,
                                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(message.body))
            .textSelection(.enabled)
            .padding(.horizontal, 12).padding(.vertical, 8)
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
