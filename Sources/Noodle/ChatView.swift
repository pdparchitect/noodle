import AppKit
import QuickLook
import PhotosUI
import SwiftUI
import NoodleCore
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    var composerFocusRequest: UUID? = nil
    @State private var composerFocused = false
    @State private var choosingAttachments = false
    @State private var showingAttachmentMenu = false
    @State private var choosingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var attachmentDestinationID: UUID?
    @State private var selectedAttachmentID: UUID?
    @State private var previewedAttachmentURL: URL?
    @State private var transcriptPositions: [UUID: TranscriptViewport] = [:]
    @State private var bottomOverlayHeight: CGFloat = 0
    @StateObject private var nameCompletion = ComposerNameCompletion()
    @State private var profileAgent: AgentRecord?
    @State private var profileAction: ProfileAction?

    private enum ProfileAction {
        case reply(name: String, conversationID: UUID)
        case directMessage(UUID)
    }

    var body: some View {
        chatContent
            .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
            .overlay {
                ConversationEffectsView(conversationID: conversation.id)
                    .id(conversation.id)
            }
            .fileImporter(
                isPresented: $choosingAttachments,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                let destination = attachmentDestinationID
                attachmentDestinationID = nil
                switch result {
                case .success(let urls):
                    if let destination { urls.forEach { store.importAttachment(from: $0, into: destination) } }
                case .failure(let error):
                    store.errorMessage = error.localizedDescription
                }
            }
            .photosPicker(isPresented: $choosingPhotos, selection: $photoSelection,
                          matching: .images, preferredItemEncoding: .current)
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty, let destination = attachmentDestinationID else { return }
                attachmentDestinationID = nil
                photoSelection = []
                Task {
                    var firstError: Error?
                    for item in items {
                        do {
                            guard let data = try await item.loadTransferable(type: Data.self) else {
                                throw AttachmentTransferError.unsupportedItem
                            }
                            try store.importPhoto(data: data, into: destination)
                        } catch { firstError = firstError ?? error }
                    }
                    if let firstError { store.errorMessage = firstError.localizedDescription }
                }
            }
            .quickLookPreview($previewedAttachmentURL)
            .sheet(item: $profileAgent, onDismiss: finishProfileAction) { agent in
                let direct = store.conversations.first {
                    $0.kind == .direct && $0.participantIDs == [agent.id]
                }
                if conversation.kind == .direct {
                    AgentProfileSheet(agent: agent)
                        .noodleSheetSizing()
                } else {
                    AgentProfileSheet(
                        agent: agent,
                        canOpenDirectMessage: direct != nil,
                        reply: {
                            profileAction = .reply(name: agent.displayName, conversationID: conversation.id)
                            profileAgent = nil
                        },
                        directMessage: {
                            if let direct { profileAction = .directMessage(direct.id) }
                            profileAgent = nil
                        }
                    )
                    .noodleSheetSizing()
                }
            }
            .onPasteCommand(of: AttachmentTransfer.pasteContentTypes) { providers in
                store.importAttachments(from: providers)
            }
            .onChange(of: conversation.id) { _, _ in
                selectedAttachmentID = nil
                previewedAttachmentURL = nil
                nameCompletion.detach()
            }
            .onChange(of: composerFocusRequest) { _, request in
                if request != nil { composerFocused = true }
            }
    }

    @ViewBuilder private var chatContent: some View {
        if #available(macOS 26.0, *) {
            topFadedTranscript
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .overlay(alignment: .bottom) {
                    measuredPinnedBottomContent
                }
        } else {
            topFadedTranscript
                .overlay(alignment: .bottom) {
                    measuredPinnedBottomContent
                        .background(.bar)
                }
        }
    }

    private var measuredPinnedBottomContent: some View {
        pinnedBottomContent
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                bottomOverlayHeight = height
            }
    }

    private var pinnedBottomContent: some View {
        VStack(spacing: 0) {
            if let request = store.runtime.approvals.first(where: { conversation.participantIDs.contains($0.agentID) }) {
                AgentApprovalView(request: request).id(request.id)
            }
            composerFooter
        }
    }

    private var topFadedTranscript: some View {
        transcript
            .mask {
                // Fade the transcript pixels themselves as they pass beneath
                // the toolbar. The separate window-wide shade remains behind
                // the sidebar and transcript for wallpaper contrast.
                VStack(spacing: 0) {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.12), location: 0.45),
                        .init(color: .white, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: 88)
                    Color.white
                }
                .ignoresSafeArea(edges: .top)
            }
    }

    private var composerFooter: some View {
        composer
            .padding(.horizontal, 12)
            .padding(.bottom, 11)
            .frame(maxWidth: .infinity)
    }

    private var transcript: some View {
        let id = conversation.id
        return ConversationTranscript(
            conversation: conversation,
            initialViewport: transcriptPositions[id] ?? TranscriptViewport(),
            selectedAttachmentID: $selectedAttachmentID,
            previewAttachment: showPreview,
            bottomOverlayHeight: bottomOverlayHeight,
            showAgentProfile: { profileAgent = $0 },
            saveViewport: { transcriptPositions[id] = $0 }
        )
        .id(id)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !store.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(store.pendingAttachments) { attachment in
                            PendingAttachmentChip(
                                attachment: attachment,
                                preview: { showPreview(attachment) },
                                remove: { store.removePendingAttachment(attachment) }
                            )
                        }
                    }
                    .padding(.horizontal, 38)
                }
            }

            composerControls
        }
        .onChange(of: composerFocused) { _, isFocused in
            store.composerIsFocused = isFocused
        }
        .onDisappear {
            store.composerIsFocused = false
            nameCompletion.detach()
        }
    }

    private var cannotSend: Bool {
        store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            store.pendingAttachments.isEmpty
    }

    @ViewBuilder private var composerControls: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: composerControlSpacing) {
                composerControlRow
            }
        } else {
            composerControlRow
        }
    }

    private var composerControlRow: some View {
        HStack(alignment: .bottom, spacing: composerControlSpacing) {
            attachmentButton
                .background {
                    ComposerAttachmentMenu(isPresented: $showingAttachmentMenu,
                        attachFile: {
                            attachmentDestinationID = conversation.id
                            choosingAttachments = true
                        },
                        choosePhoto: {
                            attachmentDestinationID = conversation.id
                            photoSelection = []
                            choosingPhotos = true
                        })
                }
            composerInput
        }
    }

    @ViewBuilder private var attachmentButton: some View {
        if #available(macOS 26.0, *) {
            Button {
                showingAttachmentMenu = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: composerControlHeight, height: composerControlHeight)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .help("Add Attachment")
        } else {
            Button {
                showingAttachmentMenu = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: composerControlHeight, height: composerControlHeight)
                    .background(.quaternary.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Add Attachment")
        }
    }

    @ViewBuilder private var composerInput: some View {
        if #available(macOS 26.0, *) {
            composerInputContents
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                )
        } else {
            composerInputContents
                .background(
                    .quaternary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                        .stroke(.separator.opacity(0.6))
                }
        }
    }

    private var composerInputContents: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollableChatComposer(
                text: Binding(
                    get: { store.draft(for: conversation.id) },
                    set: { store.setDraft($0, for: conversation.id) }
                ),
                isFocused: $composerFocused,
                conversationID: conversation.id,
                placeholder: composerPrompt,
                agents: store.agents,
                preferredIDs: Set(conversation.participantIDs),
                completion: nameCompletion,
                submit: store.sendDraft
            )
            .padding(.leading, 12)
            .padding(.trailing, composerSendControlWidth + 14)
            .padding(.vertical, 6)
            .frame(minHeight: composerControlHeight, alignment: .center)

            if cannotSend {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                    .frame(width: composerSendControlWidth, height: composerControlHeight)
                    .padding(.trailing, 7)
            } else {
                Button(action: store.sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 23))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: composerSendControlWidth, height: composerControlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 7)
                .help("Send Message")
            }
        }
    }

    private func showPreview(_ attachment: ConversationAttachment) {
        selectedAttachmentID = attachment.id
        previewedAttachmentURL = store.attachmentFileURL(attachment)
    }

    private func finishProfileAction() {
        guard let action = profileAction else { return }
        profileAction = nil
        switch action {
        case .reply(let name, let conversationID):
            guard conversation.id == conversationID else { return }
            store.draft = "\(name), " + store.draft
        case .directMessage(let id):
            store.selectedConversationID = id
        }
        // Restore keyboard focus after AppKit finishes dismissing the sheet.
        DispatchQueue.main.async { composerFocused = true }
    }

    private var composerPrompt: String {
        "Message \(store.title(for: conversation))"
    }

    private var composerControlHeight: CGFloat { 36 }
    private var composerControlSpacing: CGFloat { 8 }
    private var composerSendControlWidth: CGFloat { 27 }
    private var composerCornerRadius: CGFloat { composerControlHeight / 2 }

}

private struct TranscriptViewport: Equatable {
    var offset: CGFloat = 0
    var isAtBottom = true
}

private struct TranscriptGeometry: Equatable {
    let viewport: TranscriptViewport
    let contentHeight: CGFloat
    let containerHeight: CGFloat
}

/// Retains the latest geometry without invalidating the SwiftUI hierarchy on
/// every pixel of a scroll gesture. The durable value is published only when
/// scrolling becomes idle.
private final class TranscriptViewportRecorder {
    var viewport: TranscriptViewport

    init(_ viewport: TranscriptViewport) {
        self.viewport = viewport
    }
}

private struct ConversationTranscript: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    @Binding var selectedAttachmentID: UUID?
    let previewAttachment: (ConversationAttachment) -> Void
    let bottomOverlayHeight: CGFloat
    let showAgentProfile: (AgentRecord) -> Void
    let saveViewport: (TranscriptViewport) -> Void
    @State private var position: ScrollPosition
    @State private var viewportRecorder: TranscriptViewportRecorder
    @State private var followsLatest: Bool
    @State private var userIsScrolling = false

    init(
        conversation: BotConversation,
        initialViewport: TranscriptViewport,
        selectedAttachmentID: Binding<UUID?>,
        previewAttachment: @escaping (ConversationAttachment) -> Void,
        bottomOverlayHeight: CGFloat,
        showAgentProfile: @escaping (AgentRecord) -> Void,
        saveViewport: @escaping (TranscriptViewport) -> Void
    ) {
        self.conversation = conversation
        _selectedAttachmentID = selectedAttachmentID
        self.previewAttachment = previewAttachment
        self.bottomOverlayHeight = bottomOverlayHeight
        self.showAgentProfile = showAgentProfile
        self.saveViewport = saveViewport
        _position = State(initialValue: initialViewport.isAtBottom
            ? ScrollPosition(edge: .bottom)
            : ScrollPosition(y: initialViewport.offset))
        _viewportRecorder = State(initialValue: TranscriptViewportRecorder(initialViewport))
        _followsLatest = State(initialValue: initialViewport.isAtBottom)
    }

    var body: some View {
        ScrollView(.vertical) {
            // Link and attachment previews reserve stable dimensions, allowing
            // long histories to remain lazy without scroll-position corrections.
            LazyVStack(spacing: 10) {
                ConversationStartView(conversation: conversation, showAgentProfile: showAgentProfile)
                    .padding(.bottom, 14)

                ForEach(store.messages(for: conversation)) { message in
                    MessageBubble(
                        message: message,
                        hasConversationBackground: !store.background(for: conversation).isDefault,
                        selectedAttachmentID: $selectedAttachmentID,
                        previewAttachment: previewAttachment,
                        showAgentProfile: showAgentProfile
                    )
                }

                // The composer overlays the scroll view so messages can pass
                // beneath it. This trailing clearance still lets the final
                // message scroll completely above the composer.
                Color.clear.frame(height: bottomOverlayHeight + 20)
            }
            .padding(.horizontal, 15)
            .padding(.top, 30)
        }
        .scrollIndicators(.automatic, axes: .vertical)
        .contentMargins(.bottom, bottomOverlayHeight + 8, for: .scrollIndicators)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(followsLatest ? .bottom : .top, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollGeometryChange(for: TranscriptGeometry.self) { geometry in
            let metrics = TranscriptScrollMetrics(
                contentOffset: geometry.contentOffset.y,
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height,
                topInset: geometry.contentInsets.top,
                bottomInset: geometry.contentInsets.bottom
            )
            return TranscriptGeometry(
                viewport: TranscriptViewport(
                    // ScrollPosition(y:) is measured from the inset-adjusted
                    // top. Geometry's raw offset starts at -contentInsets.top.
                    // Restoring the raw value subtracts the toolbar inset on
                    // every round trip through another conversation.
                    offset: metrics.offset,
                    isAtBottom: metrics.isAtBottom
                ),
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height
            )
        } action: { _, updated in
            viewportRecorder.viewport = updated.viewport
            // isPositionedByUser stays true after a gesture ends. It must not
            // turn a later message/thumbnail resize into an apparent scroll away.
            if userIsScrolling {
                if followsLatest != updated.viewport.isAtBottom {
                    followsLatest = updated.viewport.isAtBottom
                }
            }
            // Never write ScrollPosition from its own geometry callback. Lazy
            // row measurement and selectable text can repeatedly invalidate
            // layout, turning corrective scrolls into a main-thread loop.
            // Size-change anchoring above handles growth; new messages request
            // a single scroll in onChange below.
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            let wasUserScrolling = oldPhase != .idle && oldPhase != .animating
            let isUserScrolling = newPhase != .idle && newPhase != .animating
            userIsScrolling = isUserScrolling
            if wasUserScrolling && !isUserScrolling {
                let finalViewport = viewportRecorder.viewport
                followsLatest = finalViewport.isAtBottom
                saveViewport(finalViewport)
            }
        }
        .onChange(of: store.messages(for: conversation).last?.id) { _, _ in
            let last = store.messages(for: conversation).last
            if last?.author == .user {
                followsLatest = true
                saveViewport(TranscriptViewport(
                    offset: viewportRecorder.viewport.offset,
                    isAtBottom: true
                ))
            }
            if followsLatest && !userIsScrolling {
                position.scrollTo(edge: .bottom)
            }
        }
        // Save only actual user scrolling (above), never teardown geometry.
        // During a conversation switch the outgoing scroll view can receive
        // a resized viewport; recording it would corrupt its saved position.
    }
}

private struct ConversationStartView: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    let showAgentProfile: (AgentRecord) -> Void

    var body: some View {
        VStack(spacing: 12) {
            if conversation.kind == .direct, let agent = store.participants(for: conversation).first {
                Button { showAgentProfile(agent) } label: {
                    avatar.contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(agent.displayName)
                .accessibilityLabel("Show \(agent.displayName)'s profile")
            } else {
                avatar
            }

            Text(store.title(for: conversation))
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            if conversation.kind == .group {
                if let publicDescription = conversation.publicDescription {
                    Text(publicDescription)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                Text(store.participants(for: conversation).map(\.displayName).joined(separator: ", "))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        }
        .frame(maxWidth: .infinity)
    }

    private var avatar: some View {
        ConversationAvatar(
            participants: store.participants(for: conversation),
            isGroup: conversation.kind == .group,
            size: 82
        )
    }
}

private struct PendingAttachmentChip: View {
    @Environment(NoodleStore.self) private var store
    let attachment: ConversationAttachment
    let preview: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: preview) {
                HStack(spacing: 6) {
                    Image(systemName: attachment.previewSymbolName)
                        .foregroundStyle(.blue)
                    Text(attachment.originalFilename)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Preview Attachment")
            .accessibilityLabel("Preview (attachment.originalFilename)")

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove Attachment")
        }
        .font(.caption)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.45)))
        .frame(maxWidth: 260)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                store.copyAttachment(attachment)
            }
            Divider()
            Button("Quick Look", systemImage: "eye", action: preview)
            Button("Remove Attachment", systemImage: "xmark", role: .destructive, action: remove)
        }
    }
}
