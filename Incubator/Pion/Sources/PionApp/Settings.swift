import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleSettingsUI
import SwiftUI

/// Gives Noodle's shared Harness, Agents and Tools settings what they need from Pion.
@MainActor @Observable final class PionSettingsHost: BotSettingsHost {
    enum Tab: Hashable { case harnesses, agents, tools }

    let model: PionModel
    let setup: HarnessSetupController
    let mcp: MCPController
    var selectedTab: Tab = .harnesses

    init(model: PionModel) {
        self.model = model
        mcp = MCPController(repository: model.repository)
        setup = HarnessSetupController(versionChecker: HarnessVersionChecker(),
                                       installer: ManagedHarnessInstaller(store: model.repository.managedHarnesses),
                                       profiles: model.repository.harnessProfiles)
        setup.subscriptionUsage = model.runtime.subscriptionUsage
        model.harnessProfiles.onSignedIn = { [weak self] id in
            guard let self, let provider = self.harnessProfiles.profile(id)?.provider else { return }
            self.runtime.retryAfterSignIn(provider: provider, profile: id, agents: self.agents, repository: self.repository)
        }
        setup.onSignedIn = { [weak self] provider in
            guard let self else { return }
            self.runtime.retryAfterSignIn(provider: provider, profile: nil, agents: self.agents, repository: self.repository)
        }
        // An agent waiting for sign-in comes back by itself once its login works again.
        model.runtime.checkSignIn = { [weak self] agent in
            guard let self, let installation = self.runtime.installation(for: agent) else { return nil }
            guard self.runtime.runningHarness(for: agent.id) == nil,
                  let profile = try? self.repository.loadAgentHarnessProfile(agent) else {
                return await self.setup.signedIn(installation)
            }
            return await self.harnessProfiles.signedIn(profile, installation: installation)
        }
    }

    var runtime: AgentRuntimeCoordinator { model.runtime }
    var repository: WorkspaceRepository { model.repository }
    var harnessProfiles: HarnessProfilesController { model.harnessProfiles }
    var agents: [AgentRecord] { model.agents }

    func deleteHarnessProfile(_ profile: HarnessProfile) {
        let affected = agents.filter { (try? repository.loadAgentHarnessProfile($0)) == profile.id }
        for agent in affected { try? repository.updateAgentHarnessProfile(agent, profile: nil) }
        try? harnessProfiles.delete(profile)
        for agent in affected { runtime.restart(agent: agent, repository: repository) }
    }

    func showHarnessSettings() { selectedTab = .harnesses }
    func botProfileButton(_ agent: AgentRecord) -> AnyView { AnyView(EmptyView()) }
    func botRuntimeEditor(_ agent: AgentRecord) -> AnyView { AnyView(EmptyView()) }
    func canArchive(_ agent: AgentRecord) -> Bool { true }
    func setArchived(_ archived: Bool, agent: AgentRecord) {
        do {
            _ = try repository.setAgentArchived(archived, agentID: agent.id)
            if archived { runtime.stop(agentID: agent.id) }
            model.reload()
        } catch { model.problem = error.localizedDescription }
    }
    func refreshCompanionSkills() {}
    func openCompanionLibrary(_ app: CompanionApp) async throws {}
}

struct PionSettingsView: View {
    @Bindable var host: PionSettingsHost
    private static let width: CGFloat = 720

    var body: some View {
        SettingsTabView(selection: $host.selectedTab) {
            HarnessesSettingsView(store: host, setup: host.setup)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Harness", systemImage: "terminal") }
                .tag(PionSettingsHost.Tab.harnesses)
            BotsSettingsView(store: host, agents: host.agents)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Agents", systemImage: "person.2") }
                .tag(PionSettingsHost.Tab.agents)
            MCPSettingsView(store: host)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Tools", systemImage: "puzzlepiece.extension") }
                .tag(PionSettingsHost.Tab.tools)
        }
        .task { await host.setup.refreshAll(host.runtime) }
    }
}
