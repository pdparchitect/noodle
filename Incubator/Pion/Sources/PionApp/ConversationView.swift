import PhotosUI
import HubLink
import NoodleCore
import NoodleWallpaper
import PionCore
import SwiftUI

/// A second conversation keeps its selection, sheets and inspector independent of the main window.
struct ConversationWindow: View {
    let model: PionModel
    @Binding var selection: UUID?
    @State private var window = WindowState()

    var body: some View {
        Group {
            if let conversation = model.conversation(selection) {
                ConversationView(model: model, window: window, conversation: conversation)
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .modifier(ConversationSheets(model: model, window: window, selection: $selection))
        .focusedSceneValue(\.pionConversation, ConversationCommandContext(selection: $selection, window: window,
            search: { window.sheet = .chooseConversation }))
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
    @State private var composerHeight: CGFloat = 0
    // Noodle's previews, capture and annotation, one of each per conversation shown.
    @State private var attachmentPreview = AttachmentPreviewController()
    @State private var screenCapturePreview = ScreenCapturePreviewController()
    @State private var conversationAnnotations = ConversationAnnotationController()
    @State private var choosingFiles = false
    @State private var choosingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var selectedAttachmentID: UUID?
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
        .environment(\.conversationAnnotations, conversationAnnotations)
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
        .inspector(isPresented: Binding(get: { window.showsInspector && investigation != nil }, set: { window.showsInspector = $0 })) {
            if let investigation {
                // Its own for each Investigation, so a scope being edited or evidence opened never carries over.
                CaseInspector(model: model, window: window, investigation: investigation)
                    .id(investigation.id)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
                    .background { Backdrop(frosted: true).ignoresSafeArea() }
            }
        }
        .onChange(of: conversation.id) { _, _ in
            attachmentPreview.close()
            screenCapturePreview.close()
            conversationAnnotations.cancel()
            selectedAttachmentID = nil
        }
    }

    private var transcript: some View {
        let messages = model.messages(in: conversation.id)
        return TranscriptScrollView(
            initialViewport: Self.viewports[conversation.id] ?? TranscriptViewport(),
            lastMessageID: messages.last?.id,
            lastMessageIsFromUser: messages.last?.author == .user,
            bottomOverlayHeight: composerHeight,
            saveViewport: { Self.viewports[conversation.id] = $0 },
            onInteraction: { model.markRead(conversation.id) },
            containsMessage: { id in messages.contains { $0.id == id } },
            onBackgroundTap: { window.composerFocusRequest = UUID() }
        ) {
            ConversationStart(model: model, window: window, conversation: conversation, investigation: investigation)
                .id(TranscriptScrollTarget.start)
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                let previous = index > 0 ? messages[index - 1] : nil
                MessageRow(model: model, window: window, conversation: conversation, investigation: investigation, message: message,
                           selectedAttachmentID: $selectedAttachmentID, preview: { showPreview($0, among: model.files(of: message)) },
                           continues: previous.map { $0.author == message.author && message.createdAt.timeIntervalSince($0.createdAt) < 600 } ?? false)
                    .id(message.id)
            }
        }
        .id(conversation.id)
        .transaction { $0.animation = nil }
    }

    private func showCapture() {
        if screenCapturePreview.focusIfOpen() { return }
        guard let host = attachmentPreview.resolveHostWindow() else { return }
        let destination = conversation.id
        attachmentPreview.close()
        screenCapturePreview.show(kind: .window, relativeTo: host) { image, title, region, comment in
            try model.importCapture(image: image, title: title, region: region, comment: comment, into: destination)
        }
    }

    /// Opens a file in Noodle's Quick Look, paging through the message's other files, where it can be annotated.
    private func showPreview(_ attachment: ConversationAttachment, among group: [ConversationAttachment] = []) {
        selectedAttachmentID = attachment.id
        if let link = attachment.url, MessageLink.webURL(from: link, preservingFragment: true) != nil, !WebLinkPreview.opensInPreview() {
            attachmentPreview.close()
            NSWorkspace.shared.open(link)
            return
        }
        if attachment.url == nil, attachment.annotation == nil, QuickLookBypass.isHeld() {
            attachmentPreview.close()
            NSWorkspace.shared.open(model.fileURL(attachment))
            return
        }
        screenCapturePreview.close()
        let edit: ((ConversationAttachment, String) throws -> ConversationAttachment)? = model.canEditAnnotation(attachment)
            ? { attachment, comment in try model.reviseAnnotationComment(attachment, comment: comment) } : nil
        let gallery = ConversationAttachment.previewGallery(opening: attachment, among: group).items
        attachmentPreview.show(attachment, url: model.fileURL(attachment), gallery: gallery.map { ($0, model.fileURL($0)) },
                               edit: edit, canEdit: { model.canEditAnnotation($0) }) { note, content, source in
            try model.saveAnnotation(note, content: content, source: source)
        }
    }

    private var subtitle: String {
        conversation.kind == .group ? model.members(of: conversation).map(\.displayName).formatted(.list(type: .and))
            : model.agent(conversation.participantIDs.first)?.publicDescription ?? ""
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
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
                    if investigation.isClosed {
                        Button("Reopen") { model.setStatus(.open, of: investigation) }
                    } else {
                        Button("Close Investigation…") { window.sheet = .close(investigation) }
                            .keyboardShortcut("k", modifiers: [.command, .shift])
                    }
                } label: {
                    Label(investigation.outcome?.title ?? investigation.status.title, systemImage: investigation.status.symbol)
                        .labelStyle(.titleAndIcon)
                }
                .help("Status")
            }
            ToolbarItem {
                Menu {
                    ForEach(Investigation.Severity.allCases.reversed(), id: \.self) { severity in
                        Button(severity.title) { model.setSeverity(severity, of: investigation) }
                    }
                } label: {
                    Label(investigation.severity.title, systemImage: "exclamationmark.triangle").labelStyle(.titleAndIcon)
                }
                .disabled(investigation.isClosed)
                .help("Severity")
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
                    .help("Show or hide the case record (⌥⌘I)")
            }
        }
    }
}

/// What a conversation is about, above its first message.
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
                    Tag(text: investigation.severity.title, color: investigation.severity.color)
                }
                Text(investigation.title).font(.title2.weight(.semibold))
                if !investigation.objective.isEmpty {
                    Text(investigation.objective).font(.body).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Label(investigation.champion, systemImage: "person.crop.circle").help("Champion")
                    if let lead = model.agent(investigation.leadAgentID) { Label("\(lead.displayName) leads", systemImage: "star") }
                    if let source = investigation.source { Label(source, systemImage: "bell").lineLimit(1) }
                    Label("Opened \(investigation.openedAt.pionShort)", systemImage: "clock")
                }
                .font(.callout).foregroundStyle(.secondary)
            } else if conversation.kind == .group {
                Text(conversation.displayName).font(.title2.weight(.semibold))
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
                        HStack(spacing: 4) {
                            AgentProfileButton(model: model, agent: agent, size: 16, phase: model.phase(of: agent)) { window.sheet = .editAgent(agent) }
                            Text(agent.displayName).font(.caption)
                        }
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
        // The transcript runs under the toolbar; at rest its heading starts clear of it.
        .padding(.top, 76)
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

    var body: some View {
        Group {
            if message.author == .user {
                HStack {
                    Spacer(minLength: 120)
                    VStack(alignment: .trailing, spacing: 4) {
                        MessageBody(text: message.body, message: message, fills: false)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.secondary.opacity(0.11), in: .rect(cornerRadius: 18, style: .continuous))
                        files
                        // Always laid out, only shown on hover, so pointing at a message never moves the others.
                        Text(message.createdAt.pionShort).font(.caption2).foregroundStyle(.tertiary)
                            .opacity(hovering ? 1 : 0)
                    }
                }
                .padding(.top, 10)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if !continues { header }
                    MessageBody(text: message.body, message: message)
                        .padding(.leading, 30)
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
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copyText(message.body) }
            if let agent = authorAgent {
                Divider()
                Button("Show Activity", systemImage: "list.bullet.rectangle") { model.showActivity(for: agent) }
                Button("Edit Agent…", systemImage: "pencil") { window.sheet = .editAgent(agent) }
            }
        }
    }

    private var authorAgent: AgentRecord? {
        if case .agent(let id) = message.author { model.agent(id) } else { nil }
    }

    /// The files sent with the message as Noodle shows them: pictures, cards and annotations, each opening
    /// in Quick Look, where it can be annotated.
    @ViewBuilder private var files: some View {
        let attached = model.files(of: message)
        if !attached.isEmpty {
            AttachmentGroup(attachments: attached, mode: .wrap, alignment: message.author == .user ? .trailing : .leading) { attachment in
                AttachmentInlinePreview(attachment: attachment, fileURL: model.fileURL(attachment), shouldLoad: true,
                                        isSelected: selectedAttachmentID == attachment.id,
                                        select: { selectedAttachmentID = attachment.id },
                                        preview: { preview(attachment) })
                    .contextMenu { AttachmentMenu(model: model, attachment: attachment) { preview(attachment) } }
            }
        }
    }

    private var header: some View {
        let agent: AgentRecord? = if case .agent(let id) = message.author { model.agent(id) } else { nil }
        let role = agent?.publicDescription
        return HStack(spacing: 8) {
            if let agent {
                AgentProfileButton(model: model, agent: agent, size: 22) { window.sheet = .editAgent(agent) }
            } else {
                AgentMark(agent: nil, size: 22)
            }
            Text(model.name(of: message.author)).font(.callout.weight(.semibold))
            if let agent, agent.id == investigation?.leadAgentID {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MessageBodyRenderer.shared.render(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let blocks): Prose(blocks: blocks, message: message)
                case .table(let table): MarkdownTable(table: table)
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

private struct MarkdownTable: View {
    let table: MessageTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                        Text(cell).font(.callout.weight(.semibold))
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(cell).font(.callout) }
                    }
                }
            }
            .padding(12)
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.secondary.opacity(0.2)))
    }
}
