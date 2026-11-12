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
    @StateObject private var completion = ComposerNameCompletion()
    @State private var focused = false
    @State private var choosingFiles = false
    @State private var recorder: VoiceRecorder?

    private var closed: Bool { investigation?.isClosed == true }
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
                                AttachmentChip(name: file.originalFilename) { model.removePending(file, from: conversation.id) }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                }
                if let recorder, recorder.phase != .idle {
                    DictationBar(recorder: recorder, finish: finishDictation, cancel: cancelDictation)
                        .padding(.horizontal, 6)
                } else {
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
                    .disabled(closed)
                    .padding(.horizontal, 4)
                }
                HStack(spacing: 10) {
                    Button { choosingFiles = true } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(ComposerIconButtonStyle())
                    .help("Attach Files")
                    .disabled(closed)
                    Spacer()
                    Button(action: startDictation) {
                        Image(systemName: "mic").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(ComposerIconButtonStyle())
                    .help("Dictate (⌘⇧D)")
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(closed || (recorder.map { $0.phase != .idle } ?? false))
                    Button { model.sendDraft(to: conversation.id) } label: {
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)).frame(width: 30, height: 30)
                            .foregroundStyle(canSend ? Color(nsColor: .textBackgroundColor) : Color.secondary)
                            .background(canSend ? Color.primary : Color.secondary.opacity(0.2), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
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
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.attach(urls, to: conversation.id) }
        }
        .onChange(of: window.composerFocusRequest, initial: true) { focused = true }
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

/// Listening: the live level, how long, and buttons to stop or cancel.
private struct DictationBar: View {
    let recorder: VoiceRecorder
    let finish: () -> Void
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
            case .failed:
                Text(recorder.error ?? "Dictation failed.").foregroundStyle(.red).lineLimit(1)
            default:
                Circle().fill(.red).frame(width: 7, height: 7)
                Levels(samples: recorder.liveLevels)
                Text(Duration.seconds(recorder.duration).formatted(.time(pattern: .minuteSecond)))
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: finish)
                .keyboardShortcut(.defaultAction)
                .disabled(recorder.phase != .recording)
        }
        .font(.callout)
        .frame(minHeight: 30)
    }
}

private struct Levels: View {
    let samples: [Float]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(samples.suffix(48).enumerated()), id: \.offset) { _, level in
                Capsule().fill(Color.primary.opacity(0.6)).frame(width: 2.5, height: max(3, CGFloat(level) * 22))
            }
        }
        .frame(height: 22)
    }
}

private struct AttachmentChip: View {
    let name: String
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc").foregroundStyle(.secondary)
            Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Remove")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
    }
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
