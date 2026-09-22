import SwiftUI
import NoodleCore

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

/// One status for a whole conversation: a working bot wins, then a failed one, then all ready.
enum ConversationRuntimeStatus: Equatable {
    case working, failed, ready, idle

    init(phases: [AgentRuntimePhase]) {
        if phases.contains(.working) { self = .working }
        else if phases.contains(.failed) { self = .failed }
        else if !phases.isEmpty, phases.allSatisfy({ $0 == .ready }) { self = .ready }
        else { self = .idle }
    }

    var color: Color {
        switch self {
        case .working: .blue
        case .failed: .red
        case .ready: .green
        case .idle: .gray
        }
    }
}

extension NoodleStore {
    func runtimeStatus(for conversation: BotConversation) -> ConversationRuntimeStatus {
        ConversationRuntimeStatus(phases: participants(for: conversation).map { runtime.snapshot(for: $0.id).phase })
    }

    func runtimeHelp(for conversation: BotConversation) -> String {
        participants(for: conversation).map { agent in
            "\(agent.displayName): \(runtime.snapshot(for: agent.id).detail)"
        }.joined(separator: "\n")
    }
}

/// A conversation picture with its runtime dot. The ring is cut out of the picture,
/// so it reads the same over a wallpaper, a vibrant panel or a list row.
struct ConversationStatusAvatar: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    let size: CGFloat
    let dotSize: CGFloat
    var ringWidth: CGFloat = 2

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ConversationAvatar(participants: store.participants(for: conversation),
                isGroup: conversation.kind == .group, size: size)
            // Opaque, or the cut leaves a ghost of the picture behind.
            Circle().fill(.black)
                .frame(width: dotSize + ringWidth * 2, height: dotSize + ringWidth * 2)
                .offset(x: ringWidth, y: ringWidth)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(store.runtimeStatus(for: conversation).color).frame(width: dotSize, height: dotSize)
        }
        .help(store.runtimeHelp(for: conversation))
    }
}

/// Counts message row work so tests can prove that typing leaves the transcript alone
/// and that re-evaluated rows do not detect their links again.
@MainActor enum TranscriptRenderProbe {
    private(set) static var bubbleBodies = 0
    private(set) static var linkScans = 0
    static func bubbleBody() {
        #if DEBUG
        bubbleBodies += 1
        #endif
    }
    static func linkScan() {
        #if DEBUG
        linkScans += 1
        #endif
    }
}

/// Rows are re-evaluated far more often than their text changes, and finding a
/// link parses the whole message. Keyed by the text, so an edited message is scanned again.
@MainActor final class MessageLinkCache {
    static let shared = MessageLinkCache()

    private final class Box {
        let value: URL?
        init(_ value: URL?) { self.value = value }
    }

    private let values = NSCache<NSString, Box>()

    private init() {
        values.countLimit = 1_000
    }

    func firstPublicWebURL(in body: String) -> URL? {
        let key = body as NSString
        if let cached = values.object(forKey: key) { return cached.value }
        TranscriptRenderProbe.linkScan()
        let url = MessageLink.firstPublicWebURL(in: body)
        values.setObject(Box(url), forKey: key)
        return url
    }
}

struct MessageBubble: View {
    @Environment(NoodleStore.self) private var store
    @AppStorage(ChatAttachmentLayout.defaultsKey) private var attachmentLayout = ChatAttachmentLayout.defaultValue.rawValue
    @State private var inspectedReaction: String?
    @State private var changingReaction = false
    @State private var isVisible = false
    @State private var transcriptAttachment: ConversationAttachment?
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

    /// How far a reaction badge hangs above the top of what it marks.
    private static let reactionOverhang: CGFloat = 12
    /// The gap between a bubble and the rows below it inside one message.
    private static let contentSpacing: CGFloat = 3

    var body: some View {
        let _ = TranscriptRenderProbe.bubbleBody()
        // Keep this one plain container. A lazy stack builds every row up front, loading the
        // whole conversation at once, when a row's body is a bare if/else (to count its views)
        // or carries a transition (to read it). The transcript applies `insertion` instead.
        VStack(spacing: 0) { row }
            // Every row keeps the badge's clearance, reactions or not, so reacting never moves
            // a message. The transcript's row gap covers all but these few points of it.
            .padding(.top, Self.reactionOverhang - TranscriptMetrics.rowSpacing)
    }

    static func insertion(for message: ChatMessage) -> AnyTransition {
        if case .system = message.author { return .opacity }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    @ViewBuilder private var row: some View {
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
                    .contextMenu {
                        Button("Show Activity") { store.showActivity(for: agent) }
                    }
                } else {
                    BotAvatar(agent: agent, size: 27)
                        .contextMenu {
                            Button("Show Activity") { store.showActivity(for: agent) }
                        }
                }
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: Self.contentSpacing) {
                if showsTextBubble(attachments: attachments) {
                MessageText(message: message)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background { messageBackground }
                    .overlay {
                        reactionContextMenu(attachment: nil)
                    }
                    .overlay(alignment: .topTrailing) {
                        if attachments.isEmpty { cornerReactions }
                    }
                }

                if let linkPreviewURL, !attachments.contains(where: {
                    $0.url.flatMap { MessageLink.publicWebURL(from: $0) } == linkPreviewURL
                }) {
                    MessageLinkPreview(url: linkPreviewURL, shouldLoad: isVisible)
                }

                if !attachments.isEmpty {
                    AttachmentGroup(attachments: attachments,
                                    mode: ChatAttachmentLayout(rawValue: attachmentLayout) ?? .defaultValue,
                                    alignment: isUser ? .trailing : .leading) { attachment in
                        attachmentPreview(attachment)
                    }
                    .overlay(alignment: .topTrailing) { cornerReactions }
                    // Badges mark the attachments here, below the bubble, so they need the
                    // clearance the stack's own spacing does not already give them.
                    .padding(.top, showsTextBubble(attachments: attachments)
                        ? Self.reactionOverhang - Self.contentSpacing : 0)
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
        .sheet(item: $transcriptAttachment) { attachment in
            if let voice = attachment.voice { VoiceTranscriptSheet(voice: voice).noodleSheetSizing() }
        }
        }
    }

    private var linkPreviewURL: URL? {
        MessageLinkCache.shared.firstPublicWebURL(in: message.body)
    }

    private func attachmentPreview(_ attachment: ConversationAttachment) -> some View {
        AttachmentInlinePreview(
            attachment: attachment,
            fileURL: store.attachmentFileURL(attachment),
            shouldLoad: isVisible,
            isSelected: selectedAttachmentID == attachment.id,
            select: { selectedAttachmentID = attachment.id },
            preview: { previewAttachment(attachment) }
        )
        .onDrag { store.attachmentDragProvider(attachment) }
        .overlay { reactionContextMenu(attachment: attachment) }
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

    /// A voice message with nothing but its recordings shows no bubble of its own.
    private func showsTextBubble(attachments: [ConversationAttachment]) -> Bool {
        !(message.body == VoiceMessage.messageBody && !attachments.isEmpty && attachments.allSatisfy { $0.voice != nil })
    }

    @ViewBuilder private var cornerReactions: some View {
        if hasReactions {
            reactionBadges
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: 5, y: -Self.reactionOverhang)
        }
    }

    private func reactionContextMenu(attachment: ConversationAttachment?) -> some View {
        let conversation = store.conversations.first { $0.id == message.conversationID }
        let iconAgent = conversation.flatMap { conversation in
            conversation.kind == .direct && conversation.participantIDs.count == 1
                ? store.agents.first { $0.id == conversation.participantIDs.first } : nil
        }
        return MessageContextMenu(
            selected: Set((message.reactions ?? []).filter { $0.author == .user }.map(\.emoji)),
            react: { store.toggleReaction($0, on: message) },
            copy: {
                if let url = attachment?.url {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    NSPasteboard.general.setString(url.absoluteString, forType: .URL)
                } else if let attachment { store.copyAttachment(attachment) }
                else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                }
            },
            preview: attachment.map { item in { previewAttachment(item) } },
            reveal: attachment.map { item in { store.revealAttachment(item) } },
            backgroundImageURL: attachment.map { store.attachmentFileURL($0) },
            useAsBackground: attachment.map { item in
                { Task { await store.useAttachmentAsBackground(item) } }
            },
            backgroundTargetName: conversation?.displayName ?? "this conversation",
            iconTargetName: iconAgent?.displayName,
            useAsIcon: attachment.flatMap { item in
                iconAgent.map { _ in { () -> Void in Task { await store.useAttachmentAsIcon(item) } } }
            },
            showTranscript: attachment.flatMap { item in
                item.voice == nil ? nil : { transcriptAttachment = item }
            }
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
        case .queued: return "Sent"
        case .delivered: return "Delivered"
        case .failed: return "Not delivered"
        }
    }

}
