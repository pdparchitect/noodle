import SwiftUI
import NoodleCore

extension View {
    func noodleSheetSizing() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .presentationSizing(.fitted)
    }
}

enum BotAvatarPalette {
    static let gradients: [[Color]] = [
        [.blue, .cyan],
        [.purple, .pink],
        [.orange, .yellow],
        [.mint, .teal],
        [.indigo, .blue],
        [.pink, .orange]
    ]
}

struct BotAvatar: View {
    let agent: AgentRecord
    let size: CGFloat

    private var palette: [Color] {
        let index = agent.avatarColorIndex ?? agent.accentSeed
        return BotAvatarPalette.gradients[abs(index) % BotAvatarPalette.gradients.count]
    }

    var body: some View {
        ZStack {
            if let data = agent.avatarImageData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))

                Image(systemName: agent.avatarSymbolName ?? "sparkles")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
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

struct MessageBubble: View {
    @Environment(NoodleStore.self) private var store
    @State private var inspectedReaction: String?
    @State private var changingReaction = false
    let message: ChatMessage
    @Binding var selectedAttachmentID: UUID?
    let previewAttachment: (ConversationAttachment) -> Void

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
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(
                        isUser ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        reactionContextMenu(attachment: nil)
                    }
                    .overlay(alignment: .topTrailing) {
                        if store.attachments(for: message).isEmpty { cornerReactions }
                    }
                    .padding(.top, hasReactions && store.attachments(for: message).isEmpty ? 12 : 0)

                ForEach(store.attachments(for: message)) { attachment in
                    AttachmentInlinePreview(
                        attachment: attachment,
                        fileURL: store.attachmentFileURL(attachment),
                        isSelected: selectedAttachmentID == attachment.id,
                        select: { selectedAttachmentID = attachment.id },
                        preview: { previewAttachment(attachment) }
                    )
                    .overlay { reactionContextMenu(attachment: attachment) }
                    .overlay(alignment: .topTrailing) {
                        if attachment.id == store.attachments(for: message).last?.id { cornerReactions }
                    }
                    .padding(.top, hasReactions && attachment.id == store.attachments(for: message).last?.id ? 12 : 0)
                }

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

    private var hasReactions: Bool { !(message.reactions ?? []).isEmpty }

    @ViewBuilder private var cornerReactions: some View {
        if hasReactions {
            reactionBadges
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: 5, y: -12)
        }
    }

    private func reactionContextMenu(attachment: ConversationAttachment?) -> some View {
        MessageContextMenu(
            selected: Set((message.reactions ?? []).filter { $0.author == .user }.map(\.emoji)),
            react: { store.toggleReaction($0, on: message) },
            copy: {
                if let attachment { store.copyAttachment(attachment) }
                else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                }
            },
            preview: attachment.map { item in { previewAttachment(item) } },
            reveal: attachment.map { item in { store.revealAttachment(item) } }
        )
    }

    private var reactionBadges: some View {
        let groups = Dictionary(grouping: message.reactions ?? [], by: \.emoji)
        let emojis = (message.reactions ?? []).map(\.emoji).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: -6) { badges(emojis, groups: groups) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], alignment: .leading, spacing: 4) {
                badges(emojis, groups: groups)
            }
            .frame(maxWidth: 280)
        }
    }

    @ViewBuilder private func badges(_ emojis: [String], groups: [String: [MessageReaction]]) -> some View {
        ForEach(emojis, id: \.self) { emoji in
            let reactions = groups[emoji] ?? []
            let isMine = reactions.contains { $0.author == .user }
            let names = reactions.map { reaction in
                switch reaction.author {
                case .user: return "You"
                case .agent(let id): return store.agents.first { $0.id == id }?.displayName ?? "Bot"
                case .system: return "Noodle"
                }
            }.joined(separator: ", ")
            Button {
                changingReaction = false
                inspectedReaction = emoji
            } label: {
                HStack(spacing: 4) {
                    Text(emoji).font(.system(size: 14))
                    if reactions.count > 1 {
                        Text("\(reactions.count)").font(.system(size: 10, weight: .medium))
                    }
                }
                .padding(.horizontal, reactions.count > 1 ? 7 : 0)
                .frame(minWidth: 28, minHeight: 28)
                .background(isMine ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15), in: Capsule())
                // An opaque base keeps overlapping badges distinct instead of blending together.
                .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color(nsColor: .textBackgroundColor).opacity(0.85), lineWidth: 1.5)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { inspectedReaction == emoji },
                set: { if !$0 { inspectedReaction = nil } }
            ), arrowEdge: .bottom) {
                VStack(spacing: 16) {
                    Text(emoji).font(.system(size: 26))
                    Text(names).font(.system(size: 13))
                        .multilineTextAlignment(.center)
                    if isMine {
                        Divider()
                        if changingReaction {
                            Text("Change Reaction").font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 6), spacing: 10) {
                                ForEach(["❤️", "👍", "👎", "😂", "🎉", "❓", "👀", "⏳", "✅", "🙏", "🔥", "💡"], id: \.self) { replacement in
                                    Button {
                                        inspectedReaction = nil
                                        store.changeReaction(emoji, to: replacement, on: message)
                                    } label: {
                                        Text(replacement).font(.system(size: 22)).frame(width: 36, height: 36)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Change to \(replacement)")
                                }
                            }
                        } else {
                            Button("Change Reaction…") { changingReaction = true }
                        }
                        Button("Remove My Reaction") {
                            inspectedReaction = nil
                            store.removeReaction(emoji, on: message)
                        }
                    }
                }
                .frame(width: 260)
                .padding(20)
            }
            .help("\(emoji) — \(names). Click to see who reacted.")
            .accessibilityLabel("\(emoji), \(names)")
        }
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
