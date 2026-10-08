import AppKit
import SwiftUI
import NoodleBrand
import NoodleCore
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

    private var harnessesNeedingAttention: Int {
        HarnessProvider.allCases.filter { id in
            harnessSetup.needsAttention(id) || store.agents.contains {
                let snapshot = store.runtime.snapshot(for: $0.id)
                return $0.harnessIdentifier == id.rawValue && snapshot.canKick && snapshot.phase == .failed
            }
        }.count
    }

    /// Tools whose row shows Needs attention.
    private var toolsNeedingAttention: Int {
        store.mcp.registry.connections.filter { store.mcp.errors[$0.id] != nil }.count
    }

    /// Wide enough for every tab in the toolbar, none left in its overflow menu.
    private static let width: CGFloat = 740

    var body: some View {
        @Bindable var store = store

        TabView(selection: $store.selectedSettingsTab.animation(.easeInOut(duration: 0.22))) {
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
            MCPSettingsView(store: store)
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Tools", systemImage: "puzzlepiece.extension") }
                .tag(NoodleSettingsTab.mcps)
            KeybindingsSettingsView()
                .settingsContentSize(width: Self.width)
                .tabItem { Label("Keybindings", systemImage: "keyboard") }
                .tag(NoodleSettingsTab.keybindings)
            PermissionsSettingsView()
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
        .modifier(SettingsWindowResizeAnchor())
        .settingsScrollIndicators(selection: store.selectedSettingsTab)
        .background(SettingsTabBadge(counts: ["Harness": harnessesNeedingAttention,
                                              "Tools": toolsNeedingAttention,
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
    @AppStorage(BotNameStyle.defaultsKey) private var botNameStyle = BotNameStyle.real.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Generated bot names", selection: $botNameStyle) {
                    ForEach(BotNameStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Keep Mac awake while agents work", isOn: Binding(
                    get: { store.runtime.preventIdleSleepWhileWorking },
                    set: { store.runtime.configurePreventIdleSleepWhileWorking($0) }
                ))
            } footer: {
                Text("Prevents automatic idle sleep only while an agent is working. Closing the lid or choosing Sleep still suspends the Mac.")
            }
        }
        .formStyle(.grouped)
    }
}

struct ChatSettingsView: View {
    @AppStorage(ComposerNameCompletion.descriptionsDefaultsKey) private var showBotDescriptions = true
    @AppStorage(WebLinkPreview.defaultsKey) private var previewsWebLinks = true
    @AppStorage(VoiceInputDevice.defaultsKey) private var microphoneUID = ""
    @AppStorage(ChatAttachmentLayout.defaultsKey) private var attachmentLayout = ChatAttachmentLayout.defaultValue.rawValue
    @AppStorage(FloatingConversations.keepsOneDefaultsKey) private var keepsOneFloat = false
    @AppStorage(MessageReceivedSound.defaultsKey) private var receivedSound = MessageReceivedSound.defaultName
    @State private var microphones: [VoiceInputDevice] = []
    @State private var defaultMicrophoneID: UInt32 = 0
    private let microphoneDevices: () -> [VoiceInputDevice]
    private let systemMicrophoneID: () -> UInt32

    init(microphoneDevices: @escaping () -> [VoiceInputDevice] = VoiceInputDevice.available,
         systemMicrophoneID: @escaping () -> UInt32 = { VoiceInputDevice.defaultDeviceID }) {
        self.microphoneDevices = microphoneDevices
        self.systemMicrophoneID = systemMicrophoneID
    }

    var body: some View {
        Form {
            Section {
                Picker("Attachment layout", selection: $attachmentLayout) {
                    ForEach(ChatAttachmentLayout.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .help((ChatAttachmentLayout(rawValue: attachmentLayout) ?? .defaultValue).explanation)
            }
            ConversationRuntimeSettingsSections()
            Section {
                Picker("Message received sound", selection: $receivedSound) {
                    Text("None").tag(MessageReceivedSound.none)
                    Divider()
                    ForEach(MessageReceivedSound.names, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: receivedSound) { MessageReceivedSound.play() }
            }
            Section {
                Picker("Microphone", selection: $microphoneUID) {
                    Text(microphones.first(where: { $0.audioID == defaultMicrophoneID })
                        .map { "System Default — \($0.name)" } ?? "System Default").tag("")
                    ForEach(microphones) { microphone in
                        Text(microphone.name).tag(microphone.id)
                    }
                    if !microphoneUID.isEmpty && !microphones.contains(where: { $0.id == microphoneUID }) {
                        Text("Selected microphone unavailable").tag(microphoneUID)
                    }
                }
            }
            .task {
                while !Task.isCancelled {
                    microphones = microphoneDevices()
                    defaultMicrophoneID = systemMicrophoneID()
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }

            Section {
                Toggle("Show descriptions in the @ name menu", isOn: $showBotDescriptions)
            } footer: {
                Text("Show each bot's public description beside its name. Private backstories are never shown.")
            }
            Section {
                Toggle("Keep one floating conversation", isOn: $keepsOneFloat)
                    .help("Floating another conversation replaces the open one, in the same place and size.")
            }
            Section {
                Toggle("Preview web links", isOn: $previewsWebLinks)
                    .help("Open web links in Quick Look first, with a button to continue in your browser. When off, links open in your browser.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsWindowResizeAnchor: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.windowResizeAnchor(.top)
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
