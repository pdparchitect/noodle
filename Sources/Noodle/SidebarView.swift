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
        if !store.conversations.isEmpty && store.filteredConversations.isEmpty {
            if store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A space with nothing in it yet.
                ContentUnavailableView("No Bots", systemImage: "square.stack")
            } else {
                ContentUnavailableView.search(text: store.searchText)
            }
        }
    }
}

private struct SidebarList: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ConversationOrder.key) private var conversationOrder = ConversationOrder.standard.rawValue
    @AppStorage(SidebarRowDetail.key) private var rowDetail = SidebarRowDetail.standard.rawValue
    @AppStorage(SidebarStyle.key) private var style = SidebarStyle.standard.rawValue
    @Binding var kickRequest: AgentKickRequest?
    @Binding var newSessionAgent: AgentRecord?
    let searchIsFocused: Bool
    let focusComposer: () -> Void
    let focusRequest: UUID?

    var body: some View {
        @Bindable var store = store

        let showsIcons = SidebarStyle(rawValue: style) == .icons
        let sections = store.sidebarSections(ConversationOrder(rawValue: conversationOrder) ?? .standard,
                                             separatingNeedsYou: showsIcons)
        Group {
            if showsIcons {
                // Not a list: in a list a whole grid is one row, which gives every picture the first one's menu.
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        grid("Needs You", sections.needsYou)
                        grid("Pinned", sections.pinned)
                        grid("Unread", sections.unread)
                        grid("Bots", sections.bots)
                        grid("Groups", sections.groups)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            } else {
                List(selection: Binding(get: { store.selectedConversationID }, set: { id in
                    // A conversation clicked starts in its input; one reached with the arrow keys leaves the list focused.
                    // Asked here, since the views showing it learn of the selection only after the click.
                    let clicked = NSApp.currentEventIsClick
                    if id != store.selectedConversationID { store.selectedConversationID = id }
                    if clicked, id != nil { DispatchQueue.main.async(execute: focusComposer) }
                })) {
                    section("Pinned", sections.pinned)
                    section("Unread", sections.unread)
                    section("Bots", sections.bots)
                    section("Groups", sections.groups)
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

    @ViewBuilder
    private func section(_ title: String, _ conversations: [BotConversation]) -> some View {
        if !conversations.isEmpty {
            Section(title) {
                ForEach(conversations) { conversation in
                    ConversationRow(conversationID: conversation.id, isGroup: conversation.kind == .group,
                        isSelected: store.selectedConversationID == conversation.id,
                        content: ConversationRowContent(conversation, store: store, detail: SidebarRowDetail(rawValue: rowDetail) ?? .standard))
                        .equatable()
                        // Outside the equatable row, where the list can see them.
                        .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 10))
                        .listRowSeparator(.visible, edges: .bottom)
                        .listRowSeparatorTint(Color.primary.opacity(0.12))
                        .tag(conversation.id)
                        .contextMenu { menu(for: conversation) }
                }
            }
        }
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
            IconGridLayout {
                ForEach(conversations) { conversation in
                    ConversationIcon(conversationID: conversation.id, isGroup: conversation.kind == .group,
                        isSelected: store.selectedConversationID == conversation.id,
                        content: ConversationRowContent(conversation, store: store, detail: SidebarRowDetail(rawValue: rowDetail) ?? .standard))
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
            Picker("Notifications", selection: Binding(
                get: { store.chosenNotifications(of: conversation.id) ?? .default },
                set: { store.setNotifications($0, conversationID: conversation.id) })) {
                Text(store.defaultNotifications(of: conversation.id) == .mentions ? "Default (Mentions Only)" : "Default (All Messages)")
                    .tag(LinkNotifications.default)
                Text("All Messages").tag(LinkNotifications.all)
                Text("Mentions Only").tag(LinkNotifications.mentions)
                Text("Muted").tag(LinkNotifications.muted)
            }
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
                Button("Show Activity") { store.showActivity(for: agent) }
                Button("Show Usage") {
                    store.usage.agentFilter = agent.id
                    openWindow(id: UsageView.windowID)
                }
                Button("Show Workspace in Finder") {
                    store.revealWorkspace(for: agent)
                }
                Divider()
                Button("Organize") { store.runtime.organize(agent.id) }
                    .disabled(!store.runtime.canOrganize(agent.id))
                Divider()
                // Kick also takes a bot on a fallback harness back to its own.
                if store.runtime.snapshot(for: agent.id).phase == .failed || store.runtime.runningHarness(for: agent.id) != nil {
                    Button("Kick") {
                        kickRequest = store.runtime.kick(agent: agent, repository: store.repository)
                    }
                    .disabled(store.runtime.changingAccess.contains(agent.id))
                }
                Button("New Session") { newSessionAgent = agent }
                    .disabled(store.runtime.changingAccess.contains(agent.id))
            }
        }
        switch conversation.kind {
        case .group:
            Divider()
            Button("Archive Group") { store.setArchived(true, conversationID: conversation.id) }
        case .direct:
            if let agent = store.participants(for: conversation).first, !store.isShared(agent.id) {
                Divider()
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

    @MainActor init(_ conversation: BotConversation, store: NoodleStore, detail: SidebarRowDetail) {
        participants = store.shownParticipants(for: conversation)
        title = store.title(for: conversation)
        timestamp = SidebarTimestamp.text(for: conversation.updatedAt)
        pause = store.pauseSummary(for: conversation)
        self.detail = store.sidebarDetail(for: conversation, showing: detail)
        runtimeStatus = store.runtimeStatus(for: conversation)
        runtimeHelp = store.runtimeHelp(for: conversation)
        isUnread = store.hasUnreadMessages(in: conversation)
        isMuted = store.isMuted(conversation.id)
    }
}

private struct ConversationRow: View, Equatable {
    @Environment(NoodleStore.self) private var store
    @State private var isDropTargeted = false
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
        // A file dropped here goes to this conversation; the row shows where it will land.
        .background {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.25))
                    .padding(.horizontal, -6)
                    .accessibilityHidden(true)
            }
        }
        .onDrop(of: AttachmentTransfer.dropContentTypes, isTargeted: $isDropTargeted) { providers in
            store.drop(providers, onConversation: conversationID)
        }
        .overlay(alignment: .leading) {
            if content.isUnread {
                // A muted group's dot is dimmed: new replies show, but do not ask for attention.
                Circle()
                    .fill(content.isMuted ? Color.secondary.opacity(0.5) : Color.blue)
                    .frame(width: 8, height: 8)
                    // Keep the dot in the leading inset, 5 points before the avatar.
                    .offset(x: -13)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
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

/// The icon view's grid: as many columns of at least 96 points as fit, each row as tall as its tallest picture.
/// Every picture is laid out, unlike a lazy grid, which in a list row only ever drew those first on screen.
private struct IconGridLayout: Layout {
    private let minimumWidth: CGFloat = 96, columnSpacing: CGFloat = 6, rowSpacing: CGFloat = 8

    private struct Grid {
        let columns: Int, itemWidth: CGFloat, rowHeights: [CGFloat]
    }

    private func grid(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Grid {
        // Asked for its smallest or largest size, it is one column or one row.
        let width = width(proposal, subviews)
        let columns = max(1, Int((width + columnSpacing) / (minimumWidth + columnSpacing)))
        let itemWidth = max(0, (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns))
        let rowHeights = stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height }.max() ?? 0
        }
        return Grid(columns: columns, itemWidth: itemWidth, rowHeights: rowHeights)
    }

    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        guard let width = proposal.width else { return minimumWidth }
        guard width.isFinite else { return CGFloat(subviews.count) * (minimumWidth + columnSpacing) - columnSpacing }
        return width
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let grid = grid(proposal, subviews)
        let height = grid.rowHeights.reduce(0, +) + rowSpacing * CGFloat(max(0, grid.rowHeights.count - 1))
        return CGSize(width: width(proposal, subviews), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let grid = grid(ProposedViewSize(width: bounds.width, height: nil), subviews)
        var y = bounds.minY
        for (row, height) in grid.rowHeights.enumerated() {
            for column in 0..<grid.columns {
                let index = row * grid.columns + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (grid.itemWidth + columnSpacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: grid.itemWidth, height: height))
            }
            y += height + rowSpacing
        }
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
                    // A muted group's dot is dimmed, as in the list.
                    Circle()
                        .fill(content.isMuted ? Color.secondary.opacity(0.5) : Color.blue)
                        .frame(width: 10, height: 10)
                        .padding(2)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                        .offset(x: -2, y: -2)
                        .accessibilityHidden(true)
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

/// What the line under each sidebar row's name shows.
enum SidebarRowDetail: String, CaseIterable, Identifiable {
    case latestMessage, description, status

    static let key = "sidebarRowDetail"
    static let standard = Self.latestMessage
    var id: String { rawValue }

    var name: String {
        switch self {
        case .latestMessage: "Latest Message"
        case .description: "Description"
        case .status: "Status"
        }
    }
}

/// How the sidebar shows bots and groups: as rows, or as a grid of their pictures.
enum SidebarStyle: String, CaseIterable, Identifiable {
    case list, icons

    static let key = "sidebarStyle"
    static let standard = Self.list
    var id: String { rawValue }

    var name: String {
        switch self {
        case .list: "As List"
        case .icons: "As Icons"
        }
    }
}
