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
    @ObservedObject private var appUpdater = AppUpdater.shared
    private let permissions = AppPermissionChecker.shared
    /// As Noodle's: wide enough for every tab in the toolbar, none left in its overflow menu.
    private static let width: CGFloat = 740

    /// Harnesses whose row asks for attention, or whose agents failed and can be kicked, as Noodle counts them.
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
        host.connectionsController.registry.connections.filter { host.connectionsController.errors[$0.id] != nil }.count
    }

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
        .background(SettingsTabBadge(counts: ["Harness": harnessesNeedingAttention,
                                              "Tools": toolsNeedingAttention,
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

/// Every group with an Archived switch, as Noodle's Settings > Groups; Investigations close rather than archive.
private struct GroupsSettingsView: View {
    let model: PionModel
    @State private var showsArchiveInfo = false
    private let archivedColumnWidth: CGFloat = 64

    var body: some View {
        let groups = model.groupsInSettings
        Form {
            Section {
                if groups.isEmpty {
                    Text("No groups").foregroundStyle(.secondary)
                } else {
                    SettingsRowList(groups) { group in row(group) }
                }
            } header: {
                if !groups.isEmpty {
                    HStack {
                        Spacer(minLength: 0)
                        Button("Archived") { showsArchiveInfo.toggle() }
                            .buttonStyle(.plain)
                            .accessibilityLabel("About archiving")
                            .help("About archiving")
                            .frame(width: archivedColumnWidth)
                            .popover(isPresented: $showsArchiveInfo) { GroupArchiveInfo() }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ group: BotConversation) -> some View {
        let members = group.participantIDs.compactMap { id in model.everyAgent.first { $0.id == id }?.displayName }
            .joined(separator: ", ")
        return HStack(spacing: 12) {
            SymbolMark(symbol: "person.3.fill", size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                if !members.isEmpty {
                    Text(members).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: Binding(get: { group.archivedAt != nil }, set: { model.setGroupArchived($0, id: group.id) })) {
                Text("Archived")
            }
            .labelsHidden()
            .controlSize(.mini)
            .accessibilityLabel("\(group.displayName), archived")
            .frame(width: archivedColumnWidth)
        }
    }
}

private struct GroupArchiveInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archived").font(.headline)
            Text("An archived group keeps its messages and attachments, but leaves the sidebar and takes no new messages. Its agents keep running in their other conversations.")
            Text("Turning this off brings the group back as it was.")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 360, alignment: .leading)
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
