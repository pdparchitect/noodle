import AppKit
import SwiftUI
import HubLink
import NoodleCore

/// Published by the visible composer so menu commands follow the key chat
/// window, including when focus is in its sidebar rather than its text editor.
struct VoiceRecordingCommand {
    private let presentation: @MainActor () -> (title: String, isEnabled: Bool)
    private let toggle: () -> Void

    @MainActor var title: String { presentation().title }
    @MainActor var isEnabled: Bool { presentation().isEnabled }

    init(phase: @escaping @MainActor () -> VoiceRecorder.Phase,
         isSending: @escaping @MainActor () -> Bool, toggle: @escaping () -> Void) {
        // Read observable recording state in the command's own view context;
        // enabled state must update even when the composer doesn't change size.
        presentation = {
            let phase = phase()
            return (phase == .recording ? "Stop Recording" : "Record Voice Message",
                    !isSending() && (phase == .idle || phase == .recording))
        }
        self.toggle = toggle
    }

    @MainActor func perform() { perform(in: NSApp.keyWindow, bindings: .shared) }

    @MainActor func perform(in window: NSWindow?, bindings: KeyboardBindings) {
        guard isEnabled, bindings.recordingAction == nil, NSApp.modalWindow == nil, let window,
              window.attachedSheet == nil, window.sheetParent == nil else { return }
        // Holding the shortcut must not stop a recording as soon as startup
        // completes and the command becomes enabled again.
        if let event = NSApp.currentEvent, event.type == .keyDown {
            if event.isARepeat { return }
            // NSMenu can match a key equivalent with extra modifiers. Honor
            // the saved binding exactly, while allowing Return in an open menu.
            if !event.modifierFlags.intersection([.command, .control]).isEmpty,
               !bindings.matches(.recordVoice, event: event) { return }
        }
        toggle()
    }
}

/// A floating panel is not a scene, so focused scene values never reach the menu
/// from it. Its chat publishes commands here and the panel runs their shortcuts.
@MainActor final class FloatingPanelCommands {
    var voiceRecording: VoiceRecordingCommand? {
        didSet {
            guard let voiceRecording, let ready = onRecordingReady else { return }
            onRecordingReady = nil
            ready(voiceRecording)
        }
    }
    private var onRecordingReady: ((VoiceRecordingCommand) -> Void)?

    /// Runs now if the chat is showing, otherwise once its composer mounts.
    func whenRecordingReady(_ run: @escaping (VoiceRecordingCommand) -> Void) {
        if let voiceRecording { run(voiceRecording) } else { onRecordingReady = run }
    }
}

private struct FloatingPanelCommandsKey: EnvironmentKey {
    static let defaultValue: FloatingPanelCommands? = nil
}

extension EnvironmentValues {
    var floatingPanelCommands: FloatingPanelCommands? {
        get { self[FloatingPanelCommandsKey.self] }
        set { self[FloatingPanelCommandsKey.self] = newValue }
    }
}

private struct VoiceRecordingCommandKey: FocusedValueKey {
    typealias Value = VoiceRecordingCommand
}

extension FocusedValues {
    var voiceRecordingCommand: VoiceRecordingCommand? {
        get { self[VoiceRecordingCommandKey.self] }
        set { self[VoiceRecordingCommandKey.self] = newValue }
    }
}

struct ConversationCommands: Commands {
    @FocusedValue(\.voiceRecordingCommand) private var command
    let search: () -> Void
    /// Act on the key window's conversation, as the sidebar menu does for its row.
    var openInNewWindow: () -> Void = {}
    var floatOnTop: () -> Void = {}
    var isOnCall: () -> Bool = { false }
    var toggleCall: () -> Void = {}
    private let annotations = AnnotationCommandsState.shared

    var body: some Commands {
        CommandMenu("Conversation") {
            Button("Search Conversations", action: search)
                .appShortcut(.searchConversations)
            Button("Choose Conversation…") { NotificationCenter.default.post(name: .floatConversation, object: nil) }
                .appShortcut(.chooseConversation)
            Divider()
            Button("Open in New Window", action: openInNewWindow)
            Button("Float on Top", action: floatOnTop)
            Divider()
            Button("Add Annotation…") { annotations.conversationOwner?.annotate() }
                .appShortcut(.annotateSelection)
                .disabled(!annotations.conversationEnabled)
            Button("Annotate Region…") { annotations.conversationOwner?.startRegion() }
                .appShortcut(.annotateRegion)
                .disabled(!annotations.conversationEnabled)
            Divider()
            Button(command?.title ?? "Record Voice Message") { command?.perform() }
                .appShortcut(.recordVoice)
                .disabled(command?.isEnabled != true)
            Button(isOnCall() ? "End Call" : "Call") {
                // Holding the shortcut must not end the call it just started.
                if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
                toggleCall()
            }
            .appShortcut(.call)
            if NoodleAppIdentity.isDevelopment {
                Divider()
                // Plays in the key chat directly, skipping the queue a bot's effect goes through.
                Menu("Play Effect") {
                    ForEach(ConversationEffectKind.allCases, id: \.self) { kind in
                        Button(kind.rawValue.capitalized) {
                            NotificationCenter.default.post(name: .previewEffect, object: kind)
                        }
                    }
                }
            }
        }
    }
}

/// All, This Mac's, a space for each joined Hub with its bots, groups and the pins it keeps, then the spaces the
/// person made. ⌘1 is All, ⌘2 on the rest.
struct SpaceCommands: Commands {
    let store: NoodleStore

    var body: some Commands {
        // Nothing to choose until a Hub is joined or a space made; a conversation's menu makes the first.
        let choices = store.spaceChoices
        if choices.count > 1 {
            CommandMenu("Spaces") {
                SpaceChoiceItems(store: store, choices: choices)
                Divider()
                SpaceEditingItems(store: store)
            }
        }
    }
}

/// Each space as a checkmark item, its own spaces after a divider; ⌘1 is All, ⌘2 to ⌘9 the rest.
struct SpaceChoiceItems: View {
    let store: NoodleStore
    let choices: [(choice: NoodleStore.SpaceChoice, title: String)]

    var body: some View {
        ForEach(Array(choices.enumerated()), id: \.element.choice) { index, entry in
            if index > 0, Self.isCustom(entry.choice), !Self.isCustom(choices[index - 1].choice) { Divider() }
            Toggle(entry.title, isOn: Binding(get: { store.shownSpace == entry.choice }, set: { if $0 { store.show(entry.choice) } }))
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)"))) : nil)
        }
    }

    private static func isCustom(_ choice: NoodleStore.SpaceChoice) -> Bool {
        if case .custom = choice { true } else { false }
    }
}

/// Making a space, and editing them once there is something to put in order.
struct SpaceEditingItems: View {
    let store: NoodleStore

    var body: some View {
        Button("New Space…") { store.spaceNaming = .init() }
        if !store.customSpaces.isEmpty || store.hubMirrors.count > 1 {
            Button("Edit Spaces…") { store.editsSpaces = true }
        }
    }
}

/// Naming a new space, in the main window.
struct SpaceAlerts: ViewModifier {
    @Environment(NoodleStore.self) private var store
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("New Space", isPresented: Binding(get: { store.spaceNaming != nil }, set: { if !$0 { store.spaceNaming = nil } })) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Create") { save(store.spaceNaming) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .onChange(of: store.spaceNaming) { name = "" }
    }

    private func save(_ naming: NoodleStore.SpaceNaming?) {
        guard let naming, let space = store.addSpace(named: name), let conversationID = naming.adding else { return }
        store.setMember(true, of: space.id, conversationID: conversationID)
    }
}

/// The spaces the person made, to put in order, rename and delete.
struct SpaceEditorSheet: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Spaces").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            List {
                // All and This Mac stay first, so they are not listed; a joined Hub's space can only be moved.
                if store.hubMirrors.count > 1 {
                    Section {
                        ForEach(store.spaceMirrors, id: \.pairing.directory) { mirror in
                            HStack {
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                Text(mirror.pairing.hub?.name ?? "Noodle Hub")
                            }
                        }
                        .onMove(perform: store.moveHubSpaces)
                    }
                }
                Section {
                    ForEach(store.customSpaces) { space in
                        SpaceEditorRow(space: space)
                    }
                    .onMove(perform: store.moveSpaces)
                }
            }
            .frame(minHeight: 160, idealHeight: 260)
        }
        .frame(width: 360)
        .noodleSheetSizing()
        .onChange(of: store.customSpaces.isEmpty) { _, isEmpty in
            if isEmpty, store.hubMirrors.count < 2 { dismiss() }
        }
        .alert("Delete “\(store.spaceBeingDeleted?.name ?? "")”?",
               isPresented: Binding(get: { store.spaceBeingDeleted != nil }, set: { if !$0 { store.spaceBeingDeleted = nil } }),
               presenting: store.spaceBeingDeleted) { _ in
            Button("Delete", role: .destructive) { store.confirmSpaceDeletion() }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("Only the space is deleted. Its bots and groups stay in All.")
        }
    }
}

private struct SpaceEditorRow: View {
    @Environment(NoodleStore.self) private var store
    let space: CustomSpace
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(save)
            Button("Delete", systemImage: "minus.circle.fill") { store.askToDeleteSpace(space.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Delete \(space.name)")
        }
        .onAppear { name = space.name }
        .onChange(of: space.name) { _, renamed in if !focused { name = renamed } }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
        .onDisappear(perform: save)
    }

    /// An empty name puts the old one back.
    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return name = space.name }
        if trimmed != space.name { store.renameSpace(space.id, to: trimmed) }
    }
}

extension Notification.Name {
    /// Development only. The object is a `ConversationEffectKind`.
    static let previewEffect = Notification.Name("Noodle.previewEffect")
    static let floatConversation = Notification.Name("Noodle.floatConversation")
}
