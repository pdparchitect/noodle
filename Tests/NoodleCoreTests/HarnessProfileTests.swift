import CryptoKit
import XCTest
@testable import NoodleCore

final class HarnessProfileTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!
    private var store: HarnessProfileStore { repository.harnessProfiles }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-profiles-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent("Noodle", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    func testProfilesKeepTheirLoginInsideTheirOwnFolder() throws {
        XCTAssertEqual(try store.load(), [])
        let work = try store.create(provider: .codex, named: "  Work  ", now: Date(timeIntervalSince1970: 1))
        let personal = try store.create(provider: .codex, named: "Personal", now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(try store.load().map(\.displayName), ["Work", "Personal"])
        XCTAssertEqual(store.accountHome(work).path,
            root.appendingPathComponent("HarnessProfiles/\(work.id.uuidString.lowercased())/home/.codex").path)
        XCTAssertEqual(try String(contentsOf: store.accountHome(work).appendingPathComponent("config.toml"), encoding: .utf8),
            "cli_auth_credentials_store = \"file\"\n")

        XCTAssertEqual(try store.rename(work, to: "Client").displayName, "Client")
        try store.delete(personal)
        XCTAssertEqual(try store.load().map(\.displayName), ["Client"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.loginHome(personal).path))

        XCTAssertThrowsError(try store.create(provider: .fx, named: "Other"))
        XCTAssertThrowsError(try store.create(provider: .codex, named: " \n "))
    }

    func testBotSelectionIsPrivateAndSurvivesRecordUpdates() throws {
        var agent = try repository.createAgent(named: "Profile Bot", harnessIdentifier: "codex").agent
        let workspace = repository.storage(for: agent.id).workspace
        XCTAssertNil(try store.selected(workspace: workspace, provider: .codex))
        XCTAssertFalse(try String(contentsOf: repository.storage(for: agent.id).configuration, encoding: .utf8).contains("harnessProfile"))

        let profile = try store.create(provider: .codex, named: "Work")
        try repository.updateAgentHarnessProfile(agent, profile: profile.id)
        agent = try repository.renameAgent(agent, to: "Renamed Bot")
        XCTAssertEqual(try repository.loadAgentHarnessProfile(agent), profile.id)
        XCTAssertEqual(try store.selected(workspace: workspace, provider: .codex), profile)
        XCTAssertFalse(try XCTUnwrap(String(data: JSONEncoder().encode(agent), encoding: .utf8)).contains(profile.id.uuidString))

        try repository.updateAgentHarnessProfile(agent, profile: nil)
        XCTAssertNil(try store.selected(workspace: workspace, provider: .codex))
    }

    func testUnavailableProfileFailsClosed() throws {
        let agent = try repository.createAgent(named: "Profile Bot", harnessIdentifier: "codex").agent
        let workspace = repository.storage(for: agent.id).workspace
        let profile = try store.create(provider: .codex, named: "Work")
        try repository.updateAgentHarnessProfile(agent, profile: profile.id)

        // The bot's harness no longer matches the profile's.
        XCTAssertThrowsError(try store.selected(workspace: workspace, provider: .claudeCode))

        // A redirected login home must not stand in for the profile.
        let home = store.loginHome(profile), moved = home.deletingLastPathComponent().appendingPathComponent("moved")
        try FileManager.default.moveItem(at: home, to: moved)
        try FileManager.default.createSymbolicLink(at: home, withDestinationURL: moved)
        XCTAssertThrowsError(try store.selected(workspace: workspace, provider: .codex))
        try FileManager.default.removeItem(at: home)
        try FileManager.default.moveItem(at: moved, to: home)
        XCTAssertEqual(try store.selected(workspace: workspace, provider: .codex), profile)

        try store.delete(profile)
        XCTAssertThrowsError(try store.selected(workspace: workspace, provider: .codex)) {
            XCTAssertTrue($0.localizedDescription.contains("profile is unavailable"))
        }
    }

    func testEachHarnessIsPointedAtItsOwnProfileFolder() throws {
        let codex = try store.create(provider: .codex, named: "Codex"), grok = try store.create(provider: .grokBuild, named: "Grok")
        let muse = try store.create(provider: .muse, named: "Muse"), claude = try store.create(provider: .claudeCode, named: "Claude")
        XCTAssertEqual(store.environment(codex), ["CODEX_HOME": store.loginHome(codex).appendingPathComponent(".codex").path])
        XCTAssertEqual(store.environment(grok), ["GROK_HOME": store.loginHome(grok).appendingPathComponent(".grok").path])
        XCTAssertEqual(store.environment(muse), ["XDG_CONFIG_HOME": store.loginHome(muse).appendingPathComponent(".config").path,
                                                 "TBH_CREDENTIAL_BACKEND": "file"])
        XCTAssertEqual(store.environment(claude), ["CLAUDE_CONFIG_DIR": store.loginHome(claude).appendingPathComponent(".claude").path])
        XCTAssertEqual(store.accountHome(muse).path, store.loginHome(muse).appendingPathComponent(".config/muse").path)
        for profile in [codex, grok, muse, claude] {
            XCTAssertEqual(try store.validated(profile.id), profile)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.accountHome(profile).path))
        }
        // A link anywhere between the login home and the account folder is refused.
        let config = store.loginHome(muse).appendingPathComponent(".config"), moved = store.loginHome(muse).appendingPathComponent("moved")
        try FileManager.default.moveItem(at: config, to: moved)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: moved)
        XCTAssertThrowsError(try store.validated(muse.id))
    }

    func testSignInChallengeAcceptsOnlyTheVendorsDevicePage() throws {
        let grok = "\nTo sign in, open this URL in your browser:\n\n  https://accounts.x.ai/oauth2/device?user_code=7ABC-DEFG\n\nConfirm this code in your browser:\n\n  7ABC-DEFG\n\nWaiting"
        let challenge = try XCTUnwrap(HarnessProfileLogin.challenge(provider: .grokBuild, text: grok))
        XCTAssertEqual(challenge.code, "7ABC-DEFG")
        XCTAssertEqual(challenge.url.absoluteString, "https://accounts.x.ai/oauth2/device?user_code=7ABC-DEFG")
        let muse = "Open this page to sign in:\n  https://auth.meta.com/oauth/device/?code=ABCD-EFGH\nconfirm this code matches:\n  ABCD-EFGH\n"
        XCTAssertEqual(HarnessProfileLogin.challenge(provider: .muse, text: muse)?.code, "ABCD-EFGH")

        // A read that ends inside the URL line waits for the rest.
        XCTAssertNil(HarnessProfileLogin.challenge(provider: .muse, text: "  https://auth.meta.com/oauth/device/?code=ABCD"))
        XCTAssertNil(HarnessProfileLogin.challenge(provider: .grokBuild, text: muse))
        XCTAssertNil(HarnessProfileLogin.challenge(provider: .codex, text: grok))
        for url in ["http://accounts.x.ai/oauth2/device?user_code=7ABC-DEFG", "https://accounts.x.ai.evil.example/oauth2/device",
                    "https://user@accounts.x.ai/oauth2/device", "https://accounts.x.ai:8443/oauth2/device", "https://accounts.x.ai/other"] {
            XCTAssertNil(HarnessProfileLogin.challenge(provider: .grokBuild, url: url, code: "7ABC-DEFG"), url)
        }
        XCTAssertNil(HarnessProfileLogin.challenge(provider: .grokBuild, url: "https://accounts.x.ai/oauth2/device", code: "7ABC DEFG; rm"))
    }

    func testMuseProfileNeverFallsBackToTheSharedKeychainLogin() throws {
        let agent = try repository.createAgent(named: "Muse Bot", harnessIdentifier: "muse").agent
        let workspace = repository.storage(for: agent.id).workspace
        let profile = try store.create(provider: .muse, named: "Work")
        let auth = store.accountHome(profile).appendingPathComponent("auth.json")
        func write(_ meta: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: ["schema_version": 1, "providers": ["meta": meta]]).write(to: auth)
        }
        XCTAssertFalse(store.loginIsShared(profile))

        try write(["mechanism": "oauth", "storage": "keychain"])
        XCTAssertTrue(store.loginIsShared(profile))
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .muse, workspace: workspace,
            loginHome: store.loginHome(profile), secret: { _, _ in nil }))

        try write(["mechanism": "oauth", "storage": "file", "access_token": "work-token"])
        XCTAssertFalse(store.loginIsShared(profile))
        try RestrictedHarnessStorage.prepare(provider: .muse, workspace: workspace, loginHome: store.loginHome(profile),
            secret: { _, _ in XCTFail("A profile must not read the Keychain"); return nil })
        let seeded = RestrictedHarnessStorage.home(workspace: workspace).appendingPathComponent(".config/muse/auth.json")
        XCTAssertTrue(try String(contentsOf: seeded, encoding: .utf8).contains("work-token"))
    }

    func testRestrictedBotIsSeededFromItsProfileLogin() throws {
        let agent = try repository.createAgent(named: "Profile Bot", harnessIdentifier: "codex").agent
        let workspace = repository.storage(for: agent.id).workspace
        let profile = try store.create(provider: .codex, named: "Work")
        let seeded = RestrictedHarnessStorage.home(workspace: workspace).appendingPathComponent(".codex/auth.json")

        // Not signed in yet: never fall back to another account.
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: store.loginHome(profile)))

        try Data("work-login".utf8).write(to: store.accountHome(profile).appendingPathComponent("auth.json"))
        try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: store.loginHome(profile))
        XCTAssertEqual(try Data(contentsOf: seeded), Data("work-login".utf8))

        // Switching profile replaces the bot's login with the other account.
        let other = try store.create(provider: .codex, named: "Personal")
        try Data("personal-login".utf8).write(to: store.accountHome(other).appendingPathComponent("auth.json"))
        try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: store.loginHome(other))
        XCTAssertEqual(try Data(contentsOf: seeded), Data("personal-login".utf8))
    }

    func testRestrictedClaudeBotIsSeededOnlyFromItsProfileKeychainItem() throws {
        let agent = try repository.createAgent(named: "Claude Bot", harnessIdentifier: "claude-code").agent
        let workspace = repository.storage(for: agent.id).workspace
        let profile = try store.create(provider: .claudeCode, named: "Work")
        // Claude Code names the item after its configuration folder.
        let digest = SHA256.hash(data: Data(store.accountHome(profile).path.utf8)).map { String(format: "%02x", $0) }.joined()
        let service = "Claude Code-credentials-" + digest.prefix(8)
        var requested: [String] = []
        func read(_ name: String, _ account: String) throws -> Data? {
            requested.append(name)
            return name == service ? Data(#"{"claudeAiOauth":{"accessToken":"work-token"},"mcpOAuth":{}}"#.utf8) : nil
        }
        try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: store.loginHome(profile),
                                             secret: store.loginSecret(profile, read: read))
        XCTAssertEqual(requested, [service])
        let seeded = RestrictedHarnessStorage.home(workspace: workspace).appendingPathComponent(".claude/.credentials.json")
        XCTAssertEqual(try String(contentsOf: seeded, encoding: .utf8), #"{"claudeAiOauth":{"accessToken":"work-token"}}"#)

        // Other harnesses keep a profile's login in its files alone.
        let codex = try store.create(provider: .codex, named: "Codex")
        XCTAssertNil(try store.loginSecret(codex, read: { _, _ in XCTFail("A Codex profile must not read the Keychain"); return nil })(
            "Claude Code-credentials", NSUserName()))
    }

    func testProfileClaudeKeychainItemIsReadWithTheSecurityTool() throws {
        var arguments: [String] = []
        let data = try RestrictedHarnessStorage.readSecret(service: "Claude Code-credentials-0123abcd", account: "me") {
            arguments = $0
            return (0, Data("login\n".utf8))
        }
        XCTAssertEqual(arguments, ["find-generic-password", "-s", "Claude Code-credentials-0123abcd", "-a", "me", "-w"])
        XCTAssertEqual(data, Data("login".utf8))
    }
}
