import NoodleCore
import PionCore
import SwiftUI
import UniformTypeIdentifiers

/// The message field: Noodle's composer, with its @mentions, pasting and dropping, in a large rounded
/// field with attach, dictate and send inside it. Dictation turns speech into text in the field, to read
/// over before sending.
struct Composer: View {
    let model: PionModel
    @Bindable var window: WindowState
    let conversation: BotConversation
    let investigation: Investigation?
    let actions: ComposerActions
    @StateObject private var completion = ComposerNameCompletion()
    @State private var focused = false
    @State private var showingAttachmentMenu = false
    @State private var recorder: VoiceRecorder?

    private var closed: Bool { investigation?.isClosed == true }
    private var dictating: Bool { recorder.map { $0.phase != .idle } ?? false }
    private var text: String { model.drafts[conversation.id] ?? "" }
    private var canSend: Bool {
        !closed && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(model.pendingAttachments[conversation.id] ?? []).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                let pending = model.pendingAttachments[conversation.id] ?? []
                if !pending.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(pending) { file in
                                AttachmentChip(attachment: file, preview: { actions.preview(file) }) { model.removePending(file, from: conversation.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                }
                // The field keeps its place while listening, so the composer never changes height.
                ScrollableChatComposer(
                    text: Binding(get: { text }, set: { model.drafts[conversation.id] = $0 }),
                    isFocused: $focused,
                    conversationID: conversation.id,
                    placeholder: closed ? "\(investigation?.reference ?? "This Investigation") is closed" : placeholder,
                    agents: model.agents,
                    preferredIDs: Set(conversation.participantIDs),
                    separatesPreferredAgents: conversation.kind == .group,
                    completion: completion,
                    submit: { model.sendDraft(to: conversation.id) },
                    dropFiles: { model.attach($0, to: conversation.id) }
                )
                // It measures its own text; a flexible frame would stretch it to whatever height is offered.
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 24)
                .disabled(closed || dictating)
                .opacity(dictating ? 0 : 1)
                .padding(.horizontal, 4)
                .overlay {
                    if let recorder, dictating {
                        DictationBar(recorder: recorder, cancel: cancelDictation).padding(.horizontal, 6)
                    }
                }
                HStack(spacing: 10) {
                    // Noodle's menu: a file, a photo, or a capture of a window or the screen.
                    Button { showingAttachmentMenu = true } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(ComposerIconButtonStyle())
                    .help("Add Attachment")
                    .disabled(closed)
                    .background {
                        ComposerAttachmentMenu(isPresented: $showingAttachmentMenu, attachFile: actions.attachFile,
                                               choosePhoto: actions.choosePhoto, capture: actions.capture)
                    }
                    Spacer()
                    if dictating {
                        // As Noodle's: Return stops listening, and what was said lands in the field.
                        Button(action: finishDictation) {
                            Image(systemName: "stop.fill").font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30)
                        }
                        .buttonStyle(ComposerIconButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .help("Stop Dictation (Return)")
                        .disabled(recorder?.phase != .recording)
                    } else {
                        Button(action: startDictation) {
                            Image(systemName: "mic").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 30)
                        }
                        .buttonStyle(ComposerIconButtonStyle())
                        .help("Dictate (⌘⇧D)")
                        .disabled(closed)
                    }
                    Button { model.sendDraft(to: conversation.id) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).frame(width: 30, height: 30)
                            .foregroundStyle(canSend ? Color(nsColor: .textBackgroundColor) : Color.secondary)
                            .background(canSend ? Color.primary : Color.secondary.opacity(0.2), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend || dictating)
                    .help("Send (Return)")
                }
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.primary.opacity(focused ? 0.22 : 0.1)))
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .frame(maxWidth: MessageRow.column + 20)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .padding(.top, 8)
        .onChange(of: window.composerFocusRequest, initial: true) { focused = true }
        .focusedSceneValue(\.pionDictation, DictationCommand(
            isRecording: recorder?.phase == .recording,
            isEnabled: !closed && (recorder == nil || recorder?.phase == .idle || recorder?.phase == .recording),
            toggle: { if recorder?.phase == .recording { finishDictation() } else { startDictation() } }))
        .onDisappear { completion.detach(); Task { await recorder?.discard() } }
    }

    private var placeholder: String {
        conversation.kind == .group ? "Message the team" : "Message \(model.agent(conversation.participantIDs.first)?.displayName ?? "the agent")"
    }

    private func startDictation() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dictation-\(conversation.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let recorder = VoiceRecorder(directory: folder)
        self.recorder = recorder
        recorder.start()
    }

    /// Stops listening and puts what was said into the field.
    private func finishDictation() {
        guard let recorder else { return }
        Task {
            await recorder.finish()
            if let transcript = recorder.transcript, !transcript.isEmpty {
                let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
                model.drafts[conversation.id] = current.isEmpty ? transcript : current + " " + transcript
            }
            await recorder.discard()
            self.recorder = nil
            focused = true
        }
    }

    private func cancelDictation() {
        guard let recorder else { return }
        Task { await recorder.discard(); self.recorder = nil; focused = true }
    }
}

/// Listening: Noodle's live waveform across the field, how long, and a button to cancel.
private struct DictationBar: View {
    let recorder: VoiceRecorder
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: cancel) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Cancel (Escape)")
            switch recorder.phase {
            case .preparing, .finishing:
                ProgressView().controlSize(.small)
                Text(recorder.phase == .preparing ? recorder.preparation : "Transcribing…").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case .failed:
                Text(recorder.error ?? "Dictation failed.").foregroundStyle(.red).lineLimit(1)
                Spacer(minLength: 0)
            default:
                Circle().fill(.red).frame(width: 6, height: 6)
                if recorder.recoveringInput {
                    Text("Reconnecting microphone…").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else if recorder.noInputSignal {
                    Text("No sound from \(recorder.inputName)").foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LiveVoiceWaveform(samples: recorder.liveLevels, duration: recorder.duration, started: recorder.recordingStarted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                }
                Text(voiceTime(recorder.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .help("Microphone: \(recorder.inputName)")
    }
}

/// A file waiting to be sent, as Noodle's composer shows it: an annotation by its note, anything else by
/// its name. It opens in Quick Look, where it can be annotated.
private struct AttachmentChip: View {
    let attachment: ConversationAttachment
    let preview: () -> Void
    let remove: () -> Void

    private var title: String {
        attachment.annotation.map { $0.comment.split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? attachment.originalFilename
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: preview) {
                HStack(spacing: 6) {
                    Image(systemName: attachment.previewSymbolName).foregroundStyle(.secondary).frame(width: 14)
                    Text(title).lineLimit(1).truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(attachment.annotation.map { "Annotation on \($0.sourceFilename)\n\n\($0.comment)" } ?? attachment.originalFilename)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Remove Attachment")
        }
        .font(.callout)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 30)
        .frame(maxWidth: 260)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .contextMenu {
            Button("Quick Look", systemImage: "eye", action: preview)
            Button("Remove Attachment", systemImage: "xmark", role: .destructive, action: remove)
        }
    }
}

/// What the composer's attachment menu and chips ask the conversation to do.
struct ComposerActions {
    let attachFile: () -> Void
    let choosePhoto: () -> Void
    let capture: () -> Void
    let preview: (ConversationAttachment) -> Void
}

/// A round, borderless control that darkens under the pointer.
struct ComposerIconButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(Color.secondary.opacity(configuration.isPressed ? 0.22 : hovering ? 0.12 : 0), in: Circle())
            .onHover { hovering = $0 }
    }
}
