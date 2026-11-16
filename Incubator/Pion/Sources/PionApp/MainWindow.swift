import AppKit
import HubLink
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import PionCore
import SwiftUI

/// The sidebar of Investigations, groups and agents beside the conversation that is selected.
struct MainWindow: View {
    let model: PionModel
    @Bindable var window: WindowState
    let setup: HarnessSetupController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        if model.showsWelcome {
            WelcomeView(model: model, setup: setup)
                .background { Backdrop().ignoresSafeArea() }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .onAppear { window.openMain = { openWindow(id: "main") } }
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(model: model, window: window)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
                // The backdrop carries on under the sidebar's glass, softened by it.
                .background { Backdrop(frosted: true).ignoresSafeArea() }
        } detail: {
            if let conversation = model.conversation(model.selection) {
                // Kept while the selection changes, as Noodle's is: only the transcript is replaced.
                ConversationView(model: model, window: window, conversation: conversation)
            } else if model.agents.isEmpty {
                ContentUnavailableView {
                    Label("No Agents", systemImage: "person.2")
                } description: {
                    Text("Create an agent to start investigating.")
                } actions: {
                    Button("Set Up Your Team") { model.showWelcome() }
                        .buttonStyle(.borderedProminent)
                    Button("New Agent") { window.sheet = .newAgent }
                        .buttonStyle(.link)
                }
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "shield.lefthalf.filled")
            }
        }
        // As in Noodle: the toolbar draws no band of its own over the content beneath it.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .modifier(ConversationSheets(model: model, window: window, selection: $model.selection))
        .modifier(RecoveryConfirmations(window: window))
        .onOpenURL { _ = model.connectionsController.receiveAuthorizationCallback($0) }
        .onAppear {
            window.openMain = { openWindow(id: "main") }
            // As in Noodle: the conversations left in windows of their own open again, unless they float.
            PionWindows.conversations?.openMainWindow = { openWindow(id: "main") }
            PionWindows.conversations?.restoreWindows { id in
                if !FloatingConversations.shared.contains(id) { openWindow(id: "conversation", value: id) }
            }
        }
        .background {
            if let registry = PionWindows.conversations {
                ConversationWindowHost(registry: registry, conversationID: model.selection, isMainWindow: true) {
                    if let id = $0 { model.markRead(id) }
                }
            }
        }
        .focusedSceneValue(\.pionConversation, ConversationCommandContext(selection: $model.selection, window: window,
            search: { window.searchFocusRequest = UUID() }))
        .onChange(of: model.selection) { _, id in
            if let id { model.markRead(id) }
            guard !window.selectedFromKeyboard else { window.selectedFromKeyboard = false; return }
            window.composerFocusRequest = UUID()
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    let model: PionModel
    @Bindable var window: WindowState
    @AppStorage(SidebarOptions.showsClosedKey) private var showsClosed = false
    @State private var closedLimit = SidebarOptions.closedShown
    @FocusState private var searchFocused: Bool
    @SceneStorage("PionClosedExpanded") private var closedExpanded = true
    @AppStorage(TaskListFilter.key) private var taskFilter = TaskListFilter.standard
    @AppStorage(ConversationOrder.key) private var order = ConversationOrder.standard.rawValue
    @AppStorage(ConversationRowDetail.key) private var rowDetail = ConversationRowDetail.standard.rawValue
    @State private var showsAllMentions = false

    var body: some View {
        let line = ConversationRowDetail(rawValue: rowDetail) ?? .standard
        Group {
            if let search = model.sidebarSearch(window.searchText, showingAll: showsAllMentions) {
                SidebarSearchResults(
                    sections: [("Investigations", search.investigations), ("Groups", search.groups), ("Agents", search.agents)],
                    mentions: search.mentions, hiddenMentions: search.hiddenMentions, term: ConversationSearch(window.searchText),
                    selection: model.selection, select: { model.selection = $0 },
                    pickMessage: { match in
                        model.selection = match.conversationID
                        // After the transcript for the selection is on screen.
                        DispatchQueue.main.async { NotificationCenter.default.post(name: .revealTranscriptMessage, object: match.messageID) }
                    },
                    showAll: { showsAllMentions = true },
                    conversation: { model.conversation($0) },
                    mentionPicture: { AnyView(ConversationPicture(model: model, conversation: $0, size: 42)) },
                    mentionTitle: { model.title(of: $0) },
                    row: { ConversationChoiceRow(model: model, conversation: $0, line: line) },
                    menu: { ConversationRowMenu(model: model, window: window, conversation: $0) })
                .overlay { if search.isEmpty { ContentUnavailableView.search(text: window.searchText) } }
            } else {
                list(line: line)
            }
        }
        // As in Noodle: Tab in the list goes to the message field, and Shift-Tab there comes back.
        .modifier(ConversationListKeyboardNavigation(hasSelection: model.selection != nil, searchIsFocused: searchFocused,
            focusComposer: { window.composerFocusRequest = UUID() }, focusRequest: window.sidebarFocusRequest))
        .onAppear { window.hasSidebar = true }
        .onChange(of: window.searchText) { showsAllMentions = false }
        .searchable(text: $window.searchText, placement: .sidebar, prompt: "Search Conversations")
        .searchFocused($searchFocused)
        .onChange(of: window.searchFocusRequest) { searchFocused = true }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Investigation") { window.sheet = .newInvestigation }.disabled(model.agents.isEmpty)
                    Button("New Group") { window.sheet = .newGroup }.disabled(model.agents.isEmpty)
                    Button("New Agent") { window.sheet = .newAgent }
                } label: { Label("New", systemImage: "plus") }
                    .help("New Investigation, Group or Agent")
            }
        }
    }

    /// The sidebar when nothing is searched for.
    private func list(line: ConversationRowDetail) -> some View {
        let sections = model.sidebarSections(ConversationOrder(rawValue: order) ?? .standard)
        let closed = model.investigations.filter(\.isClosed).sorted { $0.updatedAt > $1.updatedAt }
        return List(selection: Binding(get: { model.selection }, set: { id in
            window.selectedFromKeyboard = NSApp.currentEvent?.type == .keyDown
            model.selection = id
        })) {
            // Noodle's Tasks section: what the agents are working on, those waiting on the champion first.
            SidebarTasks(store: model, filter: taskFilter, inList: true)
            // As Noodle's, and a section shows only once it has something in it.
            rows(sections.pinned, header: "Pinned", line: line)
            rows(sections.unread, header: "Unread", line: line)
            rows(sections.investigations, header: "Investigations", line: line)
            // Closed ones only when asked for, a few at a time, to look back at.
            if showsClosed, !closed.isEmpty {
                Section(isExpanded: $closedExpanded) {
                    ForEach(closed.prefix(closedLimit)) { investigation in
                        InvestigationRow(model: model, investigation: investigation).tag(investigation.id)
                            .contextMenu {
                                if let conversation = model.conversation(investigation.id) {
                                    ConversationRowMenu(model: model, window: window, conversation: conversation)
                                }
                            }
                    }
                    if closed.count > closedLimit {
                        Button("Show \(min(closed.count - closedLimit, SidebarOptions.closedShown)) More") {
                            closedLimit += SidebarOptions.closedShown
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .selectionDisabled()
                    }
                } header: {
                    Text("Closed")
                }
            }
            rows(sections.groups, header: "Groups", line: line)
            rows(sections.agents, header: "Agents", line: line)
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private func rows(_ conversations: [BotConversation], header: String, line: ConversationRowDetail) -> some View {
        if !conversations.isEmpty {
            Section {
                ForEach(conversations) { conversation in
                    ConversationChoiceRow(model: model, conversation: conversation, line: line).tag(conversation.id)
                        .conversationDropTarget { model.drop($0, onConversation: conversation.id) }
                        .contextMenu { ConversationRowMenu(model: model, window: window, conversation: conversation) }
                }
            } header: {
                Text(header)
            }
        }
    }
}

/// A conversation's picture where it stands for the whole conversation: an Investigation's severity, an agent's
/// mark, or a group's.
struct ConversationPicture: View {
    let model: PionModel
    let conversation: BotConversation
    let size: CGFloat

    var body: some View {
        if let investigation = model.investigation(conversation.id) {
            SeverityGlyph(severity: investigation.severity, closed: investigation.isClosed).frame(width: size, height: size)
        } else if conversation.kind == .direct, let agent = model.agent(conversation.participantIDs.first) {
            AgentMark(agent: agent, size: size)
        } else {
            SymbolMark(symbol: "person.3.fill", size: size)
        }
    }
}

/// Shared by sidebar rows and search results; actions target the row that was clicked.
/// The menu of a conversation in the sidebar, in Noodle's order: opening it, editing it, looking at it in
/// other places, then stopping, closing or archiving it. Investigations, groups and agents share it, so the
/// same action sits in the same place whatever the row.
struct ConversationRowMenu: View {
    let model: PionModel
    let window: WindowState
    let conversation: BotConversation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let investigation = model.investigation(conversation.id)
        let agent = conversation.kind == .direct ? model.agent(conversation.participantIDs.first) : nil
        let closed = investigation?.isClosed == true
        // As in Noodle: where it opens, then pinning and notifications, editing, looking at it elsewhere, the
        // agent's housekeeping, and last stopping, suspending and closing or archiving.
        Button("Open in New Window") {
            // Opened in a window, a floating conversation stops floating, as Noodle docks it.
            PionWindows.panels?.close(conversation.id)
            openWindow(id: "conversation", value: conversation.id)
        }
        Button("Float on Top") { PionWindows.float(conversation.id) }
        Divider()
        Button(model.isPinned(conversation.id) ? "Unpin" : "Pin") {
            model.setPinned(!model.isPinned(conversation.id), conversationID: conversation.id)
        }
        .disabled(closed)
        if agent == nil {
            Picker("Notifications", selection: Binding(
                get: { model.chosenNotifications(of: conversation.id) ?? .default },
                set: { model.setNotifications($0, conversationID: conversation.id) })) {
                Text(model.groupNotifications == .mentions ? "Default (Mentions Only)" : "Default (All Messages)")
                    .tag(LinkNotifications.default)
                Text("All Messages").tag(LinkNotifications.all)
                Text("Mentions Only").tag(LinkNotifications.mentions)
                Text("Muted").tag(LinkNotifications.muted)
            }
        }
        Divider()
        Button(investigation != nil ? "Edit Investigation…" : agent != nil ? "Edit Agent…" : "Edit Group…") {
            window.edit(conversation, in: model)
        }
        .disabled(closed)
        if let investigation {
            Picker("Status", selection: Binding(get: { investigation.status }, set: { model.setStatus($0, of: investigation) })) {
                ForEach([Investigation.Status.open, .triaging, .contained], id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(closed)
        }
        Divider()
        if let agent {
            Button("Show Activity") { model.showActivity(for: agent) }
            Button("Show Usage") {
                model.usage.agentFilter = agent.id
                openWindow(id: UsageView.windowID)
            }
            Button("Show Workspace in Finder") { model.reveal(conversation) }
            Divider()
            Button("Organize") { model.runtime.organize(agent.id) }
                .disabled(!model.runtime.canOrganize(agent.id))
            Divider()
            // Kick also takes an agent on a fallback harness back to its own.
            if model.runtime.snapshot(for: agent.id).phase == .failed || model.runtime.runningHarness(for: agent.id) != nil {
                Button("Kick") { window.kickRequest = model.runtime.kick(agent: agent, repository: model.repository) }
                    .disabled(model.runtime.changingAccess.contains(agent.id))
            }
            Button("New Session") { window.newSessionAgent = agent }
                .disabled(model.runtime.changingAccess.contains(agent.id))
        } else {
            Button("Show in Finder") { model.reveal(conversation) }
            if let investigation {
                Button("Export Investigation…") { model.exportInvestigation(investigation) }
            }
        }
        Divider()
        if let agent {
            if model.stoppableAgent(in: conversation.id) != nil { Button("Stop") { model.stop(in: conversation.id) } }
            SuspendAgentMenu(model: model, agent: agent)
            Button("Archive Agent") { model.archive(agent) }
        } else if let investigation {
            if closed {
                Button("Reopen") { model.setStatus(.open, of: investigation) }
            } else {
                Button("Close Investigation…") { window.sheet = .close(investigation) }
            }
        } else {
            Button("Archive Group") { model.archive(conversation) }
        }
    }
}

/// Suspend Agent's choices of how long, as Noodle offers them, or Unsuspend Agent for one already suspended.
struct SuspendAgentMenu: View {
    let model: PionModel
    let agent: AgentRecord

    var body: some View {
        if agent.isSuspended() {
            Button("Unsuspend Agent") { model.setSuspended(until: nil, agent: agent) }
        } else {
            Menu("Suspend Agent") {
                ForEach(LinkSuspensionChoice.allCases, id: \.self) { choice in
                    Button(choice.title) { model.setSuspended(until: choice.until(), agent: agent) }
                }
            }
        }
    }
}

/// One activity window per agent, Noodle's own, kept for the whole app.
@MainActor private let activityWindows = AgentActivityWindows()

extension PionModel {
    func showActivity(for agent: AgentRecord) {
        activityWindows.show(agent: agent, log: runtime.activity.log(for: agent.id))
    }

    /// An agent's workspace; an Investigation's own folder, with its case record and audit log; a group's
    /// conversation folder, with its messages and attachments.
    func reveal(_ conversation: BotConversation) {
        let url: URL
        if conversation.kind == .direct, let agent = agent(conversation.participantIDs.first) {
            url = repository.directory(for: agent)
        } else if investigation(conversation.id) != nil {
            url = store.folder(conversation.id)
        } else {
            url = repository.conversationDirectory(id: conversation.id)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func archive(_ agent: AgentRecord) {
        do {
            _ = try repository.setAgentArchived(true, agentID: agent.id)
            runtime.stop(agentID: agent.id)
            reload()
            activityWindows.synchronize(agents: agents)
        } catch { problem = error.localizedDescription }
    }

    func archive(_ group: BotConversation) { setGroupArchived(true, id: group.id) }
}

struct InvestigationRow: View {
    let model: PionModel
    let investigation: Investigation

    var body: some View {
        let unread = model.countsAsUnread(investigation.id)
        HStack(alignment: .top, spacing: 8) {
            SeverityGlyph(severity: investigation.severity, closed: investigation.isClosed)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(investigation.reference).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(investigation.updatedAt.pionShort).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                Text(investigation.title)
                    .font(.callout.weight(unread ? .semibold : .regular))
                    .lineLimit(2)
                Text(investigation.outcome?.title ?? investigation.status.title)
                    .font(.caption)
                    .foregroundStyle(investigation.isClosed ? Color.secondary : investigation.status.color)
            }
        }
        .padding(.vertical, 3)
    }
}

struct GroupRow: View {
    let model: PionModel
    let group: BotConversation
    var line = ConversationRowDetail.standard

    var body: some View {
        let unread = model.countsAsUnread(group.id)
        HStack(spacing: 8) {
            SymbolMark(symbol: "person.3.fill", size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.displayName).font(.callout.weight(unread ? .semibold : .regular)).lineLimit(1)
                Text(model.rowDetail(for: group, showing: line))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct AgentRow: View {
    let model: PionModel
    let agent: AgentRecord
    let unread: Bool
    /// The agent's own conversation, whose line shows under the name; a paused or failed agent says so instead.
    var conversation: BotConversation?
    var line = ConversationRowDetail.standard

    var body: some View {
        let phase = model.phase(of: agent)
        HStack(spacing: 8) {
            AgentMark(agent: agent, size: 22, phase: phase)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName).font(.callout.weight(unread ? .semibold : .regular))
                if let detail = model.interruption(of: agent) ?? conversation.map({ model.rowDetail(for: $0, showing: line) })
                    ?? model.phaseDetail(of: agent) ?? agent.publicDescription {
                    Text(detail).font(.caption).foregroundStyle(phase == .failed ? Color.red : Color.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension PionModel: BotBudgetHost {}

extension PionModel: AttachmentOpeningHost {}

/// Noodle's patch review windows, one per patch, kept for the whole app.
@MainActor let patchReviews = PatchReviewWindows()

extension PionModel: AgentTaskHost {
    func taskAgentName(_ id: UUID) -> String? { agent(id)?.displayName }
    func taskAvatar(_ agent: AgentRecord) -> AnyView { AnyView(AgentMark(agent: agent, size: 22)) }
    func openConversation(for task: AgentTask, of agentID: UUID) { selection = conversationID(for: task, of: agentID) }
    func reportTaskError(_ message: String) { problem = message }
}
