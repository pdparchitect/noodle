import AppKit
import SwiftUI
import NoodleCore

struct SidebarView: View {
    @Environment(NoodleStore.self) private var store
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selectedConversationID) {
            if !store.directConversations.isEmpty {
                Section("Bots") {
                    ForEach(store.directConversations) { conversation in
                        ConversationRow(conversation: conversation)
                            .tag(conversation.id)
                            .contextMenu {
                                if let agent = store.participants(for: conversation).first {
                                    Button("Edit Bot") {
                                        store.agentBeingEdited = agent
                                    }
                                    Button("Show Workspace in Finder") {
                                        store.revealWorkspace(for: agent)
                                    }
                                }
                                Button("Change Background…") { store.backgroundBeingEdited = conversation }
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
                                Button("Edit Group…") { store.groupBeingEdited = conversation }
                                Button("Change Background…") { store.backgroundBeingEdited = conversation }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
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
            store.draft = ""
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
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .opacity(store.hasUnreadMessages(in: conversation) ? 1 : 0)
                    .accessibilityHidden(true)
            }

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

                Text(hasPendingApproval ? "Waiting for your response" : store.preview(for: conversation))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 66)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
        .listRowSeparator(.visible, edges: .bottom)
        .listRowSeparatorTint(Color.primary.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var timestamp: String {
        if Calendar.current.isDateInToday(conversation.updatedAt) {
            conversation.updatedAt.formatted(date: .omitted, time: .shortened)
        } else {
            conversation.updatedAt.formatted(date: .abbreviated, time: .omitted)
        }
    }

    private var runtimeColor: Color {
        if hasPendingApproval { return .orange }
        let phases = store.participants(for: conversation).map { store.runtime.snapshot(for: $0.id).phase }
        if phases.contains(.working) { return .blue }
        if phases.contains(.failed) { return .red }
        if !phases.isEmpty, phases.allSatisfy({ $0 == .ready }) { return .green }
        return .gray
    }

    private var accessibilityLabel: String {
        let unread = store.hasUnreadMessages(in: conversation) ? "Unread, " : ""
        return "\(unread)\(store.title(for: conversation)), \(hasPendingApproval ? "Waiting for your response" : store.preview(for: conversation))"
    }

    private var hasPendingApproval: Bool {
        store.runtime.approvals.contains { conversation.participantIDs.contains($0.agentID) }
    }
}
