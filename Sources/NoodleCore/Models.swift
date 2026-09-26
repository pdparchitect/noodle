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
        avatarImageData: Data? = nil
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

    public init(
        id: UUID = UUID(),
        displayName: String,
        publicDescription: String? = nil,
        kind: ConversationKind,
        participantIDs: [UUID],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.publicDescription = publicDescription
        self.kind = kind
        self.participantIDs = participantIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
    case user
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

    public init(
        participant: MessengerIdentity,
        publicDescription: String?,
        lastActiveAt: Date?
    ) {
        self.participant = participant
        self.publicDescription = publicDescription
        self.lastActiveAt = lastActiveAt
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
