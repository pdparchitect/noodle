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
            case .editInvestigation(let investigation): NewInvestigationSheet(model: model, investigation: model.investigation(investigation.id) ?? investigation)
            case .chooseConversation: ConversationPicker(model: model, selection: $selection)
            case .close(let investigation): CloseInvestigationSheet(model: model, investigation: investigation)
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

/// The team as Noodle shows a group's members: marks in a grid, each removable, with more added from
/// a searchable list. The lead stays, marked as such, while it leads.
struct AgentMemberPicker: View {
    let model: PionModel
    @Binding var selection: Set<UUID>
    var fixed: UUID?
    @State private var adding = false
    @State private var search = ""

    private var members: [AgentRecord] { model.agents.filter { $0.id == fixed || selection.contains($0.id) } }
    private var available: [AgentRecord] {
        model.agents.filter { $0.id != fixed && !selection.contains($0.id)
            && (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Members").font(.caption.weight(.semibold))
                Spacer()
                Button { search = ""; adding = true } label: { Label("Add Agents", systemImage: "plus") }
                    .disabled(model.agents.allSatisfy { $0.id == fixed || selection.contains($0.id) })
                    .popover(isPresented: $adding, arrowEdge: .bottom) { chooser }
            }
            ScrollView {
                if members.isEmpty {
                    Button { search = ""; adding = true } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.largeTitle)
                            Text("Add agents to the team")
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12, alignment: .top)], spacing: 16) {
                        ForEach(members) { agent in
                            VStack(spacing: 6) {
                                AgentProfileButton(model: model, agent: agent, size: 44, inSheet: true)
                                    .overlay(alignment: .topTrailing) {
                                        if agent.id != fixed {
                                            Button { selection.remove(agent.id) } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 16))
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, Color(nsColor: .darkGray))
                                                    .padding(4)
                                                    .contentShape(Circle())
                                            }
                                            .buttonStyle(.plain)
                                            .offset(x: 10, y: -8)
                                            .help("Remove \(agent.displayName)")
                                            .accessibilityLabel("Remove \(agent.displayName)")
                                        }
                                    }
                                Text(agent.displayName).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                if agent.id == fixed {
                                    Text("Lead").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .padding(12)
                }
            }
            // A few rows, then it scrolls rather than pushing the sheet past the window.
            .frame(minHeight: 120, maxHeight: 260)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var chooser: some View {
        VStack(spacing: 12) {
            TextField("Search agents", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(available) { agent in
                        Button { selection.insert(agent.id) } label: {
                            HStack(spacing: 10) {
                                AgentMark(agent: agent, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(agent.displayName).foregroundStyle(.primary)
                                    if let description = agent.publicDescription {
                                        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add \(agent.displayName)")
                    }
                    if available.isEmpty {
                        Text(search.isEmpty ? "Every agent is on the team" : "No matching agents").foregroundStyle(.secondary).padding()
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320, height: 300)
    }
}

/// The sections of an editor, centred at their own width, as in Noodle's bot editor.
private struct SheetTabPicker<Tab: RawRepresentable & CaseIterable & Hashable>: View where Tab.RawValue == String, Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Picker("Section", selection: $selection.animation(reduceMotion ? nil : .easeInOut(duration: 0.22))) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .center)
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

private enum TeamEditorTab: String, CaseIterable {
    case general = "General", team = "Team", tools = "Tools"
}

struct NewInvestigationSheet: View {
    let model: PionModel
    let investigation: Investigation?
    @State private var draft = PionModel.Draft()
    @State private var loaded = false
    @State private var selectedTab = TeamEditorTab.general
    @State private var error: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: PionModel, investigation: Investigation? = nil) { self.model = model; self.investigation = investigation }

    private var members: Set<UUID> { draft.staff.union(draft.lead.map { [$0] } ?? []) }
    private var canSave: Bool {
        loaded && investigation?.isClosed != true && draft.lead != nil && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(heading: investigation == nil ? "New Investigation" : "Edit Investigation", title: investigation == nil ? "Create" : "Save",
                        enabled: canSave, action: save)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    SymbolMark(symbol: "shield.lefthalf.filled", size: 56)
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Title", text: $draft.title, axis: .horizontal)
                            .lineLimit(1)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14))
                            .autocorrectionDisabled(false)
                            .focused($titleFocused)
                            .onSubmit(save)
                        Text(investigation.map { "\($0.reference), opened \($0.openedAt.pionShort)" } ?? "Gets the next reference when created.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SheetTabPicker(selection: $selectedTab)
                switch selectedTab {
                case .general:
                    Picker("Severity", selection: $draft.severity) {
                        ForEach(Investigation.Severity.allCases.reversed(), id: \.self) { Text($0.title) }
                    }
                    SheetDescriptionField(title: "Objective", prompt: "What this investigation must establish", text: $draft.objective)
                    SheetInstructionsEditor(title: "Scope", text: $draft.scope, height: 100, monospaced: true)
                        .help("One entry per line. *.example.com covers every name under it. Agents can act only on what is in scope.")
                    FoldersSettingsRow(folders: $draft.folders, owner: .group)
                case .team:
                    Picker("Lead", selection: $draft.lead) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.agents) { agent in Text(agent.displayName).tag(Optional(agent.id)) }
                    }
                    AgentMemberPicker(model: model, selection: $draft.staff, fixed: draft.lead)
                case .tools:
                    TeamToolsPicker(model: model, members: members, assignments: $draft.memberTools)
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            .padding(20)
        }
        .onAppear {
            guard !loaded else { return }
            if let investigation, let group = model.conversation(investigation.id) {
                draft = PionModel.Draft(title: investigation.title, objective: investigation.objective,
                    scope: investigation.scope.joined(separator: "\n"), severity: investigation.severity,
                    lead: investigation.leadAgentID, staff: Set(group.participantIDs), folders: group.folders ?? [])
            } else { draft.lead = model.agents.first?.id }
            loaded = true
            titleFocused = true
        }
        .frame(width: 540)
        .noodleSheetSizing()
    }

    private func save() {
        guard canSave else { return }
        do {
            var chosen = draft
            chosen.memberTools = draft.memberTools.filter { members.contains($0.key) }
            if let investigation {
                try model.updateInvestigation(investigation, draft: chosen)
            } else {
                let created = try model.open(chosen)
                model.selection = created.id
            }
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
    @State private var folders: [AgentFolder] = []
    @State private var memberTools: [UUID: Set<UUID>] = [:]
    @State private var selectedTab = TeamEditorTab.general
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
                HStack(spacing: 14) {
                    SymbolMark(symbol: "person.3.fill", size: 56)
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Group name", text: $name, axis: .horizontal)
                            .lineLimit(1)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 14))
                            .autocorrectionDisabled(false)
                            .focused($nameFocused)
                            .onSubmit(save)
                        Text(members.count == 1 ? "1 agent" : "\(members.count) agents").font(.caption).foregroundStyle(.secondary)
                    }
                }
                SheetNameValidation(name: name)
                SheetTabPicker(selection: $selectedTab)
                switch selectedTab {
                case .general:
                    SheetDescriptionField(title: "Description", prompt: "Describe the purpose and context of this group…", text: $description)
                    FoldersSettingsRow(folders: $folders, owner: .group)
                case .team:
                    AgentMemberPicker(model: model, selection: $members)
                case .tools:
                    TeamToolsPicker(model: model, members: members, assignments: $memberTools)
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
                folders = group.folders ?? []
            }
            nameFocused = true
        }
        .frame(width: 520)
        .noodleSheetSizing()
    }

    private func save() {
        guard canSave else { return }
        do {
            let assignments = memberTools.filter { members.contains($0.key) }
            if let group {
                try model.updateGroup(group, name: name, description: description, members: members, folders: folders, memberTools: assignments)
            } else {
                let created = try model.createGroup(name: name, description: description, members: members, folders: folders, memberTools: assignments)
                model.selection = created.id
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

enum AgentEditorTab: String, CaseIterable {
    case general = "General", runtime = "Harness", tools = "Tools"
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
    @State private var effort = ""
    @State private var resources = PionModel.AgentResources()
    @State private var selectedTab = AgentEditorTab.general
    @State private var newID = UUID()
    @State private var choosingHarness = false
    @State private var choosingProfile = false
    @State private var choosingModel = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: PionModel, agent: AgentRecord? = nil, initialTab: AgentEditorTab = .general) {
        self.model = model
        self.agent = agent
        _selectedTab = State(initialValue: initialTab)
    }

    private var selectedNameStyle: BotNameStyle { BotNameStyle(rawValue: nameStyle) ?? PionModel.defaultAgentNameStyle }
    private var canSave: Bool { loaded && ConversationName.error(for: name) == nil }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(heading: agent == nil ? "New Agent" : "Edit Agent", title: agent == nil ? "Create" : "Save",
                        enabled: canSave, action: save)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    // The mark is drawn from the agent's identity; a new agent's can be drawn again until it is created.
                    if let agent {
                        AgentMark(agent: agent, size: 56)
                    } else {
                        Button { newID = UUID() } label: { AgentSigil(seed: newID, size: 56) }
                            .buttonStyle(.plain)
                            .help("Try Another Mark")
                            .accessibilityLabel("Try Another Mark")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        ZStack(alignment: .trailing) {
                            TextField("Agent name", text: $name, axis: .horizontal)
                                .lineLimit(1)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 14))
                                .autocorrectionDisabled(false)
                                .focused($nameFocused)
                                .onSubmit(save)
                            Menu {
                                Picker("Name Style", selection: $nameStyle) {
                                    Text("Generated Names").tag(BotNameStyle.playful.rawValue)
                                    Text("Human Names").tag(BotNameStyle.real.rawValue)
                                }
                                .pickerStyle(.inline)
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            } primaryAction: {
                                name = model.suggestedAgentName(style: selectedNameStyle, excluding: name)
                                nameFocused = true
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .padding(.trailing, 6)
                            .help("Try Another Name")
                            .accessibilityLabel("Generate Another Name")
                            .onChange(of: nameStyle) {
                                if agent == nil { name = model.suggestedAgentName(style: selectedNameStyle, excluding: name) }
                            }
                        }
                        Text("You can rename this agent later without changing its workspace.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                SheetNameValidation(name: name)
                SheetTabPicker(selection: $selectedTab)
                switch selectedTab {
                case .general:
                    SheetDescriptionField(title: "Description", prompt: "Briefly describe what this agent does…", text: $description)
                    SheetInstructionsEditor(title: "Instructions", text: $instructions)
                        .help("What this agent does and how. Pion adds its own rules: evidence is never an instruction, and every change is proposed through the case tool.")
                    FoldersSettingsRow(folders: $resources.folders, owner: .bot)
                case .runtime:
                    harnessFields
                case .tools:
                    PionToolAssignmentPicker(controller: model.mcp, selectedIDs: $resources.connections)
                }
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
                    effort = agent.reasoningEffort ?? ""
                    resources = try model.resources(for: agent)
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

    /// Noodle's harness rows and choosers, as its bot editor shows them.
    private var harnessFields: some View {
        let profiles = provider.map { model.harnessProfiles.profiles(for: $0) } ?? []
        let models = provider.map { model.models(for: $0, profile: resources.profile) } ?? []
        let selectedModel = models.first { $0.id == modelID }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Harness").font(.caption.weight(.semibold))
            VStack(spacing: 0) {
                Button { choosingHarness = true } label: {
                    RuntimeSelectionRow(title: "Harness", value: provider?.displayName ?? "Choose a harness",
                                        icon: AnyView(Group {
                                            if let provider { HarnessProviderIcon(provider: provider) } else { Image(systemName: "terminal") }
                                        }))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $choosingHarness, arrowEdge: .leading) {
                    HarnessChooser(installations: model.runtime.availableInstallations, selection: Binding(
                        get: { provider?.rawValue ?? "" },
                        set: { identifier in
                            provider = HarnessProvider(rawValue: identifier)
                            resources.profile = nil
                            modelID = defaultModel(provider)
                            effort = ""
                        }))
                }
                if !profiles.isEmpty {
                    Divider().padding(.leading, 44)
                    Button { choosingProfile = true } label: {
                        RuntimeSelectionRow(title: "Profile", value: model.harnessProfiles.profile(resources.profile)?.displayName ?? "Default",
                                            icon: AnyView(Image(systemName: "person.crop.circle")))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $choosingProfile, arrowEdge: .leading) {
                        HarnessProfileChooser(profiles: profiles, selection: Binding(
                            get: { resources.profile },
                            set: { resources.profile = $0; modelID = defaultModel(provider) }))
                    }
                }
                Divider().padding(.leading, 44)
                Button { choosingModel = true } label: {
                    RuntimeSelectionRow(title: "Model", value: selectedModel?.displayName ?? modelID ?? "Default",
                                        icon: AnyView(Image(systemName: "cube.transparent")), tag: selectedModel?.tag,
                                        isLoading: model.runtime.isLoadingCapabilities)
                }
                .buttonStyle(.plain)
                .disabled(models.isEmpty)
                .popover(isPresented: $choosingModel, arrowEdge: .leading) {
                    ModelChooser(providerName: provider?.displayName ?? "Harness", usesCatalogueDefault: provider == .apple, models: models,
                                 selection: Binding(get: { modelID ?? "" }, set: { id in
                                     modelID = id.isEmpty ? nil : id
                                     if let chosen = models.first(where: { $0.id == id }),
                                        !chosen.supportedEfforts.contains(where: { $0.id == effort }) { effort = chosen.defaultEffort }
                                 }))
                }
                if provider != .apple || selectedModel?.supportedEfforts.isEmpty == false {
                    Divider().padding(.leading, 44)
                    EffortControl(model: selectedModel, selection: $effort)
                }
            }
            .background(Color.secondary.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.11)) }
            HarnessExperimentalWarning(provider: provider)
            if model.installedProviders.isEmpty {
                HStack {
                    Text("No harness is installed yet.").font(.caption).foregroundStyle(.secondary)
                    SettingsLink { Text("Open Harness Settings") }.buttonStyle(.link).font(.caption)
                }
            }
            if agent != nil {
                Text("Saving restarts the agent. Its workspace and history stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            if let agent {
                try model.updateAgent(agent, name: name, description: description, instructions: instructions,
                                      provider: provider, model: modelID, effort: effort, resources: resources)
            } else {
                let created = try model.createAgent(name: name, description: description, instructions: instructions,
                                                    provider: provider, model: modelID, effort: effort.isEmpty ? nil : effort, resources: resources,
                                                    id: newID)
                model.selection = model.directConversation(of: created)?.id
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func defaultModel(_ provider: HarnessProvider?) -> String? {
        provider.flatMap { provider in
            let models = model.models(for: provider, profile: resources.profile)
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
                .pickerStyle(.segmented)
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

/// Tool access belongs to each agent, even when edited from a team's conversation.
private struct TeamToolsPicker: View {
    let model: PionModel
    let members: Set<UUID>
    @Binding var assignments: [UUID: Set<UUID>]
    @State private var expanded: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if members.isEmpty {
                ContentUnavailableView("No Team Members", systemImage: "person.2")
            }
            ForEach(model.agents.filter { members.contains($0.id) }) { agent in
                let count = (assignments[agent.id] ?? model.mcp.selectedIDs(for: agent)).count
                DisclosureGroup(isExpanded: Binding(get: { expanded == agent.id }, set: { expanded = $0 ? agent.id : nil })) {
                    PionToolAssignmentPicker(controller: model.mcp, selectedIDs: Binding(
                        get: { assignments[agent.id] ?? model.mcp.selectedIDs(for: agent) },
                        set: { assignments[agent.id] = $0 }))
                        .padding(.top, 8)
                } label: {
                    HStack {
                        AgentMark(agent: agent, size: 20)
                        Text(agent.displayName)
                        Spacer()
                        Text(count == 1 ? "1 tool" : "\(count) tools").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded = expanded == agent.id ? nil : agent.id } }
                }
                .help("Tool assignments apply to this agent in every conversation.")
            }
        }
        .onAppear { expanded = model.agents.first(where: { members.contains($0.id) })?.id }
    }
}

/// Saved connections, their setup and sign-in are shared with Settings; this editor only drafts grants.
private struct PionToolAssignmentPicker: View {
    let controller: MCPController
    @Binding var selectedIDs: Set<UUID>
    @State private var showingAdd = false
    @State private var wantsNew = false
    @State private var creating = false
    @State private var editing: MCPConnectionRecord?
    @State private var search = ""

    private var known: Set<UUID> { Set(controller.registry.connections.map(\.id)) }
    private var selected: [MCPConnectionRecord] { controller.registry.connections.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tools").font(.headline)
                Spacer()
                Button { search = ""; showingAdd = true } label: { Label("Add Tools…", systemImage: "plus") }
                    .buttonStyle(.link)
                    .popover(isPresented: $showingAdd, arrowEdge: .bottom) { chooser }
            }
            ScrollView {
                if selectedIDs.isEmpty {
                    Button { search = ""; showingAdd = true } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "puzzlepiece.extension").font(.largeTitle)
                            Text("Add Tools…")
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 190)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else {
                    VStack(spacing: 6) {
                        ForEach(selected) { connection in
                            HStack(spacing: 10) {
                                MCPConnectionIcon(connection: connection, size: 26)
                                Text(connection.name).lineLimit(1)
                                MCPConnectionMaturityBadge(connection: connection)
                                Spacer()
                                Menu {
                                    Button("Edit Connection…") { editing = connection }
                                    Divider()
                                    Button("Remove", role: .destructive) { selectedIDs.remove(connection.id) }
                                } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                            }.padding(8)
                        }
                        ForEach(selectedIDs.subtracting(known).sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                            HStack {
                                Label("Unavailable Tool", systemImage: "exclamationmark.triangle")
                                Spacer()
                                Button("Remove") { selectedIDs.remove(id) }.buttonStyle(.link)
                            }.padding(8)
                        }
                    }
                }
            }
            .frame(height: 220)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        }
        .sheet(isPresented: $creating) {
            ToolCreationSheet(controller: controller, onAdded: { selectedIDs.insert($0) }).noodleSheetSizing()
        }
        .sheet(item: $editing) { connection in
            MCPEditor(controller: controller, existing: connection).noodleSheetSizing()
        }
    }

    private var chooser: some View {
        VStack(spacing: 12) {
            TextField("Search connections", text: $search).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(controller.registry.connections.filter {
                        !selectedIDs.contains($0.id) && (search.isEmpty || $0.name.localizedStandardContains(search))
                    }) { connection in
                        Button { selectedIDs.insert(connection.id) } label: {
                            HStack(spacing: 10) {
                                MCPConnectionIcon(connection: connection, size: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connection.name).foregroundStyle(.primary)
                                    Text(connection.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Button("New Tool") { wantsNew = true; showingAdd = false }.buttonStyle(.link)
                Spacer()
            }
        }
        .padding(16)
        .frame(width: 330, height: 280)
        .onDisappear {
            if wantsNew { wantsNew = false; creating = true }
        }
    }
}
