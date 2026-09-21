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

    /// What points the harness at this profile instead of the user's home.
    public func environment(_ profile: HarnessProfile) -> [String: String] {
        switch profile.provider {
        case .codex: ["CODEX_HOME": accountHome(profile).path]
        case .grokBuild: ["GROK_HOME": accountHome(profile).path]
        case .muse:
            // Muse otherwise keeps every login in one Keychain item per user.
            ["XDG_CONFIG_HOME": loginHome(profile).appendingPathComponent(".config", isDirectory: true).path,
             "TBH_CREDENTIAL_BACKEND": "file"]
        // Antigravity has no setting for its folder. A different home also puts the
        // user's Keychain out of reach, so the CLI keeps this login in a file here.
        case .antigravity: ["HOME": loginHome(profile).path]
        default: [:]
        }
    }

    /// Resolves the profile a bot selected in its agent.json. Nil means the
    /// system profile. A missing, redirected, or mismatched profile is an
    /// error: a bot must never start under a different account by accident.
    public func selected(workspace: URL, provider: HarnessProvider) throws -> HarnessProfile? {
        guard let id = try AgentConfiguration.load(from: AgentStorageLayout(workspace: workspace)).harnessProfile else { return nil }
        guard let profile = try? validated(id), profile.provider == provider else {
            throw HarnessSetupError("This bot's \(provider.displayName) profile is unavailable. Choose another profile in the bot's settings, then retry startup.")
        }
        return profile
    }

    /// A profile whose folders are in place and not redirected elsewhere.
    public func validated(_ id: UUID) throws -> HarnessProfile {
        let profile = try profile(id)
        guard profile.provider.supportsProfiles else {
            throw HarnessSetupError("\(profile.provider.displayName) does not support separate profiles.")
        }
        var folder = accountHome(profile)
        while folder.path.hasPrefix(loginHome(profile).path) {
            try AgentStorageLayout.requireDirectory(folder)
            folder.deleteLastPathComponent()
        }
        return profile
    }

    /// True when the login sits in the user's shared Keychain item, not in this
    /// folder, so it is neither separate nor readable for a restricted bot.
    public func loginIsShared(_ profile: HarnessProfile) -> Bool {
        guard profile.provider == .muse,
              let files = try? WorkspaceMailbox(workspace: loginHome(profile), path: Self.accountPath(.muse)),
              files.contains("auth.json"), let data = try? files.read("auth.json", limit: 1_048_576),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = (root["providers"] as? [String: Any])?["meta"] as? [String: Any] else { return false }
        return meta["storage"] as? String == "keychain"
    }

    private static func accountPath(_ provider: HarnessProvider) -> String {
        switch provider {
        case .grokBuild: ".grok"
        case .muse: ".config/muse"
        case .antigravity: ".gemini/antigravity-cli"
        default: ".codex"
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

/// Device-code sign-in for a profile, run by the Agent Host with the profile's
/// environment. Only the vendor's own sign-in page is ever offered to the user.
public enum HarnessProfileLogin {
    public static func arguments(_ provider: HarnessProvider) -> [String]? {
        switch provider {
        case .grokBuild: ["login", "--device-auth"]
        case .muse: ["login"]
        default: nil
        }
    }

    /// A streaming read can end midway through a line; only whole lines count.
    public static func challenge(provider: HarnessProvider, text: String) -> HarnessSignInChallenge? {
        for line in text.components(separatedBy: .newlines).dropLast() {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix("https://"), let components = URLComponents(string: candidate) else { continue }
            let name = provider == .grokBuild ? "user_code" : "code"
            guard let code = components.queryItems?.first(where: { $0.name == name })?.value,
                  let challenge = challenge(provider: provider, url: candidate, code: code) else { continue }
            return challenge
        }
        return nil
    }

    public static func challenge(provider: HarnessProvider, url rawURL: String, code: String) -> HarnessSignInChallenge? {
        let page: (host: String, path: String)
        switch provider {
        case .grokBuild: page = ("accounts.x.ai", "/oauth2/device")
        case .muse: page = ("auth.meta.com", "/oauth/device")
        default: return nil
        }
        // Foundation drops a trailing slash from the path on some releases only.
        guard let url = URL(string: rawURL), url.scheme == "https", url.host == page.host,
              [page.path, page.path + "/"].contains(url.path), url.user == nil, url.password == nil, url.port == nil,
              (4...64).contains(code.count),
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return HarnessSignInChallenge(url: url, code: code)
    }
}
