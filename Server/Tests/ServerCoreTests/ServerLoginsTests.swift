import Foundation
import NoodleCore
@testable import ServerCore
import XCTest

/// Each harness, and each of its profiles, has one login on the server, signed in with `noodled login`.
/// A bot works on its own copy of the login its plan lends it.
final class ServerLoginsTests: XCTestCase {
    private var root: URL!
    private var logins: ServerLogins!
    private var workspace: URL { root.appendingPathComponent("Agents/bot/workspace") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodled-\(UUID())")
        try FileManager.default.createDirectory(at: AgentStorageLayout(workspace: workspace).runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        logins = ServerLogins(configuration: configuration, profiles: HarnessProfileStore(root: root))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private let configuration = try! ServerConfiguration(yaml: """
    harnesses:
      claude-code:
        path: /opt/claude/bin/claude
        profiles: [Work]
      codex: /usr/local/bin/codex
    """)

    /// What `noodled login` signs in, as the harness keeps it in the login's own folder.
    private func signIn(_ provider: HarnessProvider, profile: String? = nil) throws {
        let login = try logins.login(provider, profile: profile)
        let account = logins.profiles.accountHome(login)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        switch provider {
        case .claudeCode:
            try Data(#"{"claudeAiOauth":{"accessToken":"token-\#(profile ?? "default")","refreshToken":"r","expiresAt":4102444800000}}"#.utf8)
                .write(to: account.appendingPathComponent(".credentials.json"))
        default:
            try Data(#"{"tokens":{"access_token":"a","refresh_token":"r"}}"#.utf8).write(to: account.appendingPathComponent("auth.json"))
        }
    }

    func testABotWorksOnItsOwnCopyOfItsLogin() throws {
        try signIn(.claudeCode, profile: "Work")
        try logins.prepare(.claudeCode, login: try logins.login(.claudeCode, profile: "Work"), workspace: workspace)
        let copy = try String(contentsOf: workspace.appendingPathComponent(".noodle/home/.claude/.credentials.json"), encoding: .utf8)
        XCTAssertTrue(copy.contains("token-Work"), copy)

        try signIn(.codex)
        try logins.prepare(.codex, login: try logins.login(.codex, profile: nil), workspace: workspace)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".noodle/home/.codex/auth.json").path))
        let settings = try String(contentsOf: workspace.appendingPathComponent(".noodle/home/.codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(settings.contains("cli_auth_credentials_store = \"file\""), settings)
    }

    func testABotOnALoginNobodySignedInToSaysHowToSignIn() throws {
        XCTAssertThrowsError(try logins.prepare(.claudeCode, login: try logins.login(.claudeCode, profile: "Work"), workspace: workspace)) {
            XCTAssertEqual($0.localizedDescription,
                           "Nobody has signed in to Claude Code's Work profile on this server. Run: noodled login claude-code --profile Work")
        }
        XCTAssertThrowsError(try logins.prepare(.codex, login: try logins.login(.codex, profile: nil), workspace: workspace)) {
            XCTAssertEqual($0.localizedDescription, "Nobody has signed in to Codex on this server. Run: noodled login codex")
        }
    }

    func testACheckListsTheLoginsNobodySignedInTo() throws {
        XCTAssertEqual(logins.unsigned(), [
            "Nobody has signed in to Claude Code on this server. Run: noodled login claude-code",
            "Nobody has signed in to Claude Code's Work profile on this server. Run: noodled login claude-code --profile Work",
            "Nobody has signed in to Codex on this server. Run: noodled login codex",
        ])
        try signIn(.claudeCode)
        try signIn(.claudeCode, profile: "Work")
        try signIn(.codex)
        XCTAssertEqual(logins.unsigned(), [])
    }

    /// The harness's own sign-in, kept to the login's folder so nothing lands in the server account's home.
    func testSigningInRunsTheHarnessesOwnSignInForThatLogin() throws {
        let work = try logins.login(.claudeCode, profile: "Work")
        let claude = try logins.signIn(.claudeCode, login: work)
        XCTAssertEqual(claude.arguments, ["auth", "login", "--claudeai"])
        XCTAssertEqual(claude.environment["HOME"], logins.profiles.loginHome(work).path)
        XCTAssertEqual(claude.environment["CLAUDE_CONFIG_DIR"], logins.profiles.accountHome(work).path)

        let own = try logins.login(.codex, profile: nil)
        let codex = try logins.signIn(.codex, login: own)
        XCTAssertEqual(codex.arguments, ["login", "--device-auth"])
        XCTAssertEqual(codex.environment["CODEX_HOME"], logins.profiles.accountHome(own).path)
        // Codex keeps the login in a file there, never in a keyring a server does not have.
        let settings = try String(contentsOf: logins.profiles.accountHome(own).appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(settings.contains("cli_auth_credentials_store = \"file\""), settings)

        XCTAssertThrowsError(try logins.login(.claudeCode, profile: "Home")) {
            XCTAssertEqual($0.localizedDescription, "Claude Code has no profile called Home; add it under harnesses.claude-code.profiles first.")
        }
    }
}
