import AppKit
import BrowserBridge
import ComputerBridge
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
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close bot profile")
            }
            BotAvatar(agent: agent, size: 88)
            Text(agent.displayName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if store.agents.first(where: { $0.id == agent.id })?.archivedAt != nil {
                Text("Archived")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            } else if let status = agent.status {
                Text(status)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("Status: \(status)")
            }
            ScrollView {
                Text(description)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 120)
            HStack(spacing: 8) {
                if let reply {
                    Button(action: reply) {
                        actionLabel("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .help("Reply in Group")
                    .accessibilityLabel("Reply in Group")
                    Divider().frame(height: 32).accessibilityHidden(true)
                }
                if let directMessage {
                    Button(action: directMessage) {
                        actionLabel("Message", systemImage: "bubble.left")
                    }
                    .disabled(!canOpenDirectMessage)
                    .help("Direct Message")
                    .accessibilityLabel("Direct Message")
                    Divider().frame(height: 32).accessibilityHidden(true)
                }
                let computers = store.computers.assigned(to: agent)
                if !computers.isEmpty {
                    CompanionOpenButton(title: "Computer", systemImage: "desktopcomputer",
                        items: computers.map { CompanionAssignmentItem(id: $0.id, name: $0.name, state: $0.state,
                            symbol: $0.symbol, colour: $0.colour, icon: $0.icon) },
                        label: actionLabel) { id in
                        try await store.computers.open(ComputerLink.url(computer: id, terminal: nil, view: nil))
                    }
                    Divider().frame(height: 32).accessibilityHidden(true)
                }
                let browsers = store.browsers.assigned(to: agent)
                if !browsers.isEmpty {
                    CompanionOpenButton(title: "Browser", systemImage: "globe",
                        items: browsers.map { CompanionAssignmentItem(id: $0.id, name: $0.name, state: $0.paused ? "Paused" : "Ready",
                            symbol: $0.symbol, colour: $0.colour, icon: $0.icon) },
                        label: actionLabel) { id in
                        try await store.browsers.open(BrowserLink.url(browser: id, tab: nil))
                    }
                    Divider().frame(height: 32).accessibilityHidden(true)
                }
                // A bot someone shared is only talked with.
                if !isShared {
                    Button(action: edit) {
                        actionLabel("Edit", systemImage: "pencil")
                    }
                    .help("Edit Bot")
                    .accessibilityLabel("Edit Bot")
                    Divider().frame(height: 32).accessibilityHidden(true)
                    Button {
                        store.usage.agentFilter = agent.id
                        openWindow(id: UsageView.windowID)
                        dismiss()
                    } label: {
                        actionLabel("Usage", systemImage: "chart.bar")
                    }
                    .help("Show Usage")
                    .accessibilityLabel("Show Usage")
                }
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        // Four actions fit the usual width; each companion button adds room so labels stay whole.
        .frame(width: max(320, 40 + CGFloat(actionCount) * 70))
        .background(ProfileOutsideClickDismissal { dismiss() })
    }

    private var isShared: Bool { store.isShared(agent.id) }

    private var actionCount: Int {
        [reply != nil, directMessage != nil, !store.computers.assigned(to: agent).isEmpty,
         !store.browsers.assigned(to: agent).isEmpty].filter { $0 }.count + (isShared ? 0 : 2)
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        ProfileActionLabel(title: title, systemImage: systemImage)
    }

    private var description: String {
        let value = agent.publicDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "No description yet." : value
    }
}

/// Opens the bot's one computer or browser, or offers a choice when it has several.
private struct CompanionOpenButton<Label: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(NoodleStore.self) private var store
    let title: String
    let systemImage: String
    let items: [CompanionAssignmentItem]
    let label: (String, String) -> Label
    let open: (UUID) async throws -> Void
    @State private var choosing = false

    var body: some View {
        Button {
            if items.count == 1 { launch(items[0].id) } else { choosing.toggle() }
        } label: { label(title, systemImage) }
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
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close group profile")
            }
            ConversationAvatar(participants: store.shownParticipants(for: group), isGroup: true, size: 88)
            Text(store.title(for: group))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if store.isArchived(group) {
                Text("Archived")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
            ScrollView {
                VStack(spacing: 8) {
                    Text(description)
                        .foregroundStyle(.secondary)
                    Text(store.participants(for: group).map(\.displayName).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 120)
            HStack(spacing: 8) {
                if let message {
                    Button(action: message) { ProfileActionLabel(title: "Message", systemImage: "bubble.left.and.bubble.right") }
                        .help("Open Conversation")
                        .accessibilityLabel("Open Conversation")
                    Divider().frame(height: 32).accessibilityHidden(true)
                }
                Button(action: edit) { ProfileActionLabel(title: "Edit", systemImage: "pencil") }
                    .help("Edit Group")
                    .accessibilityLabel("Edit Group")
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 320)
        .background(ProfileOutsideClickDismissal { dismiss() })
    }

    private var description: String {
        let value = store.conversations.first { $0.id == group.id }?.publicDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "No description yet." : value
    }
}

/// One of the actions along the bottom of a bot's or group's profile.
struct ProfileActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .frame(height: 20)
            Text(title)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// Informational profiles can be dismissed without a decision. Keep this local
/// to the profile: clicking outside an editor must not discard unsaved changes.
struct ProfileOutsideClickDismissal: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> DismissalView { DismissalView() }

    func updateNSView(_ view: DismissalView, context: Context) {
        view.dismiss = dismiss
    }

    static func dismantleNSView(_ view: DismissalView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class DismissalView: NSView {
        var dismiss: (() -> Void)?
        private var mouseMonitor: Any?
        private var deactivationObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let outside = MainActor.assumeIsolated {
                    guard let self, let sheet = self.window, let parent = sheet.sheetParent,
                          event.window === parent else { return false }
                    let point = parent.convertPoint(toScreen: event.locationInWindow)
                    guard !sheet.frame.contains(point) else { return false }
                    self.dismiss?()
                    return true
                }
                // Dismiss only; don't activate whatever was behind the sheet.
                return outside ? nil : event
            }
            deactivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss?() }
            }
        }

        func stopMonitoring() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
            mouseMonitor = nil
            deactivationObserver = nil
        }
    }
}
