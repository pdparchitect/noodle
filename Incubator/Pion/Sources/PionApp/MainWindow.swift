import AppKit
import HubWire
import NoodleCore
import NoodleRuntimeSettings
import PionCore
import SwiftUI

/// The sidebar of Investigations, groups and agents beside the conversation that is selected.
struct MainWindow: View {
    let model: PionModel
    @Bindable var window: WindowState

    var body: some View {
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
                    Label("Set Up Your Team", systemImage: "person.2")
                } description: {
                    Text("Investigations are worked by agents. Create your first one.")
                } actions: {
                    Button("New Agent") { window.sheet = .newAgent }
                }
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "shield.lefthalf.filled")
            }
        }
        // As in Noodle: the toolbar draws no band of its own over the content beneath it.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .modifier(ConversationSheets(model: model, window: window, selection: $model.selection))
        .onOpenURL { _ = model.mcp.receiveAuthorizationCallback($0) }
        .focusedSceneValue(\.pionConversation, ConversationCommandContext(selection: $model.selection, window: window,
            search: { window.searchFocusRequest = UUID() }))
        .alert("Something Went Wrong", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK") { model.problem = nil }
        } message: {
            Text(model.problem ?? "")
        }
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

    var body: some View {
        @Bindable var model = model
        let active = model.investigations.filter { !$0.isClosed }
            .sorted { ($0.severity, $0.updatedAt) > ($1.severity, $1.updatedAt) }
        let closed = model.investigations.filter(\.isClosed).sorted { $0.updatedAt > $1.updatedAt }
        List(selection: Binding(get: { model.selection }, set: { id in
            window.selectedFromKeyboard = NSApp.currentEvent?.type == .keyDown
            model.selection = id
        })) {
            if !window.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ForEach(model.searchConversations(window.searchText)) { conversation in
                    ConversationChoiceRow(model: model, conversation: conversation).tag(conversation.id)
                        .contextMenu { ConversationRowMenu(model: model, window: window, conversation: conversation) }
                }
            } else {
                Section {
                    ForEach(active) { investigation in
                        InvestigationRow(model: model, investigation: investigation).tag(investigation.id)
                            .contextMenu {
                                if let conversation = model.conversation(investigation.id) {
                                    ConversationRowMenu(model: model, window: window, conversation: conversation)
                                }
                            }
                    }
                } header: {
                    Text("Investigations")
                }
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
                if !model.groups.isEmpty {
                    Section {
                        ForEach(model.groups) { group in
                            GroupRow(model: model, group: group).tag(group.id)
                                .contextMenu { ConversationRowMenu(model: model, window: window, conversation: group) }
                        }
                    } header: {
                        Text("Groups")
                    }
                }
                Section {
                    ForEach(model.agents) { agent in
                        if let direct = model.directConversation(of: agent) {
                            AgentRow(model: model, agent: agent, unread: model.isUnread(direct.id)).tag(direct.id)
                                .contextMenu { ConversationRowMenu(model: model, window: window, conversation: direct) }
                        }
                    }
                } header: {
                    Text("Agents")
                }
            }
        }
        .listStyle(.sidebar)
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
        Button("Open in New Window") { openWindow(id: "conversation", value: conversation.id) }
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
            Picker("Severity", selection: Binding(get: { investigation.severity }, set: { model.setSeverity($0, of: investigation) })) {
                ForEach(Investigation.Severity.allCases.reversed(), id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(closed)
        }
        Divider()
        if let agent {
            Button("Show Activity") { model.showActivity(for: agent) }
            Button("Show Workspace in Finder") { model.reveal(conversation) }
        } else {
            Button("Show in Finder") { model.reveal(conversation) }
        }
        if let investigation {
            Button("Export Investigation…") { model.exportInvestigation(investigation) }
        }
        Divider()
        if agent != nil {
            Button("Stop") { model.stop(in: conversation.id) }
                .disabled(model.stoppableAgent(in: conversation.id) == nil)
        }
        if let agent { SuspendAgentMenu(model: model, agent: agent) }
        if let investigation {
            if closed {
                Button("Reopen") { model.setStatus(.open, of: investigation) }
            } else {
                Button("Close Investigation…") { window.sheet = .close(investigation) }
            }
        } else if let agent {
            Button("Archive Agent") { model.archive(agent) }
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

    func archive(_ group: BotConversation) {
        do {
            _ = try repository.setConversationArchived(true, conversationID: group.id)
            if selection == group.id { selection = nil }
            reload()
        } catch { problem = error.localizedDescription }
    }
}

struct InvestigationRow: View {
    let model: PionModel
    let investigation: Investigation

    var body: some View {
        let unread = model.isUnread(investigation.id)
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

    var body: some View {
        let members = model.members(of: group)
        let unread = model.isUnread(group.id)
        HStack(spacing: 8) {
            SymbolMark(symbol: "person.3.fill", size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.displayName).font(.callout.weight(unread ? .semibold : .regular)).lineLimit(1)
                Text(members.map(\.displayName).formatted(.list(type: .and)))
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

    var body: some View {
        let phase = model.phase(of: agent)
        HStack(spacing: 8) {
            AgentMark(agent: agent, size: 22, phase: phase)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName).font(.callout.weight(unread ? .semibold : .regular))
                if let detail = model.phaseDetail(of: agent) ?? agent.publicDescription {
                    Text(detail).font(.caption).foregroundStyle(phase == .failed ? Color.red : Color.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
