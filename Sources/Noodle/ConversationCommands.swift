import AppKit
import SwiftUI
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
        if !store.hubMirrors.isEmpty || !store.customSpaces.isEmpty {
            CommandMenu("Spaces") {
                Toggle("All", isOn: Binding(get: { store.isShowingAll }, set: { if $0 { store.showSpace(nil) } }))
                    .keyboardShortcut("1")
                // Only beside a Hub: with none it would be the same as All.
                if !store.hubMirrors.isEmpty {
                    Toggle("This Mac", isOn: Binding(get: { store.showsThisMac }, set: { if $0 { store.showThisMac() } }))
                        .keyboardShortcut("2")
                }
                ForEach(Array(store.hubMirrors.enumerated()), id: \.element.pairing.directory) { index, mirror in
                    Toggle(mirror.pairing.hub?.name ?? "Noodle Hub",
                           isOn: Binding(get: { store.spaceMirror === mirror }, set: { if $0 { store.showSpace(mirror) } }))
                        .keyboardShortcut(Self.shortcut(1 + index))
                }
                if !store.customSpaces.isEmpty { Divider() }
                ForEach(Array(store.customSpaces.enumerated()), id: \.element.id) { index, space in
                    Toggle(space.name, isOn: Binding(get: { store.shownCustomSpace?.id == space.id },
                                                     set: { if $0 { store.showSpace(custom: space.id) } }))
                        .keyboardShortcut(Self.shortcut((store.hubMirrors.isEmpty ? 0 : store.hubMirrors.count + 1) + index))
                }
                Divider()
                Button("New Space…") { store.spaceNaming = .new(adding: nil) }
                if let space = store.shownCustomSpace {
                    Button("Rename Space…") { store.spaceNaming = .rename(space) }
                    Button("Delete Space") { store.spaceBeingDeleted = space }
                }
            }
        }
    }

    /// ⌘2 to ⌘9, after All.
    private static func shortcut(_ index: Int) -> KeyboardShortcut? {
        index < 8 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 2)"))) : nil
    }
}

/// Naming and deleting the spaces the person made, in the main window.
struct SpaceAlerts: ViewModifier {
    @Environment(NoodleStore.self) private var store
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(isRenaming ? "Rename Space" : "New Space",
                   isPresented: Binding(get: { store.spaceNaming != nil }, set: { if !$0 { store.spaceNaming = nil } })) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button(isRenaming ? "Rename" : "Create") { save(store.spaceNaming) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .onChange(of: store.spaceNaming) { _, naming in
                if case .rename(let space) = naming { name = space.name } else { name = "" }
            }
            .alert("Delete \(store.spaceBeingDeleted?.name ?? "Space")?",
                   isPresented: Binding(get: { store.spaceBeingDeleted != nil }, set: { if !$0 { store.spaceBeingDeleted = nil } }),
                   presenting: store.spaceBeingDeleted) { space in
                Button("Delete", role: .destructive) { store.deleteSpace(space.id) }
                Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            } message: { _ in
                Text("Its bots and groups stay in All.")
            }
    }

    private var isRenaming: Bool {
        if case .rename = store.spaceNaming { true } else { false }
    }

    private func save(_ naming: NoodleStore.SpaceNaming?) {
        switch naming {
        case .new(let conversationID):
            guard let space = store.addSpace(named: name), let conversationID else { return }
            store.setMember(true, of: space.id, conversationID: conversationID)
        case .rename(let space):
            store.renameSpace(space.id, to: name)
        case nil:
            break
        }
    }
}

extension Notification.Name {
    /// Development only. The object is a `ConversationEffectKind`.
    static let previewEffect = Notification.Name("Noodle.previewEffect")
    static let floatConversation = Notification.Name("Noodle.floatConversation")
}
