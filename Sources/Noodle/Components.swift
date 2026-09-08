import SwiftUI
import NoodleCore

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
            if participants.count == 1, let agent = participants.first {
                singleMemberGroupAvatar(agent)
            } else {
                multiMemberGroupAvatar
            }
        } else if let agent = participants.first {
            BotAvatar(agent: agent, size: size)
        } else {
            Image(systemName: "questionmark.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    private func singleMemberGroupAvatar(_ agent: AgentRecord) -> some View {
        ZStack {
            Circle()
                .fill(.quaternary)
                .frame(width: size * 0.88, height: size * 0.88)
                .offset(x: size * 0.06, y: size * 0.06)

            BotAvatar(agent: agent, size: size * 0.86)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                .offset(x: -size * 0.06, y: -size * 0.06)
        }
        .frame(width: size, height: size)
    }

    private var multiMemberGroupAvatar: some View {
        ZStack {
            Circle().fill(.quaternary)
            ForEach(Array(participants.prefix(3).enumerated()), id: \.element.id) { index, agent in
                BotAvatar(agent: agent, size: size * 0.62)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .offset(groupOffset(index))
            }
        }
        .frame(width: size, height: size)
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
    @State private var isVisible = false
    let message: ChatMessage
    let hasConversationBackground: Bool
    @Binding var selectedAttachmentID: UUID?
    let previewAttachment: (ConversationAttachment) -> Void
    let showAgentProfile: ((AgentRecord) -> Void)?

    private var isUser: Bool {
        if case .user = message.author { return true }
        return false
    }

    private var isSystem: Bool {
        if case .system = message.author { return true }
        return false
    }

    private var renderedBody: AttributedString {
        MessageMarkdownCache.shared.render(message)
    }

    var body: some View {
        let attachments = store.attachments(for: message)
        if isSystem {
            HStack {
                Spacer(minLength: 80)
                Label(message.body, systemImage: "person.2.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 80)
            }
            .transition(.opacity)
        } else {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 120) }

            if !isUser, case .agent(let id) = message.author,
               let agent = store.agents.first(where: { $0.id == id }) {
                if let showAgentProfile {
                    Button { showAgentProfile(agent) } label: {
                        BotAvatar(agent: agent, size: 27)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(agent.displayName)
                    .accessibilityLabel("Show \(agent.displayName)'s profile")
                } else {
                    BotAvatar(agent: agent, size: 27)
                }
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Text(renderedBody)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background { messageBackground }
                    .overlay {
                        reactionContextMenu(attachment: nil)
                    }
                    .overlay(alignment: .topTrailing) {
                        if attachments.isEmpty { cornerReactions }
                    }
                    .padding(.top, hasReactions && attachments.isEmpty ? 12 : 0)

                if let linkPreviewURL {
                    MessageLinkPreview(url: linkPreviewURL, shouldLoad: isVisible)
                }

                ForEach(attachments) { attachment in
                    AttachmentInlinePreview(
                        attachment: attachment,
                        fileURL: store.attachmentFileURL(attachment),
                        shouldLoad: isVisible,
                        isSelected: selectedAttachmentID == attachment.id,
                        select: { selectedAttachmentID = attachment.id },
                        preview: { previewAttachment(attachment) }
                    )
                    .overlay { reactionContextMenu(attachment: attachment) }
                    .overlay(alignment: .topTrailing) {
                        if attachment.id == attachments.last?.id { cornerReactions }
                    }
                    .padding(.top, hasReactions && attachment.id == attachments.last?.id ? 12 : 0)
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
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isVisible = visible
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var linkPreviewURL: URL? {
        MessageLink.firstPublicWebURL(in: message.body)
    }

    @ViewBuilder private var messageBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        if hasConversationBackground {
            shape
                .fill(.ultraThinMaterial)
                .overlay {
                    shape.fill(isUser ? Color.accentColor.opacity(0.28) : Color.black.opacity(0.22))
                }
        } else {
            shape.fill(isUser ? Color.accentColor : Color(white: 0.20))
        }
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

private final class MessageMarkdownCache: @unchecked Sendable {
    static let shared = MessageMarkdownCache()

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private let values = NSCache<NSUUID, Box>()

    private init() {
        values.countLimit = 1_000
    }

    func render(_ message: ChatMessage) -> AttributedString {
        let key = message.id as NSUUID
        if let cached = values.object(forKey: key) { return cached.value }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var rendered = (try? AttributedString(markdown: message.body, options: options))
            ?? AttributedString(message.body)
        let allowedSchemes = Set(["http", "https", "mailto"])
        let unsafeLinkRanges = rendered.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link,
                  !allowedSchemes.contains(link.scheme?.lowercased() ?? "") else { return nil }
            return run.range
        }
        for range in unsafeLinkRanges { rendered[range].link = nil }
        values.setObject(Box(rendered), forKey: key)
        return rendered
    }
}
