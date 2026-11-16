import AppKit
import BrowserBridge
import ComputerBridge
import HubLink
import SwiftUI
import NoodleCore
import NoodleRuntimeSettings

/// Deliberately uses only the public record, never the workspace/backstory.
struct AgentProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(NoodleStore.self) private var store
    let agent: AgentRecord
    let edit: () -> Void
    var canOpenDirectMessage = false
    var reply: (() -> Void)? = nil
    var directMessage: (() -> Void)? = nil

    var body: some View {
        ProfileCard(picture: AnyView(BotAvatar(agent: agent, size: 88)), name: agent.displayName, status: status,
                    description: ProfileCard.description(agent.publicDescription), actions: actions,
                    closeLabel: "Close bot profile") { dismiss() }
    }

    @MainActor private var status: AnyView? {
        if store.agents.first(where: { $0.id == agent.id })?.archivedAt != nil {
            return AnyView(ProfileStatusBadge(text: "Archived", faded: true))
        }
        guard let status = agent.status else { return nil }
        // Older than a heartbeat, the bot has had its chance to update it, so it may no longer hold.
        let stale = current.isStatusStale(after: TimeInterval(store.runtime.heartbeatConfiguration.intervalMinutes * 60))
        return AnyView(ProfileStatusBadge(text: status, faded: stale, setAt: current.statusSetAt)
            .accessibilityLabel("Status: \(status)"))
    }

    private var isShared: Bool { store.isShared(agent.id) }

    /// The bot as the store has it now, so Suspend and Unsuspend follow a change made here.
    private var current: AgentRecord { store.agents.first { $0.id == agent.id } ?? agent }

    /// The direct conversation a call would start in, while the bot can take one now and isn't already on it.
    private var callableConversation: BotConversation? {
        guard let direct = store.conversations.first(where: { $0.kind == .direct && $0.participantIDs == [agent.id] }),
              store.canCallNow(in: direct),
              store.voiceCalls.call?.conversationID != direct.id else { return nil }
        return direct
    }

    private var actions: [ProfileCardAction] {
        var actions: [ProfileCardAction] = []
        if let reply { actions.append(.button("Reply", systemImage: "arrowshape.turn.up.left", help: "Reply in Group", action: reply)) }
        if let directMessage {
            actions.append(.button("Message", systemImage: "bubble.left", help: "Direct Message", disabled: !canOpenDirectMessage,
                                   action: directMessage))
        }
        if let callable = callableConversation {
            actions.append(.button("Call", systemImage: "phone", help: "Call \(agent.displayName)") {
                store.startVoiceCall(in: callable)
                // The call's controls are in its conversation, so show it.
                if let directMessage { directMessage() } else { dismiss() }
            })
        }
        let computers = store.computers.assigned(to: agent)
        if !computers.isEmpty {
            actions.append(.custom("computer", CompanionOpenButton(title: "Computer", systemImage: "desktopcomputer",
                items: computers.map { CompanionAssignmentItem(id: $0.id, name: $0.name, state: $0.state,
                    symbol: $0.symbol, colour: $0.colour, icon: $0.icon) }) { id in
                try await store.computers.open(ComputerLink.url(computer: id, terminal: nil, view: nil))
            }))
        }
        let browsers = store.browsers.assigned(to: agent)
        if !browsers.isEmpty {
            actions.append(.custom("browser", CompanionOpenButton(title: "Browser", systemImage: "globe",
                items: browsers.map { CompanionAssignmentItem(id: $0.id, name: $0.name, state: $0.paused ? "Paused" : "Ready",
                    symbol: $0.symbol, colour: $0.colour, icon: $0.icon) }) { id in
                try await store.browsers.open(BrowserLink.url(browser: id, tab: nil))
            }))
        }
        // A bot someone shared is only talked with.
        if !isShared {
            actions.append(.button("Edit", systemImage: "pencil", help: "Edit Bot", action: edit))
            actions.append(.button("Usage", systemImage: "chart.bar", help: "Show Usage") {
                store.usage.agentFilter = agent.id
                openWindow(id: UsageView.windowID)
                dismiss()
            })
        }
        if current.archivedAt == nil, store.canSuspend(agent.id) {
            actions.append(.suspend(isSuspended: current.isSuspended(), noun: "Bot") { store.setSuspended(until: $0, agentID: agent.id) })
        }
        return actions
    }
}

/// Opens the bot's one computer or browser, or offers a choice when it has several.
private struct CompanionOpenButton: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NoodleStore.self) private var store
    let title: String
    let systemImage: String
    let items: [CompanionAssignmentItem]
    let open: (UUID) async throws -> Void
    @State private var choosing = false

    var body: some View {
        Button {
            if items.count == 1 { launch(items[0].id) } else { choosing.toggle() }
        } label: { ProfileActionLabel(title: title, systemImage: systemImage) }
        .help(items.count == 1 ? "Open \(items[0].name)" : "Open \(title)")
        .accessibilityLabel(items.count == 1 ? "Open \(items[0].name)" : "Open \(title)")
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    Button { launch(item.id) } label: {
                        HStack(spacing: 8) {
                            CompanionAssignmentAvatar(item: item, size: 22)
                            Text(item.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.tooltip)
                    .accessibilityLabel("Open \(item.name)")
                }
            }
            .padding(6)
            .frame(minWidth: 200, maxWidth: 280)
        }
    }

    private func launch(_ id: UUID) {
        choosing = false
        Task {
            do { try await open(id); dismiss() }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
}

/// A group's profile: what it is for and who is in it. `message` opens it from outside the conversation.
struct GroupProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NoodleStore.self) private var store
    let group: BotConversation
    let edit: () -> Void
    var message: (() -> Void)? = nil

    var body: some View {
        var actions: [ProfileCardAction] = []
        if let message {
            actions.append(.button("Message", systemImage: "bubble.left.and.bubble.right", help: "Open Conversation", action: message))
        }
        actions.append(.button("Edit", systemImage: "pencil", help: "Edit Group", action: edit))
        return ProfileCard(picture: AnyView(ConversationAvatar(participants: store.shownParticipants(for: group), isGroup: true, size: 88)),
                           name: store.title(for: group),
                           status: store.isArchived(group) ? AnyView(ProfileStatusBadge(text: "Archived", faded: true)) : nil,
                           description: ProfileCard.description(store.conversations.first { $0.id == group.id }?.publicDescription),
                           detail: store.participants(for: group).map(\.displayName).joined(separator: ", "),
                           actions: actions, closeLabel: "Close group profile") { dismiss() }
    }
}
