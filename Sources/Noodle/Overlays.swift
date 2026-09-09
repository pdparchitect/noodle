import AppKit
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import NoodleCore

private enum BotEditorTab: String, CaseIterable {
    case general = "General", runtime = "Runtime", mcp = "Tools"
}

private struct BotEditorTabPicker: View {
    @Binding var selection: BotEditorTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Picker("Bot settings", selection: $selection.animation(reduceMotion ? nil : .easeInOut(duration: 0.22))) {
            ForEach(BotEditorTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
        }.pickerStyle(.segmented).labelsHidden()
    }
}

private struct NameValidationMessage: View {
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
    @State private var selectedHarnessIdentifier = HarnessProvider.codex.rawValue
    @State private var selectedModelIdentifier = ""
    @State private var selectedEffort = ""
    @State private var publicDescription = ""
    @State private var backstory = ""
    @State private var avatarSymbolName: String? = "sparkles"
    @State private var avatarColorIndex = Int.random(in: BotAvatarPalette.gradients.indices)
    @State private var avatarImageData: Data?
    @State private var editingAvatar = false
    @State private var mcpConnectionIDs: Set<UUID> = []
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

                BotEditorTabPicker(selection: $selectedTab)
                switch selectedTab {
                case .general:
                    BotPublicDescriptionEditor(publicDescription: $publicDescription)
                    BotBackstoryEditor(backstory: $backstory)
                case .runtime:
                    AgentConfigurationFields(
                        selectedHarnessIdentifier: $selectedHarnessIdentifier,
                        selectedModelIdentifier: $selectedModelIdentifier,
                        selectedEffort: $selectedEffort
                    )
                case .mcp:
                    MCPAssignmentPicker(controller: store.mcp, selectedIDs: $mcpConnectionIDs)
                }
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear {
            if name.isEmpty { name = BotNameGenerator.random(style: selectedBotNameStyle) }
            if !store.runtime.availableInstallations.contains(where: {
                $0.provider.rawValue == selectedHarnessIdentifier
            }), let first = store.runtime.availableInstallations.first {
                selectedHarnessIdentifier = first.provider.rawValue
            }
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
            .noodleSheetSizing()
        }
    }

    private var canCreate: Bool {
        ConversationName.error(for: name) == nil &&
            store.runtime.availableInstallations.contains {
                $0.provider.rawValue == selectedHarnessIdentifier
            }
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
            mcpConnectionIDs: mcpConnectionIDs
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
    @State private var publicDescription: String
    @State private var backstory = ""
    @State private var avatarSymbolName: String?
    @State private var avatarColorIndex: Int
    @State private var avatarImageData: Data?
    @State private var editingAvatar = false
    @State private var mcpConnectionIDs: Set<UUID> = []
    @State private var confirmingDeletion = false
    @State private var selectedTab = BotEditorTab.general
    @FocusState private var nameFocused: Bool

    init(agent: AgentRecord) {
        self.agent = agent
        _name = State(initialValue: agent.displayName)
        _selectedHarnessIdentifier = State(initialValue: agent.harnessIdentifier ?? HarnessProvider.codex.rawValue)
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

                BotEditorTabPicker(selection: $selectedTab)
                switch selectedTab {
                case .general:
                    BotPublicDescriptionEditor(publicDescription: $publicDescription)
                    BotBackstoryEditor(backstory: $backstory)
                    if let conversation = directConversation {
                        ConversationBackgroundSettingsRow(conversation: conversation)
                    }
                    Divider()
                    Button("Delete Bot\u{2026}", role: .destructive) {
                        confirmingDeletion = true
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .runtime:
                    AgentConfigurationFields(
                        selectedHarnessIdentifier: $selectedHarnessIdentifier,
                        selectedModelIdentifier: $selectedModelIdentifier,
                        selectedEffort: $selectedEffort
                    )
                    Text("Saving restarts the bot. Its workspace and history stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .mcp:
                    MCPAssignmentPicker(controller: store.mcp, selectedIDs: $mcpConnectionIDs)
                }
            }
            .padding(20)
        }
        .frame(width: 520)
        .onAppear {
            nameFocused = true
            backstory = store.backstory(for: agent)
            mcpConnectionIDs = store.mcp.selectedIDs(for: agent)
            store.runtime.refreshCapabilities()
        }
        .sheet(isPresented: $editingAvatar) {
            BotIconEditor(
                name: name,
                symbolName: $avatarSymbolName,
                colorIndex: $avatarColorIndex,
                imageData: $avatarImageData
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

    private var canSave: Bool {
        ConversationName.error(for: name) == nil &&
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
            publicDescription: publicDescription,
            backstory: backstory,
            mcpConnectionIDs: mcpConnectionIDs
        ) {
            dismiss()
        }
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
    @Environment(\.dismiss) private var dismiss
    let name: String
    @Binding var symbolName: String?
    @Binding var colorIndex: Int
    @Binding var imageData: Data?

    @State private var editedSymbolName: String?
    @State private var editedColorIndex: Int
    @State private var editedImageData: Data?
    @State private var photoSelection: PhotosPickerItem?
    @State private var choosingFile = false
    @State private var choosingPhoto = false
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

                GroupBox("Image") {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Menu {
                                Button("Choose File…", systemImage: "folder") {
                                    choosingFile = true
                                }
                                Button("Photos Library…", systemImage: "photo.on.rectangle") {
                                    photoSelection = nil
                                    choosingPhoto = true
                                }
                            } label: {
                                Label("Choose Image…", systemImage: "photo")
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(maxWidth: .infinity)

                            if #available(macOS 15.1, *) {
                                NoodleImagePlaygroundButton(
                                    sourceImageData: editedImageData
                                ) { url in
                                    Task { await loadImage(at: url, requiresSecurityScope: false) }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }

                        Divider()

                        Button {
                            editedImageData = nil
                            photoSelection = nil
                        } label: {
                            Label(
                                editedImageData == nil ? "Using Symbol" : "Use Symbol Instead",
                                systemImage: editedImageData == nil ? "checkmark" : "square.grid.2x2"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(editedImageData == nil)

                        if isLoadingPhoto {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(8)
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

            }
            .padding(20)
        }
        .frame(width: 440)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                Task { await loadImage(at: url, requiresSecurityScope: true) }
            case .failure(let error):
                photoError = error.localizedDescription
            }
        }
        .photosPicker(
            isPresented: $choosingPhoto,
            selection: $photoSelection,
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
    }

    @MainActor
    private func loadImage(at url: URL, requiresSecurityScope: Bool) async {
        isLoadingPhoto = true
        photoError = nil
        defer { isLoadingPhoto = false }

        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let accessed = requiresSecurityScope && url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }

                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 50 * 1_024 * 1_024 else { throw BotIconImageError.tooLarge }
                return try Data(contentsOf: url)
            }.value

            guard let prepared = Self.preparedAvatarData(from: data) else {
                throw BotIconImageError.invalidImage
            }
            editedImageData = prepared
            photoSelection = nil
        } catch {
            photoError = error.localizedDescription
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

private enum BotIconImageError: LocalizedError {
    case invalidImage
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "That image could not be used."
        case .tooLarge:
            "Choose an image smaller than 50 MB."
        }
    }
}

struct GroupInfoSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversation: BotConversation
    @State private var name: String
    @State private var publicDescription: String
    @State private var selectedIDs: Set<UUID>
    @State private var confirmingDeletion = false
    @FocusState private var nameFocused: Bool

    init(conversation: BotConversation) {
        self.conversation = conversation
        _name = State(initialValue: conversation.displayName)
        _publicDescription = State(initialValue: conversation.publicDescription ?? "")
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
                    if store.updateGroup(
                        conversation,
                        named: name,
                        publicDescription: publicDescription,
                        participantIDs: selectedIDs
                    ) {
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
                        TextField("Group name", text: $name, axis: .horizontal)
                            .lineLimit(1)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled(false)
                            .focused($nameFocused)
                            .onSubmit {
                                if canSave,
                                   store.updateGroup(
                                       conversation,
                                       named: name,
                                       publicDescription: publicDescription,
                                       participantIDs: selectedIDs
                                   ) {
                                    dismiss()
                                }
                            }
                        Text(selectedIDs.count == 1 ? "1 bot" : "\(selectedIDs.count) bots")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NameValidationMessage(name: name)

                GroupDescriptionEditor(publicDescription: $publicDescription)

                GroupMemberPicker(agents: store.agents, selectedIDs: $selectedIDs)

                Text("Add at least one bot. Membership changes apply to future messages.")
                    .font(.caption)
                    .foregroundStyle(!selectedIDs.isEmpty ? Color.secondary : Color.red)

                ConversationBackgroundSettingsRow(conversation: conversation)

                Divider()

                Button("Delete Group\u{2026}", role: .destructive) {
                    confirmingDeletion = true
                }
                .buttonStyle(.bordered)
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

    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = publicDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConversationName.error(for: name) == nil && !selectedIDs.isEmpty && (
            trimmedName != conversation.displayName ||
                trimmedDescription != (conversation.publicDescription ?? "") ||
                selectedIDs != Set(conversation.participantIDs)
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
                    _ = store.createGroup(
                        named: name,
                        publicDescription: publicDescription,
                        participantIDs: selectedIDs
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

            GroupMemberPicker(agents: store.agents, selectedIDs: $selectedIDs)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            Text("Add at least one bot. You can change the members later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
        .frame(width: 480)
        .onAppear { nameFocused = true }
    }

    private var canCreate: Bool {
        ConversationName.error(for: name) == nil && !selectedIDs.isEmpty
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
