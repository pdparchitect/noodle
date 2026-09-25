import AppKit
import HubCore
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleSettingsUI
import Observation
import SwiftUI

enum HubSettingsTab: Hashable {
    case harnesses, users, plans, heartbeats, sandbox, tools, companions, updates
}

/// Gives the shared Harness, Heartbeat and Sandbox settings what they need from the Hub.
/// The Hub has no bot profiles or bot editor yet, so those show the bot's avatar and nothing.
@MainActor @Observable final class HubSettingsHost: BotSettingsHost {
    let hub: Hub
    let setup: HarnessSetupController
    let mcp: MCPController
    var selectedTab: HubSettingsTab = .harnesses

    init(hub: Hub) {
        self.hub = hub
        mcp = MCPController(repository: hub.repository)
        setup = HarnessSetupController(versionChecker: HarnessVersionChecker(),
                                       installer: ManagedHarnessInstaller(store: hub.repository.managedHarnesses))
    }

    var runtime: AgentRuntimeCoordinator { hub.runtime }
    var repository: WorkspaceRepository { hub.repository }
    var harnessProfiles: HarnessProfilesController { hub.harnessProfiles }
    var agents: [AgentRecord] { (try? hub.repository.loadAgents()) ?? [] }

    func deleteHarnessProfile(_ profile: HarnessProfile) {
        let affected = agents.filter { (try? repository.loadAgentHarnessProfile($0)) == profile.id }
        for agent in affected { try? repository.updateAgentHarnessProfile(agent, profile: nil) }
        try? harnessProfiles.delete(profile)
        hub.access.removeProfile(profile.id)
        for agent in affected { runtime.restart(agent: agent, repository: repository) }
    }

    func showHarnessSettings() { selectedTab = .harnesses }
    func botProfileButton(_ agent: AgentRecord) -> AnyView { AnyView(BotAvatar(agent: agent, size: 32)) }
    func botRuntimeEditor(_ agent: AgentRecord) -> AnyView { AnyView(EmptyView()) }

    /// The Hub does not publish companion skills to bots yet.
    func refreshCompanionSkills() {}

    /// The Hub does not connect to companions yet, so it opens the installed app itself.
    func openCompanionLibrary(_ app: CompanionApp) async throws {
        guard let installation = CompanionApp.installedApps()[app] else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: installation.applicationURL, configuration: configuration)
    }

    func openComputerDownload() async throws { NSWorkspace.shared.open(CompanionApp.computer.documentationURL) }
}

struct HubSettingsView: View {
    @Bindable var host: HubSettingsHost
    @ObservedObject private var updater = HubUpdater.shared
    private let companionUpdates = CompanionUpdateChecker.shared

    private var harnessesNeedingAttention: Int {
        HarnessProvider.allCases.filter { id in
            host.setup.needsAttention(id) || host.agents.contains {
                let snapshot = host.runtime.snapshot(for: $0.id)
                return $0.harnessIdentifier == id.rawValue && snapshot.canKick && snapshot.phase == .failed
            }
        }.count
    }

    /// Tools whose row shows Needs attention.
    private var toolsNeedingAttention: Int {
        host.mcp.registry.connections.filter { host.mcp.errors[$0.id] != nil }.count
    }

    var body: some View {
        TabView(selection: $host.selectedTab.animation(.easeInOut(duration: 0.22))) {
            HarnessesSettingsView(store: host, setup: host.setup)
                .hubSettingsSize()
                .tabItem { Label("Harness", systemImage: "terminal") }
                .tag(HubSettingsTab.harnesses)
            HubUsersSettingsView(host: host)
                .hubSettingsSize()
                .tabItem { Label("Users", systemImage: "person.2") }
                .tag(HubSettingsTab.users)
            HubPlansSettingsView(host: host)
                .hubSettingsSize()
                .tabItem { Label("Plans", systemImage: "rectangle.stack.badge.person.crop") }
                .tag(HubSettingsTab.plans)
            HeartbeatsSettingsView(store: host)
                .hubSettingsSize()
                .tabItem { Label("Heartbeat", systemImage: "waveform.path.ecg") }
                .tag(HubSettingsTab.heartbeats)
            AgentAccessSettingsView(store: host)
                .hubSettingsSize()
                .tabItem { Label("Sandbox", systemImage: "lock.shield") }
                .tag(HubSettingsTab.sandbox)
            MCPSettingsView(store: host)
                .hubSettingsSize()
                .tabItem { Label("Tools", systemImage: "puzzlepiece.extension") }
                .tag(HubSettingsTab.tools)
            CompanionAppsSettingsView(store: host)
                .hubSettingsSize()
                .tabItem { Label("Companions", systemImage: "square.stack.3d.up") }
                .tag(HubSettingsTab.companions)
            HubUpdatesSettingsView()
                .hubSettingsSize()
                .tabItem { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
                .tag(HubSettingsTab.updates)
        }
        .modifier(SettingsWindowResizeAnchor())
        .settingsScrollIndicators(selection: host.selectedTab)
        .background(SettingsTabBadge(counts: ["Harness": harnessesNeedingAttention,
                                              "Tools": toolsNeedingAttention,
                                              "Companions": companionUpdates.updates.count,
                                              "Update": updater.availableVersion == nil ? 0 : 1]))
        // Check on opening Settings so the tabs are badged before they are selected.
        .onAppear {
            companionUpdates.refresh(CompanionApp.installedApps())
            updater.probeForUpdate()
        }
        .task { await host.setup.refreshAll(host.runtime) }
    }
}

private struct SettingsWindowResizeAnchor: ViewModifier {
    func body(content: Content) -> some View {
        content.windowResizeAnchor(.top)
    }
}

private extension View {
    /// The same pane width as Noodle's settings.
    func hubSettingsSize() -> some View {
        frame(width: 680).fixedSize(horizontal: false, vertical: true)
    }
}
