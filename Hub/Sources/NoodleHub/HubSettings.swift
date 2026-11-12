import AppKit
import HubCore
import HubMac
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleSettingsUI
import Observation
import SwiftUI

enum HubSettingsTab: Hashable {
    case harnesses, users, plans, bots, groups, conversation, network, tools, companions, updates
}

/// What failed in Settings, shown in an alert until dismissed.
struct HubSettingsProblem: Equatable {
    let title: String
    let message: String
}

/// Gives the shared Harness and Bots settings what they need from the Hub.
/// The Hub has no bot editor yet; a bot's profile holds its folder, activity and New Session.
@MainActor @Observable final class HubSettingsHost: BotSettingsHost {
    let hub: Hub
    let setup: HarnessSetupController
    let mcp: MCPController
    var selectedTab: HubSettingsTab = .network
    /// Why archiving a bot or group, or changing a bot's model, failed, shown until dismissed.
    var problem: HubSettingsProblem?
    let activityWindows = AgentActivityWindows()

    init(hub: Hub) {
        self.hub = hub
        mcp = MCPController(repository: hub.repository)
        setup = HarnessSetupController(versionChecker: HarnessVersionChecker(),
                                       installer: ManagedHarnessInstaller(store: hub.repository.managedHarnesses),
                                       profiles: hub.repository.harnessProfiles)
        setup.subscriptionUsage = hub.runtime.subscriptionUsage
        hub.harnessProfiles.onSignedIn = { [weak self] id in
            guard let self, let provider = self.harnessProfiles.profile(id)?.provider else { return }
            self.runtime.retryAfterSignIn(provider: provider, profile: id, agents: self.agents, repository: self.repository)
        }
        setup.onSignedIn = { [weak self] provider in
            guard let self else { return }
            self.runtime.retryAfterSignIn(provider: provider, profile: nil, agents: self.agents, repository: self.repository)
        }
        // Lets a bot waiting for sign-in come back by itself once its login works again.
        hub.runtime.checkSignIn = { [weak self] agent in
            guard let self, let installation = self.runtime.installation(for: agent) else { return nil }
            guard self.runtime.runningHarness(for: agent.id) == nil,
                  let profile = try? self.repository.loadAgentHarnessProfile(agent) else {
                return await self.setup.signedIn(installation)
            }
            return await self.harnessProfiles.signedIn(profile, installation: installation)
        }
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

    func botProblem(_ agent: AgentRecord) -> AnyView? {
        hub.bots.unlentModel(of: agent).map { AnyView(HubUnlentModelLabel(host: self, bot: $0)) }
    }

    /// For the bot's or group's owner, on all their devices.
    func setArchived(_ archived: Bool, id: UUID) {
        do { try hub.bots.setArchived(archived, id: id) } catch {
            problem = HubSettingsProblem(title: "Could Not Archive", message: error.localizedDescription)
        }
    }

    /// Suspends a bot until then, or unsuspends it when nil, for its owner, on all their devices.
    func setSuspended(until: Date?, id: UUID) {
        do { try hub.bots.setSuspended(until: until, id: id) } catch {
            problem = HubSettingsProblem(title: "Could Not Suspend", message: error.localizedDescription)
        }
    }

    /// Ends the turn a bot is working on, for its owner, and says so in their conversation with it.
    func stop(id: UUID) {
        do { try hub.bots.stop(id) } catch {
            problem = HubSettingsProblem(title: "Could Not Stop", message: error.localizedDescription)
        }
    }

    func modelName(_ model: String, on harness: HubHarness) -> String {
        runtime.models(for: harness.provider.rawValue, profile: harness.profile).first { $0.id == model }?.displayName ?? model
    }

    /// Moves each bot to `model`, for its owner, on all their devices; returns why one could not move.
    func changeModel(of bots: [HubUnlentModel], to model: String) -> String? {
        var failure: String?
        for bot in bots {
            do { try hub.bots.changeModel(of: bot.id, to: model) } catch { failure = error.localizedDescription }
        }
        return failure
    }

    /// Gives the Hub's bots Noodle Applet's skill as soon as it is installed.
    func refreshCompanionSkills() { hub.applets.refreshSkills() }

    func openCompanionLibrary(_ app: CompanionApp) async throws {
        guard let installation = CompanionApp.installedApps()[app] else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: installation.applicationURL, configuration: configuration)
    }
}

/// The Hub's built-in tools, shared by every person's bots. Connections are each person's own,
/// added from their devices, so they are not listed here.
struct HubToolsSettingsView: View {
    let hub: Hub
    var body: some View {
        ImageGenerationSettingsRow(controller: hub.imageGeneration)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            .padding(20)
    }
}

struct HubSettingsView: View {
    /// Tools configures connections the way Noodle does, but the Hub's bots use the ones their
    /// owners add from Noodle, so the Hub's tab shows only its built-in tools.
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
        SettingsTabView(selection: $host.selectedTab) {
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
            } else {
                HubToolsSettingsView(hub: host.hub)
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
        .alert(host.problem?.title ?? "", isPresented: Binding(get: { host.problem != nil }, set: { if !$0 { host.problem = nil } })) {
            Button("OK") { host.problem = nil }
        } message: {
            Text(host.problem?.message ?? "")
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


private extension View {
    /// The same pane width as Noodle's settings.
    func hubSettingsSize() -> some View {
        settingsContentSize(width: 680)
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
