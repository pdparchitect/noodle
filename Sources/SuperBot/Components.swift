import SwiftUI
import SuperBotCore

struct BotAvatar: View {
    let agent: AgentRecord
    let size: CGFloat

    private var palette: [Color] {
        let palettes: [[Color]] = [
            [.blue, .cyan],
            [.purple, .pink],
            [.orange, .yellow],
            [.mint, .teal],
            [.indigo, .blue],
            [.pink, .orange]
        ]
        return palettes[abs(agent.accentSeed) % palettes.count]
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))

            Image(systemName: "sparkles")
                .font(.system(size: size * 0.33, weight: .bold))
                .foregroundStyle(.white)

            Text(agent.displayName.prefix(1).uppercased())
                .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .offset(y: size * 0.24)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        .accessibilityHidden(true)
    }
}

struct ConversationAvatar: View {
    let participants: [AgentRecord]
    let isGroup: Bool
    let size: CGFloat

    var body: some View {
        if isGroup {
            ZStack {
                Circle().fill(.quaternary)
                ForEach(Array(participants.prefix(3).enumerated()), id: \.element.id) { index, agent in
                    BotAvatar(agent: agent, size: size * 0.62)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(groupOffset(index))
                }
            }
            .frame(width: size, height: size)
        } else if let agent = participants.first {
            BotAvatar(agent: agent, size: size)
        } else {
            Image(systemName: "questionmark.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    private func groupOffset(_ index: Int) -> CGSize {
        switch index {
        case 0: return CGSize(width: -size * 0.18, height: -size * 0.14)
        case 1: return CGSize(width: size * 0.18, height: -size * 0.14)
        default: return CGSize(width: 0, height: size * 0.19)
        }
    }
}

struct ConversationToolbarLabel: View {
    @Environment(SuperBotStore.self) private var store
    let conversation: BotConversation

    var body: some View {
        VStack(spacing: 2) {
            ConversationAvatar(
                participants: store.participants(for: conversation),
                isGroup: conversation.kind == .group,
                size: 36
            )

            HStack(spacing: 3) {
                Text(store.title(for: conversation))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 150)
    }
}

struct MessageBubble: View {
    @Environment(SuperBotStore.self) private var store
    let message: ChatMessage

    private var isUser: Bool {
        if case .user = message.author { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 120) }

            if !isUser, case .agent(let id) = message.author,
               let agent = store.agents.first(where: { $0.id == id }) {
                BotAvatar(agent: agent, size: 27)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Text(message.body)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(
                        isUser ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )

                if isUser {
                    Text(deliveryLabel)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 5)
                }
            }

            if !isUser { Spacer(minLength: 120) }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var deliveryLabel: String {
        switch message.delivery {
        case .saved: return "Saved"
        case .queued: return "Waiting for harness"
        case .delivered: return "Delivered"
        case .failed: return "Not delivered"
        }
    }
}
