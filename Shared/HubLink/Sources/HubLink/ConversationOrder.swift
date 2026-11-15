import Foundation

/// How the conversation list orders bots and groups, so new messages are easy to find. The list itself comes
/// newest message first; this decides where the unread ones go.
public enum ConversationOrder: String, CaseIterable, Identifiable, Sendable {
    case newestFirst, unreadFirst, unreadSection

    public static let key = "conversationOrder"
    public static let standard = Self.newestFirst
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .newestFirst: "Newest First"
        case .unreadFirst: "Unread First"
        case .unreadSection: "Unread Section"
        }
    }

    public var explanation: String {
        switch self {
        case .newestFirst: "Bots and groups with the newest messages come first."
        case .unreadFirst: "Unread bots and groups come first in their section, then the rest, newest first."
        case .unreadSection: "Unread bots and groups move to a section of their own at the top until read."
        }
    }

    /// The items an Unread section shows, in the order given; none unless the order has one.
    public func unread<T>(_ items: [T], isUnread: (T) -> Bool) -> [T] {
        self == .unreadSection ? items.filter(isUnread) : []
    }

    /// A section's items in the order given, with the unread ones moved ahead when they come first.
    public func arranged<T>(_ items: [T], isUnread: (T) -> Bool) -> [T] {
        guard self == .unreadFirst else { return items }
        return items.filter(isUnread) + items.filter { !isUnread($0) }
    }

    /// A sidebar's sections: pins on top in the order they were pinned, then, newest message first, an Unread
    /// section when the order has one and the rest, the unread ones ahead when they come first.
    public func sections<Item: Identifiable>(_ items: [Item], pinned: [Item.ID], lastActivity: (Item) -> Date,
                                             isUnread: (Item) -> Bool) -> ConversationSections<Item> {
        let pinnedIDs = Set(pinned)
        let byID = Dictionary(items.map { ($0.id, $0) }) { first, _ in first }
        // Said in the same second, they keep the order given, so the list does not jump about.
        let newest = items.filter { !pinnedIDs.contains($0.id) }.enumerated()
            .sorted { (lastActivity($0.element), -$0.offset) > (lastActivity($1.element), -$1.offset) }.map(\.element)
        let unread = self.unread(newest, isUnread: isUnread), unreadIDs = Set(unread.map(\.id))
        return ConversationSections(unread: unread, pinned: pinned.compactMap { byID[$0] },
                                    rest: arranged(newest.filter { !unreadIDs.contains($0.id) }, isUnread: isUnread))
    }
}

/// What ``ConversationOrder/sections(_:pinned:lastActivity:isUnread:)`` gives; each app splits the rest its own way.
public struct ConversationSections<Item> {
    public var unread: [Item]
    public var pinned: [Item]
    public var rest: [Item]
}
