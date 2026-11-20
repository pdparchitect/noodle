import HubLink
import NoodleCore
import NoodleRuntimeSettings
import NoodleWallpaper
import RookCore
import SwiftUI
import NoodleSettingsUI

/// A second conversation keeps its selection, sheets and case record independent of the main window.
struct ConversationWindow: View {
    let model: RookModel
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
                    Button { RookWindows.returnToMainWindow(selection, model: model) } label: {
                        Label("Show in Main Window", systemImage: "pip.exit")
                    }
                    .help("Show in Main Window")
                }
            }
        }
        // Noodle's window registry: what this window shows is read while it is on screen, and the window opens again.
        .background {
            if let registry = RookWindows.conversations {
                ConversationWindowHost(registry: registry, conversationID: selection) { if let id = $0 { model.markRead(id) } }
            }
        }
        .modifier(ConversationSheets(model: model, window: window, selection: $selection))
        .modifier(RecoveryConfirmations(window: window))
        // As in Noodle, a conversation deleted elsewhere takes its window with it.
        .onChange(of: selection.map { model.conversation($0) == nil } == true) { _, missing in
            guard missing, let selection else { return }
            if panel != nil { RookWindows.panels?.close(selection) } else { dismiss() }
        }
        // A window of its own has no sidebar to search, so Search Conversations is the main window's alone.
        .focusedSceneValue(\.rookConversation, ConversationCommandContext(selection: $selection, window: window, search: nil))
        .onChange(of: selection, initial: true) { _, id in
            if let id { model.markRead(id) }
            window.composerFocusRequest = UUID()
        }
    }
}

/// One conversation as a document: a header, the messages in a reading column, and the composer.
/// A Mission also has its case record in a panel beside it.
struct ConversationView: View {
    let model: RookModel
    @Bindable var window: WindowState
    let conversation: BotConversation
    /// The main window presents the graph itself; floating conversations present their own sheet.
    var presentsGraphSheet = true
    @State private var graphContainerSize = CGSize(width: 1000, height: 760)
    @Environment(RookCalls.self) private var calls
    @Environment(RookSettingsHost.self) private var host
    @Environment(\.openSettings) private var openSettings
    @State private var composerHeight: CGFloat = 0
    // Noodle's previews, capture and annotation, one of each per conversation shown.
    @State private var attachmentPreview = AttachmentPreviewController()
    @State private var screenCapturePreview = ScreenCapturePreviewController()
    @State private var conversationAnnotations = ConversationAnnotationController()
    @State private var pickers = AttachmentPickers()
    @State private var selectedAttachmentID: UUID?
    /// The file Forward… was chosen for, held here rather than by its message.
    @State private var forwarding: ConversationAttachment?

    private var mission: Mission? { model.mission(conversation.id) }

    var body: some View {
        HStack(spacing: 0) {
            // Noodle's dissolve: the transcript alone is rebuilt for another conversation, so the toolbar,
            // composer and case record stay put and the composer keeps the keyboard.
            ConversationTransition(conversationID: conversation.id) {
                transcript
                    // Noodle's shade: messages fade as they pass under the toolbar, and only once there is something under it.
                    .conversationTopFade()
            }
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .bottom) {
                Composer(model: model, window: window, conversation: conversation, mission: mission,
                         actions: ComposerActions(attachFile: { pickers.attachFile(to: conversation.id) },
                                                  choosePhoto: { pickers.choosePhoto(for: conversation.id) },
                                                  capture: showCapture,
                                                  preview: { showPreview($0) }))
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
            // Hidden for an agent or group without forgetting it was open, so it is back on returning to a Mission.
            if window.showsInspector, let mission {
                // Its own for each Mission, so evidence opened in one never shows open in another.
                CasePanel(model: model, window: window, mission: mission)
                    .id(mission.id)
                    .transition(.move(edge: .trailing))
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { graphContainerSize = $0 }
        .sheet(isPresented: Binding(get: { presentsGraphSheet && window.showsGraph }, set: { window.showsGraph = $0 })) {
            if let mission {
                let size = MissionGraphView.sheetSize(in: graphContainerSize)
                MissionGraphView(model: model, mission: mission) { window.showsGraph = false }
                    .frame(width: size.width, height: size.height)
                    .presentationBackground(.ultraThinMaterial)
                    .noodleSheetSizing()
            }
        }
        .animation(.snappy(duration: 0.25), value: window.showsInspector)
        // Leaving the Mission closes the graph, so it never lingers over another conversation.
        .onChange(of: conversation.id) { window.showsGraph = false }
        // As in Noodle: files dropped anywhere on the conversation wait in its message field.
        .conversationFileDrop(isEnabled: { mission?.isClosed != true }) { model.attachDropped($0, to: conversation.id) }
        // As in Noodle: a picture or file pasted with the message field out of focus waits there too.
        .onPasteCommand(of: AttachmentTransfer.pasteContentTypes) { providers in
            guard mission?.isClosed != true else { return }
            model.attachDropped(providers, to: conversation.id, context: .paste)
        }
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
            title: mission?.reference ?? conversation.displayName,
            save: { note, content, source, raw in
                try model.saveConversationAnnotation(note, content: content, source: source, sourceData: raw)
            }, focusComposer: { window.composerFocusRequest = UUID() }).frame(width: 0, height: 0))
        .background(CaptureShortcut(capture: showCapture).frame(width: 0, height: 0))
        .attachmentPickers($pickers, importFiles: { model.attach($0, to: $1) },
                           importPhoto: { try model.importPhoto(data: $0, into: $1) }, report: { model.problem = $0 })
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
        .navigationTitle(mission?.reference ?? conversation.displayName)
        .navigationSubtitle(mission?.title ?? subtitle)
        .toolbar { toolbar }
        .onChange(of: conversation.id) { _, _ in
            attachmentPreview.close()
            screenCapturePreview.close()
            conversationAnnotations.cancel()
            selectedAttachmentID = nil
        }
    }

    private var transcript: some View {
        Transcript(model: model, window: window, conversation: conversation, mission: mission,
                   initialViewport: model.transcriptViewport(for: conversation.id), bottomOverlayHeight: composerHeight,
                   selectedAttachmentID: $selectedAttachmentID, saveViewport: { model.saveTranscriptViewport($0, for: conversation.id) },
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
        if mission?.isClosed != true {
            ToolbarItem {
                Button { window.edit(conversation, in: model) } label: { Label("Edit…", systemImage: "pencil") }
                    .help(mission != nil ? "Edit Mission…" : conversation.kind == .group ? "Edit Group…" : "Edit Agent…")
                    .accessibilityLabel(mission != nil ? "Edit Mission…" : conversation.kind == .group ? "Edit Group…" : "Edit Agent…")
            }
        }
        if let mission {
            ToolbarItem {
                Menu {
                    ForEach([Mission.Status.open, .active, .proven], id: \.self) { status in
                        Button { model.setStatus(status, of: mission) } label: { Label(status.title, systemImage: status.symbol) }
                            .disabled(mission.isClosed || mission.status == status)
                    }
                    Divider()
                    // Shown, not chosen: only the lead agent sets it, through the case tool.
                    Text("Severity: \(mission.severityTitle), set by the lead agent")
                    Divider()
                    if mission.isClosed {
                        Button("Reopen") { model.setStatus(.open, of: mission) }
                    } else {
                        Button("Close Mission…") { window.sheet = .close(mission) }
                            .appShortcut(RookShortcuts.closeMission)
                    }
                } label: {
                    WidestLabel(title: mission.outcome?.title ?? mission.status.title, symbol: mission.status.symbol,
                                choices: [Mission.Status.open, .active, .proven].map { ($0.title, $0.symbol) }
                                    + Mission.Outcome.allCases.map { ($0.title, Mission.Status.closed.symbol) })
                }
                .help("Status")
            }
        }
        if let mission {
            ToolbarItem {
                Menu {
                    Button("Export as Zip…") { model.exportMission(mission) }
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
                Button { window.showsGraph.toggle() } label: { Label("Graph", systemImage: "point.3.connected.trianglepath.dotted") }
                    .help("Show the Mission's attack graph")
            }
            ToolbarItem {
                Button { window.showsInspector.toggle() } label: { Label("Case", systemImage: "sidebar.trailing") }
                    .help(KeyboardBindings.shared.help("Show or hide the case record", for: RookShortcuts.showInspector))
            }
        }
    }
}

/// The case record beside a Mission, at the width it was last left at, here and on the next launch. Rook's
/// own panel rather than SwiftUI's inspector, whose column, even hidden, laid the whole window out a second time at every
/// step of a resize. Its edge is dragged to resize it, as an inspector's is.
private struct CasePanel: View {
    let model: RookModel
    @Bindable var window: WindowState
    let mission: Mission
    @Environment(\.colorScheme) private var colorScheme
    @State private var width = CasePanel.storedWidth
    @State private var dragStart: CGFloat?

    static let widthKey = "RookInspectorWidth"
    static let widths: ClosedRange<CGFloat> = 300...520
    private static var storedWidth: CGFloat {
        (UserDefaults.standard.object(forKey: widthKey) as? Double).map { CGFloat($0) }.map { min(max($0, widths.lowerBound), widths.upperBound) } ?? 360
    }

    var body: some View {
        CaseInspector(model: model, window: window, mission: mission)
            .frame(width: width)
            // Set apart from the conversation as the sidebar is: the window's backdrop a little darker, to the top.
            .background(Color.black.opacity(colorScheme == .dark ? 0.24 : 0.04).ignoresSafeArea())
            .overlay(alignment: .leading) { resizeEdge }
    }

    /// A strip along the panel's edge, wider than it looks, that drags it wider or narrower. The width is kept once
    /// the drag ends, not at every step.
    private var resizeEdge: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .offset(x: -4)
            .pointerStyle(.columnResize)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? width
                    dragStart = start
                    width = min(max(start - drag.translation.width, Self.widths.lowerBound), Self.widths.upperBound)
                }
                .onEnded { _ in
                    dragStart = nil
                    UserDefaults.standard.set(Double(width), forKey: Self.widthKey)
                })
            .accessibilityHidden(true)
    }
}

/// What a conversation is about, above its first message.
/// The messages of a conversation, Noodle's way: a page at a time from the newest, calls placed among them.
private struct Transcript: View {
    let model: RookModel
    let window: WindowState
    let conversation: BotConversation
    let mission: Mission?
    let initialViewport: TranscriptViewport
    let bottomOverlayHeight: CGFloat
    @Binding var selectedAttachmentID: UUID?
    let saveViewport: (TranscriptViewport) -> Void
    let preview: (ConversationAttachment, [ConversationAttachment]) -> Void
    @Environment(RookCalls.self) private var calls
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
                ConversationStart(model: model, window: window, conversation: conversation, mission: mission)
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
                        MessageRow(model: model, window: window, conversation: conversation, mission: mission, message: message,
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
    let model: RookModel
    let window: WindowState
    let conversation: BotConversation
    let mission: Mission?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let mission {
                HStack(spacing: 8) {
                    Text(mission.reference).font(.callout.monospaced()).foregroundStyle(.secondary)
                    Tag(text: mission.outcome?.title ?? mission.status.title,
                        color: mission.isClosed ? .secondary : mission.status.color, symbol: mission.status.symbol)
                    Tag(text: mission.severityTitle, color: mission.severityColor)
                }
                Text(mission.title).font(.title2.weight(.semibold))
                if !mission.objective.isEmpty {
                    Text(mission.objective).font(.body).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Label(mission.champion, systemImage: "person.crop.circle").help("Champion")
                    if let lead = model.agent(model.conversation(mission.id)?.lead) { Label("\(lead.displayName) leads", systemImage: "star") }
                    if let source = mission.source { Label(source, systemImage: "bell").lineLimit(1) }
                    Label("Opened \(mission.openedAt.rookShort)", systemImage: "clock")
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
        // The transcript runs under the toolbar; at rest its heading lines up with the sidebar's first section and the case record's divider.
        .padding(.top, 20)
    }
}

/// One message. An agent's fills the reading column with its name above, as an assistant's answer in
/// ChatGPT; the champion's sits on the right in a quiet box. Nothing is folded away.
struct MessageRow: View {
    /// The reading column, the composer's width with it: about 85 characters of the transcript's text to a line, as
    /// long as reads comfortably.
    static let column: CGFloat = 650

    let model: RookModel
    let window: WindowState
    let conversation: BotConversation
    let mission: Mission?
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
                VStack(alignment: .trailing, spacing: 4) {
                    if message.task != nil || showsText || hasLinkPreview {
                        HStack {
                            Spacer(minLength: 120)
                            VStack(alignment: .trailing, spacing: 4) {
                                // Written from a task in the sidebar.
                                if let task = message.task { MessageTaskLabel(task: task) }
                                if showsText {
                                    MessageBody(text: message.body, message: message, fills: false) { model.problem = $0 }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .background(Color.secondary.opacity(0.11), in: .rect(cornerRadius: 18, style: .continuous))
                                        .overlay(alignment: .topTrailing) { reactions.offset(x: 5, y: -12) }
                                }
                                linkPreview
                            }
                        }
                    }
                    // The whole column, not the text's indented share of it, so two cards fit side by side.
                    filesWithReactions
                    HStack(spacing: 6) {
                        // Always laid out, only shown on hover, so pointing at a message never moves the others.
                        Text(message.createdAt.rookShort).font(.caption2).foregroundStyle(.tertiary)
                            .opacity(hovering ? 1 : 0)
                        // As Noodle's: whether it reached the conversation, and whether an agent got it.
                        MessageDeliveryLabel(delivery: message.delivery)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 10)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if !continues { header }
                    if showsText {
                        MessageBody(text: message.body, message: message) { model.problem = $0 }
                            .padding(.leading, 30)
                            .overlay(alignment: .topTrailing) { reactions.offset(x: 5, y: -12) }
                    }
                    linkPreview.padding(.leading, 30)
                    filesWithReactions.padding(.leading, 30)
                }
                .padding(.top, continues ? 2 : 14)
            }
        }
        .frame(maxWidth: Self.column)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Noodle's message menu: react, copy, then Rook's own items for the agent who wrote it.
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
                case .system: rookAppName
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

    private var hasLinkPreview: Bool { MessageLinkPreviews.url(for: message, attachments: model.files(of: message)) != nil }

    /// As in Noodle: a voice message with nothing but its recordings shows no text of its own.
    private var showsText: Bool { VoiceMessage.showsText(message.body, with: model.files(of: message)) }

    /// Reactions mark the text, and the files only when there is no text to mark.
    private var filesWithReactions: some View {
        files.overlay(alignment: .topTrailing) { if !showsText { reactions.offset(x: 5, y: -12) } }
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
            if let agent, mission != nil, agent.id == model.conversation(message.conversationID)?.lead {
                Text("Lead").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.4)))
            }
            if let role { Text(role).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Text(message.createdAt.rookShort).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
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
                case .prose(let blocks): MessageBlocksView(blocks: blocks, message: message)
                case .table(let table): MarkdownTable(table: table, failed: failed)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: fills ? .infinity : nil, alignment: .leading)
    }
}


/// A table in Rook's reading style, sorted by a click on a column as Noodle sorts, with Noodle's Copy and Save as CSV.
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
    @Environment(RookSettingsHost.self) private var host

    func body(content: Content) -> some View {
        content
            .modifier(AgentKickConfirmation(store: host, request: $window.kickRequest))
            .modifier(NewSessionConfirmation(store: host, agent: $window.newSessionAgent))
    }
}
