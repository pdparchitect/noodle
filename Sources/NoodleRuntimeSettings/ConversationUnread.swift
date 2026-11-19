import Foundation
import HubLink
import NoodleCore
import SwiftUI

/// Which conversations wait for the person, in every app, and which of those a bot's message named them in.
public struct ConversationUnread: Equatable, Sendable {
    public private(set) var unread: Set<UUID> = []
    public private(set) var mentioned: Set<UUID> = []

    public init(unread: Set<UUID> = [], mentioned: Set<UUID> = []) {
        self.unread = unread
        self.mentioned = mentioned.intersection(unread)
    }

    /// As the repository keeps them, leaving out conversations that are gone; when any were, the rest is saved.
    public static func load(from repository: WorkspaceRepository, keeping known: Set<UUID>) throws -> ConversationUnread {
        let stored = try repository.loadUnreadConversationIDs()
        let state = ConversationUnread(unread: stored.intersection(known), mentioned: try repository.loadMentionedConversationIDs())
        if state.unread != stored { try state.save(to: repository) }
        return state
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

/// The dot, in the accent colour as Mail's is, an unread conversation's row carries in a sidebar. A muted group's is dimmed: its new replies show,
/// but do not ask for attention. `ringed` parts it from a picture it sits on, as in a grid of conversations.
public struct UnreadDot: View {
    let isMuted: Bool
    let size: CGFloat
    let ringed: Bool

    public init(isMuted: Bool = false, size: CGFloat = 8, ringed: Bool = false) {
        self.isMuted = isMuted; self.size = size; self.ringed = ringed
    }

    public var body: some View {
        Circle()
            .fill(isMuted ? Color.secondary.opacity(0.5) : Color.accentColor)
            .frame(width: size, height: size)
            .padding(ringed ? 2 : 0)
            .background { if ringed { Circle().fill(Color(nsColor: .windowBackgroundColor)) } }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
