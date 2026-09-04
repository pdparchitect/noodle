import SwiftUI
import SuperBotCore

struct NewBotSheet: View {
    @Environment(SuperBotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedHarnessIdentifier = HarnessProvider.codex.rawValue
    @State private var selectedModelIdentifier = ""
    @State private var selectedEffort = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "New Bot", createTitle: "Create") {
                create()
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    BotPreview(name: name)
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

                GroupBox {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Private app workspace")
                                .font(.system(size: 12.5, weight: .semibold))
                            Text("SuperBot creates an opaque UUID folder containing agent.json, instructions.md, and memory.md.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "folder.badge.gearshape")
                            .foregroundStyle(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
            .padding(20)
        }
        .frame(width: 520, height: 500)
        .onAppear {
            nameFocused = true
            store.runtime.refreshCapabilities()
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
            reasoningEffort: selectedEffort.nilIfEmpty
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
    @Environment(SuperBotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let agent: AgentRecord
    @State private var name: String
    @State private var selectedHarnessIdentifier: String
    @State private var selectedModelIdentifier: String
    @State private var selectedEffort: String
    @State private var confirmingDeletion = false
    @FocusState private var nameFocused: Bool

    init(agent: AgentRecord) {
        self.agent = agent
        _name = State(initialValue: agent.displayName)
        _selectedHarnessIdentifier = State(initialValue: agent.harnessIdentifier ?? HarnessProvider.codex.rawValue)
        _selectedModelIdentifier = State(initialValue: agent.modelIdentifier ?? "")
        _selectedEffort = State(initialValue: agent.reasoningEffort ?? "")
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
                    BotAvatar(agent: agent, size: 64)
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

                Text("Saving restarts this bot with the selected Codex model. Its workspace and conversation history stay unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                Divider()

                Button("Delete Bot\u{2026}", role: .destructive) {
                    confirmingDeletion = true
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
        }
        .frame(width: 520, height: 490)
        .onAppear {
            nameFocused = true
            store.runtime.refreshCapabilities()
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

    private func save() {
        if store.updateAgent(
            agent,
            name: name,
            harnessIdentifier: selectedHarnessIdentifier,
            modelIdentifier: selectedModelIdentifier.nilIfEmpty,
            reasoningEffort: selectedEffort.nilIfEmpty
        ) {
            dismiss()
        }
    }
}

struct GroupInfoSheet: View {
    @Environment(SuperBotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let conversation: BotConversation
    @State private var confirmingDeletion = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                Spacer()
                Text("Group Info").font(.headline)
                Spacer()
                Color.clear.frame(width: 34, height: 1)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    ConversationAvatar(
                        participants: store.participants(for: conversation),
                        isGroup: true,
                        size: 64
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.displayName)
                            .font(.title3.weight(.semibold))
                        Text("\(store.participants(for: conversation).count) bots")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Bots") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.participants(for: conversation)) { agent in
                            HStack(spacing: 9) {
                                BotAvatar(agent: agent, size: 28)
                                Text(agent.displayName)
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
                Divider()

                Button("Delete Group\u{2026}", role: .destructive) {
                    confirmingDeletion = true
                }
            }
            .padding(20)
        }
        .frame(width: 460, height: 420)
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
}

private struct AgentConfigurationFields: View {
    @Environment(SuperBotStore.self) private var store
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
        } else if let selectedModel, !selectedModel.description.isEmpty {
            Text(selectedModel.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Models and effort levels are reported directly by the selected harness.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct NewGroupSheet: View {
    @Environment(SuperBotStore.self) private var store
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

            List(store.agents) { agent in
                Toggle(isOn: selectionBinding(for: agent.id)) {
                    HStack(spacing: 10) {
                        BotAvatar(agent: agent, size: 34)
                        Text(agent.displayName)
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.vertical, 4)
            }
            .listStyle(.inset)

            Text("Choose at least two bots")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
        .frame(width: 480, height: 440)
        .onAppear { nameFocused = true }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedIDs.count >= 2
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isSelected in
                if isSelected {
                    selectedIDs.insert(id)
                } else {
                    selectedIDs.remove(id)
                }
            }
        )
    }
}

private struct BotPreview: View {
    let name: String

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            if let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first {
                Text(String(first).uppercased())
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .offset(y: 18)
            }
        }
        .frame(width: 64, height: 64)
    }
}
