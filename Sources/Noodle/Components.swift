import SwiftUI
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import HubLink
import NoodleHubClient

struct ConversationAvatar: View {
    let participants: [AgentRecord]
    let isGroup: Bool
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale

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
        let frames = Self.memberFrames(count: 1, size: size, scale: displayScale)
        return ZStack(alignment: .topLeading) {
            let back = Self.snapped(size * 0.88, scale: displayScale)
            let backOrigin = Self.snapped(size * 0.06, scale: displayScale) + (size - back) / 2
            Circle()
                .fill(.quaternary)
                .frame(width: back, height: back)
                .offset(x: backOrigin, y: backOrigin)

            member(agent, in: frames[0])
        }
        .frame(width: size, height: size)
    }

    private var multiMemberGroupAvatar: some View {
        let members = Array(participants.prefix(3))
        let frames = Self.memberFrames(count: members.count, size: size, scale: displayScale)
        return ZStack(alignment: .topLeading) {
            Circle().fill(.quaternary).frame(width: size, height: size)
            ForEach(Array(zip(members, frames)), id: \.0.id) { agent, frame in
                member(agent, in: frame)
            }
        }
        .frame(width: size, height: size)
    }

    private func member(_ agent: AgentRecord, in frame: CGRect) -> some View {
        BotAvatar(agent: agent, size: frame.width, showsShadow: false)
            // Gray but opaque: the faces overlap, and a group nobody can answer in is dimmed as a whole.
            .grayscale(agent.isSuspended() ? 1 : 0)
            // Thinner on a small picture, where a fixed border would cover much of each face.
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: max(1, size * 0.04)))
            .offset(x: frame.minX, y: frame.minY)
    }

    /// Where each member picture sits inside the group picture, from its top-left corner.
    /// On whole pixels, or the pictures get resampled and look soft.
    static func memberFrames(count: Int, size: CGFloat, scale: CGFloat) -> [CGRect] {
        let snap = { snapped($0, scale: scale) }
        if count == 1 {
            let side = snap(size * 0.86)
            let origin = snap((size - side) / 2 - size * 0.06)
            return [CGRect(x: origin, y: origin, width: side, height: side)]
        }
        if count == 2 {
            // Diagonally across the middle, as large as the circle holds them.
            let side = snap(size * 0.6)
            let centre = (size - side) / 2
            return [CGPoint(x: -0.14, y: -0.14), CGPoint(x: 0.14, y: 0.14)].map {
                CGRect(x: snap(centre + size * $0.x), y: snap(centre + size * $0.y), width: side, height: side)
            }
        }
        let side = snap(size * 0.62)
        let centre = (size - side) / 2
        let offsets = [CGPoint(x: -0.18, y: -0.14), CGPoint(x: 0.18, y: -0.14), CGPoint(x: 0, y: 0.19)]
        return offsets.prefix(count).map {
            CGRect(x: snap(centre + size * $0.x), y: snap(centre + size * $0.y), width: side, height: side)
        }
    }

    private static func snapped(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }
}

/// One status for a whole conversation: a working bot wins, then a failed one, then any that can answer.
enum ConversationRuntimeStatus: Equatable {
    case working, failed, ready, idle

    init(phases: [AgentRuntimePhase]) {
        if phases.contains(.working) { self = .working }
        else if phases.contains(.failed) { self = .failed }
        else if phases.contains(.ready) { self = .ready }
        else { self = .idle }
    }

    /// Only a bot waiting for Kick marks the picture with a dot; the other states change the picture itself.
    var hasMark: Bool { self == .failed }
}

/// The red dot of a bot that waits for Kick.
struct RuntimeStatusMark: View {
    let status: ConversationRuntimeStatus
    let size: CGFloat

    var body: some View {
        if status == .failed { Circle().fill(.red).frame(width: size, height: size) }
    }
}

/// An arc that circles a working bot's picture.
/// The turn is read from the clock: a repeating animation would also repeat any move
/// made as the ring appears, and a toolbar places its items just then.
private struct WorkingRing: View {
    let lineWidth: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.1) / 1.1 * 360))
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// A ready bot's picture is shown as it is; a working one is circled, and an idle one, stopped or starting, greyed out.
    /// The ring scales with the picture's `size`, sitting just outside its edge.
    func runtimeLook(_ status: ConversationRuntimeStatus, size: CGFloat) -> some View {
        let ringWidth = max(1, size * 0.045)
        return grayscale(status == .idle ? 1 : 0)
            .opacity(status == .idle ? 0.5 : 1)
            .overlay {
                if status == .working {
                    WorkingRing(lineWidth: ringWidth).padding(-(ringWidth / 2 + max(1, size * 0.04)))
                }
            }
    }
}

extension NoodleStore {
    func runtimeStatus(for conversation: BotConversation) -> ConversationRuntimeStatus {
        ConversationRuntimeStatus(phases: shownParticipants(for: conversation).map { agent in
            // A bot on a Noodle Hub runs there; here it shows what the Hub last said, while it is reachable.
            if let mirror = hubMirror(forAgent: agent.id) { return mirror.isConnected ? mirror.phase(ofAgent: agent.id) ?? .ready : .offline }
            return runtime.snapshot(for: agent.id).phase
        })
    }

    func runtimeHelp(for conversation: BotConversation) -> String {
        shownParticipants(for: conversation).map { agent in
            if let mirror = hubMirror(forAgent: agent.id) {
                let hub = mirror.pairing.hub?.name ?? "Noodle Hub"
                let working = mirror.isConnected && mirror.phase(ofAgent: agent.id) == .working
                return "\(agent.displayName): " + (working ? "Working on \(hub)" : "Runs on \(hub)") + (mirror.isConnected ? "" : " (not connected)")
            }
            return "\(agent.displayName): \(runtime.snapshot(for: agent.id).detail)"
        }.joined(separator: "\n")
    }
}

extension NoodleStore {
    /// The conversation's bots that run on this Mac and wait for Kick.
    func agentsWaitingForKick(in conversation: BotConversation) -> [AgentRecord] {
        shownParticipants(for: conversation).filter { runsHere($0.id) && runtime.snapshot(for: $0.id).phase == .failed }
    }

    /// Why a bot on a Noodle Hub does not answer for now, such as its plan's token limit, as the Hub last
    /// said while it is reachable.
    func hubPause(ofAgent id: UUID) -> LinkBotPause? {
        guard let mirror = hubMirror(forAgent: id), mirror.isConnected else { return nil }
        return mirror.pause(ofAgent: id)
    }

    /// The bot of a direct conversation that could not be loaded, such as one made by an older version.
    private func setAsideAgent(of conversation: BotConversation) -> SetAsideAgent? {
        guard conversation.kind == .direct, let id = conversation.participantIDs.first else { return nil }
        return setAsideAgents.first { $0.id == id }
    }

    /// A bot's own conversation says why it waits; a group names the bots that wait.
    func pauseSummary(for conversation: BotConversation) -> String? {
        pauseSummary(for: conversation, namingSuspended: true)
    }

    /// What a conversation's row says. Suspending a bot was deliberate, so only its own row mentions it, not a group's.
    func sidebarPauseSummary(for conversation: BotConversation) -> String? {
        pauseSummary(for: conversation, namingSuspended: false)
    }

    private func pauseSummary(for conversation: BotConversation, namingSuspended: Bool) -> String? {
        if let setAside = setAsideAgent(of: conversation) { return setAside.helpURL == nil ? "Can't start" : "Needs an upgrade" }
        let waiting = Set(agentsWaitingForKick(in: conversation).map(\.id))
        let paused = shownParticipants(for: conversation).filter {
            waiting.contains($0.id) || $0.isSuspended() || hubPause(ofAgent: $0.id) != nil
        }
        guard let first = paused.first else { return nil }
        guard conversation.kind == .group else {
            if first.isSuspended(), let until = first.suspendedUntil { return AgentRecord.suspension(until: until) }
            return waiting.contains(first.id) ? runtime.snapshot(for: first.id).pauseSummary : hubPause(ofAgent: first.id)?.shown()
        }
        let named = namingSuspended ? paused : paused.filter { !$0.isSuspended() }
        return named.isEmpty ? nil : "Paused: " + named.map(\.displayName).joined(separator: ", ")
    }

    /// The full message behind the pause shown over a conversation.
    func pauseDetail(for conversation: BotConversation) -> String? {
        if let setAside = setAsideAgent(of: conversation) { return setAside.message }
        if let agent = agentsWaitingForKick(in: conversation).first { return runtime.snapshot(for: agent.id).detail }
        return shownParticipants(for: conversation).lazy.compactMap { self.hubPause(ofAgent: $0.id)?.detail }.first
    }
}

/// Over a conversation while one of its bots waits for Kick or a Hub's limit holds it: why, in a few words,
/// and Kick for one on this Mac. In a group, Kick starts the first bot that waits; the next one shows once it is back.
/// A bot waiting for sign-in gets Sign In instead, since only signing in brings it back.
/// It sits in the toolbar, so its window presents the Kick alert: see `AgentKickConfirmation`.
struct ConversationPauseControl: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    let conversation: BotConversation
    @Binding var kickRequest: AgentKickRequest?

    var body: some View {
        if let summary = store.pauseSummary(for: conversation) {
            HStack(spacing: 8) {
                Text(summary)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(store.pauseDetail(for: conversation) ?? summary)
                if let agent = store.agentsWaitingForKick(in: conversation).first,
                   store.runtime.snapshot(for: agent.id).failure == .authenticationRequired {
                    Button("Sign In…") {
                        store.showHarnessSettings()
                        openSettings()
                    }
                    .help("Sign in to the harness \(agent.displayName) uses")
                } else if let agent = store.shownParticipants(for: conversation).first(where: { $0.isSuspended() }),
                          store.canSuspend(agent.id) {
                    Button("Unsuspend") { store.setSuspended(until: nil, agentID: agent.id) }
                        .help("Let \(agent.displayName) take new turns again")
                } else if let agent = store.agentsWaitingForKick(in: conversation).first {
                    Button("Kick") {
                        kickRequest = store.runtime.kick(agent: agent, repository: store.repository)
                    }
                    .disabled(store.runtime.changingAccess.contains(agent.id))
                    .help("Kick \(agent.displayName)")
                }
            }
            .padding(.horizontal, 6)
        }
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
        let status = store.runtimeStatus(for: conversation)
        ZStack(alignment: .bottomTrailing) {
            ConversationAvatar(participants: store.shownParticipants(for: conversation),
                isGroup: conversation.kind == .group, size: size)
                .runtimeLook(status, size: size)
            // Opaque, or the cut leaves a ghost of the picture behind.
            if status.hasMark {
                Circle().fill(.black)
                    .frame(width: dotSize + ringWidth * 2, height: dotSize + ringWidth * 2)
                    .offset(x: ringWidth, y: ringWidth)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .overlay(alignment: .bottomTrailing) {
            RuntimeStatusMark(status: status, size: dotSize)
        }
        .help(store.runtimeHelp(for: conversation))
    }
}

/// Counts message row work so tests can prove that typing leaves the transcript alone,
/// that re-evaluated rows do not detect their links again, and which messages the transcript holds.
@MainActor enum TranscriptRenderProbe {
    private(set) static var bubbleBodies = 0
    private(set) static var linkScans = 0
    private(set) static var transcriptRows = 0
    private(set) static var firstTranscriptRow: UUID?
    static func bubbleBody() {
        #if DEBUG
        bubbleBodies += 1
        #endif
    }
    static func transcript(_ messages: some Collection<ChatMessage>) {
        #if DEBUG
        transcriptRows = messages.count
        firstTranscriptRow = messages.first?.id
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
    @Environment(\.forwardAttachment) private var forwardAttachment
    @Environment(\.isNarrowTranscript) private var isNarrowTranscript
    @AppStorage(ChatAttachmentLayout.defaultsKey) private var attachmentLayout = ChatAttachmentLayout.defaultValue.rawValue
    @AppStorage(MessageTextLayout.defaultsKey) private var textLayout = MessageTextLayout.defaultValue.rawValue
    @State private var inspectedReaction: String?
    @State private var changingReaction = false
    @State private var isVisible = false
    /// The voice message whose transcript is open.
    @State private var transcriptAttachmentID: UUID?
    let message: ChatMessage
    let hasConversationBackground: Bool
    @Binding var selectedAttachmentID: UUID?
    /// Opens an attachment together with the others in its message.
    let previewAttachment: (ConversationAttachment, [ConversationAttachment]) -> Void
    let showAgentProfile: ((AgentRecord) -> Void)?
    /// What was said on a call after this message and before the next.
    var spokenBlock: VoiceCallBlock?

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
        VStack(spacing: 0) {
            row
            if let spokenBlock {
                VoiceCallBlockView(block: spokenBlock).padding(.top, 8)
            }
        }
            // Every row keeps the badge's clearance, reactions or not, so reacting never moves
            // a message. The transcript's row gap covers all but these few points of it.
            .padding(.top, Self.reactionOverhang - TranscriptMetrics.rowSpacing)
    }

    static func insertion(for message: ChatMessage) -> AnyTransition {
        if case .system = message.author { return .opacity }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    /// The room kept on the far side of a bubble. A narrow transcript keeps little, or its text would wrap at half its width.
    private var sideGap: CGFloat { isNarrowTranscript ? 32 : 120 }

    @ViewBuilder private var row: some View {
        let attachments = store.attachments(for: message)
        if let call = message.call {
            VoiceCallCard(message: message, record: call)
        } else if isSystem {
            HStack {
                Spacer(minLength: 80)
                // Groups announce member changes; a bot's own conversation, only a change of harness.
                Label(message.body, systemImage: store.conversation(withID: message.conversationID)?.kind == .direct
                      ? "arrow.left.arrow.right" : "person.2.fill")
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
            if isUser { Spacer(minLength: sideGap) }

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
                        if store.runsHere(agent.id) { Button("Show Activity") { store.showActivity(for: agent) } }
                    }
                } else {
                    BotAvatar(agent: agent, size: 27)
                        .contextMenu {
                            if store.runsHere(agent.id) { Button("Show Activity") { store.showActivity(for: agent) } }
                        }
                }
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: Self.contentSpacing) {
                // Written from a task in the sidebar.
                if let task = message.task {
                    Label(task.title, systemImage: "checklist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if showsTextBubble(attachments: attachments) {
                    // Tables and the long message layout split the text into separate bubbles;
                    // reactions mark the first.
                    let segments = MessageMarkdownCache.shared.segments(
                        message, layout: MessageTextLayout(rawValue: textLayout) ?? .defaultValue)
                    ForEach(segments.indices, id: \.self) { index in
                        segmentBubble(segments[index])
                            .overlay(alignment: .topTrailing) { if index == 0 { cornerReactions } }
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
                    // Reactions are on the message, so they mark its text, and the files only when
                    // there is no text to mark.
                    .overlay(alignment: .topTrailing) {
                        if !showsTextBubble(attachments: attachments) { cornerReactions }
                    }
                }

                if isUser {
                    Text(deliveryLabel)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 5)
                }
            }

            if !isUser { Spacer(minLength: sideGap) }
        }
        // A fixed-width card can make the row wider than a narrow window. Keep the avatar side
        // in place and let the overflow eat into the spacer's side, rather than centring.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isVisible = visible
        }
        }
    }

    @ViewBuilder private func segmentBubble(_ segment: MessageMarkdownCache.Segment) -> some View {
        switch segment {
        case .text(let text, let source):
            // Links on the accent bubble are white and underlined; the link blue is unreadable on it.
            MessageText(message: message, text: isUser ? Self.underliningLinks(text) : text, source: source)
                .foregroundStyle(isUser ? .white : .primary)
                .tint(isUser ? .white : nil)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background { messageBackground }
                .overlay {
                    reactionContextMenu(attachment: nil)
                }
        case .table(let table):
            MessageTableView(message: message, table: table) { shown in reactionContextMenu(attachment: nil, table: shown) }
                .foregroundStyle(isUser ? .white : .primary)
                .background { messageBackground }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private static func underliningLinks(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs where run.link != nil { text[run.range].underlineStyle = .single }
        return text
    }

    private var linkPreviewURL: URL? {
        MessageLinkCache.shared.firstPublicWebURL(in: message.body)
    }

    private func attachmentPreview(_ attachment: ConversationAttachment) -> some View {
        let hub = store.hubKeeping(attachment)
        return AttachmentInlinePreview(
            attachment: attachment,
            fileURL: store.attachmentFileURL(attachment),
            hubPreview: hub.map { hub in { try? await hub.preview(of: attachment) } },
            shouldLoad: isVisible,
            isSelected: selectedAttachmentID == attachment.id,
            select: { selectedAttachmentID = attachment.id },
            preview: { previewAttachment(attachment, store.attachments(for: message)) },
            showsTranscript: attachment.voice == nil ? nil : Binding(
                get: { transcriptAttachmentID == attachment.id },
                set: { shown in
                    if shown { transcriptAttachmentID = attachment.id }
                    else if transcriptAttachmentID == attachment.id { transcriptAttachmentID = nil }
                })
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
            shape.fill(isUser ? Color.accentColor : Color(nsColor: .incomingBubble))
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

    private func reactionContextMenu(attachment: ConversationAttachment?, table: MessageTable? = nil) -> MessageContextMenu {
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
            preview: attachment.map { item in { previewAttachment(item, store.attachments(for: message)) } },
            reveal: attachment.map { item in { store.revealAttachment(item) } },
            save: attachment.flatMap { item in item.isSavable ? { store.saveAttachment(item) } : nil },
            // A picture only its Hub has is told by the Hub's picture of it, and comes down when used.
            backgroundImageURL: attachment.flatMap { item -> URL? in
                guard let hub = store.hubKeeping(item) else { return store.attachmentFileURL(item) }
                return item.mediaType.hasPrefix("image/") ? hub.keptPreview(of: item) : nil
            },
            useAsBackground: attachment.map { item in
                { Task { await store.useAttachmentAsBackground(item) } }
            },
            backgroundTargetName: conversation?.displayName ?? "this conversation",
            iconTargetName: iconAgent?.displayName,
            useAsIcon: attachment.flatMap { item in
                iconAgent.map { _ in { () -> Void in Task { await store.useAttachmentAsIcon(item) } } }
            },
            showTranscript: attachment.flatMap { item in
                item.voice == nil ? nil : { transcriptAttachmentID = item.id }
            },
            openOnThisMac: attachment.flatMap { item in
                store.isHubNoodlet(item) ? { Task { try? await store.openCompanion(item, at: .device) } } : nil
            },
            openOnHub: attachment.flatMap { item in
                store.isHubNoodlet(item) ? { Task { try? await store.openCompanion(item, at: .hub) } } : nil
            },
            copyTable: table.map { table in { MessageTableActions.copy(table) } },
            saveTable: table.map { table in { store.saveTable(table) } },
            forward: attachment.flatMap { item -> (() -> Void)? in
                guard AttachmentForwarding.canForward(item), let forwardAttachment else { return nil }
                return { forwardAttachment(item) }
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

private extension NSColor {
    static let incomingBubble = NSColor(name: nil) {
        NSColor(white: $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.20 : 0.90, alpha: 1)
    }
}

extension NoodleStore {
    /// Whether this Mac may suspend the bot: one of its own, or one its Hub can suspend, not one shared with it.
    func canSuspend(_ id: UUID) -> Bool {
        guard !isShared(id) else { return false }
        guard let mirror = hubMirror(forAgent: id) else { return runsHere(id) }
        return mirror.suspendsBots
    }

    /// Whether this Mac may stop the bot now: one of its own that is working, here or on a Hub that can stop
    /// bots; never one shared with it.
    func canStop(_ id: UUID) -> Bool {
        guard !isShared(id) else { return false }
        guard let mirror = hubMirror(forAgent: id) else { return runsHere(id) && runtime.canStopTurn(id) }
        return mirror.stopsBots && mirror.isConnected && mirror.phase(ofAgent: id) == .working
    }

    /// The bot Stop in the Conversation menu ends: that of a direct conversation, while it can be stopped.
    func stoppableAgent(in conversationID: UUID?) -> AgentRecord? {
        guard let conversation = conversations.first(where: { $0.id == conversationID }), conversation.kind == .direct,
              let agent = participants(for: conversation).first, canStop(agent.id) else { return nil }
        return agent
    }
}

/// Suspend Bot's choices of how long, or Unsuspend Bot for one already suspended.
struct SuspendBotMenu: View {
    @Environment(NoodleStore.self) private var store
    let agent: AgentRecord

    var body: some View {
        if agent.isSuspended() {
            Button("Unsuspend Bot") { store.setSuspended(until: nil, agentID: agent.id) }
        } else {
            Menu("Suspend Bot") {
                ForEach(LinkSuspensionChoice.allCases, id: \.self) { choice in
                    Button(choice.title) { store.setSuspended(until: choice.until(), agentID: agent.id) }
                }
            }
        }
    }
}
