import AppKit
import AppletBridge
import PhotosUI
import SwiftUI
import NoodleCore
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.controlActiveState) private var activeState
    let conversation: BotConversation
    let attachmentPreview: AttachmentPreviewController
    var composerFocusRequest: UUID? = nil
    var focusSidebar: (() -> Void)? = nil
    var openDirectMessage: ((UUID) -> Void)? = nil
    var editAgent: ((AgentRecord) -> Void)? = nil
    @State private var composerFocused = false
    @State private var choosingAttachments = false
    @State private var showingAttachmentMenu = false
    @State private var choosingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var attachmentDestinationID: UUID?
    @State private var selectedAttachmentID: UUID?
    @State private var attachmentOpenTask: Task<Void, Never>?
    @State private var screenCapturePreview = ScreenCapturePreviewController()
    @State private var conversationAnnotations = ConversationAnnotationController()
    @State private var bottomOverlayHeight: CGFloat = 0
    @StateObject private var nameCompletion = ComposerNameCompletion()
    @State private var profileAgent: AgentRecord?
    @State private var profileAction: ProfileAction?

    private enum ProfileAction {
        case reply(name: String, conversationID: UUID)
        case directMessage(UUID)
        case edit(UUID)
    }

    var body: some View {
        chatContent
            .simultaneousGesture(TapGesture().onEnded { store.markConversationRead(conversation.id) })
            .onChange(of: activeState, initial: true) { _, state in
                if state == .key { store.markConversationRead(conversation.id) }
            }
            .onChange(of: store.hasUnreadMessages(in: conversation)) { _, unread in
                if unread, activeState == .key { store.markConversationRead(conversation.id) }
            }
            .onChange(of: composerFocused) { _, focused in
                if focused { store.markConversationRead(conversation.id) }
            }
            .environment(\.conversationAnnotations, conversationAnnotations)
            .background(ConversationAnnotationHost(controller: conversationAnnotations,
                conversationID: conversation.id, title: store.title(for: conversation),
                save: { note, content, source, raw in
                    try store.saveConversationAnnotation(note, content: content, source: source, sourceData: raw)
                }, focusComposer: { [focus = $composerFocused] in
                    focus.wrappedValue = true
                }).frame(width: 0, height: 0))
            .background(CaptureShortcut(capture: { showCapture(.window) }).frame(width: 0, height: 0))
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
            .sheet(item: $profileAgent, onDismiss: finishProfileAction) { agent in
                let direct = store.conversations.first {
                    $0.kind == .direct && $0.participantIDs == [agent.id]
                }
                if conversation.kind == .direct {
                    AgentProfileSheet(agent: agent, edit: {
                        profileAction = .edit(agent.id)
                        profileAgent = nil
                    })
                        .noodleSheetSizing()
                } else {
                    AgentProfileSheet(
                        agent: agent,
                        edit: {
                            profileAction = .edit(agent.id)
                            profileAgent = nil
                        },
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
                store.importAttachments(from: providers, into: conversation.id, context: .paste)
            }
            .onChange(of: conversation.id) { _, _ in
                if activeState == .key { store.markConversationRead(conversation.id) }
                attachmentOpenTask?.cancel()
                conversationAnnotations.cancel()
                selectedAttachmentID = nil
                screenCapturePreview.close()
                nameCompletion.detach()
            }
            .onDisappear { attachmentOpenTask?.cancel(); screenCapturePreview.close(); conversationAnnotations.cancel() }
            .onChange(of: composerFocusRequest) { _, request in
                guard request != nil else { return }
                // The flag can still read focused just after another view took first responder;
                // a request must move the caret back regardless.
                if composerFocused {
                    composerFocused = false
                    DispatchQueue.main.async { composerFocused = true }
                } else { composerFocused = true }
            }
    }

    @ViewBuilder private var chatContent: some View {
        topFadedTranscript
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .overlay(alignment: .bottom) {
                measuredPinnedBottomContent
            }
    }

    private var measuredPinnedBottomContent: some View {
        composerFooter
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                bottomOverlayHeight = height
            }
    }

    private var topFadedTranscript: some View {
        ConversationTransition(conversationID: conversation.id) {
            transcript
                .mask {
                    // Fade the transcript pixels themselves as they pass beneath
                    // the toolbar. The separate window-wide shade remains behind
                    // the sidebar and transcript for wallpaper contrast.
                    ConversationContentTopFade()
                }
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
            initialViewport: store.transcriptViewport(for: conversation),
            selectedAttachmentID: $selectedAttachmentID,
            previewAttachment: showPreview,
            bottomOverlayHeight: bottomOverlayHeight,
            showAgentProfile: { profileAgent = $0 },
            saveViewport: { store.saveTranscriptViewport($0, for: id) }
        )
        .id(id)
        .transaction { transaction in
            transaction.animation = nil
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let link = WebLinkPreview.previewed(url, enabled: WebLinkPreview.opensInPreview()) else { return .systemAction }
            screenCapturePreview.close()
            attachmentPreview.showLink(link, conversationID: id) { note, content, source, raw in
                try store.saveConversationAnnotation(note, content: content, source: source, sourceData: raw)
            }
            return .handled
        })
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            PendingAttachmentStrip(conversationID: conversation.id,
                leadingInset: composerControlHeight + composerControlSpacing, preview: { showPreview($0) })

            composerControls
        }
        .onDisappear {
            nameCompletion.detach()
        }
    }

    @ViewBuilder private var composerControls: some View {
        GlassEffectContainer(spacing: composerControlSpacing) {
            composerControlRow
        }
    }

    private func showCapture(_ kind: ScreenCaptureKind) {
        attachmentOpenTask?.cancel()
        if screenCapturePreview.focusIfOpen() { return }
        guard let host = attachmentPreview.resolveHostWindow() else { return }
        let destination = conversation.id
        attachmentPreview.close()
        screenCapturePreview.show(kind: kind, relativeTo: host) { image, title, region, comment in
            try store.importCapture(image: image, title: title, region: region, comment: comment, into: destination)
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
                        },
                        capture: { showCapture(.window) })
                }
            VoiceMessageComposer(
                recorder: store.voiceRecorder(for: conversation.id),
                send: { url, voice in try store.sendVoiceMessage(from: url, voice: voice, to: conversation.id) }
            ) { start in
                composerInput(microphoneAction: start)
            }
        }
    }

    @ViewBuilder private var attachmentButton: some View {
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
    }

    @ViewBuilder private func composerInput(microphoneAction: (() -> Void)? = nil) -> some View {
        composerInputContents(microphoneAction: microphoneAction)
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
            )
            .modifier(ComposerFocusSurface(cornerRadius: composerCornerRadius,
                controlsWidth: composerSendControlWidth + 7 + (microphoneAction == nil ? 0 : 31)) { composerFocused = true })
    }

    private func composerInputContents(microphoneAction: (() -> Void)? = nil) -> some View {
        ComposerDraftInput(conversation: conversation, isFocused: $composerFocused, placeholder: composerPrompt,
            completion: nameCompletion, focusSidebar: focusSidebar, microphoneAction: microphoneAction,
            controlHeight: composerControlHeight, sendControlWidth: composerSendControlWidth)
    }

    private func showPreview(_ attachment: ConversationAttachment, among group: [ConversationAttachment] = []) {
        attachmentOpenTask?.cancel()
        selectedAttachmentID = attachment.id
        if attachment.opensInCompanion {
            attachmentPreview.close()
            screenCapturePreview.close()
            attachmentOpenTask = Task { @MainActor in
                do { try await store.openCompanion(attachment) }
                catch { if !Task.isCancelled { store.errorMessage = error.localizedDescription } }
            }
            return
        }
        if let link = attachment.url, MessageLink.publicWebURL(from: link, preservingFragment: true) != nil,
           !WebLinkPreview.opensInPreview() {
            attachmentPreview.close()
            NSWorkspace.shared.open(link)
            return
        }
        // Annotations stay in Quick Look, where their note is shown and edited.
        if attachment.url == nil, attachment.annotation == nil, QuickLookBypass.isHeld() {
            attachmentPreview.close()
            NSWorkspace.shared.open(store.attachmentFileURL(attachment))
            return
        }
        let edit: ((ConversationAttachment, String) throws -> ConversationAttachment)? = store.canEditAnnotation(attachment) ? { [weak store] attachment, comment in
            guard let store else { throw WorkspaceError.missingConversation(attachment.conversationID) }
            return try store.reviseAnnotationComment(attachment, comment: comment)
        } : nil
        let gallery = ConversationAttachment.previewGallery(opening: attachment, among: group).items
        attachmentPreview.show(attachment, url: store.attachmentFileURL(attachment),
            gallery: gallery.map { ($0, store.attachmentFileURL($0)) }, edit: edit,
            canEdit: { [weak store] in store?.canEditAnnotation($0) == true }) { [weak store] note, content, source in
            guard let store else { throw WorkspaceError.missingConversation(source.conversationID) }
            try store.saveAnnotation(note, content: content, source: source)
        }
    }

    private func finishProfileAction() {
        guard let action = profileAction else { return }
        profileAction = nil
        switch action {
        case .reply(let name, let conversationID):
            guard conversation.id == conversationID else { return }
            store.setDraft("\(name), " + store.draft(for: conversationID), for: conversationID)
        case .directMessage(let id):
            if let openDirectMessage { openDirectMessage(id) }
            else { store.selectedConversationID = id }
        case .edit(let id):
            guard let agent = store.agents.first(where: { $0.id == id }) else { return }
            if let editAgent { editAgent(agent) }
            else { store.agentBeingEdited = agent }
            return
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

// The draft is read in these views' own bodies, so that typing re-evaluates the
// composer alone and leaves the transcript beside it untouched.
private struct PendingAttachmentStrip: View {
    @Environment(NoodleStore.self) private var store
    let conversationID: UUID
    let leadingInset: CGFloat
    let preview: (ConversationAttachment) -> Void

    var body: some View {
        let attachments = store.pendingAttachments(for: conversationID)
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(attachments) { attachment in
                        PendingAttachmentChip(
                            attachment: attachment,
                            preview: { preview(attachment) },
                            remove: { store.removePendingAttachment(attachment) }
                        )
                    }
                }
            }
            .padding(.leading, leadingInset)
        }
    }
}

private struct ComposerDraftInput: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    @Binding var isFocused: Bool
    let placeholder: String
    let completion: ComposerNameCompletion
    let focusSidebar: (() -> Void)?
    let microphoneAction: (() -> Void)?
    let controlHeight: CGFloat
    let sendControlWidth: CGFloat

    private var cannotSend: Bool {
        store.draft(for: conversation.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            store.pendingAttachments(for: conversation.id).isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollableChatComposer(
                text: Binding(
                    get: { store.draft(for: conversation.id) },
                    set: { store.setDraft($0, for: conversation.id) }
                ),
                isFocused: $isFocused,
                conversationID: conversation.id,
                placeholder: placeholder,
                agents: store.agents,
                preferredIDs: Set(conversation.participantIDs),
                separatesPreferredAgents: conversation.kind == .group,
                completion: completion,
                submit: { store.sendDraft(to: conversation.id) },
                focusSidebar: focusSidebar,
                pasteAttachments: { store.importAttachmentsFromPasteboard(into: conversation.id, pasteboard: $0) },
                dropFiles: { urls in
                    urls.forEach { store.importAttachment(from: $0, into: conversation.id) }
                }
            )
            .padding(.leading, 12)
            .padding(.trailing, sendControlWidth + 14 + (microphoneAction == nil ? 0 : 31))
            .padding(.vertical, 6)
            .frame(minHeight: controlHeight, alignment: .center)

            HStack(spacing: 4) {
            if let microphoneAction {
                Button(action: microphoneAction) {
                    Image(systemName: "mic")
                        .font(.system(size: 16))
                        .frame(width: 27, height: controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(KeyboardBindings.shared.help("Record Voice Message", for: .recordVoice))
                .accessibilityLabel("Record voice message")
            }
            if cannotSend {
                Image(systemName: "arrow.up.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                    .frame(width: sendControlWidth, height: controlHeight)
                    .padding(.trailing, 7)
            } else {
                Button(action: { store.sendDraft(to: conversation.id) }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 23))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: sendControlWidth, height: controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 7)
                .help("Send Message")
            }
            }
        }
    }
}

private struct ConversationTranscript: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    let initialViewport: TranscriptViewport
    @Binding var selectedAttachmentID: UUID?
    let previewAttachment: (ConversationAttachment, [ConversationAttachment]) -> Void
    let bottomOverlayHeight: CGFloat
    let showAgentProfile: (AgentRecord) -> Void
    let saveViewport: (TranscriptViewport) -> Void
    /// The oldest message shown. Until set, the newest page and the opening reading position show.
    @State private var firstShownID: UUID?

    /// Messages shown when a conversation opens, and added each time the top is reached.
    /// Layout work for every update grows with the rows a transcript holds, not with what is on screen.
    static let pageSize = 100

    private func firstShown(in messages: [ChatMessage]) -> Int {
        if let firstShownID, let index = messages.firstIndex(where: { $0.id == firstShownID }) { return index }
        let reading = initialViewport.messageID.flatMap { id in messages.firstIndex { $0.id == id } }
        return min(max(messages.count - Self.pageSize, 0), reading ?? .max)
    }

    var body: some View {
        let all = store.messages(for: conversation)
        let first = firstShown(in: all)
        let messages = all[first...]
        let _ = TranscriptRenderProbe.transcript(messages)
        TranscriptScrollView(
            initialViewport: initialViewport,
            lastMessageID: messages.last?.id,
            lastMessageIsFromUser: messages.last?.author == .user,
            bottomOverlayHeight: bottomOverlayHeight,
            saveViewport: saveViewport,
            onInteraction: { store.markConversationRead(conversation.id) },
            containsMessage: { id in all.contains { $0.id == id } }
        ) {
            if first == 0 {
                ConversationStartView(conversation: conversation, showAgentProfile: showAgentProfile)
                    .padding(.bottom, 14)
                    .id(TranscriptScrollTarget.start)
            } else {
                // Reaching the top shows the page before. Rows keep their place by ID.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    // Keyed by the first row, so a page too short to push it off screen still loads the next.
                    .task(id: first) { firstShownID = all[max(first - Self.pageSize, 0)].id }
            }

            ForEach(messages) { message in
                MessageBubble(
                    message: message,
                    hasConversationBackground: !store.background(for: conversation).isDefault,
                    selectedAttachmentID: $selectedAttachmentID,
                    previewAttachment: previewAttachment,
                    showAgentProfile: showAgentProfile
                )
                .transition(MessageBubble.insertion(for: message))
                .id(TranscriptScrollTarget.message(message.id))
            }
        }
        // Later replies add to what shows rather than pushing the oldest rows out from under the reader.
        .onAppear { firstShownID = firstShownID ?? messages.first?.id }
        .onChange(of: messages.first?.id) { _, id in firstShownID = firstShownID ?? id }
        .onReceive(NotificationCenter.default.publisher(for: .revealTranscriptMessage)) { notification in
            guard let id = notification.object as? UUID, let index = all.firstIndex(where: { $0.id == id }),
                  index < first else { return }
            firstShownID = id
        }
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
                .contextMenu {
                    Button("Show Activity") { store.showActivity(for: agent) }
                }
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

    private var title: String {
        attachment.annotation.map { $0.comment.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            ?? attachment.originalFilename
    }

    private var previewDescription: String {
        guard let note = attachment.annotation else { return attachment.originalFilename }
        return "Annotation on \(note.sourceFilename)\n\n\(note.comment)"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: preview) {
                HStack(spacing: 6) {
                    Image(systemName: attachment.previewSymbolName)
                        .foregroundStyle(.blue)
                        .frame(width: 14)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(previewDescription)
            .accessibilityLabel("Preview \(previewDescription)")
            .onDrag { store.attachmentDragProvider(attachment) }

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
        .frame(height: 28)
        .modifier(PendingAttachmentSurface())
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

private struct PendingAttachmentSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        content.glassEffect(.regular, in: Capsule())
    }
}
