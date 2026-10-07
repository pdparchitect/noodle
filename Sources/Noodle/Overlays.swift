import AppKit
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import NoodleCore
import HubLink
import NoodleHubClient
import NoodleRuntimeSettings

enum BotEditorTab: String, CaseIterable {
    case general = "General", runtime = "Harness", mcp = "Tools", computers = "Computers", browsers = "Browsers"
}

private struct BotEditorTabPicker: View {
    @Binding var selection: BotEditorTab
    let harnessIdentifier: String
    /// What was chosen on this Mac means nothing on a Hub, and one Hub's means nothing on another.
    var onToolsHomeChange: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Picker("Bot settings", selection: $selection.animation(reduceMotion ? nil : .easeInOut(duration: 0.22))) {
            ForEach(BotEditorTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
        }.pickerStyle(.segmented).labelsHidden()
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .center)
            .onChange(of: HubHarnessChoice(identifier: harnessIdentifier)?.hub) { onToolsHomeChange() }
    }
}

struct NameValidationMessage: View {
    let name: String
    var body: some View {
        if !name.isEmpty, let error = ConversationName.error(for: name) {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct NewBotSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BotNameStyle.defaultsKey) private var botNameStyle = BotNameStyle.real.rawValue
    @State private var name = ""
    @State private var selectedHarnessIdentifier = ""
    @State private var hasChosenHarness = false
    @State private var selectedModelIdentifier = ""
    @State private var selectedEffort = ""
    @State private var selectedVoice = ""
    @State private var hasChosenVoice = false
    @State private var publicDescription = ""
    @State private var backstory = ""
    @State private var avatarSymbolName: String? = "sparkles"
    @State private var avatarColorIndex = Int.random(in: BotAvatarPalette.gradients.indices)
    @State private var avatarImageData: Data?
    @State private var editingAvatar = false
    @State private var mcpConnectionIDs: Set<UUID> = []
    @State private var computerIDs: Set<UUID> = []
    @State private var browserIDs: Set<UUID> = []
    @State private var calendarIDs: Set<String> = []
    @State private var reminderListIDs: Set<String> = []
    @State private var builtInTools: Set<EventKitAssignments.Kind> = []
    @State private var folders: [AgentFolder] = []
    @State private var selectedProfileID: UUID?
    @State private var selectedTab = BotEditorTab.general
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "New Bot", createTitle: "Create") {
                create()
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Button {
                        editingAvatar = true
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            BotAvatar(agent: previewAgent, size: 64)
                            Image(systemName: "pencil.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.system(size: 21))
                                .background(.background, in: Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Change Bot Icon")
                    .accessibilityLabel("Change Bot Icon")

                    VStack(alignment: .leading, spacing: 5) {
                        ZStack(alignment: .trailing) {
                            TextField("Bot name", text: $name, axis: .horizontal)
                                .lineLimit(1)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 14))
                                .autocorrectionDisabled(false)
                                .focused($nameFocused)
                                .onSubmit {
                                    if canCreate { create() }
                                }

                            Button {
                                name = BotNameGenerator.random(style: selectedBotNameStyle, excluding: name)
                                nameFocused = true
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(PointingHandCursorView())
                            .padding(.trailing, 4)
                            .help("Try Another Name")
                            .accessibilityLabel("Generate Another Name")
                        }
                        Text("You can rename this bot later without changing its workspace location.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NameValidationMessage(name: name)

                BotEditorTabPicker(selection: $selectedTab, harnessIdentifier: selectedHarnessIdentifier) {
                    mcpConnectionIDs = []; computerIDs = []; browserIDs = []
                }
                switch selectedTab {
                case .general:
                    BotPublicDescriptionEditor(publicDescription: $publicDescription)
                    BotBackstoryEditor(backstory: $backstory)
                    if HubHarnessChoice(identifier: selectedHarnessIdentifier) == nil {
                        FoldersSettingsRow(folders: $folders, owner: .bot)
                    }
                case .runtime:
                    AgentConfigurationFields(
                        selectedHarnessIdentifier: Binding(
                            get: { selectedHarnessIdentifier },
                            set: { selectedHarnessIdentifier = $0; hasChosenHarness = true }
                        ),
                        selectedModelIdentifier: $selectedModelIdentifier,
                        selectedEffort: $selectedEffort,
                        selectedProfileID: $selectedProfileID,
                        selectedVoice: Binding(get: { selectedVoice }, set: { selectedVoice = $0; hasChosenVoice = true })
                    )
                case .mcp:
                    if let mirror = store.hubMirror(forHarness: selectedHarnessIdentifier) {
                        HubConnectionPicker(mirror: mirror, selectedIDs: $mcpConnectionIDs)
                    } else {
                        MCPAssignmentPicker(controller: store.mcp, selectedIDs: $mcpConnectionIDs,
                                            calendars: store.calendars, reminders: store.reminders,
                                            calendarIDs: $calendarIDs, reminderIDs: $reminderListIDs,
                                            builtIn: $builtInTools)
                    }
                case .browsers:
                    if let mirror = store.hubMirror(forHarness: selectedHarnessIdentifier) {
                        HubBrowserPicker(mirror: mirror, bot: name, selectedIDs: $browserIDs)
                    } else {
                        BrowserAssignmentPicker(controller: store.browsers, bot: name, selectedIDs: $browserIDs)
                    }
                case .computers:
                    if let mirror = store.hubMirror(forHarness: selectedHarnessIdentifier) {
                        HubComputerPicker(mirror: mirror, bot: name, selectedIDs: $computerIDs)
                    } else {
                        ComputerAssignmentPicker(controller: store.computers, bot: name, selectedIDs: $computerIDs)
                    }
                }
                if selectedTab != .runtime {
                    HarnessExperimentalWarning(provider: HarnessProvider(rawValue: selectedHarnessIdentifier))
                }
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear {
            if name.isEmpty { name = BotNameGenerator.random(style: selectedBotNameStyle) }
            selectAvailableHarnessIfNeeded()
            nameFocused = true
            store.runtime.refreshCapabilities()
        }
        .followsNameForVoice($selectedVoice, chosen: $hasChosenVoice, name: name,
                             harnessIdentifier: selectedHarnessIdentifier, store: store)
        .onChange(of: store.runtime.availableInstallations) { _, _ in
            selectAvailableHarnessIfNeeded()
        }
        .sheet(isPresented: $editingAvatar) {
            BotIconEditor(
                symbolName: $avatarSymbolName,
                colorIndex: $avatarColorIndex,
                imageData: $avatarImageData,
                avatar: AvatarIdea(name: name, description: publicDescription, backstory: backstory)
            )
            .noodleSheetSizing()
        }
    }

    private var canCreate: Bool {
        ConversationName.error(for: name) == nil && (HubHarnessChoice(identifier: selectedHarnessIdentifier) != nil ||
            store.runtime.availableInstallations.contains {
                $0.provider.rawValue == selectedHarnessIdentifier
            })
    }

    private func selectAvailableHarnessIfNeeded() {
        let installations = store.runtime.availableInstallations
        if hasChosenHarness, HubHarnessChoice(identifier: selectedHarnessIdentifier) != nil
            || installations.contains(where: { $0.provider.rawValue == selectedHarnessIdentifier }) { return }
        hasChosenHarness = false
        // In a Hub's space, on that Hub, so the new bot shows there.
        let preferred = store.spaceHarnessIdentifier ?? installations.first?.provider.rawValue ?? ""
        guard selectedHarnessIdentifier != preferred else { return }
        selectedHarnessIdentifier = preferred
        selectedModelIdentifier = ""
        selectedEffort = ""
    }

    private var selectedBotNameStyle: BotNameStyle {
        BotNameStyle(rawValue: botNameStyle) ?? .real
    }

    private func create() {
        _ = store.createAgent(
            named: name,
            harnessIdentifier: selectedHarnessIdentifier,
            modelIdentifier: selectedModelIdentifier.nilIfEmpty,
            reasoningEffort: selectedEffort.nilIfEmpty,
            avatarSymbolName: avatarSymbolName,
            avatarColorIndex: avatarColorIndex,
            avatarImageData: avatarImageData,
            publicDescription: publicDescription,
            backstory: backstory,
            mcpConnectionIDs: mcpConnectionIDs,
            computerIDs: computerIDs, browserIDs: browserIDs, calendarIDs: calendarIDs, reminderListIDs: reminderListIDs, folders: folders,
            harnessProfile: selectedProfileID,
            voice: selectedVoice.nilIfEmpty
        )
    }

    private var previewAgent: AgentRecord {
        AgentRecord(
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Bot",
            accentSeed: avatarColorIndex,
            avatarSymbolName: avatarSymbolName,
            avatarColorIndex: avatarColorIndex,
            avatarImageData: avatarImageData
        )
    }

    private func sheetHeader(title: String, createTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            Spacer()
            Text(title).font(.headline)
            Spacer()
            Button(createTitle, action: action)
                .buttonStyle(.plain)
                .foregroundStyle(canCreate ? Color.blue : .secondary)
                .disabled(!canCreate)
        }
        .padding(16)
    }
}

struct EditBotSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let agent: AgentRecord
    @State private var name: String
    @State private var selectedHarnessIdentifier: String
    @State private var selectedModelIdentifier: String
    @State private var selectedEffort: String
    @State private var selectedVoice = ""
    @State private var hasChosenVoice = false
    @State private var publicDescription: String
    @State private var backstory = ""
    @State private var avatarSymbolName: String?
    @State private var avatarColorIndex: Int
    @State private var avatarImageData: Data?
    @State private var editingAvatar = false
    @State private var mcpConnectionIDs: Set<UUID> = []
    @State private var computerIDs: Set<UUID> = []
    @State private var browserIDs: Set<UUID> = []
    @State private var calendarIDs: Set<String> = []
    @State private var reminderListIDs: Set<String> = []
    @State private var builtInTools: Set<EventKitAssignments.Kind> = []
    @State private var folders: [AgentFolder] = []
    @State private var selectedProfileID: UUID?
    @State private var sharedWith: Set<UUID> = []
    @State private var confirmingDeletion = false
    @State private var selectedTab = BotEditorTab.general
    @State private var backgroundDraft: BackgroundSelection?
    @FocusState private var nameFocused: Bool

    init(agent: AgentRecord, initialTab: BotEditorTab = .general) {
        self.agent = agent
        _selectedTab = State(initialValue: initialTab)
        _name = State(initialValue: agent.displayName)
        _selectedHarnessIdentifier = State(initialValue: agent.harnessIdentifier ?? "")
        _selectedModelIdentifier = State(initialValue: agent.modelIdentifier ?? "")
        _selectedEffort = State(initialValue: agent.reasoningEffort ?? "")
        _publicDescription = State(initialValue: agent.publicDescription ?? "")
        _avatarSymbolName = State(initialValue: agent.avatarSymbolName)
        _avatarColorIndex = State(initialValue: agent.avatarColorIndex ?? agent.accentSeed)
        _avatarImageData = State(initialValue: agent.avatarImageData)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                Spacer()
                Text("Edit Bot").font(.headline)
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.plain)
                    .foregroundStyle(canSave ? Color.blue : .secondary)
                    .disabled(!canSave)
            }
            .padding(16)

            Divider()

            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    Button {
                        editingAvatar = true
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            BotAvatar(agent: previewAgent, size: 64)
                            Image(systemName: "pencil.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.system(size: 21))
                                .background(.background, in: Circle())
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Change Bot Icon")
                    .accessibilityLabel("Change Bot Icon")

                    TextField("Bot name", text: $name, axis: .horizontal)
                        .lineLimit(1)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled(false)
                        .focused($nameFocused)
                        .onSubmit { if canSave { save() } }
                }

                NameValidationMessage(name: name)

                BotEditorTabPicker(selection: $selectedTab, harnessIdentifier: selectedHarnessIdentifier)
                switch selectedTab {
                case .general:
                    BotPublicDescriptionEditor(publicDescription: $publicDescription)
                    BotBackstoryEditor(backstory: $backstory)
                    if HubHarnessChoice(identifier: selectedHarnessIdentifier) == nil {
                        FoldersSettingsRow(folders: $folders, owner: .bot)
                    }
                    if let conversation = directConversation {
                        ConversationBackgroundSettingsRow(conversation: conversation, draft: $backgroundDraft)
                    }
                    if let sharingHub {
                        BotSharingPicker(mirror: sharingHub, bot: name, selectedIDs: $sharedWith)
                    }
                    Divider()
                    DestructiveActionButton(title: "Delete Bot") {
                        confirmingDeletion = true
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .runtime:
                    AgentConfigurationFields(
                        selectedHarnessIdentifier: $selectedHarnessIdentifier,
                        selectedModelIdentifier: $selectedModelIdentifier,
                        selectedEffort: $selectedEffort,
                        selectedProfileID: $selectedProfileID,
                        selectedVoice: Binding(get: { selectedVoice }, set: { selectedVoice = $0; hasChosenVoice = true })
                    )
                    Text("Saving restarts the bot. Its workspace and history stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .mcp:
                    if let mirror = store.hubMirror(forHarness: selectedHarnessIdentifier) {
                        HubConnectionPicker(mirror: mirror, selectedIDs: $mcpConnectionIDs)
                    } else {
                        MCPAssignmentPicker(controller: store.mcp, selectedIDs: $mcpConnectionIDs,
                                            calendars: store.calendars, reminders: store.reminders,
                                            calendarIDs: $calendarIDs, reminderIDs: $reminderListIDs,
                                            builtIn: $builtInTools)
                    }
                case .browsers:
                    if let mirror = store.hubMirror(forHarness: selectedHarnessIdentifier) {
                        HubBrowserPicker(mirror: mirror, bot: name, selectedIDs: $browserIDs)
                    } else {
                        BrowserAssignmentPicker(controller: store.browsers, bot: name, selectedIDs: $browserIDs)
                    }
                case .computers:
                    if let mirror = store.hubMirror(forHarness: selectedHarnessIdentifier) {
                        HubComputerPicker(mirror: mirror, bot: name, selectedIDs: $computerIDs)
                    } else {
                        ComputerAssignmentPicker(controller: store.computers, bot: name, selectedIDs: $computerIDs)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 520)
        .followsNameForVoice($selectedVoice, chosen: $hasChosenVoice, name: name,
                             harnessIdentifier: selectedHarnessIdentifier, store: store)
        .onAppear {
            nameFocused = selectedTab == .general
            backstory = store.backstory(for: agent)
            mcpConnectionIDs = store.mcp.selectedIDs(for: agent)
            computerIDs = store.computers.selectedIDs(for: agent)
            browserIDs = store.browsers.selectedIDs(for: agent)
            calendarIDs = store.calendars.selectedIDs(for: agent)
            reminderListIDs = store.reminders.selectedIDs(for: agent)
            builtInTools = Set(EventKitAssignments.Kind.allCases.filter {
                !($0 == .calendar ? calendarIDs : reminderListIDs).isEmpty
            })
            folders = store.folders(for: agent)
            selectedProfileID = store.harnessProfile(for: agent)
            selectedVoice = store.voice(for: agent) ?? ""
            hasChosenVoice = !selectedVoice.isEmpty
            // A bot on a Noodle Hub runs on that Hub's harness.
            if let mirror = store.hubMirror(forAgent: agent.id), let choice = mirror.harness(ofAgent: agent.id) {
                selectedHarnessIdentifier = choice.identifier
                mcpConnectionIDs = mirror.connectionIDs(forAgent: agent.id)
                computerIDs = mirror.computerIDs(forAgent: agent.id)
                browserIDs = mirror.browserIDs(forAgent: agent.id)
                sharedWith = Set(mirror.sharedWith(agent: agent.id))
            }
            if selectedHarnessIdentifier.isEmpty {
                selectedHarnessIdentifier = store.runtime.availableInstallations.first?.provider.rawValue ?? ""
            }
            store.runtime.refreshCapabilities()
        }
        .sheet(isPresented: $editingAvatar) {
            BotIconEditor(
                symbolName: $avatarSymbolName,
                colorIndex: $avatarColorIndex,
                imageData: $avatarImageData,
                avatar: AvatarIdea(name: name, description: publicDescription, backstory: backstory)
            )
            .noodleSheetSizing()
        }
        .confirmationDialog(
            "Delete Bot?",
            isPresented: $confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Bot", role: .destructive) {
                guard let conversation = directConversation else { return }
                if store.delete(conversation) { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let conversation = directConversation {
                Text(store.deletionMessage(for: conversation))
            }
        }
    }

    private var directConversation: BotConversation? {
        store.conversations.first {
            $0.kind == .direct && $0.participantIDs == [agent.id]
        }
    }

    /// The Noodle Hub this Mac's user keeps the bot on, when they can share it there: not on their own Mac.
    private var sharingHub: HubMirror? {
        store.hubMirror(forAgent: agent.id).flatMap {
            $0.owner(ofAgent: agent.id) == nil && $0.pairing.status?.canShareBots == true ? $0 : nil
        }
    }

    private var canSave: Bool {
        ConversationName.error(for: name) == nil && (HubHarnessChoice(identifier: selectedHarnessIdentifier) != nil ||
            store.runtime.availableInstallations.contains {
                $0.provider.rawValue == selectedHarnessIdentifier
            })
    }

    private var previewAgent: AgentRecord {
        var preview = agent
        let editedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !editedName.isEmpty { preview.displayName = editedName }
        preview.avatarSymbolName = avatarSymbolName
        preview.avatarColorIndex = avatarColorIndex
        preview.avatarImageData = avatarImageData
        return preview
    }

    private func save() {
        if store.saveSettings(background: backgroundDraft, for: directConversation, saving: {
            store.updateAgent(
                agent,
                name: name,
                harnessIdentifier: selectedHarnessIdentifier,
                modelIdentifier: selectedModelIdentifier.nilIfEmpty,
                reasoningEffort: selectedEffort.nilIfEmpty,
                avatarSymbolName: avatarSymbolName,
                avatarColorIndex: avatarColorIndex,
                avatarImageData: avatarImageData,
                publicDescription: publicDescription,
                backstory: backstory,
                mcpConnectionIDs: mcpConnectionIDs,
                computerIDs: computerIDs, browserIDs: browserIDs, calendarIDs: calendarIDs, reminderListIDs: reminderListIDs, folders: folders,
                harnessProfile: .some(selectedProfileID),
                sharedWith: sharingHub == nil ? nil : sharedWith,
                voice: .some(selectedVoice.nilIfEmpty)
            )
        }) {
            dismiss()
        }
    }
}

/// Whom a bot kept on a Noodle Hub is shared with: everyone else on the Hub, picked by tapping them,
/// and saved with the bot.
struct BotSharingPicker: View {
    let mirror: HubMirror
    let bot: String
    @Binding var selectedIDs: Set<UUID>
    @State private var people: [LinkPerson]?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sharing")
                .font(.caption.weight(.semibold))
            if let people, people.isEmpty {
                Text("Nobody else is on this Hub").font(.caption).foregroundStyle(.secondary)
            } else if let people {
                BotSharingPeople(people: people, bot: bot, selectedIDs: $selectedIDs)
            } else if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            do { people = try await mirror.people() } catch { failure = error.localizedDescription }
        }
    }

}

/// Everyone else on the Hub, each tapped to share the bot with them or stop, and who that lets talk to it.
struct BotSharingPeople: View {
    let people: [LinkPerson]
    let bot: String
    @Binding var selectedIDs: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], alignment: .leading, spacing: 10) {
                ForEach(people) { person($0) }
            }
            Text(LinkPerson.sharingSummary(bot: bot, people: people.filter { selectedIDs.contains($0.id) }.map(\.name)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
    }

    private func person(_ person: LinkPerson) -> some View {
        let selected = selectedIDs.contains(person.id)
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if selected { selectedIDs.remove(person.id) } else { selectedIDs.insert(person.id) }
            }
        } label: {
            VStack(spacing: 5) {
                PersonBadge(name: person.name, avatar: person.avatar, id: person.id, size: 44)
                    .padding(3)
                    .overlay { Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2) }
                    .overlay(alignment: .bottomTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.system(size: 16))
                                .background(.background, in: Circle())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .opacity(selected ? 1 : 0.55)
                Text(person.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(selected ? "Stop sharing with \(person.name)" : "Share with \(person.name)")
        .accessibilityLabel(person.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct BotPublicDescriptionEditor: View {
    @Binding var publicDescription: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description")
                .font(.caption.weight(.semibold))

            TextField(
                "Briefly describe what this bot does…",
                text: $publicDescription,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...3)
            .autocorrectionDisabled(false)

            Text("Visible to other bots in shared groups. The private backstory below is never included.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BotBackstoryEditor: View {
    @Binding var backstory: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Backstory")
                .font(.caption.weight(.semibold))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))

                if backstory.isEmpty {
                    Text("Describe who this bot is, its role, tone, or priorities…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        // Match the editor's outer inset; the native text view
                        // contributes its own horizontal line-fragment padding.
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $backstory)
                    .font(.system(size: 13))
                    .autocorrectionDisabled(false)
                    .scrollContentBackground(.hidden)
                    .padding(4)
            }
            .frame(height: 160)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18))
            }

        }
    }
}

private struct BotIconEditor: View {
    @Binding var symbolName: String?
    @Binding var colorIndex: Int
    @Binding var imageData: Data?
    let avatar: AvatarIdea

    private static let symbols = [
        "sparkles",
        "bolt.fill",
        "brain.head.profile",
        "hammer.fill",
        "terminal.fill",
        "magnifyingglass",
        "shippingbox.fill",
        "paintbrush.fill",
        "checkmark.seal.fill",
        "ladybug.fill",
        "wand.and.stars",
        "gearshape.2.fill"
    ]

    var body: some View {
        // Bot icons are stored as JPEG, and the colour stays the bot's own seed
        // until the user picks one. Done always records a symbol, as it always has.
        IconEditorSheet(
            title: "Bot Icon",
            icon: Binding(
                get: { IconAppearance(symbol: symbolName, colour: colorIndex, image: imageData) },
                set: { icon in
                    symbolName = icon.iconSymbol ?? BotAvatar.defaultSymbol
                    colorIndex = icon.iconColour
                    imageData = icon.iconImage
                }
            ),
            symbol: BotAvatar.defaultSymbol,
            symbols: Self.symbols,
            encoding: .jpeg(quality: 0.86),
            avatar: avatar
        )
    }
}

struct GroupInfoSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversation: BotConversation
    @State private var name: String
    @State private var publicDescription: String
    @State private var selectedIDs: Set<UUID>
    @State private var folders: [AgentFolder]
    @State private var backgroundDraft: BackgroundSelection?
    @State private var confirmingDeletion = false
    @FocusState private var nameFocused: Bool

    init(conversation: BotConversation) {
        self.conversation = conversation
        _name = State(initialValue: conversation.displayName)
        _publicDescription = State(initialValue: conversation.publicDescription ?? "")
        _selectedIDs = State(initialValue: Set(conversation.participantIDs))
        _folders = State(initialValue: conversation.folders ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                Spacer()
                Text("Group Info").font(.headline)
                Spacer()
                Button("Save", action: save)
                .buttonStyle(.plain)
                .foregroundStyle(canSave ? Color.blue : .secondary)
                .disabled(!canSave)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ConversationAvatar(
                        participants: selectedBots,
                        isGroup: true,
                        size: 64
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Group name", text: $name, axis: .horizontal)
                            .lineLimit(1)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(false)
                            .focused($nameFocused)
                            .onSubmit { if canSave { save() } }
                        Text(selectedIDs.count == 1 ? "1 bot" : "\(selectedIDs.count) bots")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NameValidationMessage(name: name)

                GroupDescriptionEditor(publicDescription: $publicDescription)

                GroupMemberPicker(agents: store.groupCandidates(on: store.hubMirror(forConversation: conversation.id)),
                                  selectedIDs: $selectedIDs)

                Text("Add at least one bot. Membership changes apply to future messages.")
                    .font(.caption)
                    .foregroundStyle(!selectedIDs.isEmpty ? Color.secondary : Color.red)

                // A Hub's bots run there, out of reach of this Mac's folders.
                if store.hubMirror(forConversation: conversation.id) == nil {
                    FoldersSettingsRow(folders: $folders, owner: .group)
                }

                ConversationBackgroundSettingsRow(conversation: conversation, draft: $backgroundDraft)

                Divider()

                DestructiveActionButton(title: "Delete Group") {
                    confirmingDeletion = true
                }
            }
            .padding(20)
        }
        .frame(width: 460)
        .confirmationDialog(
            "Delete Group?",
            isPresented: $confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Group", role: .destructive) {
                if store.delete(conversation) { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.deletionMessage(for: conversation))
        }
        .onAppear { nameFocused = true }
    }

    private var selectedBots: [AgentRecord] {
        store.agents.filter { selectedIDs.contains($0.id) }
    }

    private func save() {
        if store.saveSettings(background: backgroundDraft, for: conversation, saving: {
            store.updateGroup(conversation, named: name, publicDescription: publicDescription, participantIDs: selectedIDs,
                              folders: folders)
        }) {
            dismiss()
        }
    }

    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = publicDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConversationName.error(for: name) == nil && !selectedIDs.isEmpty && (
            trimmedName != conversation.displayName ||
                trimmedDescription != (conversation.publicDescription ?? "") ||
                selectedIDs != Set(conversation.participantIDs) || folders != (conversation.folders ?? []) || backgroundDraft != nil
        )
    }
}

private struct PointingHandCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        PointingHandCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class PointingHandCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct NewGroupSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var publicDescription = ""
    @State private var selectedIDs = Set<UUID>()
    @State private var folders: [AgentFolder] = []
    /// The joined Hub to keep the group on, or nil for this Mac.
    @State private var hubID: ObjectIdentifier?
    @FocusState private var nameFocused: Bool

    init(participantIDs: Set<UUID> = []) {
        _selectedIDs = State(initialValue: participantIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                Spacer()
                Text("New Group").font(.headline)
                Spacer()
                Button("Create") {
                    _ = store.createGroup(
                        named: name,
                        publicDescription: publicDescription,
                        participantIDs: selectedIDs,
                        folders: hub == nil ? folders : [],
                        on: hub
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(canCreate ? Color.blue : .secondary)
                .disabled(!canCreate)
            }
            .padding(16)

            Divider()

            TextField("Group name", text: $name, axis: .horizontal)
                .lineLimit(1)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            NameValidationMessage(name: name)
                .padding(.horizontal, 16)

            GroupDescriptionEditor(publicDescription: $publicDescription)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            // Only someone who joined a Hub chooses: a group is all this Mac's bots, or all one Hub's.
            if !store.hubMirrors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Location").font(.caption.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        GroupLocationTile(title: "This Mac", systemImage: "laptopcomputer", isSelected: hubID == nil) {
                            hubID = nil
                        }
                        ForEach(store.hubMirrors, id: \.pairing.directory) { mirror in
                            GroupLocationTile(title: mirror.pairing.hub?.name ?? "Noodle Hub", systemImage: "server.rack",
                                              isSelected: hubID == ObjectIdentifier(mirror)) {
                                hubID = ObjectIdentifier(mirror)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .onChange(of: hubID) { selectedIDs.formIntersection(candidates.map(\.id)) }
            }

            GroupMemberPicker(agents: candidates, selectedIDs: $selectedIDs)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)

            Text("Add at least one bot. You can change the members later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)

            if hub == nil {
                FoldersSettingsRow(folders: $folders, owner: .group)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
        .frame(width: 480)
        .onAppear {
            nameFocused = true
            // In a Hub's space, on that Hub, so the new group shows there.
            hubID = store.groupCreationHub(participantIDs: selectedIDs).map(ObjectIdentifier.init)
        }
    }

    private var hub: HubMirror? { store.hubMirrors.first { ObjectIdentifier($0) == hubID } }

    private var candidates: [AgentRecord] { store.groupCandidates(on: hub) }

    private var canCreate: Bool {
        ConversationName.error(for: name) == nil && !selectedIDs.isEmpty
    }
}

/// Where a new group is kept: this Mac or one joined Hub, chosen as one tile among them.
private struct GroupLocationTile: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct GroupDescriptionEditor: View {
    @Binding var publicDescription: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description")
                .font(.caption.weight(.semibold))

            TextField(
                "Describe the purpose and context of this group…",
                text: $publicDescription,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)
            .autocorrectionDisabled(false)

            Text("Shared with every bot in this group so they understand its purpose.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
