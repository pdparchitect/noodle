import HubLink
import SwiftUI

/// The bots this phone's user keeps on the Hub and their conversations, kept current from the Hub's events.
@MainActor @Observable final class HubChats {
    let pairing: HubPairing
    private(set) var agents: [LinkBot] = []
    private(set) var error: String?
    private var conversations: [UUID: [LinkMessage]] = [:]
    /// How far each conversation has been read. It stops at a message the bot has not taken yet,
    /// so that message is read again until it shows as delivered.
    @ObservationIgnored private var read: [UUID: Int] = [:]

    init(pairing: HubPairing) { self.pairing = pairing }

    /// Newest conversation first, as in Messages.
    var sortedAgents: [LinkBot] {
        agents.sorted { (latestMessage(of: $0)?.createdAt ?? $0.createdAt) > (latestMessage(of: $1)?.createdAt ?? $1.createdAt) }
    }

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
                    case .conversationChanged(let id, _): try await load(id)
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
        error = nil
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
    @State private var showingProfile = false

    init(pairing: HubPairing) { _chats = State(initialValue: HubChats(pairing: pairing)) }

    var body: some View {
        NavigationStack {
            List(chats.sortedAgents) { agent in
                NavigationLink(value: agent.id) { AgentRow(agent: agent, latest: chats.latestMessage(of: agent)) }
            }
            .listStyle(.plain)
            .overlay {
                if chats.agents.isEmpty {
                    if let error = chats.error {
                        ContentUnavailableView("Not Connected", systemImage: "wifi.exclamationmark", description: Text(error))
                    } else {
                        ContentUnavailableView("No Agents", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            .navigationTitle("Agents")
            .navigationDestination(for: UUID.self) { id in
                if let agent = chats.agents.first(where: { $0.id == id }) { ChatView(chats: chats, agent: agent) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingProfile = true } label: { Image(systemName: "person.crop.circle") }
                        .accessibilityLabel("Profile")
                }
            }
            .refreshable { try? await chats.reload() }
            .sheet(isPresented: $showingProfile) { ProfileView(pairing: chats.pairing) }
        }
        .task { await chats.follow() }
    }
}

private struct AgentRow: View {
    let agent: LinkBot
    let latest: LinkMessage?

    var body: some View {
        HStack(spacing: 12) {
            AgentAvatar(draft: agent.draft, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(agent.draft.name).font(.headline).lineLimit(1)
                    Spacer()
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
    let agent: LinkBot
    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
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
                HStack(spacing: 8) {
                    AgentAvatar(draft: agent.draft, size: 28)
                    Text(agent.draft.name).font(.headline)
                }
            }
        }
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
        guard !body.isEmpty else { return }
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

/// The bot's picture, or its symbol on its colour, as Noodle on the Mac shows it.
struct AgentAvatar: View {
    /// The same gradients as the Mac's bot avatars, indexed the same way.
    private static let gradients: [[Color]] = [
        [.blue, .cyan], [.purple, .pink], [.orange, .yellow], [.mint, .teal], [.indigo, .blue], [.pink, .orange],
    ]
    let draft: LinkBotDraft
    let size: CGFloat

    var body: some View {
        Group {
            if let data = draft.avatarImageData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: Self.gradients[Int(draft.avatarColorIndex.magnitude % UInt(Self.gradients.count))],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
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
