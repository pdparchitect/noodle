import SwiftUI
import NoodleRuntimeSettings

/// Settings > Conversation: how conversations sound, listen, name and float, in every app that has them.
struct ChatSettingsView: View {
    @AppStorage(ComposerNameCompletion.descriptionsDefaultsKey) private var showBotDescriptions = true
    @AppStorage(WebLinkPreview.defaultsKey) private var previewsWebLinks = true
    @AppStorage(FloatingConversations.keepsOneDefaultsKey) private var keepsOneFloat = false
    @AppStorage(MessageReceivedSound.defaultsKey) private var receivedSound = MessageReceivedSound.defaultName
    private let microphoneDevices: () -> [VoiceInputDevice]
    private let systemMicrophoneID: () -> UInt32
    /// What the app calls the members of a conversation, for the @ name menu's footer.
    private let member: String

    init(member: String = "bot", microphoneDevices: @escaping () -> [VoiceInputDevice] = VoiceInputDevice.available,
         systemMicrophoneID: @escaping () -> UInt32 = { VoiceInputDevice.defaultDeviceID }) {
        self.member = member
        self.microphoneDevices = microphoneDevices
        self.systemMicrophoneID = systemMicrophoneID
    }

    var body: some View {
        Form {
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
            MicrophoneSettingsSection(devices: microphoneDevices, systemID: systemMicrophoneID)
            Section {
                Toggle("Show descriptions in the @ name menu", isOn: $showBotDescriptions)
            } footer: {
                Text("Show each \(member)'s public description beside its name. Private backstories are never shown.")
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
