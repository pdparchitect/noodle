import Darwin
import AppletBridge
import ComputerBridge
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
    public let computer: ComputerCard?
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
        computer: ComputerCard? = nil,
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
        self.computer = computer
        self.annotation = annotation
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
    public let annotation: AttachmentAnnotation?
    public let computer: ComputerCard?
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
        computer = attachment.computer
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
    private let discoverAppletApplication: @Sendable () -> URL?

    public static let managedSkillVersion = 24

    public init(rootURL: URL, launcherExecutableURL: URL? = nil,
                discoverAppletApplication: @escaping @Sendable () -> URL? = { AppletAgentSkill.installedApplicationURL() }) {
        self.rootURL = AgentStorageLayout.canonicalURL(rootURL)
        self.launcherExecutableURL = launcherExecutableURL?.standardizedFileURL
        self.discoverAppletApplication = discoverAppletApplication
    }

    public var appletExecutableURL: URL? {
        guard let executable = launcherExecutableURL?.deletingLastPathComponent().appendingPathComponent("noodlet"),
              FileManager.default.isExecutableFile(atPath: executable.path),
              AppletAgentSkill.isCompanionInstalled(at: discoverAppletApplication()) else { return nil }
        return executable
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
        publicDescription: String? = nil,
        avatarSymbolName: String? = nil,
        avatarColorIndex: Int? = nil,
        avatarImageData: Data? = nil,
        backstory: String = "",
        now: Date = Date()
    ) throws -> CreatedAgentWorkspace {
        let name = try ConversationName.validated(rawName)
        try prepare()

        let agent = AgentRecord(
            displayName: name,
            createdAt: now,
            updatedAt: now,
            harnessIdentifier: harnessIdentifier,
            modelIdentifier: modelIdentifier,
            reasoningEffort: reasoningEffort,
            publicDescription: Self.normalizedOptionalText(publicDescription),
            avatarSymbolName: avatarSymbolName,
            avatarColorIndex: avatarColorIndex,
            avatarImageData: avatarImageData
        )
        let layout = storage(for: agent.id)
        try layout.create()
        let agentDirectory = layout.workspace
        try write(agent, to: layout.configuration)
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
            publicDescription: agent.publicDescription,
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
        publicDescription: String? = nil,
        avatarSymbolName: String? = nil,
        avatarColorIndex: Int? = nil,
        avatarImageData: Data? = nil,
        now: Date = Date()
    ) throws -> AgentRecord {
        var renamed = agent
        renamed.displayName = try ConversationName.validated(rawName)
        renamed.updatedAt = now
        renamed.harnessIdentifier = harnessIdentifier
        renamed.modelIdentifier = modelIdentifier
        renamed.reasoningEffort = reasoningEffort
        renamed.publicDescription = Self.normalizedOptionalText(publicDescription)
        renamed.avatarSymbolName = avatarSymbolName
        renamed.avatarColorIndex = avatarColorIndex
        renamed.avatarImageData = avatarImageData
        try write(renamed, to: storage(for: agent.id).configuration)
        return renamed
    }

    public func setAgentIcon(from attachment: ConversationAttachment) throws -> AgentRecord {
        guard let conversation = try loadConversations().first(where: { $0.id == attachment.conversationID }),
              conversation.kind == .direct, conversation.participantIDs.count == 1,
              var agent = try loadAgents().first(where: { $0.id == conversation.participantIDs[0] }) else {
            throw WorkspaceError.invalidAttachment
        }
        let url = attachmentFileURL(attachment)
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 50 * 1024 * 1024, ConversationBackground.canUseImage(at: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { throw ConversationBackgroundError.invalidImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversationBackgroundError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversationBackgroundError.invalidImage }
        // Appearance only: preserve runtime configuration and do not restart the bot.
        agent.avatarImageData = data as Data
        agent.updatedAt = Date()
        try write(agent, to: storage(for: agent.id).configuration)
        return agent
    }

    public func createGroup(
        named rawName: String,
        publicDescription: String? = nil,
        participantIDs: [UUID],
        existingAgents: [AgentRecord],
        now: Date = Date()
    ) throws -> BotConversation {
        let name = try ConversationName.validated(rawName)
        let uniqueIDs = Array(Set(participantIDs))
        guard !uniqueIDs.isEmpty else { throw WorkspaceError.insufficientGroupParticipants }

        let knownIDs = Set(existingAgents.map(\.id))
        guard Set(uniqueIDs).isSubset(of: knownIDs) else {
            throw WorkspaceError.missingAgent(uniqueIDs.first(where: { !knownIDs.contains($0) }) ?? UUID())
        }

        let conversation = BotConversation(
            displayName: name,
            publicDescription: Self.normalizedOptionalText(publicDescription),
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
            publicDescription: conversation.publicDescription,
            participantIDs: participantIDs,
            existingAgents: existingAgents,
            now: now
        )
    }

    public func updateGroup(
        conversationID: UUID,
        named rawName: String,
        publicDescription: String?,
        participantIDs: [UUID],
        existingAgents: [AgentRecord],
        now: Date = Date()
    ) throws -> BotConversation {
        guard var conversation = try loadConversations().first(where: {
            $0.id == conversationID && $0.kind == .group
        }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }

        let name = try ConversationName.validated(rawName)
        let uniqueIDs = Array(Set(participantIDs))
        guard !uniqueIDs.isEmpty else { throw WorkspaceError.insufficientGroupParticipants }

        let knownIDs = Set(existingAgents.map(\.id))
        guard Set(uniqueIDs).isSubset(of: knownIDs) else {
            throw WorkspaceError.missingAgent(uniqueIDs.first(where: { !knownIDs.contains($0) }) ?? UUID())
        }

        let previousIDs = Set(conversation.participantIDs)
        let addedIDs = Set(uniqueIDs).subtracting(previousIDs)
        let removedIDs = previousIDs.subtracting(uniqueIDs)
        let normalizedDescription = Self.normalizedOptionalText(publicDescription)
        let descriptionChanged = conversation.publicDescription != normalizedDescription
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
        conversation.publicDescription = normalizedDescription
        conversation.participantIDs = uniqueIDs.sorted { $0.uuidString < $1.uuidString }
        conversation.updatedAt = now
        try updateConversation(conversation)

        if !addedIDs.isEmpty || !removedIDs.isEmpty || descriptionChanged {
            let namesByID = Dictionary(uniqueKeysWithValues: existingAgents.map { ($0.id, $0.displayName) })
            let addedNames = addedIDs.compactMap { namesByID[$0] }.sorted()
            let removedNames = removedIDs.compactMap { namesByID[$0] }.sorted()
            var changes: [GroupNotice] = []
            if !addedNames.isEmpty {
                changes.append(.membersAdded(addedNames))
            }
            if !removedNames.isEmpty {
                changes.append(.membersRemoved(removedNames))
            }
            if descriptionChanged {
                changes.append(.descriptionChanged(normalizedDescription))
            }
            try append(ChatMessage(
                conversationID: conversation.id,
                author: .system,
                body: changes.map(\.body).joined(separator: " "),
                createdAt: now,
                delivery: .delivered
            ))
        }
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
        try storage(for: agent.id).validate()
        let directory = directory(for: agent)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkspaceError.missingAgent(agent.id)
        }

        let workspaceFiles = try WorkspaceMailbox(workspace: directory, path: "")
        let agentsFiles = try WorkspaceMailbox(workspace: directory, path: ".agents", create: true)
        let messengerFiles = try WorkspaceMailbox(workspace: directory, path: ".agents/skills/messenger", create: true)

        let backstory = try loadAgentBackstory(agent)
        let mcpRegistry = try MCPRegistry.load(root: rootURL)
        let computerAssigned = !(try ComputerAssignments.load(root: rootURL)).assigned(to: agent.id).isEmpty
        let appletExecutable = appletExecutableURL
        let appletEnabled = appletExecutable != nil
        let appletInstructions = appletEnabled ? "\n## Creative applets\nRead `.agents/skills/applet/SKILL.md` to build and run HTML and native Swift noodlets in Noodle Applet.\n" : ""
        let computerInstructions = computerAssigned ? "\n## Assigned computers\nRead `.agents/skills/computer/SKILL.md` to access your assigned computers through Noodle.\n" : ""
        try workspaceFiles.writeData(Data((Self.renderedAgentInstructions(backstory: backstory,
            mcpConnections: mcpRegistry.assigned(to: agent.id)) + computerInstructions + appletInstructions).utf8), named: "AGENTS.md")
        workspaceFiles.remove("instructions.md")
        try workspaceFiles.symlink("CLAUDE.md", destination: "AGENTS.md")
        let mcpExecutable = launcherExecutableURL?.deletingLastPathComponent().appendingPathComponent("mcpshim")
        try MCPSkillWriter.synchronize(workspace: directory, connections: mcpRegistry.assigned(to: agent.id),
            executable: mcpExecutable.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil })
        let computerExecutable = launcherExecutableURL?.deletingLastPathComponent().appendingPathComponent("computer")
        try ComputerAgentSkill.synchronize(workspace: directory, enabled: computerAssigned,
            executable: computerExecutable.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil })
        try AppletAgentSkill.synchronize(workspace: directory, enabled: appletEnabled, executable: appletEnabled ? appletExecutable : nil)
        let claudeSkillPaths = try synchronizeClaudeSkillLinks(in: directory)

        try messengerFiles.writeData(Data(Self.messengerSkill.utf8), named: "SKILL.md")
        if let launcherExecutableURL {
            try messengerFiles.symlink("messenger", destination: launcherExecutableURL.path)
        }

        let manifest = ManagedSkillManifest(
            version: Self.managedSkillVersion,
            managedPaths: [
                "AGENTS.md",
                "CLAUDE.md",
                ".agents/skills/messenger/SKILL.md",
                ".agents/skills/messenger/messenger"
            ] + (computerAssigned ? [".agents/skills/computer/SKILL.md", ".agents/skills/computer/computer", ".agents/skills/computer/.noodle-managed"] : []) + (appletEnabled ? [".agents/skills/applet/SKILL.md", ".agents/skills/applet/noodlet", ".agents/skills/applet/.noodle-managed"] : []) + claudeSkillPaths
        )
        try agentsFiles.write(manifest, named: "managed-skills.json")
    }

    public func loadAgentBackstory(_ agent: AgentRecord) throws -> String {
        let directory = directory(for: agent)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw WorkspaceError.missingAgent(agent.id)
        }

        let files = try WorkspaceMailbox(workspace: directory, path: "")
        if files.contains("AGENTS.md") {
            let contents = String(decoding: try files.read("AGENTS.md", limit: 4 * 1_048_576), as: UTF8.self)
            if let backstory = Self.backstory(fromManagedInstructions: contents) { return backstory }
            if !Self.looksLikeLegacyManagedInstructions(contents) { return Self.normalizedLegacyBackstory(contents) }
        }
        guard files.contains("instructions.md") else { return "" }
        let legacy = String(decoding: try files.read("instructions.md", limit: 4 * 1_048_576), as: UTF8.self)
        return Self.normalizedLegacyBackstory(legacy)
    }

    public func updateAgentBackstory(_ agent: AgentRecord, backstory: String) throws {
        let files = try WorkspaceMailbox(workspace: directory(for: agent), path: "")
        try files.writeData(Data(Self.renderedAgentInstructions(backstory: backstory,
            mcpConnections: MCPRegistry.load(root: rootURL).assigned(to: agent.id)).utf8), named: "AGENTS.md")
        files.remove("instructions.md")
    }

    public func importAttachment(
        from sourceURL: URL,
        into conversationID: UUID,
        mediaType: String,
        now: Date = Date(),
        voice: VoiceMessage? = nil
    ) throws -> ConversationAttachment {
        if let voice {
            guard sourceURL.isFileURL, mediaType.hasPrefix("audio/"), voice.isValid else {
                throw WorkspaceError.invalidAttachment
            }
        }
        if !sourceURL.isFileURL {
            return try importLinkAttachment(sourceURL, into: conversationID, now: now)
        }
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
            createdAt: now,
            voice: voice
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
        now: Date = Date(),
        linkURL: URL? = nil,
        computer: ComputerCard? = nil,
        annotation: AttachmentAnnotation? = nil
    ) throws -> ConversationAttachment {
        if let annotation {
            guard annotation.isValid, computer == nil, linkURL == nil, mediaType == annotation.mediaType,
                  let source = try loadAttachments(conversationID: conversationID).first(where: { $0.id == annotation.sourceAttachmentID }),
                  source.originalFilename == annotation.sourceFilename else { throw WorkspaceError.invalidAttachment }
            if let messageID = annotation.sourceMessageID {
                guard try loadMessages(conversationID: conversationID).contains(where: { $0.id == messageID }) else {
                    throw WorkspaceError.invalidAttachment
                }
            }
            if annotation.version == 1 {
                guard data.starts(with: Data("%PDF-".utf8)) else { throw WorkspaceError.invalidAttachment }
            } else if annotation.region != nil {
                guard detectedImageMediaType(in: data) == "image/png",
                      let image = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw WorkspaceError.invalidAttachment }
            } else {
                guard data == Data(annotation.textRepresentation.utf8) else { throw WorkspaceError.invalidAttachment }
            }
        }
        if let computer {
            guard computer.version == 1, mediaType == ComputerCard.mediaType, linkURL == nil,
                  data.count <= 900_000, (try? JSONDecoder().decode(ComputerCard.self, from: data)) == computer else {
                throw WorkspaceError.invalidAttachment
            }
        }
        if let linkURL {
            guard MessageLink.publicWebURL(from: linkURL, preservingFragment: true) == linkURL || NoodletLink.id(in: linkURL) != nil,
                  mediaType == "application/x-webloc",
                  let bookmark = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
                  bookmark["URL"] == linkURL.absoluteString else { throw WorkspaceError.invalidAttachment }
        }
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
            createdAt: now,
            url: linkURL,
            computer: computer,
            annotation: annotation
        )
        let directory = attachmentsDirectory(conversationID: conversationID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(
            to: directory.appendingPathComponent(attachment.storedFilename),
            options: .atomic
        )
        do {
            try write(attachment, to: directory.appendingPathComponent("\(attachment.id.uuidString.lowercased()).json"))
        } catch {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(attachment.storedFilename))
            throw error
        }
        return attachment
    }

    public func importLinkAttachment(_ url: URL, into conversationID: UUID, now: Date = Date()) throws -> ConversationAttachment {
        guard let url = NoodletLink.id(in: url).map(NoodletLink.url)
            ?? MessageLink.publicWebURL(from: url, preservingFragment: true) else { throw AttachmentSource.InvalidSource() }
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
        return try importAttachment(data: data, originalFilename: NoodletLink.id(in: url) != nil ? "Noodlet.webloc" : "\(url.host ?? "Link").webloc", into: conversationID,
            mediaType: "application/x-webloc", now: now, linkURL: url)
    }

    /// Only unsent annotations can change. Check message references under the
    /// same lock as submission, including edits from an already-open preview.
    public func reviseAnnotationComment(_ expected: ConversationAttachment, comment: String, content: Data) throws -> ConversationAttachment {
        try withConversationLock(expected.conversationID) {
            guard let current = try loadAttachments(conversationID: expected.conversationID).first(where: { $0.id == expected.id }),
                  let original = current.annotation, original == expected.annotation,
                  current.storedFilename == expected.storedFilename else { throw WorkspaceError.invalidAttachment }
            guard try !loadMessages(conversationID: current.conversationID)
                .contains(where: { $0.attachments.contains(current.id) }) else { throw WorkspaceError.invalidAttachment }
            let annotation = original.replacingComment(comment)
            guard annotation.isValid else { throw WorkspaceError.invalidAttachment }
            if annotation == original { return current }
            if annotation.version == 1 {
                guard content.starts(with: Data("%PDF-".utf8)) else { throw WorkspaceError.invalidAttachment }
            } else if annotation.region == nil {
                guard content == Data(annotation.textRepresentation.utf8) else { throw WorkspaceError.invalidAttachment }
            } else {
                guard content == (try Data(contentsOf: attachmentFileURL(current))) else { throw WorkspaceError.invalidAttachment }
            }
            let updated = ConversationAttachment(id: current.id,
                conversationID: current.conversationID, originalFilename: current.originalFilename,
                storedFilename: storedAttachmentName(id: UUID(), originalFilename: current.originalFilename),
                mediaType: current.mediaType, byteCount: Int64(content.count),
                createdAt: current.createdAt, annotation: annotation)
            let file = attachmentFileURL(updated)
            try content.write(to: file, options: .atomic)
            do {
                try write(updated, to: attachmentsDirectory(conversationID: current.conversationID)
                    .appendingPathComponent("\(updated.id.uuidString.lowercased()).json"))
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            try? FileManager.default.removeItem(at: attachmentFileURL(current))
            return updated
        }
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
            if attachment.url != nil { return attachment }
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
                createdAt: attachment.createdAt,
                voice: attachment.voice,
                computer: attachment.computer,
                annotation: attachment.annotation
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
        guard attachment.url == nil, attachment.mediaType.lowercased().hasPrefix("image/") else { return nil }

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
        includingRead: Bool = false,
        preparing: (([MessengerDelivery]) throws -> Void)? = nil
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

        deliveries.sort {
            ($0.reactionChange?.createdAt ?? $0.message.createdAt) < ($1.reactionChange?.createdAt ?? $1.message.createdAt)
        }
        // Broker attachment delivery must succeed before advancing the inbox.
        try preparing?(deliveries)
        if consuming && !includingRead { try saveInbox(inbox, for: agentID) }
        return deliveries
    }

    public func participantRoster(for agentID: UUID, conversationID: UUID) throws -> MessengerRoster {
        let agents = try loadAgents()
        guard let readingAgent = agents.first(where: { $0.id == agentID }) else {
            throw WorkspaceError.missingAgent(agentID)
        }
        guard let conversation = try loadConversations().first(where: {
            $0.id == conversationID && $0.participantIDs.contains(agentID)
        }) else {
            throw WorkspaceError.missingConversation(conversationID)
        }

        let agentsByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        let messages = try loadMessages(conversationID: conversationID)
        var lastActivity: [UUID: Date] = [:]
        for message in messages {
            guard case .agent(let authorID) = message.author else { continue }
            lastActivity[authorID] = max(lastActivity[authorID] ?? .distantPast, message.createdAt)
        }

        let me = MessengerIdentity(handle: .me, agentID: agentID, displayName: readingAgent.displayName)
        let participants = conversation.participantIDs.compactMap { participantID -> MessengerParticipantStatus? in
            guard let agent = agentsByID[participantID] else { return nil }
            let identity = participantID == agentID
                ? me
                : MessengerIdentity(handle: .bot, agentID: participantID, displayName: agent.displayName)
            return MessengerParticipantStatus(
                participant: identity,
                publicDescription: agent.publicDescription,
                lastActiveAt: lastActivity[participantID]
            )
        }.sorted {
            if $0.participant.handle == .me { return true }
            if $1.participant.handle == .me { return false }
            return $0.participant.displayName.localizedCaseInsensitiveCompare(
                $1.participant.displayName
            ) == .orderedAscending
        }
        return MessengerRoster(me: me, conversation: conversation, participants: participants)
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
        let directory = storage(for: agent.id).package
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
        return try agentPackages().map { layout in
            try layout.validate()
            return try agentRecord(in: layout)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// App startup only. The CLI deliberately cannot migrate app-owned storage.
    @discardableResult
    public func migrateAgentStorage() throws -> [UUID] {
        try prepare()
        return try agentPackages().compactMap { layout in
            let agent = try agentRecord(in: layout)
            return try AgentStorageMigration.migrate(layout) ? agent.id : nil
        }
    }

    private func agentPackages() throws -> [AgentStorageLayout] {
        try FileManager.default.contentsOfDirectory(at: agentsURL, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles]).compactMap { url in
            let layout = AgentStorageLayout(package: url)
            guard AgentStorageLayout.exists(layout.configuration) else { return nil }
            try AgentStorageLayout.requireDirectory(url)
            try AgentStorageLayout.requireFile(layout.configuration)
            return layout
        }
    }

    private func agentRecord(in layout: AgentStorageLayout) throws -> AgentRecord {
        let agent = try read(AgentRecord.self, from: layout.configuration)
        guard layout.package.lastPathComponent == agent.id.uuidString.lowercased() else {
            throw AgentStorageError("The bot identifier does not match its storage folder. Restore the original UUID folder name.")
        }
        return agent
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
        storage(for: id).workspace
    }

    public func storage(for id: UUID) -> AgentStorageLayout {
        AgentStorageLayout(package: agentsURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true))
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

    private static func normalizedOptionalText(_ rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
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
        try AtomicFile.write(encoder.encode(value), to: url)
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    private func synchronizeClaudeSkillLinks(in directory: URL) throws -> [String] {
        let root = try WorkspaceMailbox(workspace: directory, path: "")
        // Preserve user redirects, without following them for privileged I/O.
        if root.contains(".claude"), root.linkDestination(".claude") != nil { return [] }
        guard let claude = try? WorkspaceMailbox(workspace: directory, path: ".claude", create: true) else { return [] }
        let destination = "../.agents/skills"
        if claude.linkDestination("skills") == destination { return [".claude/skills"] }
        if !claude.contains("skills") {
            try claude.symlink("skills", destination: destination)
            return [".claude/skills"]
        }
        guard let native = try? WorkspaceMailbox(workspace: directory, path: ".claude/skills") else { return [] }
        let shared = try WorkspaceMailbox(workspace: directory, path: ".agents/skills")
        var managedPaths: [String] = []
        for name in try shared.names().sorted() {
            let target = "../../.agents/skills/" + name
            if native.linkDestination(name) == target {
                managedPaths.append(".claude/skills/" + name)
            } else if !native.contains(name) {
                try native.symlink(name, destination: target)
                managedPaths.append(".claude/skills/" + name)
            }
        }
        return managedPaths
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

    private static func renderedAgentInstructions(backstory: String, mcpConnections: [MCPConnectionRecord] = []) -> String {
        let normalizedBackstory = backstory.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # Noodle Agent

        ## Backstory

        \(normalizedBackstory)

        \(managedInstructionsStart)
        \(managedAgentInstructions)
        \(MCPSkillWriter.index(mcpConnections))
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

    private static var managedAgentInstructions: String {
        """
        ## Noodle Runtime

        This directory is the bot's persistent workspace. The Backstory section above is this bot's user-authored instructions. Noodle manages the runtime section, Messenger core skill, and assigned MCP connection skills; unrelated skills under `.agents/skills` belong to this bot and are left untouched.

        ## Messages

        \(MessengerDocumentation.bootstrapInstructions)
        """
    }

    private static var messengerSkill: String {
        """
        ---
        name: messenger
        description: Read and reply to this bot's Noodle direct and group conversations.
        ---

        # Messenger

        \(MessengerDocumentation.skillInstructions)
        """
    }
}

private struct ConversationReadState: Codable {
    let version: Int
    let unreadConversationIDs: Set<UUID>

    init(unreadConversationIDs: Set<UUID>) {
        version = 1
        self.unreadConversationIDs = unreadConversationIDs
    }
}
