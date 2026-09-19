import Foundation

/// Private fields share agent.json with the public record, but are never added
/// to AgentRecord or exposed by profiles and participant lists.
struct AgentConfiguration: Codable {
    var agent: AgentRecord
    var backstory: String?
    var folders: [AgentFolder] = []
    /// Nil selects the system profile: the harness's login in the user's home.
    var harnessProfile: UUID?

    init(agent: AgentRecord, backstory: String) {
        self.agent = agent
        self.backstory = backstory
    }

    private enum CodingKeys: String, CodingKey { case backstory, folders, harnessProfile }

    init(from decoder: Decoder) throws {
        agent = try AgentRecord(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Absence identifies an unmigrated package. Null and other invalid
        // values are corruption, not a request to reimport generated Markdown.
        backstory = values.contains(.backstory) ? try values.decode(String.self, forKey: .backstory) : nil
        folders = try values.decodeIfPresent([AgentFolder].self, forKey: .folders) ?? []
        harnessProfile = try values.decodeIfPresent(UUID.self, forKey: .harnessProfile)
    }

    func encode(to encoder: Encoder) throws {
        try agent.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(backstory, forKey: .backstory)
        if !folders.isEmpty { try values.encode(folders, forKey: .folders) }
        try values.encodeIfPresent(harnessProfile, forKey: .harnessProfile)
    }

    func requireBackstory() throws -> String {
        guard let backstory else {
            throw AgentStorageError("This bot needs a backstory migration. Run Noodle 0.14.0 to move its backstory into agent.json before starting it.")
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
