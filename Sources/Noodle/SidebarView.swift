import AppKit
import SwiftUI
import NoodleCore

struct SidebarView: View {
    var focusComposer: () -> Void = {}
    var focusRequest: UUID? = nil
    @Environment(NoodleStore.self) private var store
    @FocusState private var searchIsFocused: Bool
    @State private var kickRequest: AgentKickRequest?

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedConversationID) {
            if !store.directConversations.isEmpty {
                Section("Bots") {
                    ForEach(store.directConversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation.id)
                            .contextMenu {
                                // How a window is opened decides its mode, so this also docks a floating one.
                                Button("Open in New Window") { store.dockConversation(conversation.id) }
                                Button("Float on Top") { store.floatConversation(conversation.id) }
                                Divider()
                                if let agent = store.participants(for: conversation).first {
                                    Button("Edit Bot") {
                                        store.agentBeingEdited = agent
                                    }
                                }
                                Button("Change Background…") { store.backgroundBeingEdited = conversation }
                                if let agent = store.participants(for: conversation).first {
                                    Divider()
                                    Button("Show Activity") { store.showActivity(for: agent) }
                                    Button("Show Workspace in Finder") {
                                        store.revealWorkspace(for: agent)
                                    }
                                    if store.runtime.snapshot(for: agent.id).phase == .failed {
                                        Divider()
                                        Button("Kick") {
                                            kickRequest = store.runtime.kick(agent: agent, repository: store.repository)
                                        }
                                        .disabled(store.runtime.changingAccess.contains(agent.id))
                                    }
                                }
                            }
                    }
                }
            }

            if !store.groupConversations.isEmpty {
                Section("Groups") {
                    ForEach(store.groupConversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation.id)
                            .contextMenu {
                                // How a window is opened decides its mode, so this also docks a floating one.
                                Button("Open in New Window") { store.dockConversation(conversation.id) }
                                Button("Float on Top") { store.floatConversation(conversation.id) }
                                Divider()
                                Button("Edit Group…") { store.groupBeingEdited = conversation }
                                Button("Change Background…") { store.backgroundBeingEdited = conversation }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .modifier(AgentKickConfirmation(request: $kickRequest))
        .scrollContentBackground(.hidden)
        .modifier(ConversationListKeyboardNavigation(
            hasSelection: store.selectedConversationID != nil,
            searchIsFocused: searchIsFocused,
            focusComposer: focusComposer,
            focusRequest: focusRequest
        ))
        .background(Color.black.opacity(0.24).ignoresSafeArea())
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search")
        .controlSize(.large)
        .searchFocused($searchIsFocused)
        .overlay {
            if !store.conversations.isEmpty && store.filteredConversations.isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            }
        }
        .onChange(of: store.selectedConversationID) { _, conversationID in
            store.markConversationRead(conversationID)
        }
        .onAppear {
            store.markSelectedConversationReadIfVisible()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.markSelectedConversationReadIfVisible()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchIsFocused = true
        }
    }
}

private struct ConversationRow: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                ConversationAvatar(
                    participants: store.participants(for: conversation),
                    isGroup: conversation.kind == .group,
                    size: 42
                )
                Circle()
                    .fill(runtimeColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
            }
            .help(runtimeHelp)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(store.title(for: conversation))
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(timestamp)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }

                Text(store.preview(for: conversation))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 66)
        .overlay(alignment: .leading) {
            if store.hasUnreadMessages(in: conversation) {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
                    // Keep the dot in the leading inset, 5 points before the avatar.
                    .offset(x: -13)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 10))
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(Color.primary.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(runtimeHelp)
    }

    private var timestamp: String {
        if Calendar.current.isDateInToday(conversation.updatedAt) {
            conversation.updatedAt.formatted(date: .omitted, time: .shortened)
        } else {
            conversation.updatedAt.formatted(date: .abbreviated, time: .omitted)
        }
    }

    private var runtimeColor: Color { store.runtimeStatus(for: conversation).color }

    private var runtimeHelp: String { store.runtimeHelp(for: conversation) }

    private var accessibilityLabel: String {
        let unread = store.hasUnreadMessages(in: conversation) ? "Unread, " : ""
        return "\(unread)\(store.title(for: conversation)), \(store.preview(for: conversation))"
    }
}
