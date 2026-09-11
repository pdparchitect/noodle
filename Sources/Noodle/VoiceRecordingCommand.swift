import AppKit
import SwiftUI

/// Published by the visible composer so menu commands follow the key chat
/// window, including when focus is in its sidebar rather than its text editor.
struct VoiceRecordingCommand {
    private let presentation: @MainActor () -> (title: String, isEnabled: Bool)
    private let toggle: () -> Void

    @MainActor var title: String { presentation().title }
    @MainActor var isEnabled: Bool { presentation().isEnabled }

    @available(macOS 26.0, *)
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

    @MainActor func perform() {
        guard isEnabled, NSApp.modalWindow == nil, let window = NSApp.keyWindow,
              window.attachedSheet == nil, window.sheetParent == nil else { return }
        // Holding the shortcut must not stop a recording as soon as startup
        // completes and the command becomes enabled again.
        if let event = NSApp.currentEvent, event.type == .keyDown {
            if event.isARepeat { return }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            if modifiers.contains(.command), modifiers != [.command, .shift] { return }
        }
        toggle()
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

    var body: some Commands {
        CommandMenu("Conversation") {
            Button("Search Conversations", action: search)
                .keyboardShortcut("f", modifiers: .command)
            if #available(macOS 26.0, *) {
                Divider()
                Button(command?.title ?? "Record Voice Message") { command?.perform() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(command?.isEnabled != true)
            }
        }
    }
}
