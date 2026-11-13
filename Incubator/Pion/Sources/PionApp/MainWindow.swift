import NoodleCore
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
        } detail: {
            if let conversation = model.conversation(model.selection) {
                ConversationView(model: model, window: window, conversation: conversation)
                    .id(conversation.id)
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
        List(selection: $model.selection) {
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
                    SidebarHeader(title: "Investigations") { window.sheet = .newInvestigation }
                }
                // Closed ones only when asked for, a few at a time, to look back at.
                if showsClosed, !closed.isEmpty {
                    Section(isExpanded: $closedExpanded) {
                        ForEach(closed.prefix(closedLimit)) { investigation in
                            InvestigationRow(model: model, investigation: investigation).tag(investigation.id)
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
                        SidebarHeader(title: "Groups") { window.sheet = .newGroup }
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
                    SidebarHeader(title: "Agents") { window.sheet = .newAgent }
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
struct ConversationRowMenu: View {
    let model: PionModel
    let window: WindowState
    let conversation: BotConversation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open in New Window") { openWindow(id: "conversation", value: conversation.id) }
        Divider()
        Button(model.investigation(conversation.id) != nil ? "Edit Investigation…" : conversation.kind == .group ? "Edit Group…" : "Edit Agent…") {
            window.edit(conversation, in: model)
        }.disabled(model.investigation(conversation.id)?.isClosed == true)
        if conversation.kind == .direct {
            Divider()
            Button("Stop") { model.stop(in: conversation.id) }
                .disabled(model.stoppableAgent(in: conversation.id) == nil)
            if let agent = model.agent(conversation.participantIDs.first) {
                Button("Show Workspace in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.repository.directory(for: agent).path) }
            }
        }
    }
}

/// A section title with a plus that appears on hover, as in Finder's and Mail's sidebars.
struct SidebarHeader: View {
    let title: String
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
                .help("New \(title.dropLast())")
        }
        .onHover { hovering = $0 }
    }
}

struct InvestigationRow: View {
    let model: PionModel
    let investigation: Investigation

    var body: some View {
        let pending = model.pendingCount(investigation.id)
        let unread = model.isUnread(investigation.id)
        HStack(alignment: .top, spacing: 8) {
            SeverityGlyph(severity: investigation.severity, closed: investigation.isClosed)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(investigation.reference).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if pending > 0 {
                        Label("\(pending)", systemImage: "hand.raised.fill")
                            .font(.caption2.weight(.semibold)).labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange)
                            .help("\(pending) \(pending == 1 ? "action needs" : "actions need") your approval")
                    }
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
            Image(systemName: "person.3.fill").font(.callout).foregroundStyle(.secondary).frame(width: 20)
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
