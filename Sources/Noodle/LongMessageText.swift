import AppKit
import SwiftUI
import NoodleCore
import HubLink

/// A message's prose, or one stretch of it between tables.
struct MessageText: View {
    /// About eight lines of the bubble's text, which a folded message shows.
    static let foldedHeight: CGFloat = 8 * (12.5 * 1.2 + 2)
    let message: ChatMessage
    let text: AttributedString
    let source: String
    /// How the bubble restyles each block's text, as the accent bubble underlines its links.
    var restyle: (AttributedString) -> AttributedString = { $0 }
    @State private var showingReader = false

    init(message: ChatMessage) {
        self.init(message: message, text: MessageMarkdownCache.shared.render(message), source: message.body)
    }

    init(message: ChatMessage, text: AttributedString, source: String, restyle: @escaping (AttributedString) -> AttributedString = { $0 }) {
        self.message = message
        self.text = text
        self.source = source
        self.restyle = restyle
    }

    var body: some View {
        let isLong = LongTextPolicy.foldsMessage(source)
        VStack(alignment: .leading, spacing: 8) {
            // Paragraphs, lists and code as Pion lays them out, at the bubble's size. A long one shows about its first
            // eight lines, fading out, with the rest in the reader.
            let blocks = MessageBlocksView(blocks: MessageMarkdownCache.shared.blocks(source).map { restyled($0) }, message: message,
                                           size: 12.5, lineSpacing: 2, spacing: 6)
                .textSelection(.enabled)
            if isLong {
                blocks
                    .frame(maxHeight: Self.foldedHeight, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            } else {
                blocks
            }

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
                    MessageTextReader(message: message, text: text, source: source, close: { showingReader = false })
                }
            }
        }
    }
}

extension MessageText {
    /// A block with its text restyled as the bubble wants.
    fileprivate func restyled(_ block: MessageBlock) -> MessageBlock {
        switch block {
        case .text(let text): .text(restyle(text))
        case .code: block
        case .list(let items): .list(items.map { MessageListItem(marker: $0.marker, text: restyle($0.text)) })
        }
    }
}

struct MessageTextReader: View {
    let message: ChatMessage
    let text: AttributedString
    /// The message's own text, laid out in blocks; the reader always shows them, as it has the room.
    var source: String? = nil
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
                Group {
                    if let source {
                        MessageBlocksView(blocks: MessageMarkdownCache.shared.blocks(source), message: message, size: 14, lineSpacing: 4)
                    } else {
                        Text(text)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .background(ConversationAnnotationText(message: message))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        }
        .foregroundStyle(Color.primary)
        .frame(width: min(600, (NSScreen.main?.visibleFrame.width ?? 800) - 80),
               height: min(540, (NSScreen.main?.visibleFrame.height ?? 700) - 100))
        .modifier(MessageReaderAnnotations(message: message))
    }
}

/// A reader opens in a popover, its own window, so it annotates into the message's conversation by itself.
struct MessageReaderAnnotations: ViewModifier {
    @Environment(NoodleStore.self) private var store
    @State private var annotations = ConversationAnnotationController()
    let message: ChatMessage

    func body(content: Content) -> some View {
        content
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
