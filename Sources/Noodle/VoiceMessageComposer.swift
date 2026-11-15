import AppKit
import SwiftUI
import Speech
import NoodleCore

struct VoiceMessageComposer<Content: View>: View {
    let recorder: VoiceRecorder
    @State private var mountedRecorder: VoiceRecorder?
    @State private var sendError: String?
    @State private var composerID = UUID()
    private var sending: Bool { recorder.isSending }
    @FocusState private var focused: Bool
    @Environment(\.floatingPanelCommands) private var panelCommands
    @Environment(\.isFocusedColumn) private var isFocusedColumn
    private var recordingCommand: VoiceRecordingCommand {
        VoiceRecordingCommand(phase: { recorder.phase }, isSending: { sending }, toggle: toggleRecording)
    }
    let send: (URL, VoiceMessage) throws -> Void
    let content: (@escaping () -> Void) -> Content

    init(recorder: VoiceRecorder, send: @escaping (URL, VoiceMessage) throws -> Void,
         @ViewBuilder content: @escaping (@escaping () -> Void) -> Content) {
        self.recorder = recorder
        self.send = send
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            if recorder.phase == .idle {
                content { recorder.start() }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        // Native default/cancel actions work throughout the chat
                        // window, including when ⌘⇧D starts from the sidebar.
                        Button { Task { await recorder.discard() } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Discard Recording (Escape)").disabled(sending)
                            .keyboardShortcut(.cancelAction)
                        if recorder.phase == .preparing || recorder.phase == .finishing {
                            ProgressView().controlSize(.small)
                            Text(recorder.phase == .preparing ? recorder.preparation : "Finishing transcription…")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        } else {
                            if recorder.phase == .recording { Circle().fill(.red).frame(width: 6, height: 6) }
                            if recorder.recoveringInput && recorder.phase == .recording {
                                Text("Reconnecting microphone…")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else if recorder.noInputSignal && recorder.phase == .recording {
                                Text("No sound from \(recorder.inputName)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help("Check the microphone’s mute switch.")
                            } else {
                                if recorder.phase == .recording {
                                    LiveVoiceWaveform(samples: recorder.liveLevels, duration: recorder.duration,
                                                      started: recorder.recordingStarted).frame(height: 22)
                                } else {
                                    VoiceWaveform(samples: recorder.levels).frame(height: 22)
                                }
                            }
                            Text(voiceTime(recorder.duration)).font(.caption.monospacedDigit())
                            if recorder.phase == .recording {
                                Button(action: toggleRecording) { Image(systemName: "stop.fill") }
                                    .buttonStyle(.plain).help(KeyboardBindings.shared.help("Stop Recording", for: .recordVoice))
                            }
                        }
                        Button { Task { await sendRecording() } } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 23))
                        }
                        .buttonStyle(.plain).foregroundStyle(.blue)
                        .disabled(sending || !(recorder.phase == .recording || recorder.phase == .ready))
                        .help("Send Voice Message (Return)")
                        .keyboardShortcut(.defaultAction)
                    }
                    .frame(height: 36)
                    .help("Microphone: \(recorder.inputName)")
                    if let error = sendError ?? recorder.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if recorder.phase == .failed && recorder.hasAudio {
                        HStack {
                            Button("Retry Transcription") { Task { await recorder.retry() } }
                            Button("Send Audio Only") { Task { await sendRecording(audioOnly: true) } }
                        }.disabled(sending)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, recorder.phase == .failed || sendError != nil ? 8 : 0)
                .frame(maxWidth: .infinity, minHeight: 36)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focusable().focusEffectDisabled().focused($focused)
                .onAppear { focused = true }
                .id(ObjectIdentifier(recorder))
            }
        }
        // Of several columns in a window, only the focused one answers the menu.
        .focusedSceneValue(\.voiceRecordingCommand, isFocusedColumn ? recordingCommand : nil)
        .onAppear { mountRecorder(); panelCommands?.voiceRecording = recordingCommand }
        .onChange(of: ObjectIdentifier(recorder)) { _, _ in mountRecorder(); panelCommands?.voiceRecording = recordingCommand }
        .onDisappear {
            panelCommands?.voiceRecording = nil
            mountedRecorder?.detachComposer(composerID)
            mountedRecorder = nil
        }
    }

    private func mountRecorder() {
        guard mountedRecorder !== recorder else { return }
        mountedRecorder?.detachComposer(composerID)
        mountedRecorder = recorder
        recorder.attachComposer(composerID)
        sendError = nil
    }

    private func toggleRecording() {
        guard !sending else { return }
        switch recorder.phase {
        case .idle: recorder.start()
        case .recording: Task { await recorder.finish() }
        case .preparing, .finishing, .ready, .failed: break
        }
    }

    private func sendRecording(audioOnly: Bool = false) async {
        guard !sending else { return }
        recorder.isSending = true
        defer { recorder.isSending = false }
        sendError = nil
        if recorder.phase == .recording { await recorder.finish() }
        guard recorder.phase == .ready || (audioOnly && recorder.phase == .failed && recorder.hasAudio) else { return }
        do {
            try send(recorder.audioURL, recorder.metadata)
            await recorder.discard()
        } catch {
            // A send can finish after navigation. Its error belongs to the
            // recorder that started it, not the newly selected conversation.
            if mountedRecorder === recorder { sendError = error.localizedDescription }
        }
    }
}

extension EnvironmentValues {
    /// False in a column other than the focused one; true wherever a conversation is shown alone.
    @Entry var isFocusedColumn = true
}

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
