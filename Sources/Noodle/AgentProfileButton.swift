import SwiftUI
import NoodleCore
import NoodleRuntimeSettings

/// Shares avatar, profile, and editor behavior across settings and group drafts.
struct AgentProfileButton: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let agent: AgentRecord
    var size: CGFloat = 32
    var showsShadow = false
    var opensMessageInSeparateWindow = false
    @State private var showsProfile = false
    @State private var pendingAction: ProfileAction?
    @State private var editingAgent: AgentRecord?

    private enum ProfileAction {
        case message, edit
    }

    private var directConversation: BotConversation? {
        store.conversations.first { $0.kind == .direct && $0.participantIDs == [agent.id] }
    }

    var body: some View {
        Button { showsProfile = true } label: {
            BotAvatar(agent: agent, size: size, showsShadow: showsShadow)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Show \(agent.displayName)’s profile")
        .accessibilityLabel("Show profile for \(agent.displayName)")
        .popover(isPresented: $showsProfile, arrowEdge: .leading) {
            AgentProfileSheet(
                agent: agent,
                edit: { dismissProfile(for: .edit) },
                canOpenDirectMessage: directConversation != nil,
                directMessage: { dismissProfile(for: .message) }
            )
            .onDisappear(perform: finishProfileAction)
        }
        .sheet(item: $editingAgent) { agent in
            EditBotSheet(agent: agent)
                .environment(store)
                .noodleSheetSizing(animated: true)
                .modifier(ConversationErrorAlert())
        }
    }

    private func dismissProfile(for action: ProfileAction) {
        pendingAction = action
        showsProfile = false
    }

    private func finishProfileAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        // Allow the popover to detach before presenting an editor or focusing a chat.
        DispatchQueue.main.async {
            switch action {
            case .message:
                guard let conversation = directConversation else { return }
                if opensMessageInSeparateWindow || !store.conversationWindows.focus(conversation.id) {
                    openWindow(id: "conversation", value: conversation.id)
                }
            case .edit:
                editingAgent = store.agents.first { $0.id == agent.id }
            }
        }
    }
}
