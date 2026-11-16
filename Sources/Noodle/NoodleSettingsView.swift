import AppKit
import NoodletRuntime
import SwiftUI
import NoodleBrand
import NoodleCore
import HubLink
import NoodleSettingsUI
import NoodleRuntime
import NoodleRuntimeSettings

enum NoodleSettingsTab: Hashable {
    case general, chat, harnesses, bots, groups, mcps, keybindings, permissions, companions, hub, updates
}

struct NoodleSettingsView: View {
    @Environment(NoodleStore.self) private var store
    private let companionUpdates = CompanionUpdateChecker.shared
    private let permissions = AppPermissionChecker.shared
    @ObservedObject private var appUpdater = AppUpdater.shared
    // Owned by the store so the Harness tab is badged before it is selected.
    private var harnessSetup: HarnessSetupController { store.harnessSetup }

    /// Wide enough for every tab in the toolbar, none left in its overflow menu.
    private static let width: CGFloat = 740

    var body: some View {
        @Bindable var store = store

        SettingsTabView(selection: $store.selectedSettingsTab) {
            GeneralSettingsView()
                .settingsContentSize(width: Self.width)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(NoodleSettingsTab.general)
            ChatSettingsView()
                .settingsContentSize(width: Self.width)
                .tabItem {
                    Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(NoodleSettingsTab.chat)
            HarnessesSettingsView(store: store, setup: harnessSetup)
                .settingsContentSize(width: Self.width)
                .tabItem {
                    Label("Harness", systemImage: "terminal")
                }
                .tag(NoodleSettingsTab.harnesses)
            BotsSettingsView(store: store, agents: store.configurableAgents)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Bots", systemImage: "sparkles") }
                .tag(NoodleSettingsTab.bots)
            GroupsSettingsView()
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Groups", systemImage: "person.3") }
                .tag(NoodleSettingsTab.groups)
            ToolConnectionsSettingsView(store: store) { ImageGenerationSettingsRow(controller: store.imageGeneration) }
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Tools", systemImage: "puzzlepiece.extension") }
                .tag(NoodleSettingsTab.mcps)
            KeybindingsSettingsView()
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Keybindings", systemImage: "keyboard") }
                .tag(NoodleSettingsTab.keybindings)
            PermissionsSettingsView { HubNoodletGrantsSection() }
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
                .tag(NoodleSettingsTab.permissions)
            CompanionAppsSettingsView(store: store)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Companions", systemImage: "square.stack.3d.up") }
                .tag(NoodleSettingsTab.companions)
            HubSettingsView()
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Hub", systemImage: "server.rack") }
                .tag(NoodleSettingsTab.hub)
            UpdatesSettingsView()
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Update", systemImage: "arrow.triangle.2.circlepath") }
                .tag(NoodleSettingsTab.updates)
        }
        .background(SettingsTabBadge(counts: ["Harness": store.harnessesNeedingAttention(harnessSetup),
                                              "Tools": store.toolsNeedingAttention,
                                              "Permissions": permissions.needingAttention,
                                              "Companions": companionUpdates.updates.count,
                                              "Update": appUpdater.availableVersion == nil ? 0 : 1]))
        // Check on opening Settings so the tabs are badged before they are selected.
        .onAppear {
            companionUpdates.refresh(CompanionApp.installedApps())
            appUpdater.probeForUpdate()
            permissions.refresh()
        }
        .task { await harnessSetup.refreshAll(store.runtime) }
    }
}

struct GeneralSettingsView: View {
    @Environment(NoodleStore.self) private var store

    var body: some View {
        @Bindable var store = store
        RuntimeGeneralSettings(member: "bot", nameStyleKey: BotNameStyle.defaultsKey, defaultNameStyle: .real,
                               groupNotifications: $store.groupNotifications, runtime: store.runtime)
    }
}

extension NoodleStore: BotSettingsHost {
    func showHarnessSettings() { selectedSettingsTab = .harnesses }

    func botProfileButton(_ agent: AgentRecord) -> AnyView {
        AnyView(AgentProfileButton(agent: agent).environment(self))
    }

    /// A Hub's bots are unarchived from that Hub in Settings > Hub, as on Mobile.
    func canArchive(_ agent: AgentRecord) -> Bool { hubMirror(forAgent: agent.id) == nil }
    func setArchived(_ archived: Bool, agent: AgentRecord) { setArchived(archived, agentID: agent.id) }

    func botRuntimeEditor(_ agent: AgentRecord) -> AnyView {
        AnyView(EditBotSheet(agent: agent, initialTab: .runtime).environment(self))
    }

    func refreshCompanionSkills() { applets.refreshSkills() }

    func openCompanionLibrary(_ app: CompanionApp) async throws {
        switch app {
        case .browser: try await browsers.openLibrary()
        case .computer: try await computers.openLibrary()
        case .applet: try await applets.openLibrary()
        }
    }
}

/// The device permissions Hub noodlets were granted on this Mac, each removable.
private struct HubNoodletGrantsSection: View {
    @State private var noodlets: [NoodletGrants.Grant] = []

    var body: some View {
        Group {
            if !noodlets.isEmpty {
                Section("Hub Noodlets") {
                    ForEach(noodlets) { grant in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(grant.title)
                                Text(grant.permissions.compactMap { NoodletManifest.permissionTitles[$0] }.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                NoodletGrants().revoke(grant.id)
                                noodlets = NoodletGrants().all
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .onAppear { noodlets = NoodletGrants().all }
    }
}
