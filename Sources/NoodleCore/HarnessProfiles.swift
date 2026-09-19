import Foundation

/// A separate harness login owned by Noodle. A bot without a profile uses the
/// system profile: the harness's own configuration in the user's home.
public struct HarnessProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let provider: HarnessProvider
    public var displayName: String
    public let createdAt: Date

    public init(id: UUID = UUID(), provider: HarnessProvider, displayName: String, createdAt: Date = Date()) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

/// Each profile is a folder holding its record and a private login home. The
/// login home mirrors the layout of the user's home, so the same seeding code
/// reads either one.
public struct HarnessProfileStore: Sendable {
    public static let directoryName = "HarnessProfiles"
    public let directory: URL

    /// `root` is Noodle's storage root, beside Agents and Conversations.
    public init(root: URL) {
        directory = AgentStorageLayout.canonicalURL(root).appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public func load() throws -> [HarnessProfile] {
        guard AgentStorageLayout.exists(directory) else { return [] }
        try AgentStorageLayout.requireDirectory(directory)
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .compactMap(UUID.init(uuidString:))
            .compactMap { try? profile($0) }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public func profile(_ id: UUID) throws -> HarnessProfile {
        let folder = try requireFolder(id)
        let files = try WorkspaceMailbox(workspace: folder, path: "")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(HarnessProfile.self, from: files.read("profile.json", limit: 65_536))
        guard profile.id == id else { throw HarnessSetupError("The harness profile does not match its storage folder.") }
        return profile
    }

    public func create(provider: HarnessProvider, named rawName: String, now: Date = Date()) throws -> HarnessProfile {
        guard provider.supportsProfiles else {
            throw HarnessSetupError("\(provider.displayName) does not support separate profiles.")
        }
        // Whole seconds, as stored, so the returned record equals a later load.
        let profile = HarnessProfile(provider: provider, displayName: try ConversationName.validated(rawName),
                                     createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AgentStorageLayout.requireDirectory(directory)
        let folder = folder(profile.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            let account = accountHome(profile)
            try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if provider == .codex {
                // Keep the login inside this folder, never in a shared Keychain item.
                try AtomicFile.write(Data("cli_auth_credentials_store = \"file\"\n".utf8),
                                     to: account.appendingPathComponent("config.toml"))
            }
            try save(profile)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return profile
    }

    public func rename(_ profile: HarnessProfile, to rawName: String) throws -> HarnessProfile {
        var renamed = try self.profile(profile.id)
        renamed.displayName = try ConversationName.validated(rawName)
        try save(renamed)
        return renamed
    }

    public func delete(_ profile: HarnessProfile) throws {
        try FileManager.default.removeItem(at: try requireFolder(profile.id))
    }

    /// The stand-in for the user's home when reading this profile's login.
    public func loginHome(_ profile: HarnessProfile) -> URL {
        folder(profile.id).appendingPathComponent("home", isDirectory: true)
    }

    /// The harness's own configuration directory, such as CODEX_HOME.
    public func accountHome(_ profile: HarnessProfile) -> URL {
        loginHome(profile).appendingPathComponent(Self.accountPath(profile.provider), isDirectory: true)
    }

    /// Resolves the profile a bot selected in its agent.json. Nil means the
    /// system profile. A missing, redirected, or mismatched profile is an
    /// error: a bot must never start under a different account by accident.
    public func selected(workspace: URL, provider: HarnessProvider) throws -> HarnessProfile? {
        guard let id = try AgentConfiguration.load(from: AgentStorageLayout(workspace: workspace)).harnessProfile else { return nil }
        guard provider.supportsProfiles, let profile = try? profile(id), profile.provider == provider else {
            throw HarnessSetupError("This bot's \(provider.displayName) profile is unavailable. Choose another profile in the bot's settings, then retry startup.")
        }
        try AgentStorageLayout.requireDirectory(loginHome(profile))
        try AgentStorageLayout.requireDirectory(accountHome(profile))
        return profile
    }

    private static func accountPath(_ provider: HarnessProvider) -> String {
        switch provider {
        case .codex: ".codex"
        default: ".\(provider.rawValue)"
        }
    }

    private func folder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func requireFolder(_ id: UUID) throws -> URL {
        try AgentStorageLayout.requireDirectory(directory)
        let folder = folder(id)
        try AgentStorageLayout.requireDirectory(folder)
        return folder
    }

    private func save(_ profile: HarnessProfile) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(encoder.encode(profile), to: folder(profile.id).appendingPathComponent("profile.json"))
    }
}
