import Darwin
import AppletBridge
import Foundation

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

    public var harnessProfiles: HarnessProfileStore { HarnessProfileStore(root: rootURL) }
    public var managedHarnesses: ManagedHarnessStore { ManagedHarnessStore(root: rootURL) }

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

    static func normalizedOptionalText(_ rawValue: String?) -> String? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    func loadChildren<Value: Decodable>(
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

    func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(encoder.encode(value), to: url)
    }

    func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    func withConversationLock<Value>(_ id: UUID, operation: () throws -> Value) throws -> Value {
        let lockURL = conversationDirectory(id: id).appendingPathComponent(".messages.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
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
