import AppKit
import SwiftUI
import NoodleCore
import NoodleSettingsUI
import NoodleRuntime
import NoodleRuntimeSettings

enum NoodleSettingsTab: Hashable {
    case general, chat, harnesses, mcps, heartbeats, sandbox, keybindings, permissions, companions, updates
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

    var body: some View {
        @Bindable var store = store

        TabView(selection: $store.selectedSettingsTab.animation(.easeInOut(duration: 0.22))) {
            GeneralSettingsView()
                .settingsContentSize()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(NoodleSettingsTab.general)
            ChatSettingsView()
                .settingsContentSize()
                .tabItem {
                    Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(NoodleSettingsTab.chat)
            HarnessesSettingsView(store: store, setup: harnessSetup)
                .settingsContentSize()
                .tabItem {
                    Label("Harness", systemImage: "terminal")
                }
                .tag(NoodleSettingsTab.harnesses)
            HeartbeatsSettingsView(store: store)
                .settingsContentSize()
                .tabItem {
                    Label("Heartbeat", systemImage: "waveform.path.ecg")
                }
                .tag(NoodleSettingsTab.heartbeats)
            AgentAccessSettingsView(store: store)
                .settingsContentSize()
                .tabItem { Label("Sandbox", systemImage: "lock.shield") }
                .tag(NoodleSettingsTab.sandbox)
            MCPSettingsView(store: store)
                .settingsContentSize()
                .tabItem { Label("Tools", systemImage: "puzzlepiece.extension") }
                .tag(NoodleSettingsTab.mcps)
            KeybindingsSettingsView()
                .settingsContentSize()
                .tabItem { Label("Keybindings", systemImage: "keyboard") }
                .tag(NoodleSettingsTab.keybindings)
            PermissionsSettingsView()
                .settingsContentSize()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
                .tag(NoodleSettingsTab.permissions)
            CompanionAppsSettingsView(store: store)
                .settingsContentSize()
                .tabItem { Label("Companions", systemImage: "square.stack.3d.up") }
                .tag(NoodleSettingsTab.companions)
            UpdatesSettingsView()
                .settingsContentSize()
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
    @AppStorage(LinkPreviewSettings.timeoutKey) private var linkPreviewTimeout = LinkPreviewSettings.defaultTimeout
    @AppStorage(VoiceInputDevice.defaultsKey) private var microphoneUID = ""
    @AppStorage(MessageDeliveryMode.defaultsKey) private var messageDelivery = MessageDeliveryMode.automatic.rawValue
    @AppStorage(ChatAttachmentLayout.defaultsKey) private var attachmentLayout = ChatAttachmentLayout.defaultValue.rawValue
    @AppStorage(FloatingConversations.keepsOneDefaultsKey) private var keepsOneFloat = false
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
            Section {
                Picker("Message delivery", selection: $messageDelivery) {
                    ForEach(MessageDeliveryMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
            } footer: {
                Text("Automatic uses Apple Intelligence to decide whether new messages should reach a busy agent immediately or wait until its turn finishes. When Apple Intelligence is unavailable, messages wait.")
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
                Picker("Link preview timeout", selection: $linkPreviewTimeout) {
                    ForEach(LinkPreviewSettings.timeoutOptions, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
            } footer: {
                Text("Maximum time for new link previews, including images. Unavailable previews remain clickable without a loading spinner.")
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

private extension View {
    func settingsContentSize() -> some View {
        frame(width: 680)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension NoodleStore: BotSettingsHost {
    func showHarnessSettings() { selectedSettingsTab = .harnesses }

    func botProfileButton(_ agent: AgentRecord) -> AnyView {
        AnyView(AgentProfileButton(agent: agent).environment(self))
    }

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

    func openComputerDownload() async throws { try await computers.openDownload() }
}
