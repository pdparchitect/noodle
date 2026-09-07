import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct AgentRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public let createdAt: Date
    public var updatedAt: Date
    public var harnessIdentifier: String?
    public var modelIdentifier: String?
    public var reasoningEffort: String?
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
    public let kind: ConversationKind
    public var participantIDs: [UUID]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        kind: ConversationKind,
        participantIDs: [UUID],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
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
    public let id: UUID
    public let conversationID: UUID
    public let originalFilename: String
    public let storedFilename: String
    public let mediaType: String
    public let byteCount: Int64
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        originalFilename: String,
        storedFilename: String,
        mediaType: String,
        byteCount: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
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
    public let id: UUID
    public let conversationID: UUID
    public let originalFilename: String
    public let storedFilename: String
    public let mediaType: String
    public let byteCount: Int64
    public let createdAt: Date
    public let absolutePath: String

    public init(attachment: ConversationAttachment, absolutePath: String) {
        id = attachment.id
        conversationID = attachment.conversationID
        originalFilename = attachment.originalFilename
        storedFilename = attachment.storedFilename
        mediaType = attachment.mediaType
        byteCount = attachment.byteCount
        createdAt = attachment.createdAt
        self.absolutePath = absolutePath
    }
}

public struct MessengerDelivery: Codable, Hashable, Sendable {
    public let me: MessengerIdentity
    public let conversation: BotConversation
    public let participants: [MessengerIdentity]
    public let sender: MessengerIdentity
    public let message: ChatMessage
    public let attachments: [MessengerAttachment]
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

public struct MessengerInlineImage: Codable, Hashable, Sendable {
    public let attachmentID: UUID
    public let originalFilename: String
    public let mediaType: String
    public let dataURL: String

    public init(
        attachmentID: UUID,
        originalFilename: String,
        mediaType: String,
        dataURL: String
    ) {
        self.attachmentID = attachmentID
        self.originalFilename = originalFilename
        self.mediaType = mediaType
        self.dataURL = dataURL
    }
}

public struct MessengerInboxPayload: Codable, Hashable, Sendable {
    public let deliveries: [MessengerDelivery]
    public let images: [MessengerInlineImage]

    public init(deliveries: [MessengerDelivery], images: [MessengerInlineImage]) {
        self.deliveries = deliveries
        self.images = images
    }
}

public struct ManagedSkillManifest: Codable, Hashable, Sendable {
    public let version: Int
    public let managedPaths: [String]

    public init(version: Int, managedPaths: [String]) {
        self.version = version
        self.managedPaths = managedPaths
    }
}

public struct CreatedAgentWorkspace: Sendable {
    public let agent: AgentRecord
    public let conversation: BotConversation
}

public enum WorkspaceError: LocalizedError, Equatable {
    case emptyName
    case missingAgent(UUID)
    case missingConversation(UUID)
    case insufficientGroupParticipants
    case invalidAgentDirectory
    case invalidAttachment
    case missingMessage(UUID)
    case invalidReaction

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a name."
        case .missingAgent:
            return "One of the selected bots no longer exists."
        case .missingConversation:
            return "The selected conversation no longer exists."
        case .insufficientGroupParticipants:
            return "Add at least one bot to the group."
        case .invalidAgentDirectory:
            return "The Messenger command is not inside a valid bot workspace."
        case .invalidAttachment:
            return "The selected attachment could not be imported."
        case .missingMessage:
            return "The selected message no longer exists."
        case .invalidReaction:
            return "Choose a single emoji for the reaction."
        }
    }
}

public struct WorkspaceRepository: Sendable {
    public let rootURL: URL
    public let launcherExecutableURL: URL?

    public static let managedSkillVersion = 13

    public init(rootURL: URL, launcherExecutableURL: URL? = nil) {
        self.rootURL = rootURL.standardizedFileURL
        self.launcherExecutableURL = launcherExecutableURL?.standardizedFileURL
    }

    public var agentsURL: URL {
        rootURL.appendingPathComponent("Agents", isDirectory: true)
    }

    public var conversationsURL: URL {
        rootURL.appendingPathComponent("Conversations", isDirectory: true)
    }

    private var conversationStateURL: URL {
        rootURL.appendingPathComponent("conversation-state.json")
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: agentsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conversationsURL, withIntermediateDirectories: true)
    }

    public func loadUnreadConversationIDs() throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: conversationStateURL.path) else {
            return []
        }
        return try read(ConversationReadState.self, from: conversationStateURL)
            .unreadConversationIDs
    }

    public func saveUnreadConversationIDs(_ ids: Set<UUID>) throws {
        try prepare()
        try write(
            ConversationReadState(unreadConversationIDs: ids),
            to: conversationStateURL
        )
    }

    public func createAgent(
        named rawName: String,
        harnessIdentifier: String? = nil,
        modelIdentifier: String? = nil,
        reasoningEffort: String? = nil,
        avatarSymbolName: String? = nil,
        avatarColorIndex: Int? = nil,
        avatarImageData: Data? = nil,
        backstory: String = "",
        now: Date = Date()
    ) throws -> CreatedAgentWorkspace {
        let name = try validatedName(rawName)
        try prepare()

        let agent = AgentRecord(
            displayName: name,
            createdAt: now,
            updatedAt: now,
            harnessIdentifier: harnessIdentifier,
            modelIdentifier: modelIdentifier,
            reasoningEffort: reasoningEffort,
            avatarSymbolName: avatarSymbolName,
            avatarColorIndex: avatarColorIndex,
            avatarImageData: avatarImageData
        )
        let agentDirectory = directory(for: agent)
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: false)
        try write(agent, to: agentDirectory.appendingPathComponent("agent.json"))
        try "# Memory\n\n".write(
            to: agentDirectory.appendingPathComponent("memory.md"),
            atomically: true,
            encoding: .utf8
        )
        try updateAgentBackstory(agent, backstory: backstory)
        try synchronizeAgentWorkspace(agent)

        let conversation = BotConversation(
            displayName: name,
            kind: .direct,
            participantIDs: [agent.id],
            createdAt: now,
            updatedAt: now
        )
        try createConversationFiles(conversation)
        return CreatedAgentWorkspace(agent: agent, conversation: conversation)
    }

    public func renameAgent(_ agent: AgentRecord, to rawName: String, now: Date = Date()) throws -> AgentRecord {
        try updateAgent(
            agent,
            displayName: rawName,
            harnessIdentifier: agent.harnessIdentifier,
            modelIdentifier: agent.modelIdentifier,
            reasoningEffort: agent.reasoningEffort,
            avatarSymbolName: agent.avatarSymbolName,
            avatarColorIndex: agent.avatarColorIndex,
            avatarImageData: agent.avatarImageData,
            now: now
        )
    }

    public func updateAgent(
        _ agent: AgentRecord,
        displayName rawName: String,
        harnessIdentifier: String?,
        modelIdentifier: String?,
        reasoningEffort: String?,
        avatarSymbolName: String? = nil,
        avatarColorIndex: Int? = nil,
        avatarImageData: Data? = nil,
        now: Date = Date()
    ) throws -> AgentRecord {
        var renamed = agent
        renamed.displayName = try validatedName(rawName)
        renamed.updatedAt = now
        renamed.harnessIdentifier = harnessIdentifier
        renamed.modelIdentifier = modelIdentifier
        renamed.reasoningEffort = reasoningEffort
        renamed.avatarSymbolName = avatarSymbolName
        renamed.avatarColorIndex = avatarColorIndex
        renamed.avatarImageData = avatarImageData
        try write(renamed, to: directory(for: agent).appendingPathComponent("agent.json"))
        return renamed
    }

    public func createGroup(
        named rawName: String,
        participantIDs: [UUID],
        existingAgents: [AgentRecord],
        now: Date = Date()
    ) throws -> BotConversation {
        let name = try validatedName(rawName)
        let uniqueIDs = Array(Set(participantIDs))
        guard !uniqueIDs.isEmpty else { throw WorkspaceError.insufficientGroupParticipants }

        let knownIDs = Set(existingAgents.map(\.id))
        guard Set(uniqueIDs).isSubset(of: knownIDs) else {
            throw WorkspaceError.missingAgent(uniqueIDs.first(where: { !knownIDs.contains($0) }) ?? UUID())
        }

        let conversation = BotConversation(
            displayName: name,
            kind: .group,
            participantIDs: uniqueIDs.sorted { $0.uuidString < $1.uuidString },
            createdAt: now,
            updatedAt: now
        )
        try createConversationFiles(conversation)
        return conversation
    }

    public func updateGroupParticipants(
        conversationID: UUID,
        participantIDs: [UUID],
        existingAgents: [AgentRecord],
        now: Date = Date()
    ) throws -> BotConversation {
        guard let conversation = try loadConversations().first(where: {
            $0.id == conversationID && $0.kind == .group
        }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }

        return try updateGroup(
            conversationID: conversationID,
            named: conversation.displayName,
            participantIDs: participantIDs,
            existingAgents: existingAgents,
            now: now
        )
    }

    public func updateGroup(
        conversationID: UUID,
        named rawName: String,
        participantIDs: [UUID],
        existingAgents: [AgentRecord],
        now: Date = Date()
    ) throws -> BotConversation {
        guard var conversation = try loadConversations().first(where: {
            $0.id == conversationID && $0.kind == .group
        }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }

        let name = try validatedName(rawName)
        let uniqueIDs = Array(Set(participantIDs))
        guard !uniqueIDs.isEmpty else { throw WorkspaceError.insufficientGroupParticipants }

        let knownIDs = Set(existingAgents.map(\.id))
        guard Set(uniqueIDs).isSubset(of: knownIDs) else {
            throw WorkspaceError.missingAgent(uniqueIDs.first(where: { !knownIDs.contains($0) }) ?? UUID())
        }

        let addedIDs = Set(uniqueIDs).subtracting(conversation.participantIDs)
        if !addedIDs.isEmpty {
            let messages = try loadMessages(conversationID: conversation.id)
            let messageCount = messages.count
            let reactionSequence = messages.flatMap { $0.reactionChanges ?? [] }.map(\.sequence).max() ?? 0
            let conversationKey = conversation.id.uuidString.lowercased()
            for agentID in addedIDs {
                var inbox = try loadInbox(for: agentID)
                inbox.conversationOffsets[conversationKey] = messageCount
                if inbox.reactionOffsets == nil { inbox.reactionOffsets = [:] }
                inbox.reactionOffsets?[conversationKey] = reactionSequence
                try saveInbox(inbox, for: agentID)
            }
        }

        conversation.displayName = name
        conversation.participantIDs = uniqueIDs.sorted { $0.uuidString < $1.uuidString }
        conversation.updatedAt = now
        try updateConversation(conversation)
        return conversation
    }

    public func append(_ message: ChatMessage) throws {
        let file = conversationDirectory(id: message.conversationID).appendingPathComponent("messages.json")
        try withConversationLock(message.conversationID) {
            var messages = (try? read([ChatMessage].self, from: file)) ?? []
            messages.append(message)
            try write(messages, to: file)
        }
    }

    public func synchronizeAgentWorkspaces(_ agents: [AgentRecord]) throws {
        for agent in agents {
            try synchronizeAgentWorkspace(agent)
        }
    }

    public func synchronizeAgentWorkspace(_ agent: AgentRecord) throws {
        let directory = directory(for: agent)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkspaceError.missingAgent(agent.id)
        }

        let agentsDirectory = directory.appendingPathComponent(".agents", isDirectory: true)
        let messengerDirectory = agentsDirectory
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("messenger", isDirectory: true)
        try FileManager.default.createDirectory(at: messengerDirectory, withIntermediateDirectories: true)

        let backstory = try loadAgentBackstory(agent)
        let agentsFile = directory.appendingPathComponent("AGENTS.md")
        try Self.renderedAgentInstructions(backstory: backstory).write(
            to: agentsFile,
            atomically: true,
            encoding: .utf8
        )

        let legacyInstructionsFile = directory.appendingPathComponent("instructions.md")
        if FileManager.default.fileExists(atPath: legacyInstructionsFile.path) {
            try FileManager.default.removeItem(at: legacyInstructionsFile)
        }

        let claudeFile = directory.appendingPathComponent("CLAUDE.md")
        try replaceSymlink(at: claudeFile, destinationPath: "AGENTS.md")

        let skillFile = messengerDirectory.appendingPathComponent("SKILL.md")
        try Self.messengerSkill.write(to: skillFile, atomically: true, encoding: .utf8)

        if let launcherExecutableURL {
            let command = messengerDirectory.appendingPathComponent("messenger")
            try replaceSymlink(at: command, destinationPath: launcherExecutableURL.path)
        }

        let manifest = ManagedSkillManifest(
            version: Self.managedSkillVersion,
            managedPaths: [
                "AGENTS.md",
                "CLAUDE.md",
                ".agents/skills/messenger/SKILL.md",
                ".agents/skills/messenger/messenger"
            ]
        )
        try write(manifest, to: agentsDirectory.appendingPathComponent("managed-skills.json"))
    }

    public func loadAgentBackstory(_ agent: AgentRecord) throws -> String {
        let directory = directory(for: agent)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkspaceError.missingAgent(agent.id)
        }

        let agentsFile = directory.appendingPathComponent("AGENTS.md")
        if let contents = try? String(contentsOf: agentsFile, encoding: .utf8) {
            if let backstory = Self.backstory(fromManagedInstructions: contents) {
                return backstory
            }
            if !Self.looksLikeLegacyManagedInstructions(contents) {
                return Self.normalizedLegacyBackstory(contents)
            }
        }

        let legacyInstructionsFile = directory.appendingPathComponent("instructions.md")
        guard FileManager.default.fileExists(atPath: legacyInstructionsFile.path) else {
            return ""
        }
        let legacy = try String(contentsOf: legacyInstructionsFile, encoding: .utf8)
        return Self.normalizedLegacyBackstory(legacy)
    }

    public func updateAgentBackstory(_ agent: AgentRecord, backstory: String) throws {
        let directory = directory(for: agent)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkspaceError.missingAgent(agent.id)
        }

        let agentsFile = directory.appendingPathComponent("AGENTS.md")
        try Self.renderedAgentInstructions(backstory: backstory).write(
            to: agentsFile,
            atomically: true,
            encoding: .utf8
        )

        let legacyInstructionsFile = directory.appendingPathComponent("instructions.md")
        if FileManager.default.fileExists(atPath: legacyInstructionsFile.path) {
            try FileManager.default.removeItem(at: legacyInstructionsFile)
        }
    }

    public func importAttachment(
        from sourceURL: URL,
        into conversationID: UUID,
        mediaType: String,
        now: Date = Date()
    ) throws -> ConversationAttachment {
        guard try loadConversations().contains(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw WorkspaceError.invalidAttachment }

        let attachmentID = UUID()
        let resolvedMediaType = detectedImageMediaType(at: sourceURL) ?? mediaType
        let attachment = ConversationAttachment(
            id: attachmentID,
            conversationID: conversationID,
            originalFilename: sourceURL.lastPathComponent,
            storedFilename: storedAttachmentName(id: attachmentID, originalFilename: sourceURL.lastPathComponent),
            mediaType: resolvedMediaType,
            byteCount: Int64(values.fileSize ?? 0),
            createdAt: now
        )
        let directory = attachmentsDirectory(conversationID: conversationID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceURL,
            to: directory.appendingPathComponent(attachment.storedFilename)
        )
        try write(attachment, to: directory.appendingPathComponent("\(attachment.id.uuidString.lowercased()).json"))
        return attachment
    }

    public func importAttachment(
        data: Data,
        originalFilename: String,
        into conversationID: UUID,
        mediaType: String,
        now: Date = Date()
    ) throws -> ConversationAttachment {
        guard try loadConversations().contains(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }

        let filename = URL(fileURLWithPath: originalFilename).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty else { throw WorkspaceError.invalidAttachment }

        let attachmentID = UUID()
        let resolvedMediaType = detectedImageMediaType(in: data) ?? mediaType
        let attachment = ConversationAttachment(
            id: attachmentID,
            conversationID: conversationID,
            originalFilename: filename,
            storedFilename: storedAttachmentName(id: attachmentID, originalFilename: filename),
            mediaType: resolvedMediaType,
            byteCount: Int64(data.count),
            createdAt: now
        )
        let directory = attachmentsDirectory(conversationID: conversationID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(
            to: directory.appendingPathComponent(attachment.storedFilename),
            options: .atomic
        )
        try write(attachment, to: directory.appendingPathComponent("\(attachment.id.uuidString.lowercased()).json"))
        return attachment
    }

    public func loadAttachments(conversationID: UUID) throws -> [ConversationAttachment] {
        let directory = attachmentsDirectory(conversationID: conversationID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { metadataURL in
            let attachment = try read(ConversationAttachment.self, from: metadataURL)
            let fileURL = attachmentFileURL(attachment)
            guard let detectedMediaType = detectedImageMediaType(at: fileURL),
                  detectedMediaType != attachment.mediaType else { return attachment }

            let repaired = ConversationAttachment(
                id: attachment.id,
                conversationID: attachment.conversationID,
                originalFilename: attachment.originalFilename,
                storedFilename: attachment.storedFilename,
                mediaType: detectedMediaType,
                byteCount: attachment.byteCount,
                createdAt: attachment.createdAt
            )
            try? write(repaired, to: metadataURL)
            return repaired
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    private func detectedImageMediaType(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return detectedImageMediaType(from: source)
    }

    private func detectedImageMediaType(in data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        return detectedImageMediaType(from: source)
    }

    private func detectedImageMediaType(from source: CGImageSource) -> String? {
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let contentType = UTType(typeIdentifier),
              contentType.conforms(to: .image) else { return nil }
        return contentType.preferredMIMEType
    }

    public func attachmentFileURL(_ attachment: ConversationAttachment) -> URL {
        attachmentsDirectory(conversationID: attachment.conversationID)
            .appendingPathComponent(attachment.storedFilename)
    }

    public func inlineImageDataURL(for attachment: MessengerAttachment) throws -> String? {
        guard attachment.mediaType.lowercased().hasPrefix("image/") else { return nil }

        let directory = attachmentsDirectory(conversationID: attachment.conversationID)
            .standardizedFileURL
        let file = directory.appendingPathComponent(attachment.storedFilename)
            .standardizedFileURL
        let deliveredFile = URL(fileURLWithPath: attachment.absolutePath)
            .standardizedFileURL
        guard file.deletingLastPathComponent() == directory,
              file == deliveredFile else {
            throw WorkspaceError.invalidAttachment
        }

        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return "data:\(attachment.mediaType);base64,\(data.base64EncodedString())"
    }

    public func removeAttachment(_ attachment: ConversationAttachment) throws {
        let file = attachmentFileURL(attachment)
        let metadata = attachmentsDirectory(conversationID: attachment.conversationID)
            .appendingPathComponent("\(attachment.id.uuidString.lowercased()).json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        if FileManager.default.fileExists(atPath: metadata.path) {
            try FileManager.default.removeItem(at: metadata)
        }
    }

    private func inboxURL(for agentID: UUID) -> URL {
        // Mutable messaging state is not skill/configuration data. Codex keeps
        // .agents read-only even within a writable workspace.
        directory(forAgentID: agentID).appendingPathComponent(".noodle/inbox.json")
    }

    private func loadInbox(for agentID: UUID) throws -> AgentInbox {
        let current = inboxURL(for: agentID)
        if FileManager.default.fileExists(atPath: current.path) {
            return try read(AgentInbox.self, from: current)
        }
        // Lazy migration: preserve the old cursor (including reaction offsets),
        // leave its file untouched, and write the new location only on consume.
        let legacy = directory(forAgentID: agentID).appendingPathComponent(".agents/inbox.json")
        if FileManager.default.fileExists(atPath: legacy.path) {
            return try read(AgentInbox.self, from: legacy)
        }
        return AgentInbox()
    }

    private func saveInbox(_ inbox: AgentInbox, for agentID: UUID) throws {
        let file = inboxURL(for: agentID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(inbox, to: file)
    }

    public func latestMessages(
        for agentID: UUID,
        consuming: Bool = true,
        in conversationID: UUID? = nil,
        includingRead: Bool = false
    ) throws -> [MessengerDelivery] {
        let agents = try loadAgents()
        guard let readingAgent = agents.first(where: { $0.id == agentID }) else {
            throw WorkspaceError.missingAgent(agentID)
        }
        let agentsByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let me = MessengerIdentity(handle: .me, agentID: agentID, displayName: readingAgent.displayName)
        let conversations = try loadConversations().filter {
            $0.participantIDs.contains(agentID) && (conversationID == nil || $0.id == conversationID)
        }
        if let conversationID, conversations.isEmpty { throw WorkspaceError.missingConversation(conversationID) }
        var inbox = try loadInbox(for: agentID)
        var deliveries: [MessengerDelivery] = []

        func identity(for author: MessageAuthor) -> MessengerIdentity {
            switch author {
            case .user: return MessengerIdentity(handle: .user, displayName: "User")
            case .agent(let id):
                return id == agentID ? me : MessengerIdentity(
                    handle: .bot, agentID: id,
                    displayName: agentsByID[id]?.displayName ?? "Unknown Bot"
                )
            case .system: return MessengerIdentity(handle: .system, displayName: "Noodle")
            }
        }

        for conversation in conversations {
            let messages = try loadMessages(conversationID: conversation.id)
            let key = conversation.id.uuidString.lowercased()
            let offset = includingRead ? 0 : min(inbox.conversationOffsets[key, default: 0], messages.count)
            let attachments = try loadAttachments(conversationID: conversation.id)
            let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
            let participants = conversation.participantIDs.map { participantID in
                if participantID == agentID { return me }
                return MessengerIdentity(
                    handle: .bot,
                    agentID: participantID,
                    displayName: agentsByID[participantID]?.displayName ?? "Unknown Bot"
                )
            }

            func delivery(for message: ChatMessage) -> MessengerDelivery {
                var delivery = MessengerDelivery(
                        me: me,
                        conversation: conversation,
                        participants: participants,
                        sender: identity(for: message.author),
                        message: message,
                        attachments: message.attachments.compactMap { attachmentID in
                            guard let attachment = byID[attachmentID] else { return nil }
                            return MessengerAttachment(
                                attachment: attachment,
                                absolutePath: attachmentFileURL(attachment).standardizedFileURL.path
                            )
                        }
                )
                delivery.reactions = (message.reactions ?? []).map {
                    MessengerReaction(emoji: $0.emoji, sender: identity(for: $0.author))
                }
                return delivery
            }

            for message in messages.dropFirst(offset) {
                if !includingRead, case .agent(let authorID) = message.author, authorID == agentID { continue }
                deliveries.append(delivery(for: message))
            }

            let changes = messages.flatMap { $0.reactionChanges ?? [] }
            let reactionOffset = inbox.reactionOffsets?[key] ?? 0
            if !includingRead {
                let byMessageID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
                for change in changes.sorted(by: { $0.sequence < $1.sequence }) where change.sequence > reactionOffset {
                    if change.author == .agent(agentID) { continue }
                    guard let message = byMessageID[change.messageID] else { continue }
                    var item = delivery(for: message)
                    item.reactionChange = MessengerReactionChange(
                        id: change.id, emoji: change.emoji, removed: change.removed,
                        sender: identity(for: change.author), createdAt: change.createdAt
                    )
                    deliveries.append(item)
                }
            }
            if consuming && !includingRead {
                inbox.conversationOffsets[key] = messages.count
                if inbox.reactionOffsets == nil { inbox.reactionOffsets = [:] }
                inbox.reactionOffsets?[key] = changes.map(\.sequence).max() ?? 0
            }
        }

        if consuming && !includingRead { try saveInbox(inbox, for: agentID) }
        return deliveries.sorted {
            ($0.reactionChange?.createdAt ?? $0.message.createdAt) < ($1.reactionChange?.createdAt ?? $1.message.createdAt)
        }
    }

    @discardableResult
    public func setReaction(
        conversationID: UUID, messageID: UUID, author: MessageAuthor,
        emoji: String, present: Bool, now: Date = Date()
    ) throws -> ChatMessage {
        let emoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MessageReaction.isValidEmoji(emoji) else {
            throw WorkspaceError.invalidReaction
        }
        guard let conversation = try loadConversations().first(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        switch author {
        case .user: break
        case .agent(let id):
            guard conversation.participantIDs.contains(id), try loadAgents().contains(where: { $0.id == id }) else {
                throw WorkspaceError.missingAgent(id)
            }
        case .system: throw WorkspaceError.invalidReaction
        }
        return try withConversationLock(conversationID) {
            var messages = try loadMessages(conversationID: conversationID)
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
                throw WorkspaceError.missingMessage(messageID)
            }
            var reactions = messages[index].reactions ?? []
            let existing = reactions.firstIndex { $0.author == author && $0.emoji == emoji }
            guard present != (existing != nil) else { return messages[index] }
            if present {
                reactions.append(MessageReaction(id: UUID(), author: author, emoji: emoji, createdAt: now))
            } else if let existing {
                reactions.remove(at: existing)
            }
            let sequence = (messages.flatMap { $0.reactionChanges ?? [] }.map(\.sequence).max() ?? 0) + 1
            let change = MessageReactionChange(
                id: UUID(), conversationID: conversationID, messageID: messageID,
                sequence: sequence, author: author, emoji: emoji, removed: !present, createdAt: now
            )
            messages[index].reactions = reactions
            messages[index].reactionChanges = (messages[index].reactionChanges ?? []) + [change]
            // Persist the badge and its inbox event in the same atomic write.
            try write(messages, to: conversationDirectory(id: conversationID).appendingPathComponent("messages.json"))
            return messages[index]
        }
    }

    public func sendAgentMessage(
        agentID: UUID,
        conversationID: UUID,
        body: String,
        attachmentIDs: [UUID] = [],
        now: Date = Date()
    ) throws -> ChatMessage {
        let name = try validatedName(body)
        guard try loadAgents().contains(where: { $0.id == agentID }) else {
            throw WorkspaceError.missingAgent(agentID)
        }
        guard let conversation = try loadConversations().first(where: { $0.id == conversationID }),
              conversation.participantIDs.contains(agentID) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let availableAttachmentIDs = Set(try loadAttachments(conversationID: conversationID).map(\.id))
        guard Set(attachmentIDs).count == attachmentIDs.count,
              Set(attachmentIDs).isSubset(of: availableAttachmentIDs) else {
            throw WorkspaceError.invalidAttachment
        }
        let message = ChatMessage(
            conversationID: conversationID,
            author: .agent(agentID),
            body: name,
            createdAt: now,
            delivery: .delivered,
            attachmentIDs: attachmentIDs
        )
        try append(message)
        var updated = conversation
        updated.updatedAt = now
        try updateConversation(updated)
        return message
    }

    public func notificationRecipientIDs(for messages: [ChatMessage]) throws -> Set<UUID> {
        let conversationsByID = Dictionary(
            uniqueKeysWithValues: try loadConversations().map { ($0.id, $0) }
        )
        var recipientIDs = Set<UUID>()

        for message in messages {
            guard case .agent(let senderID) = message.author,
                  let conversation = conversationsByID[message.conversationID],
                  conversation.kind == .group else { continue }

            recipientIDs.formUnion(
                conversation.participantIDs.filter { $0 != senderID }
            )
        }

        return recipientIDs
    }

    public func sendUserMessage(
        conversationID: UUID,
        body: String,
        attachmentIDs: [UUID] = [],
        now: Date = Date()
    ) throws -> ChatMessage {
        let text = try validatedName(body)
        guard var conversation = try loadConversations().first(where: { $0.id == conversationID }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }
        let message = ChatMessage(
            conversationID: conversationID,
            author: .user,
            body: text,
            createdAt: now,
            delivery: .delivered,
            attachmentIDs: attachmentIDs
        )
        try append(message)
        conversation.updatedAt = now
        try updateConversation(conversation)
        return message
    }

    /// Queue retries reuse the request UUID, so restarting after delivery never sends twice.
    public func sendSharedMessage(_ request: SharedRequest, files: [URL]) throws -> ChatMessage {
        guard var conversation = try loadConversations().first(where: { $0.id == request.conversationID }),
              request.filenames.count == files.count else { throw SharedInboxError.invalidRequest }
        return try withConversationLock(conversation.id) {
            var messages = try loadMessages(conversationID: conversation.id)
            if let existing = messages.first(where: { $0.id == request.id }) { return existing }
            var imported: [ConversationAttachment] = []
            do {
                for file in files {
                    imported.append(try importAttachment(from: file, into: conversation.id,
                        mediaType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"))
                }
                let message = ChatMessage(id: request.id, conversationID: conversation.id, author: .user,
                    body: request.body.isEmpty ? "Sent \(files.count) attachment\(files.count == 1 ? "" : "s")" : request.body,
                    delivery: .queued, attachmentIDs: imported.map(\.id))
                messages.append(message)
                try write(messages, to: conversationDirectory(id: conversation.id).appendingPathComponent("messages.json"))
                conversation.updatedAt = message.createdAt
                try? updateConversation(conversation)
                return message
            } catch {
                for attachment in imported { try? removeAttachment(attachment) }
                throw error
            }
        }
    }

    public func updateConversation(_ conversation: BotConversation) throws {
        let file = conversationDirectory(id: conversation.id).appendingPathComponent("conversation.json")
        try write(conversation, to: file)
    }

    public func deleteConversation(id: UUID) throws {
        let directory = conversationDirectory(id: id)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkspaceError.missingConversation(id)
        }
        try FileManager.default.removeItem(at: directory)
    }

    public func deleteAgent(_ agent: AgentRecord) throws {
        let directory = directory(for: agent)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkspaceError.missingAgent(agent.id)
        }

        for conversation in try loadConversations() where conversation.participantIDs.contains(agent.id) {
            if conversation.kind == .direct {
                try deleteConversation(id: conversation.id)
            } else {
                var updated = conversation
                updated.participantIDs.removeAll { $0 == agent.id }
                try updateConversation(updated)
            }
        }

        try FileManager.default.removeItem(at: directory)
    }

    public func loadAgents() throws -> [AgentRecord] {
        try prepare()
        return try loadChildren(from: agentsURL, filename: "agent.json", as: AgentRecord.self)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func loadConversations() throws -> [BotConversation] {
        try prepare()
        return try loadChildren(from: conversationsURL, filename: "conversation.json", as: BotConversation.self)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func loadMessages(conversationID: UUID) throws -> [ChatMessage] {
        let file = conversationDirectory(id: conversationID).appendingPathComponent("messages.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try read([ChatMessage].self, from: file)
    }

    public func directory(for agent: AgentRecord) -> URL {
        directory(forAgentID: agent.id)
    }

    public func directory(forAgentID id: UUID) -> URL {
        agentsURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    public func conversationDirectory(id: UUID) -> URL {
        conversationsURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    public func attachmentsDirectory(conversationID: UUID) -> URL {
        conversationDirectory(id: conversationID).appendingPathComponent("Attachments", isDirectory: true)
    }

    private func createConversationFiles(_ conversation: BotConversation) throws {
        try prepare()
        let directory = conversationDirectory(id: conversation.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try write(conversation, to: directory.appendingPathComponent("conversation.json"))
        try write([ChatMessage](), to: directory.appendingPathComponent("messages.json"))
        try FileManager.default.createDirectory(
            at: attachmentsDirectory(conversationID: conversation.id),
            withIntermediateDirectories: true
        )
    }

    private func validatedName(_ rawName: String) throws -> String {
        let value = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw WorkspaceError.emptyName }
        return value
    }

    private func loadChildren<Value: Decodable>(
        from parent: URL,
        filename: String,
        as type: Value.Type
    ) throws -> [Value] {
        let directories = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try directories.compactMap { directory in
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            let file = directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try read(Value.self, from: file)
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func replaceSymlink(at url: URL, destinationPath: String) throws {
        if FileManager.default.fileExists(atPath: url.path) ||
            (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destinationPath)
    }

    private func storedAttachmentName(id: UUID, originalFilename: String) -> String {
        let suffix = URL(fileURLWithPath: originalFilename).pathExtension
        return id.uuidString.lowercased() + (suffix.isEmpty ? "" : ".\(suffix)")
    }

    private func withConversationLock<Value>(_ id: UUID, operation: () throws -> Value) throws -> Value {
        let lockURL = conversationDirectory(id: id).appendingPathComponent(".messages.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static let managedInstructionsStart = "<!-- noodle:managed:start -->"
    private static let managedInstructionsEnd = "<!-- noodle:managed:end -->"

    private static func renderedAgentInstructions(backstory: String) -> String {
        let normalizedBackstory = backstory.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # Noodle Agent

        ## Backstory

        \(normalizedBackstory)

        \(managedInstructionsStart)
        \(managedAgentInstructions)
        \(managedInstructionsEnd)
        """
    }

    private static func backstory(fromManagedInstructions contents: String) -> String? {
        guard let heading = contents.range(of: "## Backstory"),
              let managedStart = contents.range(
                of: managedInstructionsStart,
                range: heading.upperBound..<contents.endIndex
              ) else { return nil }
        return String(contents[heading.upperBound..<managedStart.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLegacyBackstory(_ contents: String) -> String {
        var lines = contents.components(separatedBy: .newlines)
        if let firstContentIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), lines[firstContentIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("# Instructions") == .orderedSame {
            lines.remove(at: firstContentIndex)
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeLegacyManagedInstructions(_ contents: String) -> Bool {
        contents.contains("# Noodle Agent") &&
            contents.contains("## Messages") &&
            contents.contains("--get-latest")
    }

    private static let managedAgentInstructions = """
    ## Noodle Runtime

    This directory is the bot's persistent workspace. The Backstory section above is this bot's user-authored instructions. Noodle manages the runtime section and Messenger core skill; other skills under `.agents/skills` belong to this bot and are left untouched.

    ## Messages

    \(AgentWakeReason.heartbeatInstructions)

    \(ConversationEffectKind.messengerInstructions)

    Reactions are lightweight acknowledgements or feedback. Use `./.agents/skills/messenger/messenger --react --conversation <uuid> --message <message-uuid> --emoji '👀'` to add your reaction; use `--unreact` with the same arguments to remove it. For example, 👀 can acknowledge receipt, ⏳ can indicate work in progress, and ✅ can indicate completion; choose reactions only when useful and keep work-status reactions accurate. Adding the same emoji twice is safe. `--list-messages --conversation <uuid>` reads full history, including your own messages and current reactions, without consuming the inbox. A delivery with `reactionChange` is feedback on the referenced message, not a new request to repeat it: its `sender` identifies the reactor, `emoji` identifies the reaction, and `removed` distinguishes removal. Reacting does not notify you of your own event. Other participants are notified; do not create acknowledgement loops or reply to every reaction.

    Noodle `inbox-changed` notifications mean that this inbox may have changed. They never contain the user's message. In Codex, immediately run the bundled Messenger CLI through the programmatic bridge: `const r = await tools.exec_command({cmd: "./.agents/skills/messenger/messenger --get-latest --inline-images", max_output_tokens: 250000}); if (r.exit_code !== 0) throw new Error(r.output); const payload = JSON.parse(r.output); text(payload.deliveries); for (const visual of payload.images) image(visual.dataURL, "original");`. Every delivery names `me`, lists the conversation's named `participants`, and annotates the message `sender` with a `user`, `me`, `bot`, or `system` handle. Images attached to unread messages arrive directly from the CLI as visual inputs, so inspect them without calling a local image viewer. Every attachment also includes its exact `absolutePath` for non-visual file work. Run the get-latest command only once for each notification because it consumes the inbox. Reply through the Messenger CLI using `--send`, the conversation UUID, and `--body-percent-encoded`; create the argument with `encodeURIComponent(body).replaceAll("'", "%27")`. Add a repeatable `--attach <file-path>` option to send files you created; reply text is optional when a file is attached. Never reply to the notification text itself. If there are no deliveries on an `inbox-changed` event, finish quietly. On a `heartbeat` event, follow the heartbeat guidance above.

    Read new direct and group messages:

    ```sh
    ./.agents/skills/messenger/messenger --get-latest
    ```

    Reply to a conversation:

    ```sh
    ./.agents/skills/messenger/messenger --send --conversation <conversation-uuid> --body "Your response"
    ```

    Reply with files created in this workspace:

    ```sh
    ./.agents/skills/messenger/messenger --send --conversation <conversation-uuid> --body "The requested files" --attach ./report.pdf --attach ./chart.png
    ```
    """

    private static let messengerSkill = """
    ---
    name: messenger
    description: Read and reply to this bot's Noodle direct and group conversations.
    ---

    # Messenger

    \(AgentWakeReason.heartbeatInstructions)

    \(ConversationEffectKind.messengerInstructions)

    Add an emoji with `./.agents/skills/messenger/messenger --react --conversation <uuid> --message <message-uuid> --emoji '👀'`. Remove only your own emoji using `--unreact` with the same arguments. Adding twice is idempotent. Use any single emoji for acknowledgement, progress, completion, or feedback, and remove outdated progress indicators when finished. `--list-messages --conversation <uuid>` lists history and current named reactions without consuming the inbox, including your own messages. `--get-latest` also delivers `reactionChange` events on already-read messages. The change has a named `sender`, `emoji`, and `removed` flag. The referenced message is context, not a new request: handle feedback appropriately without repeating the original task or creating reaction/reply loops. You do not receive your own reaction events.

    In Codex, run the bundled CLI through the programmatic bridge: `const r = await tools.exec_command({cmd: "./.agents/skills/messenger/messenger --get-latest --inline-images", max_output_tokens: 250000}); if (r.exit_code !== 0) throw new Error(r.output); const payload = JSON.parse(r.output); text(payload.deliveries); for (const visual of payload.images) image(visual.dataURL, "original");`. Each delivery includes `me`, a named participant roster, an explicitly annotated sender (`user`, `me`, `bot`, or `system`), the message, and linked attachments. The CLI includes attached images as visual inputs; inspect those without calling a local image viewer. Every attachment also includes its exact `absolutePath` for non-visual file work. Run get-latest only once for each notification because it consumes the inbox.

    The bundled command-line helper remains available to harnesses that use shell commands:

    `./.agents/skills/messenger/messenger --get-latest --inline-images`

    Reply with `./.agents/skills/messenger/messenger --send --conversation <uuid> --body-percent-encoded <percent-encoded-utf8>`. In Codex, create the encoded value with `encodeURIComponent(body).replaceAll("'", "%27")` and pass it as a single-quoted command argument. Add `--attach <file-path>` once for each file the bot should send. Relative paths resolve from the bot's workspace, files are copied into the conversation, and the body is optional when at least one attachment is supplied. The executable identifies this bot from the opaque workspace path. Do not edit Noodle's conversation JSON directly.
    """
}

private struct ConversationReadState: Codable {
    let version: Int
    let unreadConversationIDs: Set<UUID>

    init(unreadConversationIDs: Set<UUID>) {
        version = 1
        self.unreadConversationIDs = unreadConversationIDs
    }
}
