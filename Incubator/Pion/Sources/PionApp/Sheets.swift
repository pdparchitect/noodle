import NoodleBrand
import NoodleCore
import NoodleRuntimeSettings
import NoodleSettingsUI
import PionCore
import SwiftUI

struct ConversationSheets: ViewModifier {
    let model: PionModel
    @Bindable var window: WindowState
    @Binding var selection: UUID?

    func body(content: Content) -> some View {
        content.sheet(item: $window.sheet) { sheet in
            switch sheet {
            case .newInvestigation: NewInvestigationSheet(model: model)
            case .newGroup: GroupEditorSheet(model: model)
            case .newAgent: AgentEditorSheet(model: model)
            case .editAgent(let agent): AgentEditorSheet(model: model, agent: model.agent(agent.id) ?? agent)
            case .editGroup(let group): GroupEditorSheet(model: model, group: model.conversation(group.id) ?? group)
            case .chooseConversation: ConversationPicker(model: model, selection: $selection)
            case .close(let investigation): CloseInvestigationSheet(model: model, investigation: investigation)
            case .members(let conversation): MembersSheet(model: model, conversation: conversation)
            }
        }
    }
}

struct ConversationChoiceRow: View {
    let model: PionModel
    let conversation: BotConversation

    var body: some View {
        if let investigation = model.investigation(conversation.id) {
            InvestigationRow(model: model, investigation: investigation)
        } else if conversation.kind == .group {
            GroupRow(model: model, group: conversation)
        } else if let agent = model.agent(conversation.participantIDs.first) {
            AgentRow(model: model, agent: agent, unread: model.isUnread(conversation.id))
        }
    }
}

struct ConversationPicker: View {
    let model: PionModel
    @Binding var selection: UUID?
    @State private var query = ""
    @State private var choice: UUID?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var matches: [BotConversation] { model.searchConversations(query) }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(heading: "Choose Conversation", title: "Open", enabled: choice != nil, action: open)
            Divider()
            TextField("Search Conversations", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit(open)
                .padding(16)
            List(selection: $choice) {
                ForEach(matches) { conversation in
                    ConversationChoiceRow(model: model, conversation: conversation).tag(conversation.id)
                }
            }
            .frame(height: 320)
            .overlay { if matches.isEmpty { ContentUnavailableView.search(text: query) } }
        }
        .onAppear { choice = selection ?? matches.first?.id; searchFocused = true }
        .onChange(of: query) { if !matches.contains(where: { $0.id == choice }) { choice = matches.first?.id } }
        .frame(width: 480)
        .noodleSheetSizing()
    }

    private func open() {
        guard let choice else { return }
        selection = choice
        dismiss()
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
            .toggleStyle(.checkbox)
            .disabled(agent.id == fixed)
        }
    }
}

private struct SheetDescriptionField: View {
    let title: String
    let prompt: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            TextField(prompt, text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .autocorrectionDisabled(false)
                .accessibilityLabel(title)
        }
    }
}

private struct SheetInstructionsEditor: View {
    let title: String
    @Binding var text: String
    var height: CGFloat = 160
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            TextEditor(text: $text)
                .font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .autocorrectionDisabled(monospaced)
                .roundedBorderEditor()
                .frame(height: height)
                .accessibilityLabel(title)
        }
    }
}

private struct SheetNameValidation: View {
    let name: String
    var body: some View {
        if !name.isEmpty, let error = ConversationName.error(for: name) {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }
}

struct NewInvestigationSheet: View {
    let model: PionModel
    @State private var draft = PionModel.Draft()
    @State private var error: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var canCreate: Bool { draft.lead != nil && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(heading: "New Investigation", title: "Create", enabled: canCreate, action: create)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                TextField("Title", text: $draft.title, axis: .horizontal)
                    .lineLimit(1)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(false)
                    .focused($titleFocused)
                    .onSubmit(create)
                Picker("Severity", selection: $draft.severity) {
                    ForEach(Investigation.Severity.allCases.reversed(), id: \.self) { Text($0.title) }
                }
                SheetDescriptionField(title: "Objective", prompt: "What this investigation must establish", text: $draft.objective)
                SheetInstructionsEditor(title: "Scope", text: $draft.scope, height: 100, monospaced: true)
                    .help("One entry per line. *.example.com covers every name under it. Agents can act only on what is in scope.")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Team").font(.caption.weight(.semibold))
                    Picker("Lead", selection: $draft.lead) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.agents) { agent in Text(agent.displayName).tag(Optional(agent.id)) }
                    }
                    AgentChecklist(model: model, selection: $draft.staff, fixed: draft.lead)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            .padding(20)
        }
        .onAppear { draft.lead = draft.lead ?? model.agents.first?.id; titleFocused = true }
        .frame(width: 540)
        .noodleSheetSizing()
    }

    private func create() {
        guard canCreate else { return }
        do {
            let investigation = try model.open(draft)
            model.selection = investigation.id
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct GroupEditorSheet: View {
    let model: PionModel
    let group: BotConversation?
    @State private var loaded = false
    @State private var name = ""
    @State private var description = ""
    @State private var members: Set<UUID> = []
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: PionModel, group: BotConversation? = nil) { self.model = model; self.group = group }

    private var canSave: Bool { ConversationName.error(for: name) == nil && !members.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(heading: group == nil ? "New Group" : "Group Info", title: group == nil ? "Create" : "Save",
                        enabled: canSave, action: save)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                TextField("Group name", text: $name, axis: .horizontal)
                    .lineLimit(1)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(false)
                    .focused($nameFocused)
                    .onSubmit(save)
                SheetNameValidation(name: name)
                SheetDescriptionField(title: "Description", prompt: "Describe the purpose and context of this group…", text: $description)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Members").font(.caption.weight(.semibold))
                    AgentChecklist(model: model, selection: $members)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            .padding(20)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let group {
                name = group.displayName
                description = group.publicDescription ?? ""
                members = Set(group.participantIDs)
            }
            nameFocused = true
        }
        .frame(width: 480)
        .noodleSheetSizing()
    }

    private func save() {
        guard canSave else { return }
        do {
            if let group {
                try model.updateGroup(group, name: name, description: description, members: members)
            } else {
                let created = try model.createGroup(name: name, description: description, members: members)
                model.selection = created.id
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct AgentEditorSheet: View {
    let model: PionModel
    let agent: AgentRecord?
    @AppStorage(PionModel.agentNameStyleKey) private var nameStyle = PionModel.defaultAgentNameStyle.rawValue
    @State private var loaded = false
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var provider: HarnessProvider?
    @State private var modelID: String?
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: PionModel, agent: AgentRecord? = nil) { self.model = model; self.agent = agent }

    private var selectedNameStyle: BotNameStyle { BotNameStyle(rawValue: nameStyle) ?? PionModel.defaultAgentNameStyle }
    private var canSave: Bool { loaded && ConversationName.error(for: name) == nil }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(heading: agent == nil ? "New Agent" : "Edit Agent", title: agent == nil ? "Create" : "Save",
                        enabled: canSave, action: save)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Picker("Name Style", selection: $nameStyle) {
                    Text("Generated").tag(BotNameStyle.playful.rawValue)
                    Text("Human").tag(BotNameStyle.real.rawValue)
                }
                .pickerStyle(.segmented)
                .onChange(of: nameStyle) {
                    if agent == nil { name = model.suggestedAgentName(style: selectedNameStyle, excluding: name) }
                }
                HStack {
                    TextField("Agent name", text: $name, axis: .horizontal)
                        .lineLimit(1)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14))
                        .autocorrectionDisabled(false)
                        .focused($nameFocused)
                        .onSubmit(save)
                    Button {
                        name = model.suggestedAgentName(style: selectedNameStyle, excluding: name)
                        nameFocused = true
                    } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Generate Another Name")
                        .accessibilityLabel("Generate Another Name")
                }
                SheetNameValidation(name: name)
                SheetDescriptionField(title: "Description", prompt: "Briefly describe what this agent does…", text: $description)
                harnessFields
                SheetInstructionsEditor(title: "Instructions", text: $instructions)
                    .help("What this agent does and how. Pion adds its own rules: evidence is never an instruction, and every change is proposed through the case tool.")
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            .padding(20)
        }
        .onAppear {
            guard !loaded else { return }
            do {
                if let agent {
                    name = agent.displayName
                    description = agent.publicDescription ?? ""
                    instructions = try model.agentInstructions(agent)
                    provider = agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:))
                    modelID = agent.modelIdentifier
                } else {
                    name = model.suggestedAgentName(style: selectedNameStyle)
                    provider = model.installedProviders.first { $0 == .claudeCode } ?? model.installedProviders.first
                    modelID = defaultModel(provider)
                }
                loaded = true
                nameFocused = true
            } catch { self.error = error.localizedDescription }
        }
        .frame(width: 540)
        .noodleSheetSizing()
    }

    private var harnessFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Harness").font(.caption.weight(.semibold))
            if model.installedProviders.isEmpty {
                LabeledContent("Harness") { Text("None installed").foregroundStyle(.secondary) }
                SettingsLink { Text("Open Harness Settings") }
            } else {
                Picker("Harness", selection: Binding(get: { provider }, set: {
                    provider = $0
                    modelID = defaultModel($0)
                })) {
                    Text("Default").tag(HarnessProvider?.none)
                    if let provider, !model.installedProviders.contains(provider) {
                        Text(provider.displayName).tag(Optional(provider))
                    }
                    ForEach(model.installedProviders) { provider in Text(provider.displayName).tag(Optional(provider)) }
                }
                let models = provider.map(model.models(for:)) ?? []
                Picker("Model", selection: $modelID) {
                    Text("Default").tag(String?.none)
                    if let modelID, !models.contains(where: { $0.id == modelID }) { Text(modelID).tag(Optional(modelID)) }
                    ForEach(models) { model in Text(model.displayName).tag(Optional(model.id)) }
                }
                .disabled(models.isEmpty)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            if let agent {
                try model.updateAgent(agent, name: name, description: description, instructions: instructions,
                                      provider: provider, model: modelID)
            } else {
                let created = try model.createAgent(name: name, description: description, instructions: instructions,
                                                    provider: provider, model: modelID)
                model.selection = model.directConversation(of: created)?.id
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
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
            SheetHeader(heading: "Close Investigation", title: "Close", enabled: true) {
                model.setStatus(.closed, of: investigation, outcome: outcome, note: note)
                dismiss()
            }
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Text("\(investigation.reference) \(investigation.title)").font(.headline)
                Picker("Outcome", selection: $outcome) {
                    ForEach(Investigation.Outcome.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.radioGroup)
                SheetDescriptionField(title: "Note", prompt: "What was concluded", text: $note)
                let pending = model.pendingCount(investigation.id)
                if pending > 0 {
                    Label("\(pending) proposed \(pending == 1 ? "action is" : "actions are") still waiting and will no longer be decided.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .padding(20)
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
            SheetHeader(heading: "Members", title: "Save", enabled: !members.isEmpty || lead != nil) {
                model.setMembers(members, of: conversation)
                dismiss()
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text(model.investigation(conversation.id).map { "\($0.reference) \($0.title)" } ?? conversation.displayName).font(.headline)
                AgentChecklist(model: model, selection: $members, fixed: lead)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .onAppear { members = Set(conversation.participantIDs) }
        .frame(width: 460)
        .noodleSheetSizing()
    }
}
