import AppKit
import SwiftUI
import HubLink
import NoodleCore
import NoodleRuntimeSettings
import NoodleSettingsUI

/// What the Tasks section needs from the app whose bots keep tasks.
@MainActor protocol AgentTaskHost: AnyObject {
    func openTasks(waitingOnMeOnly: Bool) -> [(agent: AgentRecord, task: AgentTask)]
    func taskAgentName(_ id: UUID) -> String?
    /// The bot's picture, 22 points across.
    func taskAvatar(_ agent: AgentRecord) -> AnyView
    func openConversation(for task: AgentTask, of agentID: UUID)
    func sendFeedback(_ text: String, on task: AgentTask, of agentID: UUID) throws
    func reportTaskError(_ message: String)
}

/// The sidebar's Tasks section: a few tasks, then a link to the rest. Clicking a task opens a
/// popover for writing to its bot about it, never a control that changes the task.
struct SidebarTasks: View {
    let store: any AgentTaskHost
    let filter: TaskListFilter
    /// In a list, a collapsible section; in the icon grid, plain rows under a title.
    let inList: Bool
    @State private var isExpanded = true
    @State private var showsAll = false

    private static let collapsedCount = 5

    var body: some View {
        let tasks = store.openTasks(waitingOnMeOnly: filter == .waitingOnMe)
        if filter != .hidden, !tasks.isEmpty {
            let shown = showsAll ? tasks : Array(tasks.prefix(Self.collapsedCount))
            if inList {
                Section(isExpanded: $isExpanded) {
                    rows(shown, total: tasks.count)
                } header: {
                    Text("Tasks")
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tasks")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    rows(shown, total: tasks.count)
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ shown: [(agent: AgentRecord, task: AgentTask)], total: Int) -> some View {
        ForEach(shown, id: \.task.id) { entry in
            TaskRow(store: store, agent: entry.agent, task: entry.task)
                .selectionDisabled()
                .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 10))
        }
        if total > Self.collapsedCount {
            Button(showsAll ? "Show Fewer" : "Show All \(total)") { showsAll.toggle() }
                .buttonStyle(.accentLink)
                .selectionDisabled()
        }
    }
}

private struct TaskRow: View {
    let store: any AgentTaskHost
    let agent: AgentRecord
    let task: AgentTask
    @State private var isPresented = false

    var body: some View {
        HStack(spacing: 8) {
            store.taskAvatar(agent)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .lineLimit(1)
                Text("\(agent.displayName) · \(TaskState.line(for: task, store: store))")
                    .font(.caption)
                    .foregroundStyle(task.waitingOn == .user ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(SidebarTimestamp.text(for: task.updatedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { isPresented = true }
        .help(task.note ?? task.title)
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            TaskFeedbackPopover(store: store, agent: agent, task: task) { isPresented = false }
        }
    }
}

/// Writing to a bot about one of its tasks. The words go to the task's conversation, carrying the
/// task, and the bot moves the task on.
private struct TaskFeedbackPopover: View {
    let store: any AgentTaskHost
    let agent: AgentRecord
    let task: AgentTask
    let dismiss: () -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(agent.displayName)
                    .foregroundStyle(.secondary)
            }
            Label(TaskState.line(for: task, store: store), systemImage: TaskState.symbol(for: task))
                .foregroundStyle(task.waitingOn == .user ? Color.accentColor : .secondary)
            if let note = task.note {
                Text(note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Message \(agent.displayName)", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
            HStack {
                Button("Open Conversation") {
                    store.openConversation(for: task, of: agent.id)
                    dismiss()
                }
                .buttonStyle(.accentLink)
                Spacer()
                Button("Send") {
                    do {
                        try store.sendFeedback(text, on: task, of: agent.id)
                        dismiss()
                    } catch {
                        store.reportTaskError(error.localizedDescription)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }
}

@MainActor
enum TaskState {
    static func line(for task: AgentTask, store: any AgentTaskHost) -> String {
        switch task.state {
        case .open: return "In progress"
        case .done: return "Done"
        case .dropped: return "Dropped"
        case .waiting:
            switch task.waitingOn {
            case .user: return "Waiting on you"
            case .agent(let id): return "Waiting on \(store.taskAgentName(id) ?? "a bot")"
            case .system, nil: return "Waiting"
            }
        }
    }

    static func symbol(for task: AgentTask) -> String {
        switch task.state {
        case .open: "circle.fill"
        case .waiting: "circle.lefthalf.filled"
        case .done: "checkmark.circle"
        case .dropped: "xmark.circle"
        }
    }
}

/// Time for today, day and month for this year, and the year only when it differs.
enum SidebarTimestamp {
    static func text(
        for date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(style.hour().minute())
        }
        style = style.day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }
}

/// The tool connections at the foot of the sidebar, as icons, when View › Sidebar › Show Tools is on: a red dot marks
/// one waiting on the person to sign in or look at a failure. Clicking one shows where it stands and what to do,
/// in a bubble, leaving the conversation open.
struct SidebarTools: View {
    static let key = "sidebarShowsTools"
    let controller: ToolConnectionsController
    /// In a list, a section; in the icon grid, icons under a title.
    let inList: Bool
    @State private var editing: ToolConnection?

    var body: some View {
        if !controller.registry.connections.isEmpty {
            if inList {
                Section {
                    // One row for the whole grid; each icon is a button of its own.
                    grid.selectionDisabled()
                } header: {
                    Text("Tools")
                }
            } else {
                Text("Tools")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                grid
            }
        }
    }

    private var grid: some View {
        ConversationIconGrid(minimumWidth: 56) {
            ForEach(controller.registry.connections) { connection in
                ToolTile(controller: controller, connection: connection, edit: { editing = $0 })
            }
        }
        .padding(.vertical, 4)
        .sheet(item: $editing) { ToolConnectionEditor(controller: controller, existing: $0).noodleSheetSizing() }
    }
}

/// View › Sidebar › Show Tools.
struct SidebarToolsToggle: View {
    @AppStorage(SidebarTools.key) private var showsTools = false

    var body: some View { Toggle("Show Tools", isOn: $showsTools) }
}

/// A tool connection's icon and name, marked when it needs the person, opening its bubble when clicked.
private struct ToolTile: View {
    let controller: ToolConnectionsController
    let connection: ToolConnection
    let edit: (ToolConnection) -> Void
    @State private var shown = false

    var body: some View {
        let status = controller.status(of: connection)
        Button { shown.toggle() } label: {
            VStack(spacing: 3) {
                ToolConnectionIcon(connection: connection, size: 30)
                    // In grey, as the agents' marks around it are, so the red dot of one that needs you is what stands out.
                    .grayscale(1)
                    .opacity(status == .managed ? 0.4 : 1)
                    .overlay(alignment: .topTrailing) {
                        if status.needsAttention {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                                .padding(1.5)
                                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                                .offset(x: 4, y: -4)
                        } else if case .signingIn = status {
                            ProgressView().controlSize(.mini).offset(x: 5, y: -5)
                        }
                    }
                Text(connection.name)
                    .font(.system(size: 10))
                    .foregroundStyle(status.needsAttention ? Color.primary : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(connection.name)
        .accessibilityLabel(connection.name)
        .accessibilityValue(status.needsAttention ? "Needs attention" : "")
        .popover(isPresented: $shown, arrowEdge: .trailing) {
            ToolBubble(controller: controller, connection: connection, status: status,
                       edit: { shown = false; edit(connection) }, close: { shown = false })
        }
    }
}

/// Where a tool connection stands and what can be done about it, as Settings › Tools offers.
private struct ToolBubble: View {
    let controller: ToolConnectionsController
    let connection: ToolConnection
    let status: ToolConnectionStatus
    let edit: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ToolConnectionIcon(connection: connection, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.name).font(.headline).lineLimit(2)
                    ToolConnectionStatusLabel(status: status)
                }
            }
            if case .failed(let reason) = status {
                Text(reason).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if case .signingIn(let stage) = status, !stage.isEmpty {
                Text(stage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if status != .managed {
                HStack(spacing: 8) {
                    if case .signingIn = status {
                        Button("Cancel") { controller.cancelSignIn() }
                    } else if connection.keepsSecret, connection.awsIdentityCenter == nil {
                        // A token or client secret is entered in the editor, as in Settings › Tools.
                        let what = connection.usesToken ? "Token" : "Credentials"
                        Button(controller.isConnected(connection) ? "Change \(what)…" : "Enter \(what)…", action: edit)
                            .keyboardShortcut(status.needsAttention ? .defaultAction : nil)
                            .disabled(controller.isSigningIn)
                    } else {
                        Button(controller.isConnected(connection) ? "Reconnect" : "Connect") { controller.connect(connection); close() }
                            .keyboardShortcut(status.needsAttention ? .defaultAction : nil)
                            .disabled(controller.isSigningIn)
                    }
                    Button("Edit…", action: edit)
                    Spacer(minLength: 0)
                    if controller.isConnected(connection) {
                        Button("Sign Out", role: .destructive) { controller.signOut(connection); close() }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

/// View › Sidebar's line under each name, the order and which tasks it lists, as one block of inline pickers.
struct SidebarListPickers: View {
    @AppStorage(ConversationRowDetail.key) private var detail = ConversationRowDetail.standard.rawValue
    @AppStorage(ConversationOrder.key) private var order = ConversationOrder.standard.rawValue
    @AppStorage(TaskListFilter.key) private var tasks = TaskListFilter.standard

    var body: some View {
        Picker("Line", selection: $detail) {
            ForEach(ConversationRowDetail.allCases) { Text("Show \($0.name)").tag($0.rawValue) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Picker("Order", selection: $order) {
            ForEach(ConversationOrder.allCases) { Text($0.name).tag($0.rawValue) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Picker("Tasks", selection: $tasks) {
            ForEach(TaskListFilter.allCases) { Text($0.menuName).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// A message found by a search: the conversation it is in, when it was said and the words around the term.
struct MentionRow: View {
    /// The conversation's picture, 42 points across.
    let picture: AnyView
    let title: String
    let timestamp: String
    let snippet: AttributedString

    var body: some View {
        HStack(spacing: 10) {
            picture
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(timestamp)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                Text(snippet)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 66)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// What a sidebar search found, as one list in every app: each section of conversations that match, then each
/// message that says the term. Picking a message opens its conversation there.
struct SidebarSearchResults<Row: View, RowMenu: View>: View {
    private enum Pick: Hashable { case conversation(UUID), mention(UUID) }

    let sections: [(title: String, conversations: [BotConversation])]
    let mentions: [LinkMessageMatch]
    let hiddenMentions: Int
    let term: ConversationSearch?
    let selection: UUID?
    let select: (UUID?) -> Void
    /// Opens a message's conversation at that message.
    let pickMessage: (LinkMessageMatch) -> Void
    let showAll: () -> Void
    let conversation: (UUID) -> BotConversation?
    /// A message's conversation as its row says it: its picture, 42 points across, and its name.
    let mentionPicture: (BotConversation) -> AnyView
    let mentionTitle: (BotConversation) -> String
    @ViewBuilder let row: (BotConversation) -> Row
    @ViewBuilder let menu: (BotConversation) -> RowMenu
    @State private var pickedMention: UUID?

    var body: some View {
        List(selection: Binding<Pick?>(get: {
            guard let id = selection else { return nil }
            if let pickedMention, mentions.contains(where: { $0.messageID == pickedMention && $0.conversationID == id }) {
                return .mention(pickedMention)
            }
            return .conversation(id)
        }, set: { pick in
            switch pick {
            case .conversation(let id):
                pickedMention = nil
                select(id)
            case .mention(let messageID):
                pickedMention = messageID
                if let match = mentions.first(where: { $0.messageID == messageID }) { pickMessage(match) }
            case nil:
                select(nil)
            }
        })) {
            ForEach(sections, id: \.title) { section in
                if !section.conversations.isEmpty {
                    Section(section.title) {
                        ForEach(section.conversations) { conversation in
                            row(conversation)
                                .tag(Pick.conversation(conversation.id))
                                .contextMenu { menu(conversation) }
                        }
                    }
                }
            }
            if !mentions.isEmpty, let term {
                Section("Messages") {
                    ForEach(mentions, id: \.messageID) { match in
                        if let conversation = conversation(match.conversationID) {
                            MentionRow(picture: mentionPicture(conversation), title: mentionTitle(conversation),
                                       timestamp: SidebarTimestamp.text(for: match.createdAt),
                                       snippet: term.highlighted(match.snippet))
                                .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 10))
                                .listRowSeparator(.visible, edges: .bottom)
                                .listRowSeparatorTint(Color.primary.opacity(0.12))
                                .tag(Pick.mention(match.messageID))
                                .contextMenu { menu(conversation) }
                        }
                    }
                    if hiddenMentions > 0 {
                        Button("Show All \(mentions.count + hiddenMentions)", action: showAll)
                            .buttonStyle(.accentLink)
                            .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
