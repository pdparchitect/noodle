import AppKit
import HubLink
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import RookCore
import SwiftUI
import NoodleSettingsUI

/// The sidebar of Missions, groups and agents beside the conversation that is selected.
struct MainWindow: View {
    @AppStorage(WindowSurface.tintKey) private var tinted = true
    let model: RookModel
    @Bindable var window: WindowState
    let setup: HarnessSetupController
    @State private var graphContainerSize = CGSize(width: 1000, height: 760)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.rookComputers) private var computers

    var body: some View {
        @Bindable var model = model
        if model.showsWelcome {
            WelcomeView(model: model, setup: setup)
                .background { Backdrop().ignoresSafeArea() }
                // Noodle's: the close button asks first, and leaving counts as Not Now.
                .background(WelcomeCloseGuard { model.finishWelcome() })
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .onAppear { window.openMain = { openWindow(id: "main") } }
        } else if let computers {
            // Noodle Computer's alert: a computer that cannot be made, started or upgraded says why.
            content.computerErrorAlert(store: computers.store)
        } else {
            content
        }
    }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(model: model, window: window)
                .navigationSplitViewColumnWidth(min: 280, ideal: 326, max: 380)
        } detail: {
            if let conversation = model.conversation(model.selection) {
                // Kept while the selection changes, as Noodle's is: only the transcript is replaced.
                ConversationView(model: model, window: window, conversation: conversation, presentsGraphSheet: false)
            } else if let computers, let id = model.selection, let session = computers.session(id) {
                // Noodle Computer's own view: the terminal, files or desktop, with Start, Stop and Edit in the toolbar. Its
                // terminal and files let Rook's window show through a little.
                ComputerDetailView(store: computers.store, session: session, panelOpacity: 0.55).id(session.id)
            } else if model.agents.isEmpty {
                ContentUnavailableView {
                    Label("No Agents", systemImage: "person.2")
                } description: {
                    Text("Create an agent to start a mission.")
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
        .onGeometryChange(for: CGSize.self, of: \.size) { graphContainerSize = $0 }
        // A native sheet makes the whole parent window, including its toolbar, modal.
        .sheet(isPresented: $window.showsGraph) {
            if let conversation = model.conversation(model.selection), let mission = model.mission(conversation.id) {
                let size = MissionGraphView.sheetSize(in: graphContainerSize)
                MissionGraphView(model: model, mission: mission) { window.showsGraph = false }
                    .frame(width: size.width, height: size.height)
                    // Frosted whatever the window's surface, with Rook's crimson wash, as a sheet's own material has nothing to blur.
                    .presentationBackground { ZStack { FrostedWindowBackground(); if tinted { Color.windowWash } } }
                    .noodleSheetSizing()
            }
        }
        // As in Noodle: the toolbar draws no band of its own over the content beneath it.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .modifier(ConversationSheets(model: model, window: window, selection: $model.selection))
        .modifier(RecoveryConfirmations(window: window))
        .onAppear {
            window.openMain = { openWindow(id: "main") }
            // As in Noodle: the conversations left in windows of their own open again, unless they float.
            RookWindows.conversations?.openMainWindow = { openWindow(id: "main") }
            RookWindows.conversations?.restoreWindows { id in
                if !FloatingConversations.shared.contains(id) { openWindow(id: "conversation", value: id) }
            }
        }
        .background {
            if let registry = RookWindows.conversations {
                ConversationWindowHost(registry: registry, conversationID: model.selection, isMainWindow: true) {
                    if let id = $0 { model.markRead(id) }
                }
            }
        }
        .focusedSceneValue(\.rookConversation, ConversationCommandContext(selection: $model.selection, window: window,
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
    let model: RookModel
    @Bindable var window: WindowState
    @AppStorage(SidebarOptions.showsClosedKey) private var showsClosed = false
    @AppStorage(ConversationListStyle.key) private var style = ConversationListStyle.standard.rawValue
    @AppStorage(SidebarTools.key) private var showsTools = false
    @State private var closedLimit = SidebarOptions.closedShown
    @FocusState private var searchFocused: Bool
    @SceneStorage("RookClosedExpanded") private var closedExpanded = true
    @AppStorage(TaskListFilter.key) private var taskFilter = TaskListFilter.standard
    @AppStorage(ConversationOrder.key) private var order = ConversationOrder.standard.rawValue
    @AppStorage(ConversationRowDetail.key) private var rowDetail = ConversationRowDetail.standard.rawValue
    @State private var showsAllMentions = false
    @State private var creatingComputer: NewComputerKind?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rookComputers) private var computers

    var body: some View {
        let line = ConversationRowDetail(rawValue: rowDetail) ?? .standard
        Group {
            if let search = model.sidebarSearch(window.searchText, showingAll: showsAllMentions, mentions: window.mentions) {
                SidebarSearchResults(
                    sections: [("Missions", search.missions), ("Agents", search.agents), ("Groups", search.groups)],
                    mentions: search.mentions, hiddenMentions: search.hiddenMentions, term: ConversationSearch(window.searchText),
                    selection: model.selection, select: { model.selection = $0 },
                    pickMessage: { match in
                        model.selection = match.conversationID
                        model.revealMessage(match.messageID, in: match.conversationID)
                    },
                    showAll: { showsAllMentions = true },
                    conversation: { model.conversation($0) },
                    mentionPicture: { AnyView(ConversationPicture(model: model, conversation: $0, size: SidebarItemDensity.compact.rowPicture)) },
                    mentionTitle: { model.title(of: $0) },
                    row: { ConversationChoiceRow(model: model, conversation: $0, line: line).sidebarItemInsets() },
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
                    List(selection: Binding(get: { model.selection }, set: select)) {
                        sections(line: line, icons: false)
                    }
                    .listStyle(.sidebar)
                }
            }
        }
        .environment(\.sidebarItemDensity, .compact)
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
                    Button("New Mission") { window.sheet = .newMission }.disabled(model.agents.isEmpty)
                    Button("New Group") { window.sheet = .newGroup }.disabled(model.agents.isEmpty)
                    Button("New Agent") { window.sheet = .newAgent }
                    if computers != nil {
                        Divider()
                        Button(NewComputerKind.linux.title) { creatingComputer = .linux }
                        Button(NewComputerKind.ssh.title) { creatingComputer = .ssh }
                    }
                } label: { Label("New", systemImage: "plus") }
                    .help("New Mission, Group, Agent or Computer")
            }
        }
        .sheet(item: $creatingComputer) { kind in
            if let computers { NewComputerSheet(computers: computers, kind: kind) { model.selection = $0 } }
        }
    }

    private func select(_ id: UUID?) {
        window.selectedFromKeyboard = NSApp.currentEvent?.type == .keyDown
        model.selection = id
    }

    @ViewBuilder private func sections(line: ConversationRowDetail, icons: Bool) -> some View {
        let sections = model.sidebarSections(ConversationOrder(rawValue: order) ?? .standard)
        let closed = model.missions.filter(\.isClosed).sorted { $0.updatedAt > $1.updatedAt }
        SidebarTasks(store: model, filter: taskFilter, inList: !icons)
        conversations(sections.pinned, header: "Pinned", line: line, icons: icons)
        conversations(sections.unread, header: "Unread", line: line, icons: icons)
        conversations(sections.missions, header: "Missions", line: line, icons: icons)
        if showsClosed, !closed.isEmpty {
            if icons {
                DisclosureGroup(isExpanded: $closedExpanded) {
                    ConversationIconGrid { closedItems(closed, icons: true) }
                        .padding(.vertical, 4)
                    showMoreClosed(total: closed.count)
                } label: { SidebarGridHeading(title: "Closed") }
            } else {
                Section(isExpanded: $closedExpanded) {
                    closedItems(closed, icons: false)
                    showMoreClosed(total: closed.count)
                } header: { Text("Closed") }
            }
        }
        conversations(sections.agents, header: "Agents", line: line, icons: icons)
        conversations(sections.groups, header: "Groups", line: line, icons: icons)
        if let computers {
            ComputersSidebarSection(computers: computers, model: model, icons: icons) { select($0) }
        }
        if showsTools {
            SidebarTools(controller: model.connectionsController, inList: !icons)
        }
    }

    private func closedItems(_ closed: [Mission], icons: Bool) -> some View {
        ForEach(closed.prefix(closedLimit)) { mission in
            Group {
                if icons {
                    tile(id: mission.id, name: mission.title, detail: mission.sidebarDetail) { size in
                        SeverityGlyph(severity: mission.severity, closed: true).scaleEffect(size / 18).frame(width: size, height: size)
                    }
                } else {
                    MissionRow(model: model, mission: mission).sidebarItemInsets()
                }
            }
            .tag(mission.id)
            .contextMenu {
                if let conversation = model.conversation(mission.id) {
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
                SidebarGridHeading(title: header)
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
                    let agent = conversation.kind == .direct ? model.agent(conversation.participantIDs.first) : nil
                    let pause = agent.flatMap { model.interruption(of: $0) }
                    let working = agent.map { model.phase(of: $0) == .working } ?? false
                    let detail = model.mission(conversation.id)?.sidebarDetail ?? model.rowDetail(for: conversation, showing: line)
                    tile(id: conversation.id, name: model.title(of: conversation),
                         detail: pause ?? (working ? "Working" : detail), paused: pause != nil, working: working) { size in
                        ConversationPicture(model: model, conversation: conversation, size: size)
                    }
                } else {
                    ConversationChoiceRow(model: model, conversation: conversation, line: line).sidebarItemInsets()
                }
            }
            .tag(conversation.id)
            .conversationDropTarget { model.drop($0, onConversation: conversation.id) }
            .contextMenu { ConversationRowMenu(model: model, window: window, conversation: conversation) }
        }
    }

    private func tile<Picture: View>(id: UUID, name: String, detail: String, paused: Bool = false, working: Bool = false,
                                     @ViewBuilder picture: @escaping (CGFloat) -> Picture) -> some View {
        let selected = model.selection == id
        return Button { select(id) } label: {
            SidebarItemTile(title: name, detail: detail,
                            tone: paused ? AnyShapeStyle(.orange) : working ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary),
                            emphasized: paused || working, selected: selected) { size in
                picture(size).overlay(alignment: .topLeading) {
                    if model.isUnread(id) {
                        UnreadDot(isMuted: model.notifications(of: id) == .muted, size: 10, ringed: true).offset(x: -2, y: -2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(name)
    }
}

/// A conversation's picture where it stands for the whole conversation: a Mission's severity, an agent's
/// mark, or a group's.
struct ConversationPicture: View {
    let model: RookModel
    let conversation: BotConversation
    let size: CGFloat

    var body: some View {
        if let mission = model.mission(conversation.id) {
            SeverityGlyph(severity: mission.severity, closed: mission.isClosed)
                .scaleEffect(size / 18).frame(width: size, height: size)
        } else if conversation.kind == .direct, let agent = model.agent(conversation.participantIDs.first) {
            AgentMark(agent: agent, size: size, phase: model.phase(of: agent))
        } else {
            GroupSigil(members: model.members(of: conversation).map(\.id), size: size)
        }
    }
}

/// Shared by sidebar rows and search results; actions target the row that was clicked.
/// The menu of a conversation in the sidebar, in Noodle's order: opening it, editing it, looking at it in
/// other places, then stopping, closing or archiving it. Missions, groups and agents share it, so the
/// same action sits in the same place whatever the row.
struct ConversationRowMenu: View {
    let model: RookModel
    let window: WindowState
    let conversation: BotConversation

    var body: some View {
        let mission = model.mission(conversation.id)
        let agent = conversation.kind == .direct ? model.agent(conversation.participantIDs.first) : nil
        let closed = mission?.isClosed == true
        // As in Noodle: where it opens, then pinning and notifications, editing, looking at it elsewhere, the
        // agent's housekeeping, and last stopping, suspending and closing or archiving.
        Button("Open in New Window") { RookWindows.dock(conversation.id) }
        Button("Float on Top") { RookWindows.float(conversation.id) }
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
        Button(mission != nil ? "Edit Mission…" : agent != nil ? "Edit Agent…" : "Edit Group…") {
            window.edit(conversation, in: model)
        }
        .disabled(closed)
        if let mission {
            Picker("Status", selection: Binding(get: { mission.status }, set: { model.setStatus($0, of: mission) })) {
                ForEach([Mission.Status.open, .active, .proven], id: \.self) { Text($0.title).tag($0) }
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
            if let mission {
                Button("Export Mission…") { model.exportMission(mission) }
            }
        }
        Divider()
        if let agent {
            if model.stoppableAgent(in: conversation.id) != nil { Button("Stop") { model.stop(in: conversation.id) } }
            SuspendMenu(isSuspended: agent.isSuspended(), noun: "Agent") { model.setSuspended(until: $0, agent: agent) }
            Button("Archive Agent") { model.archive(agent) }
        } else if let mission {
            if closed {
                Button("Reopen") { model.setStatus(.open, of: mission) }
            } else {
                Button("Close Mission…") { window.sheet = .close(mission) }
            }
        } else {
            Button("Archive Group") { model.archive(conversation) }
        }
    }
}

/// One activity window per agent, Noodle's own, kept for the whole app.
@MainActor private let activityWindows = ActivityWindows()

extension RookModel {
    func showActivity(for agent: AgentRecord) {
        activityWindows.show(agent: agent, log: runtime.activity.log(for: agent.id))
    }

    /// An agent's workspace; a Mission's own folder, with its case record and audit log; a group's
    /// conversation folder, with its messages and attachments.
    func reveal(_ conversation: BotConversation) {
        let url: URL
        if conversation.kind == .direct, let agent = agent(conversation.participantIDs.first) {
            url = repository.directory(for: agent)
        } else if mission(conversation.id) != nil {
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

struct MissionRow: View {
    let model: RookModel
    let mission: Mission

    var body: some View {
        SidebarItemRow(title: mission.title, detail: mission.sidebarDetail,
                       timestamp: SidebarTimestamp.text(for: mission.updatedAt)) { size in
            SeverityGlyph(severity: mission.severity, closed: mission.isClosed)
                .scaleEffect(size / 18).frame(width: size, height: size)
        }
        .modifier(UnreadMark(model: model, id: mission.id))
    }
}

private extension Mission {
    var sidebarDetail: String { "\(reference) · \(outcome?.title ?? status.title)" }
}

/// Noodle's blue dot on an unread row, in the leading inset 5 points before its mark; a muted group's is dimmed.
struct UnreadMark: ViewModifier {
    let unread: Bool
    var muted = false

    init(unread: Bool, muted: Bool = false) { self.unread = unread; self.muted = muted }

    init(model: RookModel, id: UUID) {
        self.init(unread: model.isUnread(id), muted: model.notifications(of: id) == .muted)
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            if unread { UnreadDot(isMuted: muted).offset(x: -13) }
        }
    }
}

struct GroupRow: View {
    let model: RookModel
    let group: BotConversation
    var line = ConversationRowDetail.standard

    var body: some View {
        SidebarItemRow(title: model.title(of: group), detail: model.rowDetail(for: group, showing: line),
                       timestamp: SidebarTimestamp.text(for: group.updatedAt)) { size in
            GroupSigil(members: model.members(of: group).map(\.id), size: size)
        }
        .modifier(UnreadMark(model: model, id: group.id))
    }
}

struct AgentRow: View {
    let model: RookModel
    let agent: AgentRecord
    let unread: Bool
    /// The agent's own conversation, whose line shows under the name; a paused or failed agent says so instead.
    var conversation: BotConversation?
    var line = ConversationRowDetail.standard

    var body: some View {
        let detail = conversation.map { model.rowDetail(for: $0, showing: line) } ?? model.phaseDetail(of: agent) ?? agent.publicDescription ?? ""
        SidebarItemRow(title: agent.displayName, detail: detail,
                       timestamp: conversation.map { SidebarTimestamp.text(for: $0.updatedAt) } ?? "",
                       pause: model.interruption(of: agent)) { size in
            AgentMark(agent: agent, size: size, phase: model.phase(of: agent))
        }
        .modifier(UnreadMark(unread: unread))
    }
}

extension RookModel: BotBudgetHost {}

extension RookModel: AttachmentOpeningHost {}

/// Noodle's patch review and document windows, one per attachment, kept for the whole app.
@MainActor let attachmentWindows = AttachmentWindows()

extension RookModel: AgentTaskHost {
    func taskAgentName(_ id: UUID) -> String? { agent(id)?.displayName }
    func taskAvatar(_ agent: AgentRecord) -> AnyView { AnyView(AgentMark(agent: agent, size: 22)) }
    func openConversation(for task: AgentTask, of agentID: UUID) { selection = conversationID(for: task, of: agentID) }
    func reportTaskError(_ message: String) { problem = message }
}
