import SwiftUI
import Speech
import NoodleCore

@available(macOS 26.0, *)
struct VoiceMessageComposer<Content: View>: View {
    let recorder: VoiceRecorder
    @State private var mountedRecorder: VoiceRecorder?
    @State private var sendError: String?
    @State private var composerID = UUID()
    private var sending: Bool { recorder.isSending }
    @FocusState private var focused: Bool
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
                                    LiveVoiceWaveform(samples: recorder.liveLevels, duration: recorder.duration).frame(height: 22)
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
        .focusedSceneValue(\.voiceRecordingCommand,
            VoiceRecordingCommand(phase: { recorder.phase }, isSending: { sending }, toggle: toggleRecording))
        .onAppear { mountRecorder() }
        .onChange(of: ObjectIdentifier(recorder)) { _, _ in mountRecorder() }
        .onDisappear {
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
