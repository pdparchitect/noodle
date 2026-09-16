import SwiftUI
import NoodleCore

/// Keeps a settings group compact while allowing rows with wrapped status or
/// error text to use their full height inside the scrollable area.
struct SettingsBotList<Row: View>: View {
    let agents: [AgentRecord]
    @ViewBuilder var row: (AgentRecord) -> Row

    private let scrollIndicatorGutter: CGFloat = 20

    var body: some View {
        SettingsBotListLayout {
            ViewThatFits(in: .vertical) {
                rows
                ScrollView {
                    rows
                        .padding(.trailing, scrollIndicatorGutter)
                }
                .scrollBounceBehavior(.basedOnSize)
                // Extend the scrollbar into the form's trailing margin while
                // keeping the rows aligned with the other settings controls.
                .padding(.trailing, -scrollIndicatorGutter)
            }
        }
        .toggleStyle(.switch)
    }

    private var rows: some View {
        VStack(spacing: 10) {
            ForEach(agents) { agent in
                row(agent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if agent.id != agents.last?.id {
                    Divider()
                }
            }
        }
    }
}

/// Reuses the chat profile and editor without leaving Settings to inspect a bot.
struct SettingsBotProfileButton: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let agent: AgentRecord
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
            BotAvatar(agent: agent, size: 32, showsShadow: false)
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
                if !store.conversationWindows.focus(conversation.id) {
                    openWindow(id: "conversation", value: conversation.id)
                }
            case .edit:
                editingAgent = store.agents.first { $0.id == agent.id }
            }
        }
    }
}

/// Propose the height limit during measurement, including when the Settings
/// window asks for its ideal size. No later state update should resize the tab.
private struct SettingsBotListLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: 360))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
