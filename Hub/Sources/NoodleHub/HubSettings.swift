import AppKit
import HubCore
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleSettingsUI
import Observation
import SwiftUI

enum HubSettingsTab: Hashable {
    case harnesses, users, plans, bots, groups, conversation, network, tools, companions, updates
}

/// Gives the shared Harness and Bots settings what they need from the Hub.
/// The Hub has no bot editor yet; a bot's profile holds its folder, activity and New Session.
@MainActor @Observable final class HubSettingsHost: BotSettingsHost {
    let hub: Hub
    let setup: HarnessSetupController
    let mcp: MCPController
    var selectedTab: HubSettingsTab = .network
    /// Why archiving a bot or group failed, shown until dismissed.
    var problem: String?
    let activityWindows = AgentActivityWindows()

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
    func botProfileButton(_ agent: AgentRecord) -> AnyView { AnyView(HubBotProfileButton(host: self, agent: agent)) }
    func botRuntimeEditor(_ agent: AgentRecord) -> AnyView { AnyView(EmptyView()) }
    func canArchive(_ agent: AgentRecord) -> Bool { true }
    func setArchived(_ archived: Bool, agent: AgentRecord) { setArchived(archived, id: agent.id) }

    /// For the bot's or group's owner, on all their devices.
    func setArchived(_ archived: Bool, id: UUID) {
        do { try hub.bots.setArchived(archived, id: id) } catch { problem = error.localizedDescription }
    }

    /// Gives the Hub's bots Noodle Applet's skill as soon as it is installed.
    func refreshCompanionSkills() { hub.bots.applets.refreshSkills() }

    func openCompanionLibrary(_ app: CompanionApp) async throws {
        guard let installation = CompanionApp.installedApps()[app] else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: installation.applicationURL, configuration: configuration)
    }
}

struct HubSettingsView: View {
    /// Tools configures connections the way Noodle does, but the Hub's bots use the ones their
    /// owners add from Noodle, so its tab stays out of Settings.
    static let showsAgentSettings = false

    @Bindable var host: HubSettingsHost
    @ObservedObject private var updater = HubUpdater.shared
    private let companionUpdates = CompanionUpdateChecker.shared

    private var harnessesNeedingAttention: Int {
        HarnessProvider.allCases.filter { id in
            host.runtime.harnesses.isOn(id) && (host.setup.needsAttention(id) || host.agents.contains {
                let snapshot = host.runtime.snapshot(for: $0.id)
                return $0.harnessIdentifier == id.rawValue && snapshot.canKick && snapshot.phase == .failed
            })
        }.count
    }

    /// Tools whose row shows Needs attention.
    private var toolsNeedingAttention: Int {
        host.mcp.registry.connections.filter { host.mcp.errors[$0.id] != nil }.count
    }

    private var networkNeedsAttention: Bool {
        if case .failed = host.hub.link.state { return true }
        return false
    }

    var body: some View {
        TabView(selection: $host.selectedTab.animation(.easeInOut(duration: 0.22))) {
            HubNetworkSettingsView(link: host.hub.link)
                .hubSettingsSize()
                .tabItem { Label("Network", systemImage: "network") }
                .tag(HubSettingsTab.network)
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
            // Bots come and go from paired devices, so the list is reread while it is open.
            TimelineView(.periodic(from: .now, by: 2)) { _ in BotsSettingsView(store: host, agents: host.agents) }
                .hubSettingsSize()
                .tabItem { Label("Bots", systemImage: "sparkles") }
                .tag(HubSettingsTab.bots)
            HubGroupsSettingsView(host: host)
                .hubSettingsSize()
                .tabItem { Label("Groups", systemImage: "person.3") }
                .tag(HubSettingsTab.groups)
            HubConversationSettingsView()
                .hubSettingsSize()
                .tabItem { Label("Conversation", systemImage: "bubble.left.and.bubble.right") }
                .tag(HubSettingsTab.conversation)
            if Self.showsAgentSettings {
                MCPSettingsView(store: host)
                    .hubSettingsSize()
                    .tabItem { Label("Tools", systemImage: "puzzlepiece.extension") }
                    .tag(HubSettingsTab.tools)
            }
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
        .alert("Could Not Archive", isPresented: Binding(get: { host.problem != nil }, set: { if !$0 { host.problem = nil } })) {
            Button("OK") { host.problem = nil }
        } message: {
            Text(host.problem ?? "")
        }
        .background(SettingsTabBadge(counts: ["Harness": harnessesNeedingAttention,
                                              "Tools": Self.showsAgentSettings ? toolsNeedingAttention : 0,
                                              "Network": networkNeedsAttention ? 1 : 0,
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

/// Noodle's Conversation settings that apply to the bots the Hub runs; the rest are about how
/// conversations look, which the Hub does not show.
struct HubConversationSettingsView: View {
    var body: some View {
        Form {
            ConversationRuntimeSettingsSections()
        }
        .formStyle(.grouped)
    }
}
