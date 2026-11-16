import HubLink
import NoodleBrand
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleSettingsUI
import PionCore
import SwiftUI

/// Gives Noodle's shared Harness, Agents and Tools settings what they need from Pion.
@MainActor @Observable final class PionSettingsHost: BotSettingsHost {
    enum Tab: Hashable { case general, conversation, harnesses, agents, groups, tools, keybindings, permissions, updates }

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
        model.runtime.connectSignIns(setup: setup, profiles: model.harnessProfiles, repository: model.repository) { [weak self] in
            self?.agents ?? []
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
    func setArchived(_ archived: Bool, agent: AgentRecord) { model.setArchived(archived, agentID: agent.id) }
    func refreshCompanionSkills() {}
    func openCompanionLibrary(_ app: CompanionApp) async throws {}
}

struct PionSettingsView: View {
    @Bindable var host: PionSettingsHost
    @ObservedObject private var appUpdater = AppUpdater.shared
    private let permissions = AppPermissionChecker.shared
    /// As Noodle's: wide enough for every tab in the toolbar, none left in its overflow menu.
    private static let width: CGFloat = 740

    var body: some View {
        SettingsTabView(selection: $host.selectedTab) {
            RuntimeGeneralSettings(member: "agent", nameStyleKey: PionModel.agentNameStyleKey,
                                   defaultNameStyle: PionModel.defaultAgentNameStyle,
                                   groupNotifications: Binding(get: { host.model.groupNotifications },
                                                                 set: { host.model.groupNotifications = $0 }), runtime: host.model.runtime)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(PionSettingsHost.Tab.general)
            ChatSettingsView(member: "agent")
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Conversation", systemImage: "bubble.left.and.bubble.right") }
                .tag(PionSettingsHost.Tab.conversation)
            HarnessesSettingsView(store: host, setup: host.setup)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Harness", systemImage: "terminal") }
                .tag(PionSettingsHost.Tab.harnesses)
            // Archived agents too, so one can be brought back.
            BotsSettingsView(store: host, agents: host.model.everyAgent)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Agents", systemImage: "sparkles") }
                .tag(PionSettingsHost.Tab.agents)
            GroupsSettingsView(model: host.model)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Groups", systemImage: "person.3") }
                .tag(PionSettingsHost.Tab.groups)
            ToolConnectionsSettingsView(store: host)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Tools", systemImage: "puzzlepiece.extension") }
                .tag(PionSettingsHost.Tab.tools)
            KeybindingsSettingsView(sections: [
                KeybindingsSection(title: "Conversations", actions: [PionShortcuts.newInvestigation, PionShortcuts.newGroup, PionShortcuts.newAgent,
                                                                     PionShortcuts.searchConversations,
                                                                     PionShortcuts.capture, PionShortcuts.recordVoice, PionShortcuts.call, PionShortcuts.stop]),
                KeybindingsSection(title: "Investigations", actions: [PionShortcuts.showInspector, PionShortcuts.closeInvestigation]),
                KeybindingsSection(title: "Annotations", actions: [PionShortcuts.annotateSelection, PionShortcuts.annotateRegion,
                                                                   PionShortcuts.saveAnnotation],
                                   footer: "Select conversation text to add an annotation, or annotate a region of the Pion window. The same shortcuts work in attachment previews. Escape cancels an annotation."),
            ])
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Keybindings", systemImage: "keyboard") }
                .tag(PionSettingsHost.Tab.keybindings)
            // Noodle's own pane; Pion asks only for what voice messages, capture and notifications need.
            PermissionsSettingsView(permissions: [.microphone, .screenRecording, .notifications])
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
                .tag(PionSettingsHost.Tab.permissions)
            UpdatesSettingsView()
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
                .tag(PionSettingsHost.Tab.updates)
        }
        .background(SettingsTabBadge(counts: ["Harness": host.harnessesNeedingAttention(host.setup),
                                              "Tools": host.toolsNeedingAttention,
                                              "Permissions": permissions.needingAttention,
                                              "Update": appUpdater.availableVersion == nil ? 0 : 1]))
        // Check on opening Settings so the tabs are badged before they are selected.
        .onAppear {
            appUpdater.probeForUpdate()
            permissions.refresh()
        }
        .sheet(item: $host.agentBeingEdited) { agent in
            AgentEditorSheet(model: host.model, agent: host.model.agent(agent.id) ?? agent, initialTab: host.agentEditorTab)
        }
        .task { await host.setup.refreshAll(host.runtime) }
    }
}

/// Noodle's Settings › Groups, with Pion's group mark; Investigations close rather than archive.
private struct GroupsSettingsView: View {
    let model: PionModel

    var body: some View {
        GroupsSettingsList(
            groups: model.groupsInSettings, members: "agents",
            picture: { _ in AnyView(SymbolMark(symbol: "person.3.fill", size: 32)) },
            subtitle: { group in
                group.participantIDs.compactMap { id in model.everyAgent.first { $0.id == id }?.displayName }.joined(separator: ", ")
            },
            archived: { group in Binding(get: { group.archivedAt != nil }, set: { model.setGroupArchived($0, id: group.id) }) })
    }
}
