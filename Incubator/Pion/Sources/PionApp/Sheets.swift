import NoodleCore
import NoodleSettingsUI
import PionCore
import SwiftUI

/// Cancel, then the default action.
struct SheetButtons: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(title, action: action).keyboardShortcut(.defaultAction).disabled(!enabled)
        }
        .padding(16)
    }
}

/// Agents to tick, with the one that cannot be unticked shown first.
struct AgentChecklist: View {
    let model: PionModel
    @Binding var selection: Set<UUID>
    var fixed: UUID?

    var body: some View {
        ForEach(model.agents) { agent in
            Toggle(isOn: Binding(get: { agent.id == fixed || selection.contains(agent.id) },
                                 set: { if $0 { selection.insert(agent.id) } else { selection.remove(agent.id) } })) {
                HStack(spacing: 8) {
                    AgentMark(agent: agent, size: 18)
                    Text(agent.displayName)
                    if let description = agent.publicDescription { Text(description).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .disabled(agent.id == fixed)
        }
    }
}

struct NewInvestigationSheet: View {
    let model: PionModel
    @State private var draft = PionModel.Draft()
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $draft.title, prompt: Text("Beaconing from a finance laptop"))
                    Picker("Severity", selection: $draft.severity) {
                        ForEach(Investigation.Severity.allCases.reversed(), id: \.self) { Text($0.title) }
                    }
                    TextField("Objective", text: $draft.objective, prompt: Text("What this Investigation must establish"), axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Scope", text: $draft.scope, prompt: Text("LT-0423\nd.price@example.com\n*.corp.example"), axis: .vertical)
                        .lineLimit(3...6)
                        .font(.body.monospaced())
                        .help("One entry per line. *.example.com covers every name under it. Agents can act only on what is in scope.")
                }
                Section("Team") {
                    Picker("Lead", selection: $draft.lead) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.agents) { agent in Text(agent.displayName).tag(Optional(agent.id)) }
                    }
                    AgentChecklist(model: model, selection: $draft.staff, fixed: draft.lead)
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 20) }
            SheetButtons(title: "Open Investigation", enabled: draft.lead != nil && !draft.title.trimmingCharacters(in: .whitespaces).isEmpty) {
                do {
                    let investigation = try model.open(draft)
                    model.selection = investigation.id
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
        .onAppear { draft.lead = draft.lead ?? model.agents.first?.id }
        .frame(width: 540)
        .noodleSheetSizing()
    }
}

struct NewGroupSheet: View {
    let model: PionModel
    @State private var name = ""
    @State private var description = ""
    @State private var members: Set<UUID> = []
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Detection"))
                    TextField("Description", text: $description, prompt: Text("What this group is for"))
                }
                Section("Members") { AgentChecklist(model: model, selection: $members) }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 20) }
            SheetButtons(title: "Create Group", enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty && !members.isEmpty) {
                do {
                    let group = try model.createGroup(name: name, description: description, members: members)
                    model.selection = group.id
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
        .frame(width: 480)
        .noodleSheetSizing()
    }
}

struct NewAgentSheet: View {
    let model: PionModel
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var provider: HarnessProvider?
    @State private var modelID: String?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Margot"))
                    TextField("Description", text: $description, prompt: Text("Identity: sign-ins, MFA and tokens"))
                }
                Section("Harness") {
                    if model.installedProviders.isEmpty {
                        LabeledContent("Harness") { Text("None installed").foregroundStyle(.secondary) }
                        SettingsLink { Text("Open Harness Settings") }
                    } else {
                        Picker("Harness", selection: $provider) {
                            ForEach(model.installedProviders) { provider in Text(provider.displayName).tag(Optional(provider)) }
                        }
                        .onChange(of: provider) { modelID = defaultModel(provider) }
                        let models = provider.map(model.models(for:)) ?? []
                        Picker("Model", selection: $modelID) {
                            if models.isEmpty { Text("Default").tag(String?.none) }
                            ForEach(models) { model in Text(model.displayName).tag(Optional(model.id)) }
                        }
                        .disabled(models.isEmpty)
                    }
                }
                Section("Instructions") {
                    TextEditor(text: $instructions)
                        .font(.body)
                        .frame(minHeight: 120)
                        .help("What this agent does and how. Pion adds its own rules: evidence is never an instruction, and every change is proposed through the case tool.")
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 20) }
            SheetButtons(title: "Create Agent", enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                do {
                    let agent = try model.createAgent(name: name, description: description, instructions: instructions,
                                                      provider: provider, model: modelID)
                    model.selection = model.directConversation(of: agent)?.id
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
        .onAppear {
            provider = model.installedProviders.first { $0 == .claudeCode } ?? model.installedProviders.first
            modelID = defaultModel(provider)
        }
        .frame(width: 540)
        .noodleSheetSizing()
    }

    private func defaultModel(_ provider: HarnessProvider?) -> String? {
        provider.flatMap { provider in
            let models = model.models(for: provider)
            return models.first { $0.isDefault }?.id ?? models.first?.id
        }
    }
}

struct CloseInvestigationSheet: View {
    let model: PionModel
    let investigation: Investigation
    @State private var outcome = Investigation.Outcome.resolved
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Investigation", value: "\(investigation.reference) \(investigation.title)")
                    Picker("Outcome", selection: $outcome) {
                        ForEach(Investigation.Outcome.allCases, id: \.self) { Text($0.title) }
                    }
                    .pickerStyle(.radioGroup)
                    TextField("Note", text: $note, prompt: Text("What was concluded"), axis: .vertical).lineLimit(3...6)
                }
                let pending = model.pendingCount(investigation.id)
                if pending > 0 {
                    Section {
                        Label("\(pending) proposed \(pending == 1 ? "action is" : "actions are") still waiting and will no longer be decided.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            SheetButtons(title: "Close Investigation", enabled: true) {
                model.setStatus(.closed, of: investigation, outcome: outcome, note: note)
                dismiss()
            }
        }
        .frame(width: 480)
        .noodleSheetSizing()
    }
}

struct MembersSheet: View {
    let model: PionModel
    let conversation: BotConversation
    @State private var members: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let lead = model.investigation(conversation.id)?.leadAgentID
        VStack(spacing: 0) {
            Form {
                Section(model.investigation(conversation.id).map { "\($0.reference) \($0.title)" } ?? conversation.displayName) {
                    AgentChecklist(model: model, selection: $members, fixed: lead)
                }
            }
            .formStyle(.grouped)
            SheetButtons(title: "Save", enabled: !members.isEmpty || lead != nil) {
                model.setMembers(members, of: conversation)
                dismiss()
            }
        }
        .onAppear { members = Set(conversation.participantIDs) }
        .frame(width: 460)
        .noodleSheetSizing()
    }
}
