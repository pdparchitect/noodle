import NoodleBrand
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleSettingsUI
import SwiftUI

/// Gives Noodle's shared Harness, Agents and Tools settings what they need from Pion.
@MainActor @Observable final class PionSettingsHost: BotSettingsHost {
    enum Tab: Hashable { case general, harnesses, agents, tools, permissions, updates }

    let model: PionModel
    let setup: HarnessSetupController
    let mcp: MCPController
    var selectedTab: Tab = .general
    var agentBeingEdited: AgentRecord?
    var agentEditorTab = AgentEditorTab.general

    init(model: PionModel) {
        self.model = model
        mcp = model.mcp
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
    func botProfileButton(_ agent: AgentRecord) -> AnyView {
        AnyView(Button { self.agentEditorTab = .general; self.agentBeingEdited = agent } label: { Image(systemName: "pencil") }
            .buttonStyle(.link).help("Edit Agent…").accessibilityLabel("Edit Agent…"))
    }
    func botRuntimeEditor(_ agent: AgentRecord) -> AnyView {
        AnyView(Button("Edit Runtime…") { self.agentEditorTab = .runtime; self.agentBeingEdited = agent }.buttonStyle(.link))
    }
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
            GeneralSettingsView()
                .settingsContentSize(width: Self.width)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(PionSettingsHost.Tab.general)
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
            // Noodle's own pane; Pion asks only for what dictation and capture need.
            PermissionsSettingsView(permissions: [.microphone, .screenRecording])
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
                .tag(PionSettingsHost.Tab.permissions)
            UpdatesSettingsView()
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
                .tag(PionSettingsHost.Tab.updates)
        }
        .onAppear { AppUpdater.shared.probeForUpdate() }
        .sheet(item: $host.agentBeingEdited) { agent in
            AgentEditorSheet(model: host.model, agent: host.model.agent(agent.id) ?? agent, initialTab: host.agentEditorTab)
        }
        .task { await host.setup.refreshAll(host.runtime) }
    }
}

/// Names for new agents and what the main window shows.
private struct GeneralSettingsView: View {
    @AppStorage(PionModel.agentNameStyleKey) private var nameStyle = PionModel.defaultAgentNameStyle.rawValue
    @AppStorage(SidebarOptions.showsClosedKey) private var showsClosed = false
    @AppStorage(BackdropEffect.key) private var effect = BackdropEffect.glyphs.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Generated agent names", selection: $nameStyle) {
                    Text("Generated").tag(BotNameStyle.playful.rawValue)
                    Text("Human").tag(BotNameStyle.real.rawValue)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("Background effect", selection: $effect) {
                    ForEach(BackdropEffect.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show closed Investigations in the sidebar", isOn: $showsClosed)
            }
        }
        .formStyle(.grouped)
    }
}
