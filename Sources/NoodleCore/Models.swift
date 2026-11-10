import BrowserBridge
import ComputerBridge
import Foundation

public struct AgentRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public let createdAt: Date
    public var updatedAt: Date
    public var harnessIdentifier: String?
    public var modelIdentifier: String?
    public var reasoningEffort: String?
    public var publicDescription: String?
    public let accentSeed: Int
    public var avatarSymbolName: String?
    public var avatarColorIndex: Int?
    public var avatarImageData: Data?
    /// One short line the bot sets itself through Messenger, such as what it is busy with.
    public var status: String?
    /// When the bot last set its status; nil without one, or when nobody knows, as for a bot mirrored from a Hub.
    public var statusSetAt: Date?
    /// Short enough for the bubble over a pinned bot.
    public static let statusLimit = 60
    /// An archived bot keeps everything but never runs and is left out of lists until unarchived.
    public var archivedAt: Date?
    /// A suspended bot stays listed but takes no new turn until then; `indefinitely` until someone unsuspends it.
    public var suspendedUntil: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        harnessIdentifier: String? = nil,
        modelIdentifier: String? = nil,
        reasoningEffort: String? = nil,
        publicDescription: String? = nil,
        accentSeed: Int = Int.random(in: 0...5),
        avatarSymbolName: String? = nil,
        avatarColorIndex: Int? = nil,
        avatarImageData: Data? = nil,
        status: String? = nil,
        archivedAt: Date? = nil,
        suspendedUntil: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.harnessIdentifier = harnessIdentifier
        self.modelIdentifier = modelIdentifier
        self.reasoningEffort = reasoningEffort
        self.publicDescription = publicDescription
        self.accentSeed = accentSeed
        self.avatarSymbolName = avatarSymbolName
        self.avatarColorIndex = avatarColorIndex
        self.avatarImageData = avatarImageData
        self.status = status
        self.archivedAt = archivedAt
        self.suspendedUntil = suspendedUntil
    }

    /// Whether its status was set longer than `interval` ago, so it may no longer hold.
    public func isStatusStale(at now: Date = Date(), after interval: TimeInterval) -> Bool {
        statusSetAt.map { now.timeIntervalSince($0) > interval } ?? false
    }

    /// Far enough off that the bot waits for someone to unsuspend it.
    public static let indefinitely = Date.distantFuture

    /// Whether it is suspended at `now`; a suspension that ran out no longer counts.
    public func isSuspended(at now: Date = Date()) -> Bool { suspendedUntil.map { $0 > now } ?? false }

    /// What a suspended bot shows: "Suspended until 14:20", "Suspended until 5 Nov at 09:00" or "Suspended".
    public static func suspension(until: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard until < Date(timeIntervalSinceNow: 50 * 365 * 86_400) else { return "Suspended" }
        let time = until.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(until, inSameDayAs: now) { return "Suspended until \(time)" }
        return "Suspended until \(until.formatted(.dateTime.day().month(.abbreviated))) at \(time)"
    }

    /// The bots suspended at `now`, each with what it shows, for the runtime to hold.
    public static func suspensions(of agents: [AgentRecord], now: Date = Date()) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: agents.compactMap { agent in
            guard agent.archivedAt == nil, let until = agent.suspendedUntil, until > now else { return nil }
            return (agent.id, suspension(until: until, now: now))
        })
    }
}

public enum ConversationKind: String, Codable, Hashable, Sendable {
    case direct
    case group
}

public struct BotConversation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var publicDescription: String?
    public let kind: ConversationKind
    public var participantIDs: [UUID]
    public let createdAt: Date
    public var updatedAt: Date
    /// Only groups are archived; a bot's direct conversation follows its bot.
    public var archivedAt: Date?
    /// Folders a group on this Mac shares with its bots; nil when there are none.
    public var folders: [AgentFolder]?
    /// On a Noodle Hub, someone the bot's owner shared it with, who talks with it here.
    public var guest: ConversationGuest?

    public init(
        id: UUID = UUID(),
        displayName: String,
        publicDescription: String? = nil,
        kind: ConversationKind,
        participantIDs: [UUID],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil,
        folders: [AgentFolder]? = nil,
        guest: ConversationGuest? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.publicDescription = publicDescription
        self.kind = kind
        self.participantIDs = participantIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.folders = folders
        self.guest = guest
    }
}

/// Someone other than a bot's owner who talks with it, as its bot knows them.
public struct ConversationGuest: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum MessageAuthor: Codable, Hashable, Sendable {
    case user
    case agent(UUID)
    case system
}

public enum MessageDelivery: String, Codable, Hashable, Sendable {
    case saved
    case queued
    case delivered
    case failed
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let author: MessageAuthor
    public let body: String
    public let createdAt: Date
    public var delivery: MessageDelivery
    public var attachmentIDs: [UUID]?
    public var reactions: [MessageReaction]?
    public var reactionChanges: [MessageReactionChange]?
    public var call: VoiceCallRecord?
    /// The task a person's message is about, when they wrote from the task.
    public var task: TaskReference?

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        author: MessageAuthor,
        body: String,
        createdAt: Date = Date(),
        delivery: MessageDelivery,
        attachmentIDs: [UUID] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.delivery = delivery
        self.attachmentIDs = attachmentIDs.isEmpty ? nil : attachmentIDs
    }

    public var attachments: [UUID] { attachmentIDs ?? [] }
}

public struct MessageReaction: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let author: MessageAuthor
    public let emoji: String
    public let createdAt: Date

    public static func isValidEmoji(_ value: String) -> Bool {
        value.count == 1 && value.unicodeScalars.contains {
            ($0.properties.isEmoji && $0.value > 127) || $0.value == 0x20E3
        }
    }
}

public struct MessageReactionChange: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let messageID: UUID
    public let sequence: Int
    public let author: MessageAuthor
    public let emoji: String
    public let removed: Bool
    public let createdAt: Date
}

public struct MessengerReaction: Codable, Hashable, Sendable {
    public let emoji: String
    public let sender: MessengerIdentity
}

public struct MessengerReactionChange: Codable, Hashable, Sendable {
    public let id: UUID
    public let emoji: String
    public let removed: Bool
    public let sender: MessengerIdentity
    public let createdAt: Date
}

public struct ConversationAttachment: Identifiable, Codable, Hashable, Sendable {
    public let annotation: AttachmentAnnotation?
    /// Present for a link to a browser tab, computer or noodlet: its label and last picture.
    public let card: LinkCard?
    public let id: UUID
    public let conversationID: UUID
    public let originalFilename: String
    public let storedFilename: String
    public let mediaType: String
    public let byteCount: Int64
    public let createdAt: Date
    /// Present for link attachments. The owned file is a small .webloc bookmark, not downloaded page content.
    public let url: URL?
    public let voice: VoiceMessage?

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        originalFilename: String,
        storedFilename: String,
        mediaType: String,
        byteCount: Int64,
        createdAt: Date = Date(),
        url: URL? = nil,
        voice: VoiceMessage? = nil,
        card: LinkCard? = nil,
        annotation: AttachmentAnnotation? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.url = url
        self.voice = voice
        self.card = card
        self.annotation = annotation
    }

    /// What a companion link points at; nil for files and web links.
    public var companion: CompanionLink? { url.flatMap(CompanionLink.init) }
}

public struct AgentInbox: Codable, Hashable, Sendable {
    public var conversationOffsets: [String: Int]
    public var reactionOffsets: [String: Int]?

    public init(conversationOffsets: [String: Int] = [:]) {
        self.conversationOffsets = conversationOffsets
    }
}

public enum MessengerHandle: String, Codable, Hashable, Sendable {
    /// The bot's owner.
    case user
    /// Someone the bot's owner shared it with.
    case guest
    case me
    case bot
    case system
}

public struct MessengerIdentity: Codable, Hashable, Sendable {
    public let handle: MessengerHandle
    public let agentID: UUID?
    public let displayName: String

    public init(handle: MessengerHandle, agentID: UUID? = nil, displayName: String) {
        self.handle = handle
        self.agentID = agentID
        self.displayName = displayName
    }
}

public struct MessengerAttachment: Codable, Hashable, Sendable {
    public let annotation: AttachmentAnnotation?
    public let card: LinkCard?
    public let id: UUID
    public let conversationID: UUID
    public let originalFilename: String
    public let storedFilename: String
    public let mediaType: String
    public let byteCount: Int64
    public let createdAt: Date
    public var absolutePath: String
    public let url: URL?
    public let voice: VoiceMessage?

    public init(attachment: ConversationAttachment, absolutePath: String) {
        id = attachment.id
        conversationID = attachment.conversationID
        originalFilename = attachment.originalFilename
        storedFilename = attachment.storedFilename
        mediaType = attachment.mediaType
        byteCount = attachment.byteCount
        createdAt = attachment.createdAt
        self.absolutePath = absolutePath
        url = attachment.url
        voice = attachment.voice
        card = attachment.card
        annotation = attachment.annotation
    }
}

public struct MessengerDelivery: Codable, Hashable, Sendable {
    public let me: MessengerIdentity
    public let conversation: BotConversation
    public let participants: [MessengerIdentity]
    public let sender: MessengerIdentity
    public let message: ChatMessage
    public var attachments: [MessengerAttachment]
    public var reactions: [MessengerReaction]?
    public var reactionChange: MessengerReactionChange?

    public init(
        me: MessengerIdentity,
        conversation: BotConversation,
        participants: [MessengerIdentity],
        sender: MessengerIdentity,
        message: ChatMessage,
        attachments: [MessengerAttachment]
    ) {
        self.me = me
        self.conversation = conversation
        self.participants = participants
        self.sender = sender
        self.message = message
        self.attachments = attachments
    }
}

public struct MessengerParticipantStatus: Codable, Hashable, Sendable {
    public let participant: MessengerIdentity
    public let publicDescription: String?
    public let lastActiveAt: Date?
    /// Set while the bot is suspended: it takes no new turn until then, and messages wait for it.
    public let suspendedUntil: Date?

    public init(
        participant: MessengerIdentity,
        publicDescription: String?,
        lastActiveAt: Date?,
        suspendedUntil: Date? = nil
    ) {
        self.participant = participant
        self.publicDescription = publicDescription
        self.lastActiveAt = lastActiveAt
        self.suspendedUntil = suspendedUntil
    }
}

public struct MessengerRoster: Codable, Hashable, Sendable {
    public let me: MessengerIdentity
    public let conversation: BotConversation
    public let participants: [MessengerParticipantStatus]

    public init(
        me: MessengerIdentity,
        conversation: BotConversation,
        participants: [MessengerParticipantStatus]
    ) {
        self.me = me
        self.conversation = conversation
        self.participants = participants
    }
}
