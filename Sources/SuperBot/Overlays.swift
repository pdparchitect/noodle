import SwiftUI
import SuperBotCore

struct NewBotSheet: View {
    @Environment(SuperBotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedHarnessIdentifier = HarnessProvider.codex.rawValue
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(title: "New Bot", createTitle: "Create") {
                _ = store.createAgent(named: name, harnessIdentifier: selectedHarnessIdentifier)
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
                                if canCreate {
                                    _ = store.createAgent(
                                        named: name,
                                        harnessIdentifier: selectedHarnessIdentifier
                                    )
                                }
                            }
                        Text("You can rename this bot later without changing its workspace location.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Harness") {
                    Picker("Harness", selection: $selectedHarnessIdentifier) {
                        ForEach(store.runtime.availableInstallations) { installation in
                            Text(installation.provider.displayName)
                                .tag(installation.provider.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)

                    if let installation = store.runtime.installations.first(where: {
                        $0.provider.rawValue == selectedHarnessIdentifier
                    }) {
                        Label(installation.detail, systemImage: installation.provider.symbolName)
                            .font(.caption)
                            .foregroundStyle(installation.readiness == .ready ? .green : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }

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
        .frame(width: 500, height: 365)
        .onAppear {
            nameFocused = true
            if !store.runtime.availableInstallations.contains(where: {
                $0.provider.rawValue == selectedHarnessIdentifier
            }), let first = store.runtime.availableInstallations.first {
                selectedHarnessIdentifier = first.provider.rawValue
            }
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

struct RenameBotSheet: View {
    @Environment(SuperBotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let agent: AgentRecord
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(agent: AgentRecord) {
        self.agent = agent
        _name = State(initialValue: agent.displayName)
    }

    var body: some View {
        VStack(spacing: 18) {
            BotAvatar(agent: agent, size: 64)
            Text("Rename Bot").font(.headline)
            TextField("Bot name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit(rename)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Rename", action: rename)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 390)
        .onAppear {
            nameFocused = true
        }
    }

    private func rename() {
        if store.renameAgent(agent, to: name) {
            dismiss()
        }
    }
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
