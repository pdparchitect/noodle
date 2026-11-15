import HubLink
import NoodleBrand
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleSettingsUI
import SwiftUI

/// Gives Noodle's shared Harness, Agents and Tools settings what they need from Pion.
@MainActor @Observable final class PionSettingsHost: BotSettingsHost {
    enum Tab: Hashable { case general, conversation, harnesses, agents, tools, permissions, updates }

    let model: PionModel
    let setup: HarnessSetupController
    let connectionsController: ToolConnectionsController
    var selectedTab: Tab = .general
    var agentBeingEdited: AgentRecord?
    var agentEditorTab = AgentEditorTab.general

    init(model: PionModel) {
        self.model = model
        connectionsController = model.connectionsController
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
    /// The agent's mark, opening its profile as Noodle's bot pictures do here.
    func botProfileButton(_ agent: AgentRecord) -> AnyView {
        AnyView(AgentProfileButton(model: model, agent: agent, size: 32, phase: model.phase(of: agent), opensMessageInWindow: true) {
            self.agentEditorTab = .general
            self.agentBeingEdited = self.model.agent(agent.id) ?? agent
        })
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
            GeneralSettingsView(model: host.model)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(PionSettingsHost.Tab.general)
            ConversationSettingsView()
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Conversation", systemImage: "bubble.left.and.bubble.right") }
                .tag(PionSettingsHost.Tab.conversation)
            HarnessesSettingsView(store: host, setup: host.setup)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Harness", systemImage: "terminal") }
                .tag(PionSettingsHost.Tab.harnesses)
            BotsSettingsView(store: host, agents: host.agents)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Agents", systemImage: "person.2") }
                .tag(PionSettingsHost.Tab.agents)
            ToolConnectionsSettingsView(store: host)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Tools", systemImage: "puzzlepiece.extension") }
                .tag(PionSettingsHost.Tab.tools)
            // Noodle's own pane; Pion asks only for what dictation, capture and notifications need.
            PermissionsSettingsView(permissions: [.microphone, .screenRecording, .notifications])
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

/// Noodle's Conversation settings, but for the received-message sound and floating conversations, which Pion
/// does not have.
private struct ConversationSettingsView: View {
    @AppStorage(ComposerNameCompletion.descriptionsDefaultsKey) private var showsDescriptions = true
    @AppStorage(WebLinkPreview.defaultsKey) private var previewsWebLinks = true

    var body: some View {
        Form {
            ConversationRuntimeSettingsSections()
            MicrophoneSettingsSection()
            Section {
                Toggle("Show descriptions in the @ name menu", isOn: $showsDescriptions)
            } footer: {
                Text("Show each agent's public description beside its name. Private backstories are never shown.")
            }
            Section {
                Toggle("Preview web links", isOn: $previewsWebLinks)
                    .help("Open web links in Quick Look first, with a button to continue in your browser. When off, links open in your browser.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Names for new agents, how groups notify and sleep while agents work. What the main window shows lives in the View menu.
private struct GeneralSettingsView: View {
    let model: PionModel
    private var runtime: AgentRuntimeCoordinator { model.runtime }
    @AppStorage(PionModel.agentNameStyleKey) private var nameStyle = PionModel.defaultAgentNameStyle.rawValue

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
                Picker("In groups, notify me for", selection: Binding(get: { model.groupNotifications },
                                                                      set: { model.groupNotifications = $0 })) {
                    Text("All messages").tag(LinkNotifications.all)
                    Text("Only when my name is mentioned").tag(LinkNotifications.mentions)
                }
                .help("Your name is your full name, or your first name alone. An agent's own conversation always notifies, and a group can have its own setting in its menu in the sidebar.")
            }
            Section {
                Toggle("Keep Mac awake while agents work", isOn: Binding(
                    get: { runtime.preventIdleSleepWhileWorking },
                    set: { runtime.configurePreventIdleSleepWhileWorking($0) }
                ))
            } footer: {
                Text("Prevents automatic idle sleep only while an agent is working. Closing the lid or choosing Sleep still suspends the Mac.")
            }
        }
        .formStyle(.grouped)
    }
}
