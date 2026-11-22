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
                // Noodle's: the close button asks first, and leaving counts as Not Now.
                .background(WelcomeCloseGuard { model.finishWelcome() })
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
        } detail: {
            if let tool = window.selectedTool.flatMap({ id in model.connectionsController.registry.connections.first { $0.id == id } }) {
                ToolPage(controller: model.connectionsController, connectionID: tool.id,
                         picture: { agent, size in AnyView(AgentMark(agent: agent, size: size)) },
                         chooser: { agents, chosen, search in
                             AnyView(GroupMemberChooser(agents: agents, selectedIDs: chosen, search: search,
                                                        words: GroupMemberWords(bot: "agent", bots: "agents", group: "tool"),
                                                        picture: { AnyView(AgentMark(agent: $0, size: 32)) }))
                         })
                .navigationTitle(tool.name)
                .id(tool.id)
            } else if let conversation = model.conversation(model.selection) {
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
                        .buttonStyle(.accentLink)
                }
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "shield.lefthalf.filled")
            }
        }
        // As in Noodle: the toolbar draws no band of its own over the content beneath it.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .modifier(ConversationSheets(model: model, window: window, selection: $model.selection))
        .modifier(RecoveryConfirmations(window: window))
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
            guard let id else { window.selectedFromKeyboard = false; return }
            window.selectedTool = nil
            model.markRead(id)
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
    @AppStorage(SidebarTools.key) private var showsTools = false
    @AppStorage(ConversationListStyle.key) private var style = ConversationListStyle.standard.rawValue
    @State private var closedLimit = SidebarOptions.closedShown
    @FocusState private var searchFocused: Bool
    @SceneStorage("PionClosedExpanded") private var closedExpanded = true
    @AppStorage(TaskListFilter.key) private var taskFilter = TaskListFilter.standard
    @AppStorage(ConversationOrder.key) private var order = ConversationOrder.standard.rawValue
    @AppStorage(ConversationRowDetail.key) private var rowDetail = ConversationRowDetail.standard.rawValue
    @State private var showsAllMentions = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let line = ConversationRowDetail(rawValue: rowDetail) ?? .standard
        Group {
            if let search = model.sidebarSearch(window.searchText, showingAll: showsAllMentions, mentions: window.mentions) {
                SidebarSearchResults(
                    sections: [("Investigations", search.investigations), ("Groups", search.groups), ("Agents", search.agents)],
                    mentions: search.mentions, hiddenMentions: search.hiddenMentions, term: ConversationSearch(window.searchText),
                    selection: model.selection, select: { model.selection = $0 },
                    pickMessage: { match in
                        model.selection = match.conversationID
                        model.revealMessage(match.messageID, in: match.conversationID)
                    },
                    showAll: { showsAllMentions = true },
                    conversation: { model.conversation($0) },
                    mentionPicture: { AnyView(ConversationPicture(model: model, conversation: $0, size: 42)) },
                    mentionTitle: { model.title(of: $0) },
                    row: { ConversationChoiceRow(model: model, conversation: $0, line: line) },
                    menu: { ConversationRowMenu(model: model, window: window, conversation: $0) })
                .overlay { if search.isEmpty { ContentUnavailableView.search(text: window.searchText) } }
            } else {
                if ConversationListStyle(rawValue: style) == .icons {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) { sections(line: line, icons: true) }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                            .focusSection()
                    }
                } else {
                    List(selection: Binding(get: { window.sidebarItem(in: model) }, set: select)) {
                        sections(line: line, icons: false)
                    }
                    .listStyle(.sidebar)
                }
            }
        }
        // As in Noodle: Tab in the list goes to the message field, and Shift-Tab there comes back.
        .modifier(ConversationListKeyboardNavigation(hasSelection: model.selection != nil, searchIsFocused: searchFocused,
            focusComposer: { window.composerFocusRequest = UUID() }, focusRequest: window.sidebarFocusRequest))
        // As Noodle's: the list draws no background of its own, so the window's backdrop carries on under it, a
        // little darker.
        .scrollContentBackground(.hidden)
        .background(Color.black.opacity(colorScheme == .dark ? 0.24 : 0.04).ignoresSafeArea())
        .onAppear { window.hasSidebar = true }
        .onChange(of: window.searchText) {
            showsAllMentions = false
            model.findMentions(window.searchText, with: window.mentions)
        }
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

    private func select(_ item: WindowState.SidebarItem?) {
        window.selectSidebarItem(item, in: model, fromKeyboard: NSApp.currentEvent?.type == .keyDown)
    }

    @ViewBuilder private func sections(line: ConversationRowDetail, icons: Bool) -> some View {
        let sections = model.sidebarSections(ConversationOrder(rawValue: order) ?? .standard)
        let closed = model.investigations.filter(\.isClosed).sorted { $0.updatedAt > $1.updatedAt }
        SidebarApprovals(store: model, agents: model.agents, inList: !icons)
        SidebarTasks(store: model, filter: taskFilter, inList: !icons)
        conversations(sections.pinned, header: "Pinned", line: line, icons: icons)
        conversations(sections.unread, header: "Unread", line: line, icons: icons)
        conversations(sections.investigations, header: "Investigations", line: line, icons: icons)
        if showsClosed, !closed.isEmpty {
            if icons {
                DisclosureGroup(isExpanded: $closedExpanded) {
                    ConversationIconGrid { closedItems(closed, icons: true) }
                        .padding(.vertical, 4)
                    showMoreClosed(total: closed.count)
                } label: { heading("Closed") }
            } else {
                Section(isExpanded: $closedExpanded) {
                    closedItems(closed, icons: false)
                    showMoreClosed(total: closed.count)
                } header: { Text("Closed") }
            }
        }
        conversations(sections.groups, header: "Groups", line: line, icons: icons)
        conversations(sections.agents, header: "Agents", line: line, icons: icons)
        if showsTools, !model.connectionsController.registry.connections.isEmpty {
            if icons {
                SidebarTools(controller: model.connectionsController, inList: false, showsOriginalIcons: true, selected: window.selectedTool) {
                    select(.tool($0.id))
                }
            } else {
                Section("Tools") {
                    ForEach(model.connectionsController.registry.connections) { tool in
                        let status = model.connectionsController.status(of: tool)
                        HStack(spacing: 8) {
                            ToolConnectionIcon(connection: tool, size: 22, frameless: true)
                            Text(tool.name).font(.callout).lineLimit(1)
                            Spacer(minLength: 4)
                            if status.needsAttention {
                                Circle().fill(.red).frame(width: 7, height: 7).accessibilityLabel("Needs attention")
                            } else if case .signingIn = status {
                                ProgressView().controlSize(.mini).accessibilityLabel("Signing in")
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .help(tool.name)
                        .accessibilityElement(children: .combine)
                        .tag(WindowState.SidebarItem.tool(tool.id))
                    }
                }
            }
        }
    }

    private func closedItems(_ closed: [Investigation], icons: Bool) -> some View {
        ForEach(closed.prefix(closedLimit)) { investigation in
            Group {
                if icons {
                    tile(id: investigation.id, name: investigation.title) {
                        SeverityGlyph(severity: investigation.severity, closed: true).scaleEffect(1.65)
                    }
                } else {
                    InvestigationRow(model: model, investigation: investigation)
                }
            }
            .tag(WindowState.SidebarItem.conversation(investigation.id))
            .contextMenu {
                if let conversation = model.conversation(investigation.id) {
                    ConversationRowMenu(model: model, window: window, conversation: conversation)
                }
            }
        }
    }

    @ViewBuilder private func showMoreClosed(total: Int) -> some View {
        if total > closedLimit {
            Button("Show \(min(total - closedLimit, SidebarOptions.closedShown)) More") { closedLimit += SidebarOptions.closedShown }
                .buttonStyle(.accentLink)
                .font(.caption)
                .selectionDisabled()
        }
    }

    @ViewBuilder private func conversations(_ items: [BotConversation], header: String, line: ConversationRowDetail, icons: Bool) -> some View {
        if !items.isEmpty {
            if icons {
                heading(header)
                ConversationIconGrid { conversationItems(items, line: line, icons: true) }
                    .padding(.vertical, 4)
            } else {
                Section(header) { conversationItems(items, line: line, icons: false) }
            }
        }
    }

    private func conversationItems(_ items: [BotConversation], line: ConversationRowDetail, icons: Bool) -> some View {
        ForEach(items) { conversation in
            Group {
                if icons {
                    tile(id: conversation.id, name: model.title(of: conversation)) {
                        if let investigation = model.investigation(conversation.id) {
                            SeverityGlyph(severity: investigation.severity).scaleEffect(1.65)
                        } else if conversation.kind == .direct, let agent = model.agent(conversation.participantIDs.first) {
                            AgentMark(agent: agent, size: 36, phase: model.phase(of: agent))
                        } else {
                            ConversationPicture(model: model, conversation: conversation, size: 36)
                        }
                    }
                } else {
                    ConversationChoiceRow(model: model, conversation: conversation, line: line)
                }
            }
            .tag(WindowState.SidebarItem.conversation(conversation.id))
            .conversationDropTarget { model.drop($0, onConversation: conversation.id) }
            .contextMenu { ConversationRowMenu(model: model, window: window, conversation: conversation) }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.leading, 4).padding(.top, 10).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func tile(id: UUID, name: String, @ViewBuilder picture: () -> some View) -> some View {
        let selected = model.selection == id && window.selectedTool == nil
        return Button { select(.conversation(id)) } label: {
            VStack(spacing: 4) {
                picture().frame(width: 36, height: 36).modifier(UnreadMark(model: model, id: id))
                Text(name).font(.caption.weight(model.countsAsUnread(id) ? .semibold : .regular))
                    .lineLimit(2).multilineTextAlignment(.center)
            }
            .padding(4).frame(maxWidth: .infinity)
            .background(Color.primary.opacity(selected ? 0.1 : 0), in: .rect(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(name)
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
            GroupSigil(members: model.members(of: conversation).map(\.id), size: size)
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

    var body: some View {
        let investigation = model.investigation(conversation.id)
        let agent = conversation.kind == .direct ? model.agent(conversation.participantIDs.first) : nil
        let closed = investigation?.isClosed == true
        // As in Noodle: where it opens, then pinning and notifications, editing, looking at it elsewhere, the
        // agent's housekeeping, and last stopping, suspending and closing or archiving.
        Button("Open in New Window") { PionWindows.dock(conversation.id) }
        Button("Float on Top") { PionWindows.float(conversation.id) }
        Divider()
        Button(model.isPinned(conversation.id) ? "Unpin" : "Pin") {
            model.setPinned(!model.isPinned(conversation.id), conversationID: conversation.id)
        }
        .disabled(closed)
        if agent == nil {
            NotificationsPicker(chosen: Binding(
                get: { model.chosenNotifications(of: conversation.id) ?? .default },
                set: { model.setNotifications($0, conversationID: conversation.id) }),
                defaultIsMentions: model.groupNotifications == .mentions)
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
            AgentHousekeepingItems(agent: agent, runtime: model.runtime, repository: model.repository,
                showActivity: { model.showActivity(for: agent) }, filterUsage: { model.usage.agentFilter = agent.id },
                revealWorkspace: { model.reveal(conversation) }, kick: { window.kickRequest = $0 },
                newSession: { window.newSessionAgent = agent })
        } else {
            Button("Show in Finder") { model.reveal(conversation) }
            if let investigation {
                Button("Export Investigation…") { model.exportInvestigation(investigation) }
            }
        }
        Divider()
        if let agent {
            if model.stoppableAgent(in: conversation.id) != nil { Button("Stop") { model.stop(in: conversation.id) } }
            SuspendMenu(isSuspended: agent.isSuspended(), noun: "Agent") { model.setSuspended(until: $0, agent: agent) }
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

/// One activity window per agent, Noodle's own, kept for the whole app.
@MainActor private let activityWindows = ActivityWindows()

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
        setArchived(true, agentID: agent.id)
        activityWindows.synchronize(agents: agents)
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
        .modifier(UnreadMark(model: model, id: investigation.id))
    }
}

/// Noodle's blue dot on an unread row, in the leading inset 5 points before its mark; a muted group's is dimmed.
/// Smaller than Noodle's, to suit Pion's smaller marks, which also keeps it clear of the sidebar's edge.
struct UnreadMark: ViewModifier {
    let unread: Bool
    var muted = false

    init(unread: Bool, muted: Bool = false) { self.unread = unread; self.muted = muted }

    init(model: PionModel, id: UUID) {
        self.init(unread: model.isUnread(id), muted: model.notifications(of: id) == .muted)
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if unread { UnreadDot(isMuted: muted, size: 6).offset(x: -11) }
        }
    }
}

struct GroupRow: View {
    let model: PionModel
    let group: BotConversation
    var line = ConversationRowDetail.standard

    var body: some View {
        let unread = model.countsAsUnread(group.id)
        HStack(spacing: 8) {
            GroupSigil(members: model.members(of: group).map(\.id), size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title(of: group)).font(.callout.weight(unread ? .semibold : .regular)).lineLimit(1)
                Text(model.rowDetail(for: group, showing: line))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(UnreadMark(model: model, id: group.id))
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
        .modifier(UnreadMark(unread: unread))
        .contentShape(Rectangle())
    }
}

extension PionModel: BotBudgetHost {}

extension PionModel: AttachmentOpeningHost {}

/// Noodle's patch review windows, one per patch, kept for the whole app.
@MainActor let patchReviews = PatchReviewWindows()

extension PionModel: AgentApprovalHost {
    func openConversation(for approval: AgentApproval, of agentID: UUID) {
        selection = approval.conversationID.flatMap { conversation($0)?.id } ?? agent(agentID).flatMap { directConversation(of: $0)?.id }
    }
}

extension PionModel: AgentTaskHost {
    func taskAgentName(_ id: UUID) -> String? { agent(id)?.displayName }
    func taskAvatar(_ agent: AgentRecord) -> AnyView { AnyView(AgentMark(agent: agent, size: 22)) }
    func openConversation(for task: AgentTask, of agentID: UUID) { selection = conversationID(for: task, of: agentID) }
    func reportTaskError(_ message: String) { problem = message }
}
