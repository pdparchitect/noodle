import NoodleCore
import NoodleRuntimeSettings
import PionCore
import SwiftUI
import UniformTypeIdentifiers

/// The message field: Noodle's composer, with its @mentions, pasting and dropping, in a large rounded
/// field with attach, record and send inside it. Recording sends a voice message, as in Noodle.
struct Composer: View {
    let model: PionModel
    @Bindable var window: WindowState
    let conversation: BotConversation
    let investigation: Investigation?
    let actions: ComposerActions
    @StateObject private var completion = ComposerNameCompletion()
    @State private var focused = false
    @State private var showingAttachmentMenu = false

    private var closed: Bool { investigation?.isClosed == true }
    /// Closed, or nothing can be sent, as when the agent is archived.
    private var isOff: Bool { closed || model.composerUnavailableReason(for: conversation) != nil }
    private var text: String { model.drafts[conversation.id].text }
    private var canSend: Bool {
        !isOff && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.drafts[conversation.id].attachments.isEmpty)
    }

    var body: some View {
        // Noodle's voice messages: the microphone records, and the recording replaces the field until it is sent.
        VoiceMessageComposer(
            recorder: model.voiceRecorder(for: conversation.id),
            send: { url, voice in try model.sendVoiceMessage(from: url, voice: voice, to: conversation.id) }
        ) { record in
            field(record: record)
        }
        .disabled(isOff)
        .frame(maxWidth: MessageRow.column + 20)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .padding(.top, 8)
        .onChange(of: window.composerFocusRequest, initial: true) {
            // As in Noodle: the flag can still read focused just after the sidebar took the keyboard,
            // and a request must bring the caret back regardless.
            if focused {
                focused = false
                DispatchQueue.main.async { focused = true }
            } else { focused = true }
        }
        // The composer stays while the selection moves; what it held for the last conversation goes.
        .onChange(of: conversation.id) { _, _ in completion.detach() }
        .onDisappear { completion.detach() }
    }

    private func field(record: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                let pending = model.drafts[conversation.id].attachments
                if !pending.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(pending) { file in
                                PendingAttachmentChip(attachment: file, preview: { actions.preview(file) },
                                                      remove: { model.removePending(file, from: conversation.id) },
                                                      copy: { AttachmentDrag.copy(file, fileURL: model.fileURL(file)) },
                                                      drag: { AttachmentDrag.dragProvider(for: file, fileURL: model.fileURL(file)) { model.problem = $0 } })
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                }
                // The field keeps its place while listening, so the composer never changes height.
                ScrollableChatComposer(
                    text: Binding(get: { text }, set: { model.drafts[conversation.id].text = $0 }),
                    isFocused: $focused,
                    conversationID: conversation.id,
                    placeholder: closed ? "\(investigation?.reference ?? "This Investigation") is closed"
                        : model.composerUnavailableReason(for: conversation) ?? placeholder,
                    agents: model.agents,
                    preferredIDs: Set(conversation.participantIDs),
                    separatesPreferredAgents: conversation.kind == .group,
                    completion: completion,
                    submit: { model.sendDraft(to: conversation.id) },
                    focusSidebar: window.hasSidebar ? { window.sidebarFocusRequest = UUID() } : nil,
                    // As Noodle's: a pasted picture or file attaches, and so does long text, or any with Paste as Attachment.
                    pasteAttachments: { pasteboard in
                        AttachmentTransfer.paste(from: pasteboard) { model.attach([$0], to: conversation.id) }
                    },
                    forcePasteAttachments: { pasteboard in
                        AttachmentTransfer.paste(from: pasteboard, textAsAttachment: true) {
                            model.attach([$0], to: conversation.id)
                        }
                    },
                    dropFiles: { model.attach($0, to: conversation.id) }
                )
                // It measures its own text; a flexible frame would stretch it to whatever height is offered.
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 24)
                .disabled(isOff)
                .padding(.horizontal, 4)
                HStack(spacing: 10) {
                    // Noodle's menu: a file, a photo, or a capture of a window or the screen.
                    Button { showingAttachmentMenu = true } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(ComposerIconButtonStyle())
                    .help("Add Attachment")
                    .disabled(isOff)
                    .background {
                        ComposerAttachmentMenu(isPresented: $showingAttachmentMenu, attachFile: actions.attachFile,
                                               choosePhoto: actions.choosePhoto, capture: actions.capture)
                    }
                    Spacer()
                    Button(action: record) {
                        Image(systemName: "mic").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(ComposerIconButtonStyle())
                    .help(KeyboardBindings.shared.help("Record Voice Message", for: .recordVoice))
                    .disabled(isOff)
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
    }

    private var placeholder: String {
        conversation.kind == .group ? "Message the team" : "Message \(model.agent(conversation.participantIDs.first)?.displayName ?? "the agent")"
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

extension PionModel {
    /// The conversation's voice recorder, as Noodle keeps one per conversation.
    func voiceRecorder(for id: UUID) -> VoiceRecorder {
        if let recorder = voiceRecorders[id] as? VoiceRecorder { return recorder }
        let recorder = VoiceRecorder(directory: repository.attachmentsDirectory(conversationID: id)
            .appendingPathComponent("VoiceDraft", isDirectory: true))
        voiceRecorders[id] = recorder
        return recorder
    }
}
