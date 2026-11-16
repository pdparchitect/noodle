import PhotosUI
import HubLink
import NoodleCore
import NoodleRuntimeSettings
import NoodleWallpaper
import PionCore
import SwiftUI

/// A second conversation keeps its selection, sheets and inspector independent of the main window.
struct ConversationWindow: View {
    let model: PionModel
    @Binding var selection: UUID?
    @State private var window = WindowState()
    @Environment(\.floatingPanelCommands) private var panel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let conversation = model.conversation(selection) {
                ConversationView(model: model, window: window, conversation: conversation)
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let selection, model.conversation(selection) != nil {
                    Button { PionWindows.returnToMainWindow(selection, model: model) } label: {
                        Label("Show in Main Window", systemImage: "pip.exit")
                    }
                    .help("Show in Main Window")
                }
            }
        }
        // Noodle's window registry: what this window shows is read while it is on screen, and the window opens again.
        .background {
            if let registry = PionWindows.conversations {
                ConversationWindowHost(registry: registry, conversationID: selection) { if let id = $0 { model.markRead(id) } }
            }
        }
        .modifier(ConversationSheets(model: model, window: window, selection: $selection))
        .modifier(RecoveryConfirmations(window: window))
        // As in Noodle, a conversation deleted elsewhere takes its window with it.
        .onChange(of: selection.map { model.conversation($0) == nil } == true) { _, missing in
            guard missing, let selection else { return }
            if panel != nil { PionWindows.panels?.close(selection) } else { dismiss() }
        }
        // A window of its own has no sidebar to search, so Search Conversations is the main window's alone.
        .focusedSceneValue(\.pionConversation, ConversationCommandContext(selection: $selection, window: window, search: nil))
        .onChange(of: selection, initial: true) { _, id in
            if let id { model.markRead(id) }
            window.composerFocusRequest = UUID()
        }
    }
}

/// One conversation as a document: a header, the messages in a reading column, and the composer.
/// An Investigation also has its case record in the inspector.
struct ConversationView: View {
    let model: PionModel
    @Bindable var window: WindowState
    let conversation: BotConversation
    @Environment(PionCalls.self) private var calls
    @Environment(PionSettingsHost.self) private var host
    @Environment(\.openSettings) private var openSettings
    @State private var composerHeight: CGFloat = 0
    // The column's ideal, read from the width it was left at only as the inspector opens. The width is
    // kept in defaults, not app storage: a stored value the view watches redraws it on every step of a
    // divider drag, in the middle of AppKit's layout, and the app crashes.
    @State private var openingInspectorWidth: Double?
    private static let inspectorWidthKey = "PionInspectorWidth"
    private static var storedInspectorWidth: Double {
        UserDefaults.standard.object(forKey: inspectorWidthKey) as? Double ?? 360
    }
    // Noodle's previews, capture and annotation, one of each per conversation shown.
    @State private var attachmentPreview = AttachmentPreviewController()
    @State private var screenCapturePreview = ScreenCapturePreviewController()
    @State private var conversationAnnotations = ConversationAnnotationController()
    @State private var choosingFiles = false
    @State private var choosingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var selectedAttachmentID: UUID?
    /// The file Forward… was chosen for, held here rather than by its message.
    @State private var forwarding: ConversationAttachment?
    /// Where the reader was in each conversation, kept while Pion runs.
    @State private static var viewports: [UUID: TranscriptViewport] = [:]

    private var investigation: Investigation? { model.investigation(conversation.id) }

    var body: some View {
        // Noodle's dissolve: the transcript alone is rebuilt for another conversation, so the toolbar,
        // composer and inspector stay put and the composer keeps the keyboard.
        ConversationTransition(conversationID: conversation.id) {
            transcript
                // Noodle's shade: messages fade as they pass under the toolbar, and only once there is something under it.
                .conversationTopFade()
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .bottom) {
            Composer(model: model, window: window, conversation: conversation, investigation: investigation,
                     actions: ComposerActions(attachFile: { choosingFiles = true },
                                              choosePhoto: { photoSelection = []; choosingPhotos = true },
                                              capture: showCapture,
                                              preview: { showPreview($0) }))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        // As in Noodle: files dropped anywhere on the conversation wait in its message field.
        .conversationFileDrop(isEnabled: { investigation?.isClosed != true }) { model.attachDropped($0, to: conversation.id) }
        .environment(\.conversationAnnotations, conversationAnnotations)
        .environment(\.forwardAttachment) { forwarding = $0 }
        .sheet(item: $forwarding) { attachment in
            ForwardAttachmentSheet(attachment: attachment,
                                   targets: { model.forwardTargets(from: attachment.conversationID, search: $0)
                                       .map { ForwardTarget(id: $0.id, title: model.title(of: $0)) } },
                                   picture: { id in AnyView(model.conversation(id).map { ConversationPicture(model: model, conversation: $0, size: 28) }) },
                                   send: { try model.forward(attachment, to: $0, comment: $1) })
                .noodleSheetSizing()
        }
        .background(AttachmentPreviewHost(controller: attachmentPreview))
        .background(ConversationAnnotationHost(controller: conversationAnnotations, conversationID: conversation.id,
            title: investigation?.reference ?? conversation.displayName,
            save: { note, content, source, raw in
                try model.saveConversationAnnotation(note, content: content, source: source, sourceData: raw)
            }, focusComposer: { window.composerFocusRequest = UUID() }).frame(width: 0, height: 0))
        .background(CaptureShortcut(capture: showCapture).frame(width: 0, height: 0))
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.attach(urls, to: conversation.id)
            case .failure(let error): model.problem = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoSelection, matching: .images, preferredItemEncoding: .current)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { model.importPhoto(data: data, into: conversation.id) }
                }
            }
        }
        // Links open in Noodle's preview, where they can be annotated, unless the person turned that off.
        .environment(\.openURL, OpenURLAction { url in
            guard let link = WebLinkPreview.previewed(url, enabled: WebLinkPreview.opensInPreview()) else { return .systemAction }
            screenCapturePreview.close()
            attachmentPreview.showLink(link, conversationID: conversation.id) { note, content, source, raw in
                try model.saveConversationAnnotation(note, content: content, source: source, sourceData: raw)
            }
            return .handled
        })
        .onAppear { attachmentPreview.reportError = { model.problem = $0.localizedDescription } }
        .onDisappear { attachmentPreview.close(); screenCapturePreview.close(); conversationAnnotations.cancel() }
        .navigationTitle(investigation?.reference ?? conversation.displayName)
        .navigationSubtitle(investigation?.title ?? subtitle)
        .toolbar { toolbar }
        // Hidden for an agent or group without forgetting it was open, so it is back on returning to an Investigation.
        // SwiftUI writes false back while it hides it, sometimes through the binding of the Investigation just
        // left, so only the Case button and View › Hide Inspector change whether it shows.
        .inspector(isPresented: Binding(get: { window.showsInspector && investigation != nil }, set: { _ in })) {
            Group {
                if let investigation {
                    // Its own for each Investigation, so evidence opened in one never shows open in another.
                    CaseInspector(model: model, window: window, investigation: investigation)
                        .id(investigation.id)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            if (300...520).contains(width) { UserDefaults.standard.set(Double(width), forKey: Self.inspectorWidthKey) }
                        }
                        .background { Backdrop(frosted: true).ignoresSafeArea() }
                }
            }
            // Back at the width it was left at, here and on the next launch; widths outside the column's
            // range come only from it opening or closing. On the root: inside the condition SwiftUI misses
            // it and the column is fixed at its default width.
            .inspectorColumnWidth(min: 300, ideal: openingInspectorWidth ?? Self.storedInspectorWidth, max: 520)
        }
        .onChange(of: window.showsInspector && investigation != nil, initial: true) { _, shown in
            if shown { openingInspectorWidth = Self.storedInspectorWidth }
        }
        .onChange(of: conversation.id) { _, _ in
            attachmentPreview.close()
            screenCapturePreview.close()
            conversationAnnotations.cancel()
            selectedAttachmentID = nil
        }
    }

    private var transcript: some View {
        Transcript(model: model, window: window, conversation: conversation, investigation: investigation,
                   initialViewport: Self.viewports[conversation.id] ?? TranscriptViewport(), bottomOverlayHeight: composerHeight,
                   selectedAttachmentID: $selectedAttachmentID, saveViewport: { Self.viewports[conversation.id] = $0 },
                   preview: { showPreview($0, among: $1) })
            // A conversation of its own starts from its newest page.
            .id(conversation.id)
    }

    private func showCapture() {
        let destination = conversation.id
        opening.showCapture(.window) { image, title, region, comment in
            try model.importCapture(image: image, title: title, region: region, comment: comment, into: destination)
        }
    }

    /// Noodle's way of opening an attachment and the screen capture.
    private var opening: AttachmentOpening {
        AttachmentOpening(preview: attachmentPreview, capture: screenCapturePreview, patchReviews: patchReviews)
    }

    private func showPreview(_ attachment: ConversationAttachment, among group: [ConversationAttachment] = []) {
        selectedAttachmentID = attachment.id
        opening.open(attachment, among: group, host: model)
    }

    private var subtitle: String {
        conversation.kind == .group ? model.members(of: conversation).map(\.displayName).formatted(.list(type: .and))
            : model.agent(conversation.participantIDs.first)?.publicDescription ?? ""
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Noodle's pause line: why an agent here doesn't answer, and Sign In, Unsuspend or Kick to bring it back.
        if let pause = model.pause(of: conversation) {
            ToolbarItem {
                ConversationPauseBar(pause: pause, runtime: model.runtime,
                                     signIn: { host.selectedTab = .harnesses; openSettings() },
                                     unsuspend: { model.setSuspended(until: nil, agent: $0) },
                                     kick: { window.kickRequest = model.runtime.kick(agent: $0, repository: model.repository) })
            }
        }
        // The call button, or this conversation's call controls, as in Noodle; only an agent with voices has one.
        if calls.voiceCallTarget(for: conversation) != nil || calls.voiceCalls.call?.conversationID == conversation.id {
            ToolbarItem { VoiceCallToolbarControl(store: calls, conversation: conversation) }
        }
        if investigation?.isClosed != true {
            ToolbarItem {
                Button { window.edit(conversation, in: model) } label: { Label("Edit…", systemImage: "pencil") }
                    .help(investigation != nil ? "Edit Investigation…" : conversation.kind == .group ? "Edit Group…" : "Edit Agent…")
                    .accessibilityLabel(investigation != nil ? "Edit Investigation…" : conversation.kind == .group ? "Edit Group…" : "Edit Agent…")
            }
        }
        if let investigation {
            ToolbarItem {
                Menu {
                    ForEach([Investigation.Status.open, .triaging, .contained], id: \.self) { status in
                        Button { model.setStatus(status, of: investigation) } label: { Label(status.title, systemImage: status.symbol) }
                            .disabled(investigation.isClosed || investigation.status == status)
                    }
                    Divider()
                    // Shown, not chosen: only the lead agent sets it, through the case tool.
                    Text("Severity: \(investigation.severityTitle), set by the lead agent")
                    Divider()
                    if investigation.isClosed {
                        Button("Reopen") { model.setStatus(.open, of: investigation) }
                    } else {
                        Button("Close Investigation…") { window.sheet = .close(investigation) }
                            .appShortcut(PionShortcuts.closeInvestigation)
                    }
                } label: {
                    WidestLabel(title: investigation.outcome?.title ?? investigation.status.title, symbol: investigation.status.symbol,
                                choices: [Investigation.Status.open, .triaging, .contained].map { ($0.title, $0.symbol) }
                                    + Investigation.Outcome.allCases.map { ($0.title, Investigation.Status.closed.symbol) })
                }
                .help("Status")
            }
        }
        if let investigation {
            ToolbarItem {
                Menu {
                    Button("Export as Zip…") { model.exportInvestigation(investigation) }
                    Button("Show in Finder") { model.reveal(conversation) }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuIndicator(.hidden)
                .help("Export")
            }
            // Apart from the export menu, so each sits in its own glass.
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button { window.showsInspector.toggle() } label: { Label("Case", systemImage: "sidebar.trailing") }
                    .help(KeyboardBindings.shared.help("Show or hide the case record", for: PionShortcuts.showInspector))
            }
        }
    }
}

/// What a conversation is about, above its first message.
/// The messages of a conversation, Noodle's way: a page at a time from the newest, calls placed among them.
private struct Transcript: View {
    let model: PionModel
    let window: WindowState
    let conversation: BotConversation
    let investigation: Investigation?
    let initialViewport: TranscriptViewport
    let bottomOverlayHeight: CGFloat
    @Binding var selectedAttachmentID: UUID?
    let saveViewport: (TranscriptViewport) -> Void
    let preview: (ConversationAttachment, [ConversationAttachment]) -> Void
    @Environment(PionCalls.self) private var calls
    /// The oldest message shown. Until set, the newest page and the opening reading position show.
    @State private var firstShownID: UUID?

    var body: some View {
        let all = model.messages(in: conversation.id)
        let first = TranscriptPaging.firstShown(in: all, firstShownID: firstShownID, reading: initialViewport.messageID)
        let messages = all[first...]
        // What was said on calls, placed among the messages sent while they ran, as Noodle shows it.
        let spoken = VoiceCallLayout.spokenLines(in: all, live: calls.liveCallCardID(in: conversation.id).map {
            ($0, calls.voiceCalls.call?.lines ?? [])
        })
        TranscriptScrollView(
            initialViewport: initialViewport,
            lastMessageID: messages.last?.id,
            lastMessageIsFromUser: messages.last?.author == .user,
            bottomOverlayHeight: bottomOverlayHeight,
            saveViewport: saveViewport,
            onInteraction: { model.markRead(conversation.id) },
            containsMessage: { id in all.contains { $0.id == id } },
            onBackgroundTap: { window.composerFocusRequest = UUID() }
        ) {
            if first == 0 {
                ConversationStart(model: model, window: window, conversation: conversation, investigation: investigation)
                    .id(TranscriptScrollTarget.start)
            } else {
                TranscriptOlderPage(first: first) { firstShownID = TranscriptPaging.pageBefore(first, in: all) }
            }
            // Indices into all, so the first shown row knows the message before it even when that one is not loaded.
            ForEach(Array(zip(messages.indices, messages)), id: \.1.id) { index, message in
                let previous = index > 0 ? all[index - 1] : nil
                VStack(spacing: 0) {
                    if let call = message.call {
                        VoiceCallCard(store: calls, message: message, record: call)
                            .padding(.top, 14)
                            .frame(maxWidth: MessageRow.column)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 28)
                    } else {
                        MessageRow(model: model, window: window, conversation: conversation, investigation: investigation, message: message,
                                   selectedAttachmentID: $selectedAttachmentID, preview: { preview($0, model.files(of: message)) },
                                   continues: previous.map { $0.call == nil && $0.author == message.author
                                       && message.createdAt.timeIntervalSince($0.createdAt) < 600 } ?? false)
                    }
                    if let block = spoken[message.id] {
                        VoiceCallBlockView(store: calls, block: block)
                            .padding(.top, 8)
                            .frame(maxWidth: MessageRow.column)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 28)
                    }
                }
                .id(TranscriptScrollTarget.message(message.id))
            }
        }
        .transaction { $0.animation = nil }
        .transcriptPaging(firstShownID: $firstShownID, shown: messages, all: all, first: first)
    }
}

struct ConversationStart: View {
    let model: PionModel
    let window: WindowState
    let conversation: BotConversation
    let investigation: Investigation?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let investigation {
                HStack(spacing: 8) {
                    Text(investigation.reference).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Tag(text: investigation.outcome?.title ?? investigation.status.title,
                        color: investigation.isClosed ? .secondary : investigation.status.color, symbol: investigation.status.symbol)
                    Tag(text: investigation.severityTitle, color: investigation.severityColor)
                }
                Text(investigation.title).font(.title2.weight(.semibold))
                if !investigation.objective.isEmpty {
                    Text(investigation.objective).font(.body).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Label(investigation.champion, systemImage: "person.crop.circle").help("Champion")
                    if let lead = model.agent(model.conversation(investigation.id)?.lead) { Label("\(lead.displayName) leads", systemImage: "star") }
                    if let source = investigation.source { Label(source, systemImage: "bell").lineLimit(1) }
                    Label("Opened \(investigation.openedAt.pionShort)", systemImage: "clock")
                }
                .font(.callout).foregroundStyle(.secondary)
            } else if conversation.kind == .group {
                GroupProfileButton(model: model, group: conversation, edit: { window.edit(conversation, in: model) }) {
                    Text(conversation.displayName).font(.title2.weight(.semibold))
                }
                if let description = conversation.publicDescription { Text(description).foregroundStyle(.secondary) }
            } else if let agent = model.agent(conversation.participantIDs.first) {
                HStack(spacing: 12) {
                    AgentProfileButton(model: model, agent: agent, size: 40) { window.sheet = .editAgent(agent) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.displayName).font(.title2.weight(.semibold))
                        if let description = agent.publicDescription { Text(description).foregroundStyle(.secondary) }
                    }
                }
            }
            if conversation.kind == .group {
                HStack(spacing: 6) {
                    ForEach(model.members(of: conversation)) { agent in
                        AgentProfileButton(model: model, agent: agent, size: 16, phase: model.phase(of: agent), showsName: true,
                                           edit: { window.sheet = .editAgent(agent) },
                                           reply: window.reply(to: agent, in: conversation, model: model))
                        .padding(.trailing, 4)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: MessageRow.column, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        // The transcript runs under the toolbar; at rest its heading lines up with the sidebar's first section and the inspector's divider.
        .padding(.top, 20)
    }
}

/// One message. An agent's fills the reading column with its name above, as an assistant's answer in
/// ChatGPT; the champion's sits on the right in a quiet box. Nothing is folded away.
struct MessageRow: View {
    static let column: CGFloat = 780

    let model: PionModel
    let window: WindowState
    let conversation: BotConversation
    let investigation: Investigation?
    let message: ChatMessage
    @Binding var selectedAttachmentID: UUID?
    let preview: (ConversationAttachment) -> Void
    let continues: Bool
    @State private var hovering = false
    /// The voice message showing its transcript, opened by its button or its menu, as in Noodle.
    @State private var transcriptAttachmentID: UUID?
    /// View › Conversation › Attachments, as in Noodle.
    @AppStorage(ChatAttachmentLayout.defaultsKey) private var attachmentLayout = ChatAttachmentLayout.defaultValue.rawValue
    @Environment(\.forwardAttachment) private var forwardAttachment

    var body: some View {
        Group {
            if message.author == .system {
                // Noodle's notice: a change of harness, or who joined or left a group.
                ConversationNoticeView(text: message.body, isDirect: conversation.kind == .direct)
                    .padding(.top, 10)
            } else if message.author == .user {
                HStack {
                    Spacer(minLength: 120)
                    VStack(alignment: .trailing, spacing: 4) {
                        // Written from a task in the sidebar.
                        if let task = message.task { MessageTaskLabel(task: task) }
                        MessageBody(text: message.body, message: message, fills: false) { model.problem = $0 }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.secondary.opacity(0.11), in: .rect(cornerRadius: 18, style: .continuous))
                            .overlay(alignment: .topTrailing) { reactions.offset(x: 5, y: -12) }
                        linkPreview
                        files
                        HStack(spacing: 6) {
                            // Always laid out, only shown on hover, so pointing at a message never moves the others.
                            Text(message.createdAt.pionShort).font(.caption2).foregroundStyle(.tertiary)
                                .opacity(hovering ? 1 : 0)
                            // As Noodle's: whether it reached the conversation, and whether an agent got it.
                            MessageDeliveryLabel(delivery: message.delivery)
                        }
                    }
                }
                .padding(.top, 10)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if !continues { header }
                    MessageBody(text: message.body, message: message) { model.problem = $0 }
                        .padding(.leading, 30)
                        .overlay(alignment: .topTrailing) { reactions.offset(x: 5, y: -12) }
                    linkPreview.padding(.leading, 30)
                    files.padding(.leading, 30)
                }
                .padding(.top, continues ? 2 : 14)
            }
        }
        .frame(maxWidth: Self.column)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Noodle's message menu: react, copy, then Pion's own items for the agent who wrote it.
        .background(MessageContextMenu(
            selected: Set((message.reactions ?? []).filter { $0.author == .user }.map(\.emoji)),
            react: { model.toggleReaction($0, on: message) },
            copy: { copyText(message.body) },
            preview: nil, reveal: nil,
            more: authorAgent.map { agent in [
                .init(title: "Show Activity", symbol: "list.bullet.rectangle") { model.showActivity(for: agent) },
                .init(title: "Edit Agent…", symbol: "pencil") { window.sheet = .editAgent(agent) },
            ] } ?? []))
    }

    /// Noodle's menu for a file: react to its message, copy it, look at it, keep a copy, find it, send it on.
    private func attachmentMenu(_ attachment: ConversationAttachment) -> MessageContextMenu {
        MessageContextMenu(
            selected: Set((message.reactions ?? []).filter { $0.author == .user }.map(\.emoji)),
            react: { model.toggleReaction($0, on: message) },
            copy: { if !AttachmentDrag.copy(attachment, fileURL: model.fileURL(attachment)) { model.problem = "The attachment could not be copied." } },
            preview: { preview(attachment) },
            reveal: attachment.url == nil ? { NSWorkspace.shared.activateFileViewerSelecting([model.fileURL(attachment)]) } : nil,
            save: attachment.isSavable ? {
                AttachmentDrag.presentSavePanel(for: attachment, fileURL: model.fileURL(attachment)) { model.problem = $0 }
            } : nil,
            showTranscript: attachment.voice == nil ? nil : { transcriptAttachmentID = attachment.id },
            forward: attachment.isForwardable ? { forwardAttachment?(attachment) } : nil)
    }

    private var authorAgent: AgentRecord? {
        if case .agent(let id) = message.author { model.agent(id) } else { nil }
    }

    /// Noodle's reaction badges, in the corner of the message.
    @ViewBuilder private var reactions: some View {
        if !(message.reactions ?? []).isEmpty {
            MessageReactionBadges(message: message, name: { author in
                switch author {
                case .user: "You"
                case .agent(let id): model.agent(id)?.displayName ?? "Agent"
                case .system: pionAppName
                }
            }, change: { model.changeReaction($0, to: $1, on: message) }, remove: { model.removeReaction($0, on: message) })
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Noodle's card for the first web page a message links to, unless that page is already attached.
    @ViewBuilder private var linkPreview: some View {
        if let url = MessageLinkPreviews.url(for: message, attachments: model.files(of: message)) {
            MessageLinkPreview(url: url, shouldLoad: true).frame(maxWidth: 420, alignment: .leading)
        }
    }

    /// The files sent with the message as Noodle shows them: pictures, cards and annotations, each opening
    /// in Quick Look, where it can be annotated.
    @ViewBuilder private var files: some View {
        let attached = model.files(of: message)
        if !attached.isEmpty {
            AttachmentGroup(attachments: attached, mode: ChatAttachmentLayout(rawValue: attachmentLayout) ?? .defaultValue, alignment: message.author == .user ? .trailing : .leading) { attachment in
                AttachmentInlinePreview(attachment: attachment, fileURL: model.fileURL(attachment), shouldLoad: true,
                                        isSelected: selectedAttachmentID == attachment.id,
                                        select: { selectedAttachmentID = attachment.id },
                                        preview: { preview(attachment) },
                                        showsTranscript: attachment.voice == nil ? nil
                                            : .showsTranscript(of: attachment.id, in: $transcriptAttachmentID))
                    // As in Noodle: dragged out as a copy of its file, and Noodle's menu for it.
                    .onDrag { AttachmentDrag.dragProvider(for: attachment, fileURL: model.fileURL(attachment)) { model.problem = $0 } }
                    .overlay { attachmentMenu(attachment) }
            }
        }
    }

    private var header: some View {
        let agent: AgentRecord? = if case .agent(let id) = message.author { model.agent(id) } else { nil }
        let role = agent?.publicDescription
        return HStack(spacing: 8) {
            if let agent {
                AgentProfileButton(model: model, agent: agent, size: 22, edit: { window.sheet = .editAgent(agent) },
                                   reply: window.reply(to: agent, in: model.conversation(message.conversationID), model: model))
            } else {
                AgentMark(agent: nil, size: 22)
            }
            Text(model.name(of: message.author)).font(.callout.weight(.semibold))
            if let agent, investigation != nil, agent.id == model.conversation(message.conversationID)?.lead {
                Text("Lead").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.4)))
            }
            if let role { Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Text(message.createdAt.pionShort).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }
}

/// Markdown as Noodle splits it: prose, code blocks and tables, each drawn for reading.
struct MessageBody: View {
    let text: String
    /// The message the text belongs to, so a selection in it can be annotated as in Noodle.
    var message: ChatMessage?
    /// An agent's message fills the column; the champion's hugs its text.
    var fills = true
    /// Says why a table could not be saved.
    var failed: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MessageBodyRenderer.shared.render(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let blocks): Prose(blocks: blocks, message: message)
                case .table(let table): MarkdownTable(table: table, failed: failed)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
    }
}

/// Prose with its code blocks set apart.
private struct Prose: View {
    let blocks: [MessageBodyRenderer.Block]
    let message: ChatMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(12)
                    }
                    .background(Color.secondary.opacity(0.09), in: .rect(cornerRadius: 10, style: .continuous))
                case .text(let text):
                    Text(text)
                        .font(.system(size: 14))
                        .lineSpacing(3.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .background { if let message { ConversationAnnotationText(message: message) } }
                }
            }
        }
    }
}

/// A table in Pion's reading style, sorted by a click on a column as Noodle sorts, with Noodle's Copy and Save as CSV.
private struct MarkdownTable: View {
    let table: MessageTable
    let failed: (String) -> Void
    @State private var sort: MessageTableSort?
    @State private var hovering = false

    var body: some View {
        // Rows keep their identity while sorting, or selectable cells would hold stale text.
        let order = table.rowOrder(by: sort)
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in header(column) }
                }
                Divider()
                ForEach(order, id: \.self) { row in
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in Text(table.rows[row][column]).font(.callout) }
                    }
                }
            }
            .padding(12)
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.secondary.opacity(0.2)))
        .overlay(alignment: .topTrailing) {
            if hovering { MessageTableActions(table: table.sorted(by: sort), failed: failed).padding(4) }
        }
        .onHover { hovering = $0 }
    }

    private func header(_ column: Int) -> some View {
        let active = sort?.column == column
        let name = MessageTable.plainText(table.header[column])
        return Button {
            withAnimation(.snappy(duration: 0.2)) { sort = MessageTableSort.next(after: sort, column: column) }
        } label: {
            HStack(spacing: 3) {
                Text(table.header[column]).font(.callout.weight(.semibold))
                // Always laid out, so a column keeps its width when it becomes the sorted one.
                Image(systemName: sort?.ascending == false ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(active ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(name)")
        .accessibilityLabel("Sort by \(name)")
        .accessibilityValue(active ? (sort?.ascending == true ? "Ascending" : "Descending") : "")
    }
}

/// A label as wide as the widest of its choices, so changing it never shifts what is beside it.
private struct WidestLabel: View {
    let title: String
    let symbol: String
    let choices: [(title: String, symbol: String)]

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(choices, id: \.title) { Label($0.title, systemImage: $0.symbol).hidden() }
            Label(title, systemImage: symbol)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// Noodle's questions before Kick and New Session, presented by the window that asked.
struct RecoveryConfirmations: ViewModifier {
    @Bindable var window: WindowState
    @Environment(PionSettingsHost.self) private var host

    func body(content: Content) -> some View {
        content
            .modifier(AgentKickConfirmation(store: host, request: $window.kickRequest))
            .modifier(NewSessionConfirmation(store: host, agent: $window.newSessionAgent))
    }
}
