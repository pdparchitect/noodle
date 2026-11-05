import Foundation

/// The person a bot on Noodle Hub belongs to, named in its agent.json so Noodle Applet can list
/// the bot's noodlets under them.
public struct AgentOwner: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// Private fields share agent.json with the public record, but are never added
/// to AgentRecord or exposed by profiles and participant lists.
struct AgentConfiguration: Codable {
    var agent: AgentRecord
    var backstory: String?
    var folders: [AgentFolder] = []
    /// What the bot's active groups share, copied from them on every workspace
    /// synchronization so Agent Host reads this file alone.
    var groupFolders: [AgentFolder] = []
    /// Nil selects the harness's default profile, Noodle's own login for it.
    var harnessProfile: UUID?
    /// Only on Noodle Hub; its bots cannot change it, since only their workspace is theirs.
    var owner: AgentOwner?
    /// The harness voice the bot speaks with on calls.
    var voice: String?
    /// How many tokens the bot may use before it waits; nil for any number.
    var budget: BotBudget?

    init(agent: AgentRecord, backstory: String) {
        self.agent = agent
        self.backstory = backstory
    }

    private enum CodingKeys: String, CodingKey { case backstory, folders, groupFolders, harnessProfile, owner, voice, budget }

    init(from decoder: Decoder) throws {
        agent = try AgentRecord(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Absence identifies an unmigrated package. Null and other invalid
        // values are corruption, not a request to reimport generated Markdown.
        backstory = values.contains(.backstory) ? try values.decode(String.self, forKey: .backstory) : nil
        folders = try values.decodeIfPresent([AgentFolder].self, forKey: .folders) ?? []
        groupFolders = try values.decodeIfPresent([AgentFolder].self, forKey: .groupFolders) ?? []
        harnessProfile = try values.decodeIfPresent(UUID.self, forKey: .harnessProfile)
        owner = try values.decodeIfPresent(AgentOwner.self, forKey: .owner)
        voice = try values.decodeIfPresent(String.self, forKey: .voice)
        budget = try values.decodeIfPresent(BotBudget.self, forKey: .budget)
    }

    func encode(to encoder: Encoder) throws {
        try agent.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(backstory, forKey: .backstory)
        if !folders.isEmpty { try values.encode(folders, forKey: .folders) }
        if !groupFolders.isEmpty { try values.encode(groupFolders, forKey: .groupFolders) }
        try values.encodeIfPresent(harnessProfile, forKey: .harnessProfile)
        try values.encodeIfPresent(owner, forKey: .owner)
        try values.encodeIfPresent(voice, forKey: .voice)
        try values.encodeIfPresent(budget, forKey: .budget)
    }

    func requireBackstory() throws -> String {
        guard let backstory else {
            throw AgentStorageError.madeBefore("0.14.0")
        }
        return backstory
    }

    static func load(from layout: AgentStorageLayout) throws -> Self {
        try AgentStorageLayout.requireDirectory(layout.package)
        let files = try WorkspaceMailbox(workspace: layout.package, path: "")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let configuration = try decoder.decode(Self.self, from: files.read("agent.json", limit: 32 * 1_048_576))
        guard layout.package.lastPathComponent == configuration.agent.id.uuidString.lowercased() else {
            throw AgentStorageError("The bot identifier does not match its storage folder. Restore the original UUID folder name.")
        }
        return configuration
    }

    func save(to layout: AgentStorageLayout) throws {
        _ = try requireBackstory()
        try AgentStorageLayout.requireDirectory(layout.package)
        let files = try WorkspaceMailbox(workspace: layout.package, path: "")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try files.writeData(encoder.encode(self), named: "agent.json")
    }
}

extension AgentStorageLayout {
    /// The bot's name from its agent.json, which Agent Host puts in its audit log.
    public var displayName: String? { try? AgentConfiguration.load(from: self).agent.displayName }
}
