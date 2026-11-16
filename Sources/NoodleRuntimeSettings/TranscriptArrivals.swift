import Darwin
import Foundation
import NoodleCore
import NoodleRuntime

/// When a conversation's messages and attachments last changed on disk, so an app reads them again only then.
/// Every conversation is checked every second: one `lstat` each, not FileManager's attributes, which also read
/// extended attributes and the owner's name. The size catches a rewrite within the same timestamp.
public struct TranscriptRevision: Equatable, Sendable {
    public let messagesModifiedAt: Date?
    public let messagesSize: UInt64?
    public let attachmentsModifiedAt: Date?

    public init(messagesModifiedAt: Date?, messagesSize: UInt64?, attachmentsModifiedAt: Date?) {
        self.messagesModifiedAt = messagesModifiedAt
        self.messagesSize = messagesSize
        self.attachmentsModifiedAt = attachmentsModifiedAt
    }

    public init(of conversationID: UUID, in repository: WorkspaceRepository) {
        func entry(_ path: String) -> stat? {
            var info = stat()
            return lstat(path, &info) == 0 ? info : nil
        }
        func date(_ time: timespec) -> Date {
            Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
        }
        let directory = repository.conversationDirectory(id: conversationID).path
        let messages = entry(directory + "/messages.json"), attachments = entry(directory + "/Attachments")
        self.init(messagesModifiedAt: messages.map { date($0.st_mtimespec) },
                  messagesSize: messages.map { UInt64($0.st_size) },
                  attachmentsModifiedAt: attachments.map { date($0.st_mtimespec) })
    }

    public func hasSameMessages(as other: TranscriptRevision?) -> Bool {
        messagesModifiedAt == other?.messagesModifiedAt && messagesSize == other?.messagesSize
    }

    public func hasSameAttachments(as other: TranscriptRevision?) -> Bool {
        attachmentsModifiedAt == other?.attachmentsModifiedAt
    }
}

/// What arrived between two reads of the transcripts, in every app: bots' new messages and new reactions, the
/// person's included. The app's own notices and the person's messages are not arrivals; the app handles those
/// where it writes them.
public struct TranscriptArrivals: Sendable {
    /// Bots' new messages, oldest first.
    public let messages: [ChatMessage]
    public let reactions: [MessageReactionChange]

    public init(before: some Sequence<ChatMessage>, after: some Sequence<ChatMessage>) {
        let before = Array(before)
        let knownMessages = Set(before.map(\.id))
        let knownReactions = Set(before.flatMap { $0.reactionChanges ?? [] }.map(\.id))
        messages = after.filter { message in
            guard !knownMessages.contains(message.id), case .agent = message.author else { return false }
            return true
        }.sorted { $0.createdAt < $1.createdAt }
        reactions = after.flatMap { $0.reactionChanges ?? [] }.filter { !knownReactions.contains($0.id) }
    }

    public var isEmpty: Bool { messages.isEmpty && reactions.isEmpty }

    /// The members a reaction wakes: everyone in its conversation but whoever reacted.
    public func reactionRecipientIDs(in conversations: [BotConversation]) -> Set<UUID> {
        Set(reactions.flatMap { change in
            (conversations.first { $0.id == change.conversationID }?.participantIDs ?? []).filter { change.author != .agent($0) }
        })
    }

    /// Tells the runtime: a bot that spoke or reacted was active, which puts off its heartbeat; the other members of
    /// a group hear a bot's message, and of any conversation a reaction.
    @MainActor
    public func deliver(to runtime: AgentRuntimeCoordinator, agents: [AgentRecord], conversations: [BotConversation],
                        repository: WorkspaceRepository) throws {
        for author in messages.map(\.author) + reactions.map(\.author) {
            if case .agent(let id) = author { runtime.recordActivity(for: id) }
        }
        let reacted = reactionRecipientIDs(in: conversations)
        if !reacted.isEmpty { runtime.notify(agents.filter { reacted.contains($0.id) }, repository: repository) }
        guard !messages.isEmpty else { return }
        let recipients = try repository.notificationRecipientIDs(for: messages)
        if !recipients.isEmpty { runtime.notify(agents.filter { recipients.contains($0.id) }, repository: repository) }
    }
}
