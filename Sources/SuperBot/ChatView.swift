import QuickLook
import SwiftUI
import SuperBotCore
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(SuperBotStore.self) private var store
    let conversation: BotConversation
    @FocusState private var composerFocused: Bool
    @State private var choosingAttachments = false
    @State private var selectedAttachmentID: UUID?
    @State private var previewedAttachmentURL: URL?
    @State private var transcriptPositions: [UUID: TranscriptViewport] = [:]

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
                .padding(.horizontal, 12)
                .padding(.bottom, 11)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
        .fileImporter(
            isPresented: $choosingAttachments,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                urls.forEach(store.importAttachment)
            case .failure(let error):
                store.errorMessage = error.localizedDescription
            }
        }
        .quickLookPreview($previewedAttachmentURL)
        .onPasteCommand(of: AttachmentTransfer.pasteContentTypes) { providers in
            store.importAttachments(from: providers)
        }
        .onChange(of: conversation.id) { _, _ in
            selectedAttachmentID = nil
            previewedAttachmentURL = nil
        }
    }

    private var transcript: some View {
        let id = conversation.id
        return ConversationTranscript(
            conversation: conversation,
            initialViewport: transcriptPositions[id] ?? TranscriptViewport(),
            selectedAttachmentID: $selectedAttachmentID,
            previewAttachment: showPreview,
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

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    choosingAttachments = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.quaternary.opacity(0.35), in: Circle())
                        .frame(width: composerControlHeight, height: composerControlHeight)
                }
                .buttonStyle(.plain)
                .help("Add Attachment")

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

                    if cannotSend {
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
                        .help("Send Message")
                    }
                }
                .padding(.horizontal, 7)
                .frame(minHeight: composerControlHeight)
                .background(.quaternary.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.6)))
            }
        }
        .onChange(of: composerFocused) { _, isFocused in
            store.composerIsFocused = isFocused
        }
        .onDisappear {
            store.composerIsFocused = false
        }
    }

    private var cannotSend: Bool {
        store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            store.pendingAttachments.isEmpty
    }

    private func showPreview(_ attachment: ConversationAttachment) {
        selectedAttachmentID = attachment.id
        previewedAttachmentURL = store.attachmentFileURL(attachment)
    }

    private var composerPrompt: String {
        "Message \(store.title(for: conversation))"
    }

    private var composerControlHeight: CGFloat { 32 }

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

private struct ConversationTranscript: View {
    @Environment(SuperBotStore.self) private var store
    let conversation: BotConversation
    @Binding var selectedAttachmentID: UUID?
    let previewAttachment: (ConversationAttachment) -> Void
    let saveViewport: (TranscriptViewport) -> Void
    @State private var position: ScrollPosition
    @State private var viewport: TranscriptViewport
    @State private var followsLatest: Bool
    @State private var userIsScrolling = false

    init(
        conversation: BotConversation,
        initialViewport: TranscriptViewport,
        selectedAttachmentID: Binding<UUID?>,
        previewAttachment: @escaping (ConversationAttachment) -> Void,
        saveViewport: @escaping (TranscriptViewport) -> Void
    ) {
        self.conversation = conversation
        _selectedAttachmentID = selectedAttachmentID
        self.previewAttachment = previewAttachment
        self.saveViewport = saveViewport
        _position = State(initialValue: initialViewport.isAtBottom
            ? ScrollPosition(edge: .bottom)
            : ScrollPosition(y: initialViewport.offset))
        _viewport = State(initialValue: initialViewport)
        _followsLatest = State(initialValue: initialViewport.isAtBottom)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // Measure the actual transcript height on its first layout. Lazy
            // estimates change as attachment rows enter the viewport and cause
            // visible corrections when restoring a bottom or pixel offset.
            VStack(spacing: 10) {
                ConversationStartView(conversation: conversation)
                    .padding(.bottom, 14)

                ForEach(store.messages(for: conversation)) { message in
                    MessageBubble(
                        message: message,
                        selectedAttachmentID: $selectedAttachmentID,
                        previewAttachment: previewAttachment
                    )
                }

                Color.clear.frame(height: 20)
            }
            .padding(.horizontal, 15)
            .padding(.top, 30)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(followsLatest ? .bottom : .top, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollGeometryChange(for: TranscriptGeometry.self) { geometry in
            let bottom = max(0, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
            return TranscriptGeometry(
                viewport: TranscriptViewport(
                    // ScrollPosition(y:) is measured from the inset-adjusted
                    // top. Geometry's raw offset starts at -contentInsets.top.
                    // Restoring the raw value subtracts the toolbar inset on
                    // every round trip through another conversation.
                    offset: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                    isAtBottom: geometry.contentOffset.y >= bottom - 2
                ),
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height
            )
        } action: { _, updated in
            viewport = updated.viewport
            // isPositionedByUser stays true after a gesture ends. It must not
            // turn a later message/thumbnail resize into an apparent scroll away.
            if userIsScrolling {
                followsLatest = updated.viewport.isAtBottom
                saveViewport(updated.viewport)
            } else if followsLatest && !updated.viewport.isAtBottom {
                position.scrollTo(edge: .bottom)
            }
        }
        .onScrollPhaseChange { _, phase in
            userIsScrolling = phase != .idle && phase != .animating
        }
        .onChange(of: store.messages(for: conversation).last?.id) { _, _ in
            let last = store.messages(for: conversation).last
            if last?.author == .user {
                followsLatest = true
                saveViewport(TranscriptViewport(offset: viewport.offset, isAtBottom: true))
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

private struct PendingAttachmentChip: View {
    @Environment(SuperBotStore.self) private var store
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
