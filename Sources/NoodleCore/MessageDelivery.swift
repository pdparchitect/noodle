import Foundation

public enum MessageDeliveryMode: String, CaseIterable, Identifiable, Sendable {
    case automatic, immediate, queue

    public static let defaultsKey = "messageDeliveryMode"
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .immediate: "Send immediately"
        case .queue: "Queue"
        }
    }
    public static func load(from defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .automatic
    }
}

/// One coalesced inbox wake. Its identity prevents a late classification from
/// interrupting newer work after the original wake has already been dispatched.
public struct PendingAgentNotification {
    public private(set) var id: UUID?
    public private(set) var isImmediate = false
    public var isPending: Bool { id != nil }
    public init() {}

    @discardableResult public mutating func enqueue(immediately: Bool = false) -> UUID {
        let id = id ?? UUID()
        self.id = id
        isImmediate = isImmediate || immediately
        return id
    }
    public mutating func promote(_ id: UUID) {
        if self.id == id { isImmediate = true }
    }
    @discardableResult public mutating func take() -> UUID? {
        defer { id = nil; isImmediate = false }
        return id
    }
    public mutating func restore(_ id: UUID) {
        if self.id == nil { self.id = id }
    }
    public mutating func deferUntilReady() { isImmediate = false }
}

/// Bounded conversation text, with voice transcripts but no private backstory,
/// files, or harness transcript. Reading this never advances Messenger cursors.
public struct MessageDeliveryContext: Codable, Sendable {
    public let unreadMessages: [String]
    public let recentMessages: [String]

    public init(unreadMessages: [String], recentMessages: [String]) {
        self.unreadMessages = unreadMessages.suffix(4).map { String($0.prefix(800)) }
        self.recentMessages = recentMessages.suffix(4).map { String($0.prefix(400)) }
    }

    public static func load(for agentID: UUID, repository: WorkspaceRepository) throws -> Self? {
        let unread = try repository.latestMessages(for: agentID, consuming: false)
            .filter { $0.reactionChange == nil && $0.message.author != .system }
        guard !unread.isEmpty else { return nil }
        let latest = Array(unread.suffix(4))
        let unreadIDs = Set(unread.map { $0.message.id })
        let conversationIDs = Set(latest.map { $0.conversation.id })
        let history = try conversationIDs.flatMap { try repository.loadMessages(conversationID: $0) }
            .filter { !unreadIDs.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        func text(_ message: ChatMessage) -> String {
            let sender: String
            switch message.author {
            case .user: sender = "User"
            case .agent(let id): sender = id == agentID ? "Assistant" : "Other agent"
            case .system: sender = "System"
            }
            return "\(sender): \(message.body)"
        }
        return Self(unreadMessages: latest.map { delivery in
            let transcripts = delivery.attachments.compactMap { $0.voice?.transcript }
            return delivery.message.body + (transcripts.isEmpty ? "" : "\n" + transcripts.joined(separator: "\n"))
        }, recentMessages: history.suffix(4).map(text))
    }

    public var prompt: String {
        // Keep the incoming batch quoted and separate from prior context.
        let encoder = JSONEncoder()
        func quoted(_ message: String) -> String {
            String(decoding: (try? encoder.encode(message)) ?? Data(), as: UTF8.self)
        }
        return """
            Conversation so far: \(recentMessages.joined(separator: " "))
            New message: \(quoted(unreadMessages.joined(separator: "\n")))
            """
    }
}
