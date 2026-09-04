import QuickLook
import SwiftUI
import SuperBotCore
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(SuperBotStore.self) private var store
    let conversation: BotConversation
    @FocusState private var composerFocused: Bool
    @State private var choosingAttachments = false
    @State private var selectedAttachmentID: UUID?
    @State private var previewedAttachmentURL: URL?
    private let transcriptBottomID = "transcript-bottom"

    var body: some View {
        VStack(spacing: 0) {
            transcript
            composer
                .padding(.horizontal, 12)
                .padding(.bottom, 11)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
        .overlay(alignment: .top) {
            conversationHeaderShadow
        }
        .fileImporter(
            isPresented: $choosingAttachments,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                urls.forEach(store.importAttachment)
            case .failure(let error):
                store.errorMessage = error.localizedDescription
            }
        }
        .quickLookPreview($previewedAttachmentURL)
        .onChange(of: conversation.id) { _, _ in
            selectedAttachmentID = nil
            previewedAttachmentURL = nil
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ConversationStartView(conversation: conversation)
                        .padding(.bottom, 14)

                    ForEach(store.messages(for: conversation)) { message in
                        MessageBubble(
                            message: message,
                            selectedAttachmentID: $selectedAttachmentID,
                            previewAttachment: { attachment in
                                selectedAttachmentID = attachment.id
                                previewedAttachmentURL = store.attachmentFileURL(attachment)
                            }
                        )
                            .id(message.id)
                    }

                    Color.clear
                        .frame(height: 20)
                        .id(transcriptBottomID)
                }
                .padding(.horizontal, 15)
                .padding(.top, 30)
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                scrollTranscriptToBottom(using: proxy, animated: false)
            }
            .onChange(of: conversation.id) { _, _ in
                scrollTranscriptToBottom(using: proxy, animated: false)
            }
            .onChange(of: store.messages(for: conversation).last?.id) { _, lastID in
                guard lastID != nil else { return }
                scrollTranscriptToBottom(using: proxy, animated: true)
            }
        }
    }

    private func scrollTranscriptToBottom(using proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.snappy) {
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(transcriptBottomID, anchor: .bottom)
            }

            // A newly inserted message can finish measuring after the first scroll.
            // Reassert the true transcript end once that layout has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                proxy.scrollTo(transcriptBottomID, anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !store.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(store.pendingAttachments) { attachment in
                            PendingAttachmentChip(attachment: attachment) {
                                store.removePendingAttachment(attachment)
                            }
                        }
                    }
                    .padding(.horizontal, 38)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    choosingAttachments = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.quaternary.opacity(0.35), in: Circle())
                        .frame(width: composerControlHeight, height: composerControlHeight)
                }
                .buttonStyle(.plain)
                .help("Add Attachment")

                HStack(alignment: .bottom, spacing: 7) {
                    TextField(
                        composerPrompt,
                        text: Binding(
                            get: { store.draft },
                            set: { store.draft = $0 }
                        ),
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit(store.sendDraft)
                    .padding(.leading, 5)
                    .padding(.vertical, 6)

                    if cannotSend {
                        Image(systemName: "arrow.up.circle")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                            .frame(width: 27, height: 27)
                    } else {
                        Button(action: store.sendDraft) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 23))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 27, height: 27)
                        }
                        .buttonStyle(.plain)
                        .help("Send Message")
                    }
                }
                .padding(.horizontal, 7)
                .frame(minHeight: composerControlHeight)
                .background(.quaternary.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.6)))
            }
        }
    }

    private var cannotSend: Bool {
        store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            store.pendingAttachments.isEmpty
    }

    private var composerPrompt: String {
        "Message \(store.title(for: conversation))"
    }

    private var composerControlHeight: CGFloat { 32 }

    private var conversationHeaderShadow: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.24), location: 0),
                        .init(color: .black.opacity(0.10), location: 0.5),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.88), location: 0.55),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: 88)
            .shadow(color: .black.opacity(0.24), radius: 14, y: 5)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ConversationStartView: View {
    @Environment(SuperBotStore.self) private var store
    let conversation: BotConversation

    var body: some View {
        VStack(spacing: 12) {
            ConversationAvatar(
                participants: store.participants(for: conversation),
                isGroup: conversation.kind == .group,
                size: 82
            )

            Text(store.title(for: conversation))
                .font(.system(size: 22, weight: .semibold))

            if conversation.kind == .group {
                Text(store.participants(for: conversation).map(\.displayName).joined(separator: ", "))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if conversation.kind == .direct,
               let agent = store.participants(for: conversation).first {
                Button("Show Bot Workspace") {
                    store.revealWorkspace(for: agent)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PendingAttachmentChip: View {
    let attachment: ConversationAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .foregroundStyle(.blue)
            Text(attachment.originalFilename)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove Attachment")
        }
        .font(.caption)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: Capsule())
        .overlay(Capsule().stroke(.separator.opacity(0.45)))
        .frame(maxWidth: 260)
    }
}

struct WelcomeView: View {
    @Environment(SuperBotStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("Create Your First Bot", systemImage: "sparkles")
        } description: {
            Text("Each bot gets its own stable workspace and direct conversation.")
        } actions: {
            Button("Create Bot") {
                store.creationSheet = .bot
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
    }
}
