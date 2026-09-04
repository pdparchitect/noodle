import SwiftUI
import SuperBotCore

struct ChatView: View {
    @Environment(SuperBotStore.self) private var store
    let conversation: BotConversation
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
                .padding(.horizontal, 12)
                .padding(.bottom, 11)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ConversationStartView(conversation: conversation)
                        .padding(.bottom, 14)

                    ForEach(store.messages(for: conversation)) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.top, 30)
                .padding(.bottom, 8)
            }
            .onChange(of: store.messages(for: conversation).count) { _, _ in
                guard let lastID = store.messages(for: conversation).last?.id else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.quaternary.opacity(0.35), in: Circle())

            HStack(alignment: .bottom, spacing: 7) {
                TextField(
                    composerPrompt,
                    text: Binding(
                        get: { store.draft },
                        set: { store.draft = $0 }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($composerFocused)
                .onSubmit(store.sendDraft)
                .padding(.leading, 5)
                .padding(.vertical, 6)

                if store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                        .frame(width: 27, height: 27)
                } else {
                    Button(action: store.sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 23))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 27, height: 27)
                    }
                    .buttonStyle(.plain)
                    .help("Send Command")
                }
            }
            .padding(.horizontal, 7)
            .frame(minHeight: 32)
            .background(.quaternary.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.6)))
        }
    }

    private var composerPrompt: String {
        "Message \(store.title(for: conversation))"
    }
}

private struct ConversationStartView: View {
    @Environment(SuperBotStore.self) private var store
    let conversation: BotConversation

    var body: some View {
        VStack(spacing: 12) {
            ConversationAvatar(
                participants: store.participants(for: conversation),
                isGroup: conversation.kind == .group,
                size: 82
            )

            Text(store.title(for: conversation))
                .font(.system(size: 22, weight: .semibold))

            if conversation.kind == .group {
                Text(store.participants(for: conversation).map(\.displayName).joined(separator: ", "))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Label("Workspace ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)

            Text("Commands are saved in this conversation and will be routed when a local harness is connected.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)

            if conversation.kind == .direct,
               let agent = store.participants(for: conversation).first {
                Button("Show Bot Workspace") {
                    store.revealWorkspace(for: agent)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct WelcomeView: View {
    @Environment(SuperBotStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("Create Your First Bot", systemImage: "sparkles")
        } description: {
            Text("Each bot gets its own stable workspace and direct conversation.")
        } actions: {
            Button("Create Bot") {
                store.creationSheet = .bot
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
    }
}
