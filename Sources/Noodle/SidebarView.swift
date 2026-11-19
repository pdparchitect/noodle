import AppKit
import SwiftUI
import HubLink
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings

struct SidebarView: View {
    var focusComposer: () -> Void = {}
    var focusRequest: UUID? = nil
    @Environment(NoodleStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchIsFocused: Bool
    @State private var kickRequest: AgentKickRequest?
    @State private var newSessionAgent: AgentRecord?

    var body: some View {
        @Bindable var store = store

        // The rows are read in a view of their own: this one carries the search field, a toolbar item
        // that AppKit lays out again whenever this body runs.
        SidebarList(kickRequest: $kickRequest, newSessionAgent: $newSessionAgent, searchIsFocused: searchIsFocused,
            focusComposer: focusComposer, focusRequest: focusRequest)
        .modifier(AgentKickConfirmation(store: store, request: $kickRequest))
        .modifier(NewSessionConfirmation(store: store, agent: $newSessionAgent))
        .scrollContentBackground(.hidden)
        .background(Color.black.opacity(colorScheme == .dark ? 0.24 : 0.04).ignoresSafeArea())
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search")
        .controlSize(.large)
        .searchFocused($searchIsFocused)
        .overlay { SidebarEmptyState() }
        .onAppear {
            store.markSelectedConversationReadIfVisible()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.markSelectedConversationReadIfVisible()
            store.fetchSpaces()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchIsFocused = true
        }
    }

}

private struct SidebarEmptyState: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        if let search = store.sidebarSearch {
            if search.isEmpty { ContentUnavailableView.search(text: store.searchText) }
        } else if !store.conversations.isEmpty && store.filteredConversations.isEmpty {
            // A space with nothing in it yet.
            ContentUnavailableView("No Bots", systemImage: "square.stack")
        }
    }
}

private struct SidebarList: View {
    @Environment(NoodleStore.self) private var store
    @AppStorage(ConversationOrder.key) private var conversationOrder = ConversationOrder.standard.rawValue
    @AppStorage(ConversationRowDetail.key) private var rowDetail = ConversationRowDetail.standard.rawValue
    @AppStorage(ConversationListStyle.key) private var style = ConversationListStyle.standard.rawValue
    @AppStorage(TaskListFilter.key) private var taskFilter = TaskListFilter.standard
    @AppStorage(SidebarTools.key) private var showsTools = false
    @Binding var kickRequest: AgentKickRequest?
    @Binding var newSessionAgent: AgentRecord?
    let searchIsFocused: Bool
    let focusComposer: () -> Void
    let focusRequest: UUID?
    var body: some View {
        @Bindable var store = store

        let showsIcons = ConversationListStyle(rawValue: style) == .icons
        let sections = store.sidebarSections(ConversationOrder(rawValue: conversationOrder) ?? .standard)
        Group {
            if let search = store.sidebarSearch {
                searchResults(search)
            } else if showsIcons {
                // Not a list: in a list a whole grid is one row, which gives every picture the first one's menu.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        SidebarTasks(store: store, filter: taskFilter, inList: false)
                        grid("Pinned", sections.pinned)
                        grid("Unread", sections.unread)
                        grid("Bots", sections.bots)
                        grid("Groups", sections.groups)
                        if showsTools { SidebarTools(controller: store.connectionsController, inList: false) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            } else {
                List(selection: Binding(get: { store.selectedConversationID }, set: select)) {
                    SidebarTasks(store: store, filter: taskFilter, inList: true)
                    section("Pinned", sections.pinned)
                    section("Unread", sections.unread)
                    section("Bots", sections.bots)
                    section("Groups", sections.groups)
                    if showsTools { SidebarTools(controller: store.connectionsController, inList: true) }
                }
                .listStyle(.sidebar)
            }
        }
        .modifier(ConversationListKeyboardNavigation(
            hasSelection: store.selectedConversationID != nil,
            searchIsFocused: searchIsFocused,
            focusComposer: focusComposer,
            focusRequest: focusRequest
        ))
        .onChange(of: store.selectedConversationID) { _, conversationID in
            store.markConversationRead(conversationID)
        }
    }

    /// A conversation clicked starts in its input; one reached with the arrow keys leaves the list focused.
    /// Asked here, since the views showing it learn of the selection only after the click.
    private func select(_ id: UUID?) {
        let clicked = NSApp.currentEventIsClick
        if id != store.selectedConversationID { store.selectedConversationID = id }
        if clicked, id != nil { DispatchQueue.main.async(execute: focusComposer) }
    }

    /// One list, whichever style the sidebar has: the bots and groups that match, then each message that does.
    private func searchResults(_ search: NoodleStore.SidebarSearch) -> some View {
        SidebarSearchResults(
            sections: [("Bots", search.bots), ("Groups", search.groups)],
            mentions: search.mentions, hiddenMentions: search.hiddenMentions, term: ConversationSearch(store.searchText),
            selection: store.selectedConversationID, select: select,
            pickMessage: { match in
                select(match.conversationID)
                store.revealMessage(match.messageID, in: match.conversationID)
            },
            showAll: { store.showsAllMentions = true },
            conversation: { id in store.conversations.first { $0.id == id } },
            mentionPicture: { AnyView(ConversationAvatar(participants: store.shownParticipants(for: $0), isGroup: $0.kind == .group, size: 42)) },
            mentionTitle: { store.title(for: $0) },
            row: { conversationRow($0) },
            menu: { menu(for: $0) })
    }

    @ViewBuilder
    private func section(_ title: String, _ conversations: [BotConversation]) -> some View {
        if !conversations.isEmpty {
            Section(title) {
                ForEach(conversations) { conversation in
                    conversationRow(conversation)
                        .tag(conversation.id)
                        .contextMenu { menu(for: conversation) }
                }
            }
        }
    }

    private func conversationRow(_ conversation: BotConversation) -> some View {
        ConversationRow(conversationID: conversation.id, isGroup: conversation.kind == .group,
            isSelected: store.selectedConversationID == conversation.id,
            content: ConversationRowContent(conversation, store: store, detail: ConversationRowDetail(rawValue: rowDetail) ?? .standard))
            .equatable()
            // Outside the equatable row, where the list can see them.
            .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 10))
            .listRowSeparator(.visible, edges: .bottom)
            .listRowSeparatorTint(Color.primary.opacity(0.12))
    }

    /// A section as a grid of pictures under its title, set like a list's section header.
    @ViewBuilder
    private func grid(_ title: String, _ conversations: [BotConversation]) -> some View {
        if !conversations.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 10)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ConversationIconGrid {
                ForEach(conversations) { conversation in
                    ConversationIcon(conversationID: conversation.id, isGroup: conversation.kind == .group,
                        isSelected: store.selectedConversationID == conversation.id,
                        content: ConversationRowContent(conversation, store: store, detail: ConversationRowDetail(rawValue: rowDetail) ?? .standard))
                        .equatable()
                        // Like a row clicked: selected, and its input focused.
                        .onTapGesture {
                            store.selectedConversationID = conversation.id
                            DispatchQueue.main.async(execute: focusComposer)
                        }
                        .contextMenu { menu(for: conversation) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func menu(for conversation: BotConversation) -> some View {
        // How a window is opened decides its mode, so this also docks a floating one.
        Button("Open in New Window") { store.dockConversation(conversation.id) }
        Button("Float on Top") { store.floatConversation(conversation.id) }
        Divider()
        if store.isPinned(conversation.id) {
            Button("Unpin") { store.setPinned(false, conversationID: conversation.id) }
        } else {
            Button("Pin") { store.setPinned(true, conversationID: conversation.id) }
        }
        if store.canNotifyMentions(conversation) {
            NotificationsPicker(chosen: Binding(
                get: { store.chosenNotifications(of: conversation.id) ?? .default },
                set: { store.setNotifications($0, conversationID: conversation.id) }),
                defaultIsMentions: store.defaultNotifications(of: conversation.id) == .mentions)
        } else if store.canMute(conversation) {
            if store.isMuted(conversation.id) {
                Button("Unmute") { store.setMuted(false, conversationID: conversation.id) }
            } else {
                Button("Mute") { store.setMuted(true, conversationID: conversation.id) }
            }
        }
        Menu("Spaces") {
            ForEach(store.customSpaces) { space in
                Toggle(space.name, isOn: Binding(get: { store.isMember(conversation.id, of: space.id) },
                                                 set: { store.setMember($0, of: space.id, conversationID: conversation.id) }))
            }
            if !store.customSpaces.isEmpty { Divider() }
            Button("New Space…") { store.spaceNaming = .init(adding: conversation.id) }
        }
        Divider()
        switch conversation.kind {
        case .group:
            Button("Edit Group…") { store.groupBeingEdited = conversation }
            Button("Change Background…") { store.backgroundBeingEdited = conversation }
        case .direct:
            if let agent = store.participants(for: conversation).first, !store.isShared(agent.id) {
                Button("Edit Bot…") {
                    store.agentBeingEdited = agent
                }
            }
            Button("Change Background…") { store.backgroundBeingEdited = conversation }
            if let agent = store.participants(for: conversation).first, store.runsHere(agent.id) {
                Divider()
                AgentHousekeepingItems(agent: agent, runtime: store.runtime, repository: store.repository,
                    showActivity: { store.showActivity(for: agent) }, filterUsage: { store.usage.agentFilter = agent.id },
                    revealWorkspace: { store.revealWorkspace(for: agent) }, kick: { kickRequest = $0 },
                    newSession: { newSessionAgent = agent })
            }
        }
        switch conversation.kind {
        case .group:
            Divider()
            Button("Archive Group") { store.setArchived(true, conversationID: conversation.id) }
        case .direct:
            if let agent = store.participants(for: conversation).first, !store.isShared(agent.id) {
                Divider()
                if store.canStop(agent.id) { Button("Stop") { store.stop(agentID: agent.id) } }
                if store.canSuspend(agent.id) { SuspendBotMenu(agent: agent) }
                Button("Archive Bot") { store.setArchived(true, agentID: agent.id) }
            }
        }
    }
}

/// What a sidebar row shows. The list works it out, so a message or a status change redraws only the rows it changes.
private struct ConversationRowContent: Equatable {
    var participants: [AgentRecord]
    var title: String
    var timestamp: String
    var pause: String?
    var detail: String
    var runtimeStatus: ConversationRuntimeStatus
    var runtimeHelp: String
    var isUnread: Bool
    var isMuted: Bool

    @MainActor init(_ conversation: BotConversation, store: NoodleStore, detail: ConversationRowDetail) {
        participants = store.shownParticipants(for: conversation)
        title = store.title(for: conversation)
        timestamp = SidebarTimestamp.text(for: conversation.updatedAt)
        pause = store.sidebarPauseSummary(for: conversation)
        self.detail = store.sidebarDetail(for: conversation, showing: detail)
        runtimeStatus = store.runtimeStatus(for: conversation)
        runtimeHelp = store.runtimeHelp(for: conversation)
        isUnread = store.hasUnreadMessages(in: conversation)
        isMuted = store.isMuted(conversation.id)
    }
}

private struct ConversationRow: View, Equatable {
    @Environment(NoodleStore.self) private var store
    let conversationID: UUID
    let isGroup: Bool
    /// Not drawn by the row, but the list's selection look reaches it only when the row is updated.
    let isSelected: Bool
    let content: ConversationRowContent

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.conversationID == b.conversationID && a.isGroup == b.isGroup && a.isSelected == b.isSelected && a.content == b.content
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                ConversationAvatar(
                    participants: content.participants,
                    isGroup: isGroup,
                    size: 42
                )
                .runtimeLook(content.runtimeStatus, size: 42)
                if content.runtimeStatus.hasMark {
                    RuntimeStatusMark(status: content.runtimeStatus, size: 10)
                        .padding(2)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .padding(-2)
                }
            }
            .help(runtimeHelp)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(content.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(timestamp)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }

                // In place of the preview's first line, so the row keeps its height.
                if let pause {
                    Text(pause)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(pause == nil ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 66)
        .conversationDropTarget { store.drop($0, onConversation: conversationID) }
        .overlay(alignment: .leading) {
            if content.isUnread {
                // Kept in the leading inset, 5 points before the avatar.
                UnreadDot(isMuted: content.isMuted).offset(x: -13)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(runtimeHelp)
    }

    private var timestamp: String { content.timestamp }
    private var runtimeHelp: String { content.runtimeHelp }
    private var pause: String? { content.pause }
    private var detail: String { content.detail }

    private var accessibilityLabel: String {
        let unread = content.isUnread ? "Unread, " : ""
        let muted = content.isMuted ? "Muted, " : ""
        let paused = pause.map { "\($0), " } ?? ""
        return "\(unread)\(muted)\(content.title), \(paused)\(detail)"
    }
}

/// A bot or group in the sidebar's icon view: its picture, name and a short line on what it is doing.
private struct ConversationIcon: View, Equatable {
    @Environment(NoodleStore.self) private var store
    @State private var isDropTargeted = false
    let conversationID: UUID
    let isGroup: Bool
    let isSelected: Bool
    let content: ConversationRowContent

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.conversationID == b.conversationID && a.isGroup == b.isGroup && a.isSelected == b.isSelected && a.content == b.content
    }

    var body: some View {
        let label = SidebarIconLabel(pause: content.pause, status: content.runtimeStatus, detail: content.detail)
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                ConversationAvatar(participants: content.participants, isGroup: isGroup, size: 60)
                    .runtimeLook(content.runtimeStatus, size: 60)
                if content.runtimeStatus.hasMark {
                    RuntimeStatusMark(status: content.runtimeStatus, size: 12)
                        .padding(2)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .padding(-2)
                }
            }
            .overlay(alignment: .topLeading) {
                if content.isUnread {
                    UnreadDot(isMuted: content.isMuted, size: 10, ringed: true).offset(x: -2, y: -2)
                }
            }
            .help(content.runtimeHelp)
            .padding(.top, 4)

            Text(content.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Text(label.text)
                .font(.system(size: 10.5, weight: label.tone == .detail ? .regular : .medium))
                .foregroundStyle(label.tone.style)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28, alignment: .top)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background {
            if isSelected || isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(isDropTargeted ? 0.25 : 0.18))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        // A file dropped here goes to this conversation, as on a row.
        .onDrop(of: AttachmentTransfer.dropContentTypes, isTargeted: $isDropTargeted) { providers in
            store.drop(providers, onConversation: conversationID)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(label))
        .accessibilityValue(content.runtimeHelp)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func accessibilityLabel(_ label: SidebarIconLabel) -> String {
        let unread = content.isUnread ? "Unread, " : ""
        let muted = content.isMuted ? "Muted, " : ""
        return "\(unread)\(muted)\(content.title), \(label.text)"
    }
}

/// The short line under a picture in the icon view: why its bot waits, that it is working, or else the row's line.
struct SidebarIconLabel: Equatable {
    enum Tone {
        case attention, working, detail

        var style: AnyShapeStyle {
            switch self {
            case .attention: AnyShapeStyle(.orange)
            case .working: AnyShapeStyle(Color.accentColor)
            case .detail: AnyShapeStyle(.secondary)
            }
        }
    }

    var text: String
    var tone: Tone

    init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    init(pause: String?, status: ConversationRuntimeStatus, detail: String) {
        if let pause { self.init(text: pause, tone: .attention) }
        else if status == .working { self.init(text: "Working", tone: .working) }
        else { self.init(text: detail, tone: .detail) }
    }
}



/// View › Sidebar › Space Picker: the shown space in the sidebar's toolbar, beside the window's buttons, to
/// switch without the Spaces menu. The toolbar shows it only while there is more than one space.
struct SidebarSpacePicker: View {
    static let key = "sidebarSpacePicker"
    @Environment(NoodleStore.self) private var store

    var body: some View {
        let choices = store.spaceChoices
        Menu {
            SpaceChoiceItems(store: store, choices: choices)
            Divider()
            SpaceEditingItems(store: store)
        } label: {
            HStack(spacing: 4) {
                Text(choices.first { $0.choice == store.shownSpace }?.title ?? "All")
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Space")
    }
}
