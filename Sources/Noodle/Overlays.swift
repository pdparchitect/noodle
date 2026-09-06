import AppKit
import ImageIO
import PhotosUI
import SwiftUI
import NoodleCore

struct NewBotSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedHarnessIdentifier = HarnessProvider.codex.rawValue
    @State private var selectedModelIdentifier = ""
    @State private var selectedEffort = ""
    @State private var backstory = ""
    @State private var avatarSymbolName: String? = "sparkles"
    @State private var avatarColorIndex = Int.random(in: BotAvatarPalette.gradients.indices)
    @State private var avatarImageData: Data?
    @State private var editingAvatar = false
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
                        TextField("Bot name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14))
                            .focused($nameFocused)
                            .onSubmit {
                                if canCreate { create() }
                            }
                        Text("You can rename this bot later without changing its workspace location.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                AgentConfigurationFields(
                    selectedHarnessIdentifier: $selectedHarnessIdentifier,
                    selectedModelIdentifier: $selectedModelIdentifier,
                    selectedEffort: $selectedEffort
                )

                BotBackstoryEditor(backstory: $backstory)

                Spacer()
            }
            .padding(20)
        }
        .frame(width: 520, height: 650)
        .onAppear {
            nameFocused = true
            store.runtime.refreshCapabilities()
        }
        .sheet(isPresented: $editingAvatar) {
            BotIconEditor(
                name: name,
                symbolName: $avatarSymbolName,
                colorIndex: $avatarColorIndex,
                imageData: $avatarImageData
            )
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            store.runtime.availableInstallations.contains {
                $0.provider.rawValue == selectedHarnessIdentifier
            }
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
            backstory: backstory
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
    @State private var backstory = ""
    @State private var avatarSymbolName: String?
    @State private var avatarColorIndex: Int
    @State private var avatarImageData: Data?
    @State private var editingAvatar = false
    @State private var confirmingDeletion = false
    @FocusState private var nameFocused: Bool

    init(agent: AgentRecord) {
        self.agent = agent
        _name = State(initialValue: agent.displayName)
        _selectedHarnessIdentifier = State(initialValue: agent.harnessIdentifier ?? HarnessProvider.codex.rawValue)
        _selectedModelIdentifier = State(initialValue: agent.modelIdentifier ?? "")
        _selectedEffort = State(initialValue: agent.reasoningEffort ?? "")
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

                    TextField("Bot name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { if canSave { save() } }
                }

                AgentConfigurationFields(
                    selectedHarnessIdentifier: $selectedHarnessIdentifier,
                    selectedModelIdentifier: $selectedModelIdentifier,
                    selectedEffort: $selectedEffort
                )

                BotBackstoryEditor(backstory: $backstory)

                Text("Saving restarts this bot with the selected Codex model. Its workspace and conversation history stay unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let conversation = directConversation {
                    ConversationBackgroundSettingsRow(conversation: conversation)
                }

                Spacer()

                Divider()

                Button("Delete Bot\u{2026}", role: .destructive) {
                    confirmingDeletion = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .frame(width: 520, height: 710)
        .onAppear {
            nameFocused = true
            backstory = store.backstory(for: agent)
            store.runtime.refreshCapabilities()
        }
        .sheet(isPresented: $editingAvatar) {
            BotIconEditor(
                name: name,
                symbolName: $avatarSymbolName,
                colorIndex: $avatarColorIndex,
                imageData: $avatarImageData
            )
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

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            store.runtime.availableInstallations.contains {
                $0.provider.rawValue == selectedHarnessIdentifier
            }
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
        if store.updateAgent(
            agent,
            name: name,
            harnessIdentifier: selectedHarnessIdentifier,
            modelIdentifier: selectedModelIdentifier.nilIfEmpty,
            reasoningEffort: selectedEffort.nilIfEmpty,
            avatarSymbolName: avatarSymbolName,
            avatarColorIndex: avatarColorIndex,
            avatarImageData: avatarImageData,
            backstory: backstory
        ) {
            dismiss()
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
                    .scrollContentBackground(.hidden)
                    .padding(4)
            }
            .frame(height: 160)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.18))
            }

            Text("Saved as this bot’s editable Backstory in AGENTS.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct BotIconEditor: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    @Binding var symbolName: String?
    @Binding var colorIndex: Int
    @Binding var imageData: Data?

    @State private var editedSymbolName: String?
    @State private var editedColorIndex: Int
    @State private var editedImageData: Data?
    @State private var photoSelection: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var photoError: String?

    private let symbols = [
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

    init(
        name: String,
        symbolName: Binding<String?>,
        colorIndex: Binding<Int>,
        imageData: Binding<Data?>
    ) {
        self.name = name
        _symbolName = symbolName
        _colorIndex = colorIndex
        _imageData = imageData
        _editedSymbolName = State(initialValue: symbolName.wrappedValue ?? "sparkles")
        _editedColorIndex = State(initialValue: colorIndex.wrappedValue)
        _editedImageData = State(initialValue: imageData.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                Spacer()
                Text("Bot Icon").font(.headline)
                Spacer()
                Button("Done") {
                    symbolName = editedSymbolName
                    colorIndex = editedColorIndex
                    imageData = editedImageData
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            .padding(16)

            Divider()

            VStack(spacing: 18) {
                BotAvatar(agent: previewAgent, size: 104)
                    .padding(.top, 4)

                HStack(spacing: 10) {
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Label("Choose Photo…", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)

                    if editedImageData != nil {
                        Button("Use Generated Icon") {
                            editedImageData = nil
                            photoSelection = nil
                        }
                        .buttonStyle(.bordered)
                    }

                    if isLoadingPhoto { ProgressView().controlSize(.small) }
                }

                if let photoError {
                    Text(photoError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                GroupBox("Colour") {
                    HStack(spacing: 12) {
                        ForEach(BotAvatarPalette.gradients.indices, id: \.self) { index in
                            Button {
                                editedColorIndex = index
                                editedImageData = nil
                            } label: {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: BotAvatarPalette.gradients[index],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        if editedImageData == nil && normalizedColorIndex == index {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Colour \(index + 1)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }

                GroupBox("Symbol") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                            Button {
                                editedSymbolName = symbol
                                editedImageData = nil
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(
                                            isSelected(symbol)
                                                ? Color.accentColor
                                                : Color.secondary.opacity(0.14)
                                        )
                                    Image(systemName: symbol)
                                        .font(.system(size: 18, weight: .semibold))
                                }
                                .foregroundStyle(
                                    isSelected(symbol) ? Color.white : Color.primary
                                )
                                .frame(height: 42)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol)
                        }
                    }
                    .padding(8)
                }

                Spacer()
            }
            .padding(20)
        }
        .frame(width: 440, height: 520)
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
    }

    private var normalizedColorIndex: Int {
        abs(editedColorIndex) % BotAvatarPalette.gradients.count
    }

    private var previewAgent: AgentRecord {
        var preview = AgentRecord(
            displayName: name.isEmpty ? "Bot" : name,
            accentSeed: editedColorIndex
        )
        preview.avatarSymbolName = editedSymbolName
        preview.avatarColorIndex = editedColorIndex
        preview.avatarImageData = editedImageData
        return preview
    }

    private func isSelected(_ symbol: String?) -> Bool {
        editedImageData == nil && editedSymbolName == symbol
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        isLoadingPhoto = true
        photoError = nil
        defer { isLoadingPhoto = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let prepared = Self.preparedAvatarData(from: data) else {
                photoError = "That image could not be used."
                return
            }
            editedImageData = prepared
        } catch {
            photoError = error.localizedDescription
        }
    }

    private static func preparedAvatarData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { return nil }

        return NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.86]
        )
    }
}

struct GroupInfoSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversation: BotConversation
    @State private var selectedIDs: Set<UUID>
    @State private var confirmingDeletion = false

    init(conversation: BotConversation) {
        self.conversation = conversation
        _selectedIDs = State(initialValue: Set(conversation.participantIDs))
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
                Button("Save") {
                    if store.updateGroup(conversation, participantIDs: selectedIDs) {
                        dismiss()
                    }
                }
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
                        Text(conversation.displayName)
                            .font(.title3.weight(.semibold))
                        Text(selectedIDs.count == 1 ? "1 bot" : "\(selectedIDs.count) bots")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupMemberPicker(agents: store.agents, selectedIDs: $selectedIDs)

                Text("Add at least one bot. Membership changes apply to future messages.")
                    .font(.caption)
                    .foregroundStyle(!selectedIDs.isEmpty ? Color.secondary : Color.red)

                ConversationBackgroundSettingsRow(conversation: conversation)

                Spacer()
                Divider()

                Button("Delete Group\u{2026}", role: .destructive) {
                    confirmingDeletion = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(20)
        }
        .frame(width: 460, height: 560)
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
    }

    private var selectedBots: [AgentRecord] {
        store.agents.filter { selectedIDs.contains($0.id) }
    }

    private var canSave: Bool {
        !selectedIDs.isEmpty && selectedIDs != Set(conversation.participantIDs)
    }
}

private struct AgentConfigurationFields: View {
    @Environment(NoodleStore.self) private var store
    @Binding var selectedHarnessIdentifier: String
    @Binding var selectedModelIdentifier: String
    @Binding var selectedEffort: String

    private var models: [HarnessModel] {
        store.runtime.models(for: selectedHarnessIdentifier)
    }

    private var selectedModel: HarnessModel? {
        models.first { $0.id == selectedModelIdentifier }
    }

    var body: some View {
        GroupBox("Agent Runtime") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Harness", selection: $selectedHarnessIdentifier) {
                    ForEach(store.runtime.availableInstallations) { installation in
                        Label(installation.provider.displayName, systemImage: installation.provider.symbolName)
                            .tag(installation.provider.rawValue)
                    }
                }

                Divider()

                Picker("Model", selection: $selectedModelIdentifier) {
                    Text("Codex default").tag("")
                    ForEach(models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .disabled(store.runtime.isLoadingCapabilities)

                Picker("Effort", selection: $selectedEffort) {
                    Text("Model default").tag("")
                    ForEach(selectedModel?.supportedEfforts ?? []) { effort in
                        Text(effort.displayName).tag(effort.id)
                    }
                }
                .disabled(selectedModel == nil)

                capabilityDetail
            }
            .padding(.top, 4)
        }
        .onChange(of: selectedHarnessIdentifier) { _, _ in
            selectedModelIdentifier = ""
            selectedEffort = ""
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
    }

    @ViewBuilder
    private var capabilityDetail: some View {
        if store.runtime.isLoadingCapabilities {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Reading models from Codex…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let provider = HarnessProvider(rawValue: selectedHarnessIdentifier),
                  let error = store.runtime.capabilityErrors[provider] {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct NewGroupSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedIDs = Set<UUID>()
    @FocusState private var nameFocused: Bool

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
                    _ = store.createGroup(named: name, participantIDs: selectedIDs)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canCreate ? Color.blue : .secondary)
                .disabled(!canCreate)
            }
            .padding(16)

            Divider()

            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .padding(16)

            GroupMemberPicker(agents: store.agents, selectedIDs: $selectedIDs)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            Text("Add at least one bot. You can change the members later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
        .frame(width: 480, height: 440)
        .onAppear { nameFocused = true }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selectedIDs.isEmpty
    }
}
