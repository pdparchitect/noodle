import AppKit
import SwiftUI
import NoodleCore

/// Keep pasted documents and long replies from taking over the conversation.
enum LongTextPolicy {
    static func requiresPreview(_ text: String) -> Bool {
        var lines = 1
        for (index, character) in text.enumerated() {
            if index >= 1_200 { return true }
            if character.isNewline {
                lines += 1
                if lines > 12 { return true }
            }
        }
        return false
    }
}

/// A message's prose, or one stretch of it between tables.
struct MessageText: View {
    let message: ChatMessage
    let text: AttributedString
    let source: String
    @State private var showingReader = false

    init(message: ChatMessage) {
        self.init(message: message, text: MessageMarkdownCache.shared.render(message), source: message.body)
    }

    init(message: ChatMessage, text: AttributedString, source: String) {
        self.message = message
        self.text = text
        self.source = source
    }

    var body: some View {
        let isLong = LongTextPolicy.requiresPreview(source)
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .lineLimit(isLong ? 8 : nil)
                .textSelection(.enabled)
                .background(ConversationAnnotationText(message: message))

            if isLong {
                Button { showingReader = true } label: {
                    Label("Read more", systemImage: "text.alignleft")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Read full message")
                .popover(isPresented: $showingReader, arrowEdge: .bottom) {
                    MessageTextReader(message: message, text: text, close: { showingReader = false })
                }
            }
        }
    }
}

struct MessageTextReader: View {
    @Environment(NoodleStore.self) private var store
    @State private var annotations = ConversationAnnotationController()
    let message: ChatMessage
    let text: AttributedString
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Message").font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy message")
                .accessibilityLabel("Copy message")
                Button(action: close) { Image(systemName: "xmark") }
                    .help("Close")
                    .accessibilityLabel("Close")
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.plain)
            .padding(16)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .background(ConversationAnnotationText(message: message))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
        .foregroundStyle(Color.primary)
        .frame(width: min(600, (NSScreen.main?.visibleFrame.width ?? 800) - 80),
               height: min(540, (NSScreen.main?.visibleFrame.height ?? 700) - 100))
        .environment(\.conversationAnnotations, annotations)
        .background(ConversationAnnotationHost(controller: annotations,
            conversationID: message.conversationID,
            title: store.conversations.first { $0.id == message.conversationID }.map { store.title(for: $0) } ?? "Message",
            save: { note, content, source, raw in
                try store.saveConversationAnnotation(note, content: content, source: source, sourceData: raw)
            }).frame(width: 0, height: 0))
        .onDisappear { annotations.cancel() }
    }
}
