import AppKit
import HubLink
import NoodleCore
import SwiftUI
import UniformTypeIdentifiers

/// A notice the app adds to a conversation, between the messages: who joined or left a group, or which harness a
/// bot continues on in its own conversation.
struct ConversationNoticeView: View {
    let text: String
    /// A bot's own conversation, whose notices are about its harness.
    let isDirect: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Label(text, systemImage: isDirect ? "arrow.left.arrow.right" : "person.2.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 80)
        }
    }
}

/// Under the person's own message: whether it reached the conversation, and whether a bot got it.
struct MessageDeliveryLabel: View {
    let delivery: MessageDelivery

    var body: some View {
        Text(Self.title(delivery))
            .font(.system(size: 9.5))
            .modifier(TranscriptCaptionStyle(style: .tertiary))
            .padding(.trailing, 5)
    }

    static func title(_ delivery: MessageDelivery) -> String {
        switch delivery {
        case .saved: "Saved"
        case .queued: "Sent"
        case .delivered: "Delivered"
        case .failed: "Not delivered"
        }
    }
}

@MainActor enum MessageLinkPreviews {
    /// The web page a message's card previews: its first public link, unless it is already attached as a link card.
    static func url(for message: ChatMessage, attachments: [ConversationAttachment]) -> URL? {
        guard let url = MessageLinkCache.shared.firstPublicWebURL(in: message.body) else { return nil }
        return attachments.contains { $0.url.flatMap { MessageLink.publicWebURL(from: $0) } == url } ? nil : url
    }
}

/// Counts message row work so tests can prove that typing leaves the transcript alone,
/// that re-evaluated rows do not detect their links again, and which messages the transcript holds.
@MainActor enum TranscriptRenderProbe {
    private(set) static var bubbleBodies = 0
    private(set) static var linkScans = 0
    private(set) static var transcriptRows = 0
    private(set) static var firstTranscriptRow: UUID?
    static func bubbleBody() {
        #if DEBUG
        bubbleBodies += 1
        #endif
    }
    static func transcript(_ messages: some Collection<ChatMessage>) {
        #if DEBUG
        transcriptRows = messages.count
        firstTranscriptRow = messages.first?.id
        #endif
    }
    static func linkScan() {
        #if DEBUG
        linkScans += 1
        #endif
    }
}

/// Rows are re-evaluated far more often than their text changes, and finding a
/// link parses the whole message. Keyed by the text, so an edited message is scanned again.
@MainActor final class MessageLinkCache {
    static let shared = MessageLinkCache()

    private final class Box {
        let value: URL?
        init(_ value: URL?) { self.value = value }
    }

    private let values = NSCache<NSString, Box>()

    private init() {
        values.countLimit = 1_000
    }

    func firstPublicWebURL(in body: String) -> URL? {
        let key = body as NSString
        if let cached = values.object(forKey: key) { return cached.value }
        TranscriptRenderProbe.linkScan()
        let url = MessageLink.firstPublicWebURL(in: body)
        values.setObject(Box(url), forKey: key)
        return url
    }
}

/// The reactions on a message, in the corner of its bubble: each emoji once, with how many, the person's own marked.
/// Clicking one shows who reacted, and lets the person change or remove theirs.
struct MessageReactionBadges: View {
    let message: ChatMessage
    let name: (MessageAuthor) -> String
    let change: (_ emoji: String, _ replacement: String) -> Void
    let remove: (_ emoji: String) -> Void
    @State private var inspectedReaction: String?
    @State private var changingReaction = false

    var body: some View {
        let groups = Dictionary(grouping: message.reactions ?? [], by: \.emoji)
        let emojis = (message.reactions ?? []).map(\.emoji).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: -6) { badges(emojis, groups: groups) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], alignment: .leading, spacing: 4) {
                badges(emojis, groups: groups)
            }
            .frame(maxWidth: 280)
        }
    }

    @ViewBuilder private func badges(_ emojis: [String], groups: [String: [MessageReaction]]) -> some View {
        ForEach(emojis, id: \.self) { emoji in
            let reactions = groups[emoji] ?? []
            let isMine = reactions.contains { $0.author == .user }
            let names = reactions.map { name($0.author) }.joined(separator: ", ")
            Button {
                changingReaction = false
                inspectedReaction = emoji
            } label: {
                HStack(spacing: 4) {
                    Text(emoji).font(.system(size: 14))
                    if reactions.count > 1 {
                        Text("\(reactions.count)").font(.system(size: 10, weight: .medium))
                    }
                }
                .padding(.horizontal, reactions.count > 1 ? 7 : 0)
                .frame(minWidth: 28, minHeight: 28)
                .background(isMine ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15), in: Capsule())
                // An opaque base keeps overlapping badges distinct instead of blending together.
                .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color(nsColor: .textBackgroundColor).opacity(0.85), lineWidth: 1.5)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(
                get: { inspectedReaction == emoji },
                set: { if !$0 { inspectedReaction = nil } }
            ), arrowEdge: .bottom) {
                VStack(spacing: 16) {
                    Text(emoji).font(.system(size: 26))
                    Text(names).font(.system(size: 13))
                        .multilineTextAlignment(.center)
                    if isMine {
                        Divider()
                        if changingReaction {
                            Text("Change Reaction").font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 6), spacing: 10) {
                                ForEach(MessageReactionChoices.rows.flatMap { $0 }, id: \.self) { replacement in
                                    Button {
                                        inspectedReaction = nil
                                        change(emoji, replacement)
                                    } label: {
                                        Text(replacement).font(.system(size: 22)).frame(width: 36, height: 36)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Change to \(replacement)")
                                }
                            }
                        } else {
                            Button("Change Reaction…") { changingReaction = true }
                        }
                        Button("Remove My Reaction") {
                            inspectedReaction = nil
                            remove(emoji)
                        }
                    }
                }
                .frame(width: 260)
                .padding(20)
            }
            .help("\(emoji) — \(names). Click to see who reacted.")
            .accessibilityLabel("\(emoji), \(names)")
        }
    }
}

/// The reactions offered in a message's menu and when changing one, in order.
enum MessageReactionChoices {
    static let rows = [["❤️", "👍", "👎", "😂", "🎉", "❓"], ["👀", "⏳", "✅", "🙏", "🔥", "💡"]]
}

/// Above a message written from a task in the sidebar: the task it is about.
struct MessageTaskLabel: View {
    let task: TaskReference

    var body: some View {
        Label(task.title, systemImage: "checklist")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// A table's Copy as CSV and Save as CSV…, in its corner while the pointer is over it, in every app.
struct MessageTableActions: View {
    let table: MessageTable
    let failed: (String) -> Void

    var body: some View {
        Menu {
            Button("Copy as CSV") { MessageTableActions.copy(table) }
            Button("Save as CSV…") { MessageTableActions.save(table, failed: failed) }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 14))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Table actions")
        .accessibilityLabel("Table actions")
    }

    static func copy(_ table: MessageTable) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(table.csv, forType: .string)
    }

    /// Asks where, on the key window, then writes the table there as CSV.
    static func save(_ table: MessageTable, failed: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Table.csv"
        let save = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try Data(table.csv.utf8).write(to: destination, options: .atomic)
            } catch {
                failed("The table could not be saved: \(error.localizedDescription)")
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: save) }
        else { panel.begin(completionHandler: save) }
    }
}
