import Darwin
import Foundation

public struct AgentRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public let createdAt: Date
    public var updatedAt: Date
    public var harnessIdentifier: String?
    public var modelIdentifier: String?
    public var reasoningEffort: String?
    public let accentSeed: Int

    public init(
        id: UUID = UUID(),
        displayName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        harnessIdentifier: String? = nil,
        modelIdentifier: String? = nil,
        reasoningEffort: String? = nil,
        accentSeed: Int = Int.random(in: 0...5)
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.harnessIdentifier = harnessIdentifier
        self.modelIdentifier = modelIdentifier
        self.reasoningEffort = reasoningEffort
        self.accentSeed = accentSeed
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

    public init(conversationOffsets: [String: Int] = [:]) {
        self.conversationOffsets = conversationOffsets
    }
}

public struct MessengerDelivery: Codable, Hashable, Sendable {
    public let conversation: BotConversation
    public let message: ChatMessage
    public let attachments: [ConversationAttachment]

    public init(
        conversation: BotConversation,
        message: ChatMessage,
        attachments: [ConversationAttachment]
    ) {
        self.conversation = conversation
        self.message = message
        self.attachments = attachments
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

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a name."
        case .missingAgent:
            return "One of the selected bots no longer exists."
        case .missingConversation:
            return "The selected conversation no longer exists."
        case .insufficientGroupParticipants:
            return "Choose at least two bots for a group."
        case .invalidAgentDirectory:
            return "The Messenger command is not inside a valid bot workspace."
        case .invalidAttachment:
            return "The selected attachment could not be imported."
        }
    }
}

public struct WorkspaceRepository: Sendable {
    public let rootURL: URL
    public let launcherExecutableURL: URL?

    public static let managedSkillVersion = 4

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

    public func prepare() throws {
        try FileManager.default.createDirectory(at: agentsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conversationsURL, withIntermediateDirectories: true)
    }

    public func createAgent(
        named rawName: String,
        harnessIdentifier: String? = nil,
        modelIdentifier: String? = nil,
        reasoningEffort: String? = nil,
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
            reasoningEffort: reasoningEffort
        )
        let agentDirectory = directory(for: agent)
        try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: false)
        try write(agent, to: agentDirectory.appendingPathComponent("agent.json"))
        try "# Instructions\n\n".write(
            to: agentDirectory.appendingPathComponent("instructions.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# Memory\n\n".write(
            to: agentDirectory.appendingPathComponent("memory.md"),
            atomically: true,
            encoding: .utf8
        )
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
            now: now
        )
    }

    public func updateAgent(
        _ agent: AgentRecord,
        displayName rawName: String,
        harnessIdentifier: String?,
        modelIdentifier: String?,
        reasoningEffort: String?,
        now: Date = Date()
    ) throws -> AgentRecord {
        var renamed = agent
        renamed.displayName = try validatedName(rawName)
        renamed.updatedAt = now
        renamed.harnessIdentifier = harnessIdentifier
        renamed.modelIdentifier = modelIdentifier
        renamed.reasoningEffort = reasoningEffort
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
        guard uniqueIDs.count >= 2 else { throw WorkspaceError.insufficientGroupParticipants }

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

        let agentsFile = directory.appendingPathComponent("AGENTS.md")
        try Self.agentsInstructions.write(to: agentsFile, atomically: true, encoding: .utf8)

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
        let attachment = ConversationAttachment(
            id: attachmentID,
            conversationID: conversationID,
            originalFilename: sourceURL.lastPathComponent,
            storedFilename: storedAttachmentName(id: attachmentID, originalFilename: sourceURL.lastPathComponent),
            mediaType: mediaType,
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

    public func loadAttachments(conversationID: UUID) throws -> [ConversationAttachment] {
        let directory = attachmentsDirectory(conversationID: conversationID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { try read(ConversationAttachment.self, from: $0) }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func attachmentFileURL(_ attachment: ConversationAttachment) -> URL {
        attachmentsDirectory(conversationID: attachment.conversationID)
            .appendingPathComponent(attachment.storedFilename)
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

    public func latestMessages(for agentID: UUID, consuming: Bool = true) throws -> [MessengerDelivery] {
        guard try loadAgents().contains(where: { $0.id == agentID }) else {
            throw WorkspaceError.missingAgent(agentID)
        }
        let conversations = try loadConversations().filter { $0.participantIDs.contains(agentID) }
        let inboxFile = directory(forAgentID: agentID).appendingPathComponent(".agents/inbox.json")
        var inbox = (try? read(AgentInbox.self, from: inboxFile)) ?? AgentInbox()
        var deliveries: [MessengerDelivery] = []

        for conversation in conversations {
            let messages = try loadMessages(conversationID: conversation.id)
            let key = conversation.id.uuidString.lowercased()
            let offset = min(inbox.conversationOffsets[key, default: 0], messages.count)
            let attachments = try loadAttachments(conversationID: conversation.id)
            let byID = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })

            for message in messages.dropFirst(offset) {
                if case .agent(let authorID) = message.author, authorID == agentID { continue }
                deliveries.append(
                    MessengerDelivery(
                        conversation: conversation,
                        message: message,
                        attachments: message.attachments.compactMap { byID[$0] }
                    )
                )
            }
            if consuming { inbox.conversationOffsets[key] = messages.count }
        }

        if consuming { try write(inbox, to: inboxFile) }
        return deliveries.sorted { $0.message.createdAt < $1.message.createdAt }
    }

    public func sendAgentMessage(
        agentID: UUID,
        conversationID: UUID,
        body: String,
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
        let message = ChatMessage(
            conversationID: conversationID,
            author: .agent(agentID),
            body: name,
            createdAt: now,
            delivery: .delivered
        )
        try append(message)
        var updated = conversation
        updated.updatedAt = now
        try updateConversation(updated)
        return message
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

    private static let agentsInstructions = """
    # SuperBot Agent

    This directory is the bot's persistent workspace. SuperBot manages the Messenger core skill; other skills under `.agents/skills` belong to this bot and are left untouched.

    ## Messages

    SuperBot notifications only mean that this inbox may have changed. They never contain the user's message. In Codex, immediately invoke the harness-provided tool through the programmatic bridge and forward its complete return value: `const deliveries = await tools.superbot_get_latest({}); text(deliveries);`. Inspect every JSON delivery and respond when appropriate with `const sent = await tools.superbot_send({conversationID: "<uuid>", body: "<reply>"}); text(sent);`. SuperBot tools return their payload directly; never inspect `result.content`. Never reply to the notification text itself. If there are no deliveries, finish quietly.

    Read new direct and group messages:

    ```sh
    ./.agents/skills/messenger/messenger --get-latest
    ```

    Reply to a conversation:

    ```sh
    ./.agents/skills/messenger/messenger --send --conversation <conversation-uuid> --body "Your response"
    ```
    """

    private static let messengerSkill = """
    ---
    name: messenger
    description: Read and reply to this bot's SuperBot direct and group conversations.
    ---

    # Messenger

    In Codex, invoke `superbot_get_latest` through the programmatic bridge and forward its complete return value with `text(deliveries)`: `const deliveries = await tools.superbot_get_latest({}); text(deliveries);`. Each delivery includes the conversation, message, and linked attachment metadata. Reply with `const sent = await tools.superbot_send({conversationID: "<uuid>", body: "<reply>"}); text(sent);`. SuperBot tools return their payload directly; never inspect `result.content`.

    The bundled command-line helper remains available to harnesses that use shell commands:

    `./.agents/skills/messenger/messenger --get-latest`

    Reply with `./.agents/skills/messenger/messenger --send --conversation <uuid> --body <text>`. The executable identifies this bot from the opaque workspace path. Do not edit SuperBot's conversation JSON directly.
    """
}
