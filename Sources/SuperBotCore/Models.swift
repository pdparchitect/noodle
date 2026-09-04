import Foundation

public struct AgentRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public let createdAt: Date
    public var updatedAt: Date
    public var harnessIdentifier: String?
    public let accentSeed: Int

    public init(
        id: UUID = UUID(),
        displayName: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        harnessIdentifier: String? = nil,
        accentSeed: Int = Int.random(in: 0...5)
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.harnessIdentifier = harnessIdentifier
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

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        author: MessageAuthor,
        body: String,
        createdAt: Date = Date(),
        delivery: MessageDelivery
    ) {
        self.id = id
        self.conversationID = conversationID
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.delivery = delivery
    }
}

public struct CreatedAgentWorkspace: Sendable {
    public let agent: AgentRecord
    public let conversation: BotConversation
}

public enum WorkspaceError: LocalizedError, Equatable {
    case emptyName
    case missingAgent(UUID)
    case insufficientGroupParticipants

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a name."
        case .missingAgent:
            return "One of the selected bots no longer exists."
        case .insufficientGroupParticipants:
            return "Choose at least two bots for a group."
        }
    }
}

public struct WorkspaceRepository: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
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

    public func createAgent(named rawName: String, now: Date = Date()) throws -> CreatedAgentWorkspace {
        let name = try validatedName(rawName)
        try prepare()

        let agent = AgentRecord(displayName: name, createdAt: now, updatedAt: now)
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
        var renamed = agent
        renamed.displayName = try validatedName(rawName)
        renamed.updatedAt = now
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
        var messages = (try? read([ChatMessage].self, from: file)) ?? []
        messages.append(message)
        try write(messages, to: file)
    }

    public func updateConversation(_ conversation: BotConversation) throws {
        let file = conversationDirectory(id: conversation.id).appendingPathComponent("conversation.json")
        try write(conversation, to: file)
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
        agentsURL.appendingPathComponent(agent.id.uuidString.lowercased(), isDirectory: true)
    }

    public func conversationDirectory(id: UUID) -> URL {
        conversationsURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func createConversationFiles(_ conversation: BotConversation) throws {
        try prepare()
        let directory = conversationDirectory(id: conversation.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try write(conversation, to: directory.appendingPathComponent("conversation.json"))
        try write([ChatMessage](), to: directory.appendingPathComponent("messages.json"))
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
}
