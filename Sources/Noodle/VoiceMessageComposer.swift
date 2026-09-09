import SwiftUI
import Speech
import NoodleCore

@available(macOS 26.0, *)
struct VoiceMessageComposer<Content: View>: View {
    @State private var recorder: VoiceRecorder
    @State private var sendError: String?
    @State private var sending = false
    @FocusState private var focused: Bool
    let send: (URL, VoiceMessage) throws -> Void
    let content: (@escaping () -> Void) -> Content

    init(recorder: VoiceRecorder, send: @escaping (URL, VoiceMessage) throws -> Void,
         @ViewBuilder content: @escaping (@escaping () -> Void) -> Content) {
        _recorder = State(initialValue: recorder)
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
                        Button { Task { await recorder.discard() } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Discard Recording (Escape)").disabled(sending)
                        if recorder.phase == .preparing || recorder.phase == .finishing {
                            ProgressView().controlSize(.small)
                            Text(recorder.phase == .preparing ? recorder.preparation : "Finishing transcription…")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        } else {
                            if recorder.phase == .recording { Circle().fill(.red).frame(width: 6, height: 6) }
                            VoiceWaveform(samples: recorder.levels).frame(height: 22)
                            Text(voiceTime(recorder.duration)).font(.caption.monospacedDigit())
                            if recorder.phase == .recording {
                                Button { Task { await recorder.finish() } } label: { Image(systemName: "stop.fill") }
                                    .buttonStyle(.plain).help("Stop Recording")
                            }
                        }
                        Button { Task { await sendRecording() } } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 23))
                        }
                        .buttonStyle(.plain).foregroundStyle(.blue)
                        .disabled(sending || !(recorder.phase == .recording || recorder.phase == .ready))
                        .help("Send Voice Message (Return)")
                    }
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
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .focusable().focusEffectDisabled().focused($focused)
                .onKeyPress(.return) { Task { await sendRecording() }; return .handled }
                .onKeyPress(.escape) { if !sending { Task { await recorder.discard() } }; return .handled }
                .onAppear { focused = true }
            }
        }
        .onDisappear { Task { await recorder.leaveConversation() } }
    }

    private func sendRecording(audioOnly: Bool = false) async {
        guard !sending else { return }
        sending = true
        defer { sending = false }
        sendError = nil
        if recorder.phase == .recording { await recorder.finish() }
        guard recorder.phase == .ready || (audioOnly && recorder.phase == .failed && recorder.hasAudio) else { return }
        do {
            try send(recorder.audioURL, recorder.metadata)
            await recorder.discard()
        } catch { sendError = error.localizedDescription }
    }
}
