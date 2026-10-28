import CryptoKit
import Foundation

/// A separate harness login owned by Noodle. A bot without a profile uses its
/// harness's default profile: Noodle's own login too, never the one the person's
/// CLI keeps in their home, so neither spends the refresh tokens the other holds.
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
            .filter { id in !HarnessProvider.allCases.contains { Self.defaultID($0) == id } }
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
        do { try populate(folder, with: profile) } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return profile
    }

    /// The same for every copy of Noodle, so the app and the Agent Host find the one folder.
    public static func defaultID(_ provider: HarnessProvider) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("noodle.default-profile.\(provider.rawValue)".utf8)).prefix(16))
        bytes[6] = bytes[6] & 0x0f | 0x50
        bytes[8] = bytes[8] & 0x3f | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The record of a harness's default profile, whether or not its folder is made yet.
    public static func defaultRecord(_ provider: HarnessProvider) -> HarnessProfile {
        HarnessProfile(id: defaultID(provider), provider: provider, displayName: "Default", createdAt: Date(timeIntervalSince1970: 0))
    }

    /// The login of a bot that chose no profile, made the first time it is needed.
    public func defaultProfile(_ provider: HarnessProvider) throws -> HarnessProfile {
        guard provider.supportsProfiles else {
            throw HarnessSetupError("\(provider.displayName) does not support separate profiles.")
        }
        let id = Self.defaultID(provider)
        if AgentStorageLayout.exists(folder(id)) { return try validated(id) }
        let profile = Self.defaultRecord(provider)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AgentStorageLayout.requireDirectory(directory)
        // Made aside and moved in whole, so the app and the Agent Host can both make it at once.
        let staging = directory.appendingPathComponent(".\(id.uuidString.lowercased())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        try populate(staging, with: profile)
        do { try FileManager.default.moveItem(at: staging, to: folder(id)) }
        catch { guard AgentStorageLayout.exists(folder(id)) else { throw error } }
        return try validated(id)
    }

    private func populate(_ folder: URL, with profile: HarnessProfile) throws {
        try populateHome(folder.appendingPathComponent("home", isDirectory: true), provider: profile.provider)
        try save(profile, in: folder)
    }

    /// A login home nobody has signed in to yet.
    private func populateHome(_ home: URL, provider: HarnessProvider) throws {
        let account = home.appendingPathComponent(Self.accountPath(provider), isDirectory: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if provider == .codex {
            // Keep the login inside this folder, never in a shared Keychain item.
            try AtomicFile.write(Data("cli_auth_credentials_store = \"file\"\n".utf8),
                                 to: account.appendingPathComponent("config.toml"))
        }
    }

    public func rename(_ profile: HarnessProfile, to rawName: String) throws -> HarnessProfile {
        var renamed = try self.profile(profile.id)
        renamed.displayName = try ConversationName.validated(rawName)
        try save(renamed)
        return renamed
    }

    /// Deletes the profile with the copy of its login its bots shared.
    public func delete(_ profile: HarnessProfile) throws {
        try FileManager.default.removeItem(at: try requireFolder(profile.id))
        RestrictedHarnessStorage.removeSharedLogin(provider: profile.provider, root: directory.deletingLastPathComponent(),
                                                   loginHome: loginHome(profile))
    }

    /// Signs the profile out of this app: its login home starts again empty, the copy its
    /// bots shared goes, and so does the Keychain item Claude Code keeps for its folder.
    /// The person's own login, in their home and the CLI's own Keychain items, and every
    /// other profile are left alone. A default profile that was never made has no login.
    public func signOut(_ profile: HarnessProfile,
                        deleteSecret: (String, String) throws -> Void = RestrictedHarnessStorage.deleteSecret) throws {
        guard AgentStorageLayout.exists(folder(profile.id)) else { return }
        let home = loginHome(profile)
        // Made aside and swapped in whole, so the Agent Host never finds the folder without a home.
        let fresh = try requireFolder(profile.id).appendingPathComponent(".home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fresh) }
        try populateHome(fresh, provider: profile.provider)
        if AgentStorageLayout.exists(home) {
            guard renamex_np(fresh.path, home.path, UInt32(RENAME_SWAP)) == 0 else {
                throw HarnessSetupError("Could not sign out: \(String(cString: strerror(errno))).")
            }
        } else {
            try FileManager.default.moveItem(at: fresh, to: home)
        }
        RestrictedHarnessStorage.removeSharedLogin(provider: profile.provider, root: directory.deletingLastPathComponent(),
                                                   loginHome: home)
        if let item = loginItem(profile) { try deleteSecret(item, NSUserName()) }
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
        case .claudeCode: ["CLAUDE_CONFIG_DIR": accountHome(profile).path]
        // FX has no setting for its folder either, and otherwise keeps logins in the Keychain.
        case .fx: ["HOME": loginHome(profile).path, "FX_DISABLE_KEYCHAIN": "1"]
        // The login is in the data folder, but the background service it talks
        // to is found through the state folder, so every folder moves.
        case .openCode:
            ["XDG_CONFIG_HOME": loginHome(profile).appendingPathComponent(".config", isDirectory: true).path,
             "XDG_DATA_HOME": loginHome(profile).appendingPathComponent(".local/share", isDirectory: true).path,
             "XDG_STATE_HOME": loginHome(profile).appendingPathComponent(".local/state", isDirectory: true).path,
             "XDG_CACHE_HOME": loginHome(profile).appendingPathComponent(".cache", isDirectory: true).path]
        default: [:]
        }
    }

    /// `base` with this profile's folder taking the place of the user's.
    public func environment(_ profile: HarnessProfile, over base: [String: String]) -> [String: String] {
        base.merging(environment(profile)) { _, profile in profile }
    }

    /// Where a restricted bot's copy of this profile's login comes from. Claude
    /// Code keeps it in a Keychain item named after the profile's folder; every
    /// other harness keeps it in files, and the user's own items belong to System.
    public func loginSecret(_ profile: HarnessProfile,
                            read: @escaping (String, String) throws -> Data? = RestrictedHarnessStorage.readSecret)
        -> (String, String) throws -> Data? {
        guard let item = loginItem(profile) else { return { _, _ in nil } }
        return { service, account in service == "Claude Code-credentials" ? try read(item, account) : nil }
    }

    /// Where a bot's refresh of this profile's login goes back to.
    public func loginWriter(_ profile: HarnessProfile,
                            write: @escaping (String, String, Data) throws -> Void = RestrictedHarnessStorage.writeSecret)
        -> ((String, String, Data) throws -> Void)? {
        guard let item = loginItem(profile) else { return nil }
        return { service, account, data in if service == "Claude Code-credentials" { try write(item, account, data) } }
    }

    private func loginItem(_ profile: HarnessProfile) -> String? {
        guard profile.provider == .claudeCode else { return nil }
        let folder = accountHome(profile).path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(folder.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + digest.prefix(8)
    }

    /// Resolves the profile a bot selected in its agent.json, or its harness's
    /// default profile when it chose none. Nil only for a harness without a
    /// login. A missing or redirected profile is an error: a bot must never start
    /// under a different account of its harness by accident. A profile belongs to
    /// its own harness. Without an explicit temporary runtime choice, starting
    /// on another harness uses that harness's Default profile.
    public func selected(workspace: URL, provider: HarnessProvider) throws -> HarnessProfile? {
        guard provider.supportsProfiles else { return nil }
        guard let id = try AgentConfiguration.load(from: AgentStorageLayout(workspace: workspace)).harnessProfile else {
            return try defaultProfile(provider)
        }
        guard let profile = try? validated(id) else {
            throw HarnessSetupError("This bot's \(provider.displayName) profile is unavailable. Choose another profile in the bot's settings, then retry startup.")
        }
        return profile.provider == provider ? profile : try defaultProfile(provider)
    }

    /// A temporary runtime choice must name an existing profile of this harness. It never
    /// edits the bot's saved choice and cannot silently use another account if it disappears.
    public func selected(workspace: URL, provider: HarnessProvider, override: UUID?) throws -> HarnessProfile? {
        guard let id = override else { return try selected(workspace: workspace, provider: provider) }
        let profile = try validated(id)
        guard profile.provider == provider else { throw HarnessSetupError("The selected profile belongs to another harness.") }
        return profile
    }

    /// A profile whose folders are in place and not redirected elsewhere.
    public func validated(_ id: UUID) throws -> HarnessProfile {
        if let provider = HarnessProvider.allCases.first(where: { Self.defaultID($0) == id }),
           !AgentStorageLayout.exists(folder(id)) { return try defaultProfile(provider) }
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

    /// OpenCode keeps a profile's login as rows in the profile's own database.
    public func openCodeSignedIn(_ profile: HarnessProfile) throws -> Bool {
        try !OpenCodeStorage.credentials(home: loginHome(profile)).isEmpty
    }

    private static func accountPath(_ provider: HarnessProvider) -> String {
        switch provider {
        case .grokBuild: ".grok"
        case .muse: ".config/muse"
        case .antigravity: ".gemini/antigravity-cli"
        case .claudeCode: ".claude"
        case .fx: ".fx"
        case .openCode: ".local/share/opencode"
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

    private func save(_ profile: HarnessProfile, in folder: URL? = nil) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(encoder.encode(profile), to: (folder ?? self.folder(profile.id)).appendingPathComponent("profile.json"))
    }
}

/// Runs a harness where it cannot open pages: in device-code sign-ins and in the
/// Agent Host's own checks, model lists and renewals, which nobody asked a page of.
/// Denying lsopen is not enough: Grok Build has CoreServicesUIAgent open the page
/// for it, so neither service may be reached. A process already in the app sandbox
/// cannot apply another, so it runs the harness as it is. So does a missing harness,
/// whose launch must still fail rather than end as sandbox-exec's exit status.
public enum BrowserlessLaunch {
    public static func wrap(_ executable: URL, arguments: [String]) -> (executable: URL, arguments: [String]) {
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return (executable, arguments) }
        let profile = #"(version 1)(allow default)(deny lsopen)"#
            + #"(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd") (global-name "com.apple.coreservices.uiagent"))"#
        return (URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-p", profile, executable.path] + arguments)
    }

    public static func configure(_ process: Process, executable: URL, arguments: [String]) {
        let launch = wrap(executable, arguments: arguments)
        process.executableURL = launch.executable
        process.arguments = launch.arguments
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

    /// Grok Build and Muse Code open the browser by themselves as soon as their
    /// sign-in starts. Kept away from the browser, they only print the page,
    /// which Noodle shows with the code for the person to open when ready.
    /// Claude Code has no code to show, so its sign-in still opens the browser.
    public static func launch(_ provider: HarnessProvider, executable: URL,
                              arguments: [String]) -> (executable: URL, arguments: [String]) {
        guard self.arguments(provider) != nil else { return (executable, arguments) }
        return BrowserlessLaunch.wrap(executable, arguments: arguments)
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
