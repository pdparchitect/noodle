import NoodleHubClient
import HubLink
import NoodleBrand
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleSettingsUI
import RookCore
import SwiftUI

struct ConversationSheets: ViewModifier {
    let model: RookModel
    @Bindable var window: WindowState
    @Binding var selection: UUID?

    func body(content: Content) -> some View {
        content.sheet(item: $window.sheet) { sheet in
            switch sheet {
            case .newMission: NewMissionSheet(model: model)
            case .newGroup: GroupEditorSheet(model: model)
            case .newAgent: AgentEditorSheet(model: model)
            case .editAgent(let agent): AgentEditorSheet(model: model, agent: model.agent(agent.id) ?? agent)
            case .editGroup(let group): GroupEditorSheet(model: model, group: model.conversation(group.id) ?? group)
            case .editMission(let mission): NewMissionSheet(model: model, mission: model.mission(mission.id) ?? mission)
            case .close(let mission): CloseMissionSheet(model: model, mission: mission)
            }
        }
    }
}

struct ConversationChoiceRow: View {
    let model: RookModel
    let conversation: BotConversation
    var line = ConversationRowDetail.standard

    var body: some View {
        if let mission = model.mission(conversation.id) {
            MissionRow(model: model, mission: mission)
        } else if conversation.kind == .group {
            GroupRow(model: model, group: conversation, line: line)
        } else if let agent = model.agent(conversation.participantIDs.first) {
            AgentRow(model: model, agent: agent, unread: model.countsAsUnread(conversation.id),
                     conversation: conversation, line: line)
        }
    }
}

/// Noodle's member picker, with Rook's words and agent marks.
extension GroupMemberPicker {
    init(model: RookModel, selection: Binding<Set<UUID>>, lead: Binding<UUID?>) {
        // Every agent, as in Noodle: an archived member shows greyed until removed, and is never offered to add.
        self.init(agents: model.everyAgent, selectedIDs: selection, lead: lead,
                  words: GroupMemberWords(bot: "agent", bots: "agents", group: "team"),
                  member: { AnyView(AgentProfileButton(model: model, agent: $0, size: 48, inSheet: true)) },
                  chooserPicture: { AnyView(AgentMark(agent: $0, size: 32)) })
    }
}

/// A note of several lines: Return starts a new line, and the field grows with the text, and the sheet with
/// it, up to about twelve lines, then scrolls.
private struct SheetNoteEditor: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var footnote: String?
    @State private var textHeight: CGFloat = 0
    private static let font = Font.system(size: 13)
    private static let minimum: CGFloat = 64, maximum: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            TextEditor(text: $text)
                .font(Self.font)
                .autocorrectionDisabled(false)
                .accessibilityLabel(title)
                .frame(height: min(max(textHeight, Self.minimum), Self.maximum))
                .background(alignment: .topLeading) {
                    // The text as the editor lays it out, measured but not shown, so the field knows its height.
                    Text(text.isEmpty ? " " : text + "\n")
                        .font(Self.font)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
                }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(prompt).font(Self.font).foregroundStyle(.tertiary)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .roundedBorderEditor()
            if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct NewMissionSheet: View {
    let model: RookModel
    let mission: Mission?
    @State private var draft = RookModel.Draft()
    @State private var loaded = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: RookModel, mission: Mission? = nil) { self.model = model; self.mission = mission }

    private var canSave: Bool {
        loaded && mission?.isClosed != true && !draft.members.isEmpty
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(heading: mission == nil ? "New Mission" : "Edit Mission", title: mission == nil ? "Create" : "Save",
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
                        Text(mission.map { "\($0.reference), opened \($0.openedAt.rookShort)" } ?? "Gets the next reference when created.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                // As Noodle's group sheets: what it is for, who is on it, then the folders they share.
                SheetDescriptionField(title: "Objective", prompt: "Describe what this mission must establish…", text: $draft.objective,
                                      footnote: "Shared with every agent on the team as the goal they work toward.")
                GroupMemberPicker(model: model, selection: $draft.staff, lead: $draft.lead)
                TeamFootnote(isNew: mission == nil, setsSeverity: true, isEmpty: draft.members.isEmpty)
                FoldersSettingsRow(folders: $draft.folders, owner: .group)
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            .padding(20)
        }
        .onAppear {
            guard !loaded else { return }
            if let mission, let group = model.conversation(mission.id) {
                draft = RookModel.Draft(title: mission.title, objective: mission.objective,
                    lead: group.lead, staff: Set(group.participantIDs), folders: group.folders ?? [])
            }
            loaded = true
            titleFocused = true
        }
        .frame(width: 540)
        .noodleSheetSizing()
    }

    private func save() {
        guard canSave else { return }
        do {
            if let mission {
                try model.updateMission(mission, draft: draft)
            } else {
                let created = try model.open(draft)
                model.selection = created.id
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct GroupEditorSheet: View {
    let model: RookModel
    let group: BotConversation?
    @State private var loaded = false
    @State private var name = ""
    @State private var description = ""
    @State private var members: Set<UUID> = []
    @State private var lead: UUID?
    @State private var folders: [AgentFolder] = []
    @State private var error: String?
    @State private var confirmingDeletion = false
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: RookModel, group: BotConversation? = nil) { self.model = model; self.group = group }

    /// As in Noodle, an existing group's Save waits for a change.
    private var canSave: Bool {
        guard ConversationName.error(for: name) == nil, !members.isEmpty else { return false }
        guard let group else { return true }
        return group.editChanges(name: name, description: description, members: members, folders: folders, lead: lead)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(heading: group == nil ? "New Group" : "Group Info", title: group == nil ? "Create" : "Save",
                        enabled: canSave, action: save)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    // The chosen members' pieces, the lead's in front, changing as they are picked.
                    GroupSigil(members: (lead.map { [$0] } ?? []) + model.agents.filter { members.contains($0.id) && $0.id != lead }
                                   .sorted { $0.displayName < $1.displayName }.map(\.id), size: 56)
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
                NameValidationMessage(name: name)
                // Noodle's Group Info, in its order: description, members, folders, then Delete.
                SheetDescriptionField(title: "Description", prompt: "Describe the purpose and context of this group…", text: $description,
                                      footnote: "Shared with every agent in this group so they understand its purpose.")
                GroupMemberPicker(model: model, selection: $members, lead: $lead)
                TeamFootnote(isNew: group == nil, setsSeverity: false, isEmpty: members.isEmpty)
                FoldersSettingsRow(folders: $folders, owner: .group)
                if group != nil {
                    Divider()
                    DestructiveActionButton(title: "Delete Group") { confirmingDeletion = true }
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
                lead = group.lead
                folders = group.folders ?? []
            }
            nameFocused = true
        }
        .frame(width: 520)
        .noodleSheetSizing()
        .confirmationDialog("Delete Group?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete Group", role: .destructive) {
                if let group, model.delete(group) { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let group { Text(ConversationDeletion.message(name: group.displayName, isDirect: false, bots: "agents")) }
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            if let group {
                let updated = try model.updateGroup(group, name: name, description: description, members: members, folders: folders)
                if updated.lead != lead { model.setLead(lead, of: updated) }
            } else {
                let created = try model.createGroup(name: name, description: description, members: members, folders: folders, lead: lead)
                model.selection = created.id
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Under the team grid, as Noodle's group sheets have it, and how a lead is chosen; red while no one is on it.
private struct TeamFootnote: View {
    let isNew: Bool
    let setsSeverity: Bool
    let isEmpty: Bool

    var body: some View {
        let members = isNew ? "You can change the members later." : "Membership changes apply to future messages."
        let lead = setsSeverity ? "it hears your messages first and sets the severity." : "it hears your messages first."
        Text("Add at least one agent. \(members) Right-click an agent to make it the lead: \(lead)")
            .font(.caption).foregroundStyle(isEmpty ? Color.red : Color.secondary)
    }
}

enum AgentEditorTab: String, CaseIterable {
    case general = "General", runtime = "Harness"
}

struct AgentEditorSheet: View {
    let model: RookModel
    let agent: AgentRecord?
    @AppStorage(RookModel.agentNameStyleKey) private var nameStyle = RookModel.defaultAgentNameStyle.rawValue
    @State private var loaded = false
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    @State private var provider: HarnessProvider?
    @State private var modelID: String?
    @State private var effort = ""
    @State private var resources = RookModel.AgentResources()
    /// Empty leaves the voice to the harness.
    @State private var voice = ""
    /// Once a voice is picked it stays; until then it follows the name, as in Noodle.
    @State private var hasChosenVoice = false
    @State private var confirmingDeletion = false
    @Environment(RookSettingsHost.self) private var host
    @State private var selectedTab = AgentEditorTab.general
    @State private var newID = UUID()
    @State private var error: String?
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: RookModel, agent: AgentRecord? = nil, initialTab: AgentEditorTab = .general) {
        self.model = model
        self.agent = agent
        _selectedTab = State(initialValue: initialTab)
    }

    private var selectedNameStyle: BotNameStyle { BotNameStyle(rawValue: nameStyle) ?? RookModel.defaultAgentNameStyle }
    /// As in Noodle, a new agent needs an installed harness.
    private var canSave: Bool {
        loaded && ConversationName.error(for: name) == nil && (agent != nil || provider.map(model.installedProviders.contains) == true)
    }

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
                            // The borderless menu brings padding of its own, so little more puts it as near the edge as Noodle's.
                            .padding(.trailing, 2)
                            .help("Try Another Name")
                            .accessibilityLabel("Generate Another Name")
                            .onChange(of: nameStyle) {
                                if agent == nil { name = model.suggestedAgentName(style: selectedNameStyle, excluding: name) }
                            }
                        }
                        Text("You can rename this agent later without changing its workspace location.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                NameValidationMessage(name: name)
                SheetTabPicker(selection: $selectedTab)
                switch selectedTab {
                case .general:
                    SheetDescriptionField(title: "Description", prompt: "Briefly describe what this agent does…", text: $description,
                                          footnote: "Visible to other agents in shared groups and Missions. The private backstory below is never included.")
                    SheetInstructionsEditor(title: "Backstory", text: $instructions,
                                            prompt: "Describe who this agent is, its role, tone, or priorities…",
                                            footnote: "Who this agent is and what it cares about. Only this agent sees it.")
                        .help("What this agent does and how. Rook adds its own rules: it stays in the mission's scope, treats what targets return as evidence, and clears anything intrusive with you first.")
                    FoldersSettingsRow(folders: $resources.folders, owner: .bot)
                    if agent != nil {
                        Divider()
                        DestructiveActionButton(title: "Delete Agent") { confirmingDeletion = true }
                    }
                case .runtime:
                    harnessFields
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
                    voice = model.voice(of: agent)
                    hasChosenVoice = !voice.isEmpty
                } else {
                    name = model.suggestedAgentName(style: selectedNameStyle)
                    selectInstalledHarnessIfNeeded()
                }
                loaded = true
                nameFocused = true
                model.runtime.refreshCapabilities()
            } catch { self.error = error.localizedDescription }
        }
        // As in Noodle: a harness installed while the sheet is open becomes a new agent's harness.
        .onChange(of: model.installedProviders) { if agent == nil { selectInstalledHarnessIfNeeded() } }
        .frame(width: 540)
        .noodleSheetSizing()
        .followsNameForVoice($voice, chosen: $hasChosenVoice, name: name, harnessIdentifier: provider?.rawValue ?? "") {
            await BotVoice.fitting(name: $0, harnessIdentifier: $1, guesser: AppleVoicePresentationGuesser())
        }
        // As Noodle's Delete Bot: it asks first, saying what goes with the agent.
        .confirmationDialog("Delete Agent?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete Agent", role: .destructive) {
                if let agent, model.delete(agent: agent) { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let agent { Text(ConversationDeletion.message(name: agent.displayName, isDirect: true, bots: "agents")) }
        }
    }

    /// Keeps a new agent's harness one that is installed, Claude Code first.
    private func selectInstalledHarnessIfNeeded() {
        let installed = model.installedProviders
        if let provider, installed.contains(provider) { return }
        provider = installed.first { $0 == .claudeCode } ?? installed.first
        modelID = defaultModel(provider)
    }

    /// Noodle's harness rows and choosers, as its bot editor shows them.
    private var harnessFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentConfigurationFields(store: model, setup: host.setup,
                selectedHarnessIdentifier: Binding(get: { provider?.rawValue ?? "" }, set: { provider = HarnessProvider(rawValue: $0) }),
                selectedModelIdentifier: Binding(get: { modelID ?? "" }, set: { modelID = $0.isEmpty ? nil : $0 }),
                selectedEffort: $effort, selectedProfileID: $resources.profile,
                selectedVoice: Binding(get: { voice }, set: { voice = $0; hasChosenVoice = true }), agent: agent,
                workspace: agent.map { model.repository.directory(for: $0) })
            if model.installedProviders.isEmpty {
                HStack {
                    Text("No harness is installed yet.").font(.caption).foregroundStyle(.secondary)
                    SettingsLink { Text("Open Harness Settings") }.buttonStyle(.accentLink).font(.caption)
                }
            }
            if let agent {
                BotBudgetSettingsRow(store: model, agent: agent)
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
                let updated = try model.updateAgent(agent, name: name, description: description, instructions: instructions,
                                                    provider: provider, model: modelID, effort: effort, resources: resources)
                model.setVoice(voice, for: updated)
            } else {
                let created = try model.createAgent(name: name, description: description, instructions: instructions,
                                                    provider: provider, model: modelID, effort: effort.isEmpty ? nil : effort, resources: resources,
                                                    id: newID)
                if !voice.isEmpty { model.setVoice(voice, for: created) }
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

struct CloseMissionSheet: View {
    let model: RookModel
    let mission: Mission
    @State private var outcome = Mission.Outcome.demonstrated
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(heading: "Close Mission", title: "Close", enabled: true) {
                model.setStatus(.closed, of: mission, outcome: outcome, note: note)
                dismiss()
            }
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Text("\(mission.reference) \(mission.title)").font(.headline)
                Picker("Outcome", selection: $outcome) {
                    ForEach(Mission.Outcome.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                SheetNoteEditor(title: "Note", prompt: "Describe what was concluded…", text: $note,
                                footnote: "Posted to the team and kept with the outcome in the audit log.")
            }
            .padding(20)
        }
        .frame(width: 480)
        .noodleSheetSizing()
    }
}

/// Rook runs its agents on this Mac alone, so nothing is lent by a Hub.
extension RookModel: AgentConfigurationHost {
    func harnessChoices(for agent: AgentRecord?) -> (installations: [HarnessInstallation], hubs: [HubHarnessSection]) {
        (runtime.availableInstallations, [])
    }

    func lentHarness(_ choice: HubHarnessChoice) -> (harness: LinkHarness?, hubName: String?) { (nil, nil) }
}
