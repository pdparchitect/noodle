import NoodleCore
import SwiftUI

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
            .foregroundStyle(.tertiary)
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
