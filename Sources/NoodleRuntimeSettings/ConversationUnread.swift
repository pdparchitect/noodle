import Foundation
import HubLink
import NoodleCore

/// Which conversations wait for the person, in every app, and which of those a bot's message named them in.
public struct ConversationUnread: Equatable, Sendable {
    public private(set) var unread: Set<UUID> = []
    public private(set) var mentioned: Set<UUID> = []

    public init(unread: Set<UUID> = [], mentioned: Set<UUID> = []) {
        self.unread = unread
        self.mentioned = mentioned.intersection(unread)
    }

    /// As the repository keeps them, leaving out conversations that are gone.
    public init(repository: WorkspaceRepository, known: Set<UUID>) {
        unread = ((try? repository.loadUnreadConversationIDs()) ?? []).intersection(known)
        mentioned = ((try? repository.loadMentionedConversationIDs()) ?? []).intersection(unread)
    }

    public func save(to repository: WorkspaceRepository) throws {
        try repository.saveUnreadConversationIDs(unread, mentioned: mentioned)
    }

    /// New messages: a conversation being looked at is read as they arrive; any other becomes unread, and
    /// mentioned when a bot names the person there. Returns the conversations read as they arrived.
    @discardableResult
    public mutating func register(_ messages: [ChatMessage], isViewing: (UUID) -> Bool, mentionName: (UUID) -> String) -> Set<UUID> {
        var viewed: Set<UUID> = []
        for message in messages {
            if isViewing(message.conversationID) {
                unread.remove(message.conversationID)
                mentioned.remove(message.conversationID)
                viewed.insert(message.conversationID)
            } else {
                unread.insert(message.conversationID)
                if case .agent = message.author, LinkMention.mentions(message.body, name: mentionName(message.conversationID)) {
                    mentioned.insert(message.conversationID)
                }
            }
        }
        return viewed
    }

    /// Returns whether it was unread.
    @discardableResult
    public mutating func markRead(_ id: UUID) -> Bool {
        guard unread.remove(id) != nil else { return false }
        mentioned.remove(id)
        return true
    }

    /// The unread conversations the Dock counts: a muted group never, a group in Mentions only once named.
    public func badged(_ notifications: (UUID) -> LinkNotifications) -> Set<UUID> {
        unread.filter { notifications($0).countsUnread(mentioned: mentioned.contains($0)) }
    }
}
