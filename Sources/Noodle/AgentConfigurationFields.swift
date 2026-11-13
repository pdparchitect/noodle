import SwiftUI
import HubLink
import NoodleCore
import NoodleHubClient
import NoodleRuntime
import NoodleRuntimeSettings

struct AgentConfigurationFields: View {
    @Environment(NoodleStore.self) private var store
    @Binding var selectedHarnessIdentifier: String
    @Binding var selectedModelIdentifier: String
    @Binding var selectedEffort: String
    @Binding var selectedProfileID: UUID?
    /// Empty leaves the voice to the harness.
    @Binding var selectedVoice: String
    /// The bot being edited; nil for a new bot.
    var agent: AgentRecord? = nil
    /// The edited bot's workspace; a new bot has none yet.
    var workspace: URL? = nil
    @State private var choosingHarness = false
    @State private var choosingVoice = false
    @State private var voicePreview = VoicePreviewPlayer()
    @State private var choosingProfile = false
    @State private var choosingModel = false

    /// A harness a joined Hub lends, when one is chosen: the bot then runs on that Hub.
    private var hubChoice: HubHarnessChoice? { HubHarnessChoice(identifier: selectedHarnessIdentifier) }


    /// What the chosen Hub lends on the chosen harness, as its last status said.
    private var lentHarness: LinkHarness? {
        guard let hubChoice else { return nil }
        return store.hubs.hubs.first { $0.hub?.key == hubChoice.hub }?.status?.harnesses.first {
            $0.provider == hubChoice.provider && $0.profile == hubChoice.profile
        }
    }

    private var harnessName: String {
        guard let hubChoice else { return selectedProvider?.displayName ?? "Choose a harness" }
        let hub = store.hubs.hubs.first { $0.hub?.key == hubChoice.hub }
        let lent = lentHarness
        let name = lent.map { harness in harness.profileName.map { "\(harness.providerName) (\($0))" } ?? harness.providerName }
            ?? selectedProvider?.displayName ?? hubChoice.provider
        return "\(name) · \(hub?.hub?.name ?? "Noodle Hub")"
    }

    private var profiles: [HarnessProfile] {
        guard hubChoice == nil, let selectedProvider, selectedProvider.supportsProfiles else { return [] }
        return store.harnessProfiles.profiles(for: selectedProvider)
    }

    /// The harness's Default login, named by the account it is signed in to.
    private var defaultProfileName: String {
        selectedProvider.map { store.harnessSetup.defaultLoginName($0) } ?? "Default"
    }

    private var models: [HarnessModel] {
        guard hubChoice != nil else {
            let shared = store.runtime.models(for: selectedHarnessIdentifier, profile: selectedProfileID)
            guard selectedProvider == .openCode, let workspace else { return shared }
            // Read on demand: the file is small and the bot or a person may edit it at any time.
            let configuration = try? WorkspaceMailbox(workspace: workspace, path: "").read("opencode.json", limit: 1_048_576)
            return OpenCodeProtocol.models(shared, configuration: configuration)
        }
        return (lentHarness?.models ?? []).map {
            HarnessModel(id: $0.id, displayName: $0.name, description: "", supportedEfforts: [], defaultEffort: "", isDefault: false)
        }
    }

    private var selectedModel: HarnessModel? {
        if selectedProvider == .apple, selectedModelIdentifier.isEmpty { return models.first(where: \.isDefault) }
        return models.first { $0.id == selectedModelIdentifier }
    }

    private var selectedProvider: HarnessProvider? {
        HarnessProvider(rawValue: hubChoice?.provider ?? selectedHarnessIdentifier)
    }

    private var selectedInstallation: HarnessInstallation? {
        store.runtime.availableInstallations.first {
            $0.provider.rawValue == selectedHarnessIdentifier
        }
    }

    private var modelName: String {
        if let selectedModel { return selectedModel.displayName }
        // Hub and OpenCode models can come from outside the list; elsewhere an unlisted model was removed.
        if hubChoice != nil || selectedProvider == .openCode, !selectedModelIdentifier.isEmpty { return selectedModelIdentifier }
        if let selectedProvider { return "\(selectedProvider.displayName) default" }
        return "Harness default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Harness")
                .font(.caption.weight(.semibold))

            VStack(spacing: 0) {
                Button { choosingHarness = true } label: {
                    RuntimeSelectionRow(
                        title: "Harness",
                        value: harnessName,
                        icon: AnyView(providerIcon)
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $choosingHarness, arrowEdge: .leading) {
                    let choices = store.harnessChoices(for: agent)
                    HarnessChooser(
                        installations: choices.installations,
                        hubs: choices.hubs,
                        selection: $selectedHarnessIdentifier
                    )
                }

                if !profiles.isEmpty {
                    Divider().padding(.leading, 44)

                    Button { choosingProfile = true } label: {
                        RuntimeSelectionRow(
                            title: "Profile",
                            value: store.harnessProfiles.profile(selectedProfileID)?.displayName ?? defaultProfileName,
                            icon: AnyView(Image(systemName: "person.crop.circle"))
                        )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $choosingProfile, arrowEdge: .leading) {
                        HarnessProfileChooser(profiles: profiles, defaultName: defaultProfileName, selection: $selectedProfileID)
                    }
                    .task(id: selectedProvider) {
                        // The Default login names its account only once its sign-in has been checked.
                        guard let selectedProvider, store.harnessSetup.accounts[selectedProvider] == nil,
                              let installation = store.runtime.installations.first(where: { $0.provider == selectedProvider }),
                              installation.isAvailable else { return }
                        await store.harnessSetup.refresh([installation])
                    }
                }

                // A Hub offers the models its plan allows, when it says which.
                if hubChoice == nil || !models.isEmpty {
                Divider().padding(.leading, 44)

                Button { choosingModel = true } label: {
                    RuntimeSelectionRow(
                        title: "Model",
                        value: modelName,
                        icon: AnyView(Image(systemName: "cube.transparent")),
                        tag: selectedModel?.tag,
                        isLoading: hubChoice == nil && store.runtime.isLoadingCapabilities
                    )
                }
                .buttonStyle(.plain)
                .disabled(store.runtime.isLoadingCapabilities && models.isEmpty)
                .popover(isPresented: $choosingModel, arrowEdge: .leading) {
                    ModelChooser(
                        providerName: selectedProvider?.displayName ?? "Harness",
                        usesCatalogueDefault: hubChoice == nil ? selectedProvider == .apple : lentHarness?.restrictsModels == true,
                        models: models,
                        selection: $selectedModelIdentifier
                    )
                }

                if hubChoice == nil, selectedProvider != .apple || selectedModel?.supportedEfforts.isEmpty == false {
                    Divider().padding(.leading, 44)
                    EffortControl(model: selectedModel, selection: $selectedEffort)
                }
                }

                if let selectedProvider, !selectedProvider.voices.isEmpty {
                    Divider().padding(.leading, 44)

                    Button { choosingVoice = true } label: {
                        RuntimeSelectionRow(
                            title: "Voice",
                            value: selectedProvider.voices.first { $0.id == selectedVoice }?.name
                                ?? "\(selectedProvider.displayName) default",
                            icon: AnyView(Image(systemName: "waveform"))
                        )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $choosingVoice, arrowEdge: .leading) {
                        VoiceChooser(provider: selectedProvider, selection: $selectedVoice, preview: voicePreview)
                    }
                }
            }
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.11))
            }

            HarnessExperimentalWarning(provider: selectedProvider)

            if hubChoice == nil, let selectedProvider, !selectedProvider.supportsRestrictedAccess {
                Text("\(selectedProvider.displayName) always uses unrestricted access and can work beyond this bot's private workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let selectedProvider, let error = store.runtime.capabilityErrors[selectedProvider] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: selectedHarnessIdentifier) { _, _ in
            selectedModelIdentifier = lentHarness?.initialModel ?? ""
            selectedEffort = ""
            selectedProfileID = nil
        }
        .onChange(of: selectedModelIdentifier) { _, newValue in
            guard let model = models.first(where: { $0.id == newValue }) else {
                selectedEffort = ""
                return
            }
            if !model.supportedEfforts.contains(where: { $0.id == selectedEffort }) {
                selectedEffort = model.defaultEffort
            }
        }
        // An FX profile offers its own team's models; one made since they were last read is read now.
        .task(id: selectedProfileID) {
            guard hubChoice == nil, selectedProvider == .fx, let profile = selectedProfileID,
                  store.runtime.fxProfileModels[profile] == nil else { return }
            store.runtime.refreshFxModels(profile: profile)
        }
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let provider = selectedInstallation?.provider ?? (hubChoice == nil ? nil : selectedProvider) {
            HarnessProviderIcon(provider: provider)
        } else {
            Image(systemName: "terminal")
        }
    }
}

extension View {
    /// Until a voice is picked, the bot's voice follows its name as it is typed.
    func followsNameForVoice(_ voice: Binding<String>, chosen: Binding<Bool>, name: String,
                             harnessIdentifier: String, store: NoodleStore) -> some View {
        task(id: name + "\n" + harnessIdentifier) {
            guard !chosen.wrappedValue else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, !chosen.wrappedValue else { return }
            let fitting = await store.defaultVoice(forBotNamed: name, harnessIdentifier: harnessIdentifier) ?? ""
            guard !Task.isCancelled, !chosen.wrappedValue else { return }
            voice.wrappedValue = fitting
        }
    }
}

/// The voice a bot speaks with on calls. Choosing a voice plays its sample and keeps
/// the chooser open, so voices can be compared by clicking through them.
struct VoiceChooser: View {
    let provider: HarnessProvider
    @Binding var selection: String
    let preview: VoicePreviewPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Voice")
                .font(.headline)
            group("Feminine", .feminine)
            group("Masculine", .masculine)
        }
        .padding(16)
        .frame(width: 340)
        .onDisappear { preview.stop() }
    }

    private func group(_ title: String, _ presentation: VoicePresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(provider.voices.filter { $0.presentation == presentation }, id: \.id) { voice in
                    tile(voice)
                }
            }
        }
    }

    private func tile(_ voice: HarnessVoice) -> some View {
        let isSelected = selection == voice.id, isPlaying = preview.playingVoice == voice.id
        return Button {
            selection = voice.id
            preview.play(voice.id, provider: provider)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.system(size: 17))
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(voice.name)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                        .padding(5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Choose \(voice.name) and hear it")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
