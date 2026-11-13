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
                    .id(conversation.id)
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
    /// Where the reader was in each conversation, kept while Pion runs.
    @State private static var viewports: [UUID: TranscriptViewport] = [:]

    private var investigation: Investigation? { model.investigation(conversation.id) }

    var body: some View {
        let messages = model.messages(in: conversation.id)
        TranscriptScrollView(
            initialViewport: Self.viewports[conversation.id] ?? TranscriptViewport(),
            lastMessageID: messages.last?.id,
            lastMessageIsFromUser: messages.last?.author == .user,
            bottomOverlayHeight: composerHeight,
            saveViewport: { Self.viewports[conversation.id] = $0 },
            onInteraction: { model.markRead(conversation.id) },
            containsMessage: { id in messages.contains { $0.id == id } },
            onBackgroundTap: { window.composerFocusRequest = UUID() }
        ) {
            ConversationStart(model: model, conversation: conversation, investigation: investigation)
                .id(TranscriptScrollTarget.start)
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                let previous = index > 0 ? messages[index - 1] : nil
                MessageRow(model: model, conversation: conversation, investigation: investigation, message: message,
                           continues: previous.map { $0.author == message.author && message.createdAt.timeIntervalSince($0.createdAt) < 600 } ?? false)
                    .id(message.id)
            }
        }
        // Noodle's shade: messages fade as they pass under the toolbar, and only once there is something under it.
        .conversationTopFade()
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .bottom) {
            Composer(model: model, window: window, conversation: conversation, investigation: investigation)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .navigationTitle(investigation?.reference ?? conversation.displayName)
        .navigationSubtitle(investigation?.title ?? subtitle)
        .toolbar { toolbar }
        .inspector(isPresented: Binding(get: { window.showsInspector && investigation != nil }, set: { window.showsInspector = $0 })) {
            if let investigation {
                CaseInspector(model: model, window: window, investigation: investigation)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            }
        }
    }

    private var subtitle: String {
        conversation.kind == .group ? model.members(of: conversation).map(\.displayName).formatted(.list(type: .and))
            : model.agent(conversation.participantIDs.first)?.publicDescription ?? ""
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
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
        if conversation.kind == .group {
            ToolbarItem {
                Button { window.sheet = .members(conversation) } label: { Label("Members", systemImage: "person.2") }
                    .help("Add or remove agents")
                    .disabled(investigation?.isClosed == true)
            }
        }
        if investigation != nil {
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
                    AgentMark(agent: agent, size: 40)
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
                            AgentMark(agent: agent, size: 16, phase: model.phase(of: agent))
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
        .padding(.top, 28)
    }
}

/// One message. An agent's fills the reading column with its name above, as an assistant's answer in
/// ChatGPT; the champion's sits on the right in a quiet box. Nothing is folded away.
struct MessageRow: View {
    static let column: CGFloat = 780

    let model: PionModel
    let conversation: BotConversation
    let investigation: Investigation?
    let message: ChatMessage
    let continues: Bool
    @State private var hovering = false

    var body: some View {
        Group {
            if message.author == .user {
                HStack {
                    Spacer(minLength: 120)
                    VStack(alignment: .trailing, spacing: 4) {
                        MessageBody(text: message.body, fills: false)
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
                    MessageBody(text: message.body)
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
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.body, forType: .string)
            }
        }
    }

    /// The files sent with the message, each opening in its own app.
    @ViewBuilder private var files: some View {
        let attached = message.attachments.compactMap { model.attachment($0, in: conversation.id) }
        if !attached.isEmpty {
            HStack(spacing: 6) {
                ForEach(attached) { file in
                    Button { NSWorkspace.shared.open(model.repository.attachmentFileURL(file)) } label: {
                        Label(file.originalFilename, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
                    .help("Open \(file.originalFilename)")
                }
            }
        }
    }

    private var header: some View {
        let agent: AgentRecord? = if case .agent(let id) = message.author { model.agent(id) } else { nil }
        let role = agent?.publicDescription
        return HStack(spacing: 8) {
            AgentMark(agent: agent, size: 22)
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
    /// An agent's message fills the column; the champion's hugs its text.
    var fills = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MessageBodyRenderer.shared.render(text).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let blocks): Prose(blocks: blocks)
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
