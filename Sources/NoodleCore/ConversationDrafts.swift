import Foundation

/// Unsent composer state lives with the conversation, not the selected view.
/// Kept in memory for the lifetime of the app; never exposed to agent inboxes.
public struct ConversationDrafts {
    public struct Draft {
        public var text = ""
        public var attachments: [ConversationAttachment] = []

        public init() {}

        public var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
    }

    private var drafts: [UUID: Draft] = [:]

    public init() {}

    public subscript(conversationID: UUID) -> Draft {
        get { drafts[conversationID] ?? Draft() }
        set { drafts[conversationID] = newValue.isEmpty ? nil : newValue }
    }

    public var hasContent: Bool { !drafts.isEmpty }

    public mutating func clear(_ conversationID: UUID) {
        drafts.removeValue(forKey: conversationID)
    }

    public mutating func retainConversations(_ ids: Set<UUID>) {
        drafts = drafts.filter { ids.contains($0.key) }
    }
}
