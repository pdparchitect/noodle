import Foundation
import NoodleCore

/// The server's logins: each harness's own and each of its profiles', kept as files in the Hub's harness
/// profiles inside the data folder. `noodled login` signs one in with the harness's own sign-in; a bot
/// works on its own copy of the one its plan lends, and refreshed logins go back to be shared.
public struct ServerLogins: Sendable {
    public let configuration: ServerConfiguration
    public let profiles: HarnessProfileStore

    public init(configuration: ServerConfiguration, profiles: HarnessProfileStore) {
        self.configuration = configuration
        self.profiles = profiles
    }

    /// The profile holding a login: the harness's own, or its profile of that name in the file, made the first time.
    public func login(_ provider: HarnessProvider, profile name: String?) throws -> HarnessProfile {
        if let existing = try existing(provider, profile: name) { return existing }
        guard let name else { return try profiles.defaultProfile(provider) }
        return try profiles.create(provider: provider, named: name)
    }

    /// The profile if it is there already; nothing is made, so a check run by another account leaves no files.
    private func existing(_ provider: HarnessProvider, profile name: String?) throws -> HarnessProfile? {
        guard let name else { return try? profiles.validated(HarnessProfileStore.defaultID(provider)) }
        guard configuration.profiles[provider]?.contains(name) == true else {
            throw ServerConfigurationError("\(provider.displayName) has no profile called \(name); add it under harnesses.\(provider.rawValue).profiles first.")
        }
        return try profiles.load().first { $0.provider == provider && $0.displayName == name }
    }

    /// What says nobody has signed in to a login, and how to.
    private func unsigned(_ provider: HarnessProvider, profile name: String?) -> String {
        let login = name.map { "\(provider.displayName)'s \($0) profile" } ?? provider.displayName
        let command = "noodled login \(provider.rawValue)" + (name.map { " --profile \($0)" } ?? "")
        return "Nobody has signed in to \(login) on this server. Run: \(command)"
    }

    private func name(of login: HarnessProfile) -> String? {
        login.id == HarnessProfileStore.defaultID(login.provider) ? nil : login.displayName
    }

    public func isSignedIn(_ login: HarnessProfile) -> Bool {
        let file = login.provider == .claudeCode ? ".credentials.json" : "auth.json"
        return FileManager.default.fileExists(atPath: profiles.accountHome(login).appendingPathComponent(file).path)
    }

    /// Every login in the file nobody has signed in to yet, each with how to.
    public func unsigned() -> [String] {
        configuration.harnesses.keys.filter(ServerConfiguration.supported.contains).sorted { $0.rawValue < $1.rawValue }.flatMap { provider in
            ([nil] + (configuration.profiles[provider] ?? []).map(Optional.some)).compactMap { name -> String? in
                guard let login = try? existing(provider, profile: name), isSignedIn(login) else { return unsigned(provider, profile: name) }
                return nil
            }
        }
    }

    /// Gives the bot at `workspace` its copy of `login`, or the latest one if it has one already.
    public func prepare(_ provider: HarnessProvider, login: HarnessProfile, workspace: URL) throws {
        guard isSignedIn(login) else { throw HarnessSetupError(unsigned(provider, profile: name(of: login))) }
        try RestrictedHarnessStorage.prepare(provider: provider, workspace: workspace, loginHome: profiles.loginHome(login),
                                             secret: { _, _ in nil })
    }

    /// What a harness working on `login` itself runs with, such as to sign in or renew it: the login's
    /// folder in place of a home.
    public func environment(_ login: HarnessProfile) -> [String: String] {
        profiles.environment(login, over: ["HOME": profiles.loginHome(login).path, "PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"])
    }

    /// The harness's own sign-in for `login`, kept to the login's folder, so nothing lands in the home of
    /// the account running it.
    public func signIn(_ provider: HarnessProvider, login: HarnessProfile) throws -> (arguments: [String], environment: [String: String]) {
        let account = profiles.accountHome(login)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let environment = environment(login)
        switch provider {
        case .claudeCode:
            return (["auth", "login", "--claudeai"], environment)
        case .codex:
            // A server has no keyring for Codex to keep the login in.
            let settings = account.appendingPathComponent("config.toml")
            let current = (try? String(contentsOf: settings, encoding: .utf8)) ?? ""
            if !current.contains("cli_auth_credentials_store") {
                try Data(("cli_auth_credentials_store = \"file\"\n" + current).utf8).write(to: settings)
            }
            return (["login", "--device-auth"], environment)
        default:
            throw HarnessSetupError("noodled signs in only to Claude Code and Codex.")
        }
    }
}
