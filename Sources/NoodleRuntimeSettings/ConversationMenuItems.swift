import HubWire
import NoodleCore
import NoodleRuntime
import SwiftUI

/// A group's Notifications choice in its menu, in every app: the default, named after what it is now, or all
/// messages, mentions only, or muted.
public struct NotificationsPicker: View {
    let chosen: Binding<LinkNotifications>
    let defaultIsMentions: Bool

    public init(chosen: Binding<LinkNotifications>, defaultIsMentions: Bool) {
        self.chosen = chosen
        self.defaultIsMentions = defaultIsMentions
    }

    public var body: some View {
        Picker("Notifications", selection: chosen) {
            Text(defaultIsMentions ? "Default (Mentions Only)" : "Default (All Messages)").tag(LinkNotifications.default)
            Text("All Messages").tag(LinkNotifications.all)
            Text("Mentions Only").tag(LinkNotifications.mentions)
            Text("Muted").tag(LinkNotifications.muted)
        }
    }
}

/// A bot's housekeeping in its conversation's menu, in every app: looking at what it did and where it works, then
/// Organize, and Kick and New Session. Kick shows only for a bot that failed or runs on a fallback harness, which
/// Kick takes back to its own.
public struct AgentHousekeepingItems: View {
    let agent: AgentRecord
    let runtime: AgentRuntimeCoordinator
    let repository: WorkspaceRepository
    let showActivity: () -> Void
    /// Narrows the Usage window to the bot before it opens.
    let filterUsage: () -> Void
    let revealWorkspace: () -> Void
    let kick: (AgentKickRequest?) -> Void
    let newSession: () -> Void
    @Environment(\.openWindow) private var openWindow

    public init(agent: AgentRecord, runtime: AgentRuntimeCoordinator, repository: WorkspaceRepository,
                showActivity: @escaping () -> Void, filterUsage: @escaping () -> Void, revealWorkspace: @escaping () -> Void,
                kick: @escaping (AgentKickRequest?) -> Void, newSession: @escaping () -> Void) {
        self.agent = agent
        self.runtime = runtime
        self.repository = repository
        self.showActivity = showActivity
        self.filterUsage = filterUsage
        self.revealWorkspace = revealWorkspace
        self.kick = kick
        self.newSession = newSession
    }

    public var body: some View {
        Button("Show Activity", action: showActivity)
        Button("Show Usage") {
            filterUsage()
            openWindow(id: UsageView.windowID)
        }
        Button("Show Workspace in Finder", action: revealWorkspace)
        Divider()
        Button("Organize") { runtime.organize(agent.id) }
            .disabled(!runtime.canOrganize(agent.id))
        Divider()
        if runtime.snapshot(for: agent.id).phase == .failed || runtime.runningHarness(for: agent.id) != nil {
            Button("Kick") { kick(runtime.kick(agent: agent, repository: repository)) }
                .disabled(runtime.changingAccess.contains(agent.id))
        }
        Button("New Session", action: newSession)
            .disabled(runtime.changingAccess.contains(agent.id))
    }
}
