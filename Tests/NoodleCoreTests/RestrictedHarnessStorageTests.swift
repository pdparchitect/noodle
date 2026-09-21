import XCTest
@testable import NoodleCore

final class RestrictedHarnessStorageTests: XCTestCase {
    func testClaudeCopiesOnlyOAuthFromItsExactKeychainItemAndPreservesPrivateRefreshes() throws {
        let (home, first, second) = try fixture()
        // A Keychain login does not need a shared config directory to exist.
        var login = Data(#"{"claudeAiOauth":{"accessToken":"first","refreshToken":"refresh","expiresAt":9999999999999},"mcpOAuth":{"unrelated":"secret"}}"#.utf8)
        var lookups = 0
        func prepare(_ workspace: URL) throws {
            try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: home) { service, account in
                XCTAssertEqual(service, "Claude Code-credentials")
                XCTAssertEqual(account, NSUserName())
                lookups += 1
                return login
            }
        }
        try prepare(first); try prepare(second)
        let a = try WorkspaceMailbox(workspace: first, path: ".noodle/home/.claude")
        let b = try WorkspaceMailbox(workspace: second, path: ".noodle/home/.claude")
        let seeded = try a.read(".credentials.json", limit: 4096)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: seeded) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["claudeAiOauth"])
        XCTAssertEqual((payload["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String, "refresh")
        let attributes = try FileManager.default.attributesOfItem(atPath: RestrictedHarnessStorage.home(workspace: first).appendingPathComponent(".claude/.credentials.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let refreshed = Data(#"{"claudeAiOauth":{"accessToken":"refreshed","refreshToken":"rotated"}}"#.utf8)
        try a.writeData(refreshed, named: ".credentials.json")
        try prepare(first)
        XCTAssertEqual(try a.read(".credentials.json", limit: 4096), refreshed)
        XCTAssertEqual(try b.read(".credentials.json", limit: 4096), seeded)
        login = Data(#"{"claudeAiOauth":{"accessToken":"new-sign-in"}}"#.utf8)
        try prepare(first)
        XCTAssertNotEqual(try a.read(".credentials.json", limit: 4096), refreshed)
        XCTAssertEqual(lookups, 4)
    }

    func testClaudeFileFallbackImportsNoSettingsHooksOrHistory() throws {
        let (home, workspace, _) = try fixture()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = try WorkspaceMailbox(workspace: home, path: ".claude", create: true)
        try source.writeData(Data(#"{"claudeAiOauth":{"accessToken":"file-login"}}"#.utf8), named: ".credentials.json")
        for name in ["settings.json", "history.jsonl", "CLAUDE.md"] {
            try source.writeData(Data("private account context".utf8), named: name)
        }
        try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: home, secret: { _, _ in nil })
        let destination = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.claude")
        XCTAssertTrue(destination.contains(".credentials.json"))
        for name in ["settings.json", "history.jsonl", "CLAUDE.md"] { XCTAssertFalse(destination.contains(name)) }
    }

    func testClaudeMissingMalformedAndDeniedLoginsFailClosed() throws {
        for login in [nil, Data("invalid".utf8), Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)] as [Data?] {
            let (home, workspace, _) = try fixture()
            XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: home,
                secret: { _, _ in login }))
        }
        let (home, workspace, _) = try fixture()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = try WorkspaceMailbox(workspace: home, path: ".claude", create: true)
        try source.writeData(Data(#"{"claudeAiOauth":{"accessToken":"stale-file"}}"#.utf8), named: ".credentials.json")
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: home,
            secret: { _, _ in throw HarnessSetupError("Keychain denied") }))
        let destination = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.claude")
        XCTAssertFalse(destination.contains(".credentials.json"))
    }

    func testClaudeLoginIsReadThroughTheSecurityToolThatOwnsTheItem() throws {
        // Claude Code writes the item with /usr/bin/security, so only that tool
        // stays trusted across token refreshes. A direct read prompts every time.
        var calls: [[String]] = []
        func read(_ status: Int32, _ output: String) throws -> Data? {
            try RestrictedHarnessStorage.readSecret(service: "Claude Code-credentials", account: "someone") { arguments in
                calls.append(arguments)
                return (status, Data(output.utf8))
            }
        }
        XCTAssertEqual(try read(0, "{\"claudeAiOauth\":{}}\n"), Data(#"{"claudeAiOauth":{}}"#.utf8))
        XCTAssertEqual(calls, [["find-generic-password", "-s", "Claude Code-credentials", "-a", "someone", "-w"]])
        // The tool prints hex when the stored bytes are not plain text.
        XCTAssertEqual(try read(0, "7b22c3a9227d\n"), Data(#"{"é"}"#.utf8))
        XCTAssertNil(try read(44, ""))
        XCTAssertThrowsError(try read(36, ""))
        XCTAssertThrowsError(try read(0, ""))
    }

    func testFXLoginIsReadThroughTheSecurityToolThatOwnsTheItem() throws {
        // FX recreates its items on token refresh, which drops any Always Allow
        // given to the host. The security tool stays trusted.
        for service in ["FX_OAUTH_SESSION_V1", "FX_AI_GATEWAY_API_KEY"] {
            var calls: [[String]] = []
            let data = try RestrictedHarnessStorage.readSecret(service: service, account: "someone") { arguments in
                calls.append(arguments)
                return (0, Data("{\"session\":1}\n".utf8))
            }
            XCTAssertEqual(data, Data(#"{"session":1}"#.utf8))
            XCTAssertEqual(calls, [["find-generic-password", "-s", service, "-a", "someone", "-w"]])
        }
    }

    func testClaudeRedirectedCredentialDestinationIsRejectedBeforeLookup() throws {
        let (home, workspace, other) = try fixture()
        let privateHome = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home", create: true)
        try privateHome.symlink(".claude", destination: other.path)
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: home,
            secret: { _, _ in XCTFail("Must reject redirection before reading login"); return nil }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent(".credentials.json").path))
    }

    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repo = WorkspaceRepository(rootURL: root.appendingPathComponent("Noodle"))
        let first = try repo.createAgent(named: "First"), second = try repo.createAgent(named: "Second")
        return (root.appendingPathComponent("Home"), repo.directory(for: first.agent), repo.directory(for: second.agent))
    }

    func testCodexAndGrokCopyOnlyLoginAndPreservePrivateRefreshes() throws {
        for provider in [HarnessProvider.codex, .grokBuild] {
            let (home, first, second) = try fixture()
            let path = provider == .codex ? ".codex" : ".grok"
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let source = try WorkspaceMailbox(workspace: home, path: path, create: true)
            try source.writeData(Data("login-one".utf8), named: "auth.json")
            try source.writeData(Data("private history".utf8), named: "sessions.json")
            try source.writeData(Data("private hooks".utf8), named: "config.toml")
            for workspace in [first, second] {
                try RestrictedHarnessStorage.prepare(provider: provider, workspace: workspace, loginHome: home,
                    secret: { _, _ in XCTFail("No Keychain lookup needed"); return nil })
            }
            let a = try WorkspaceMailbox(workspace: first, path: ".noodle/home/" + path)
            let b = try WorkspaceMailbox(workspace: second, path: ".noodle/home/" + path)
            XCTAssertFalse(a.contains("sessions.json"))
            if provider == .codex { XCTAssertFalse(try String(decoding: a.read("config.toml", limit: 100), as: UTF8.self).contains("private hooks")) }
            try a.writeData(Data("refreshed".utf8), named: "auth.json")
            try RestrictedHarnessStorage.prepare(provider: provider, workspace: first, loginHome: home, secret: { _, _ in nil })
            XCTAssertEqual(try a.read("auth.json", limit: 100), Data("refreshed".utf8))
            XCTAssertEqual(try b.read("auth.json", limit: 100), Data("login-one".utf8))
            XCTAssertEqual(try source.read("auth.json", limit: 100), Data("login-one".utf8))
            try source.writeData(Data("new-sign-in".utf8), named: "auth.json")
            try RestrictedHarnessStorage.prepare(provider: provider, workspace: first, loginHome: home, secret: { _, _ in nil })
            XCTAssertEqual(try a.read("auth.json", limit: 100), Data("new-sign-in".utf8))
        }
    }

    func testMuseReadsOnlyItsProviderKeychainItemAndKeepsOtherProvidersOut() throws {
        let (home, workspace, _) = try fixture()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = try WorkspaceMailbox(workspace: home, path: ".config/muse", create: true)
        try source.writeData(Data(#"{"schema_version":1,"providers":{"meta":{"mechanism":"oauth","storage":"keychain"},"other":{"api_key":"unrelated"}}}"#.utf8), named: "auth.json")
        try RestrictedHarnessStorage.prepare(provider: .muse, workspace: workspace, loginHome: home, secret: { service, account in
            XCTAssertEqual(service, "ai.meta.dev.credentials"); XCTAssertEqual(account, "meta")
            return Data(#"{"secret_schema_version":1,"api_key":"fixture-key","access_token":"fixture-token"}"#.utf8)
        })
        let target = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.config/muse")
        let auth = try JSONSerialization.jsonObject(with: target.read("auth.json", limit: 4096)) as! [String: Any]
        let providers = auth["providers"] as! [String: [String: Any]]
        XCTAssertEqual(Array(providers.keys), ["meta"])
        XCTAssertEqual(providers["meta"]?["storage"] as? String, "file")
        XCTAssertEqual(providers["meta"]?["access_token"] as? String, "fixture-token")
    }

    func testFXImportsSelectedLoginWithoutSharedSkillsHooksOrMCP() throws {
        let (home, workspace, _) = try fixture()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = try WorkspaceMailbox(workspace: home, path: ".fx", create: true)
        try source.writeData(Data(#"{"provider":"gateway","credential_source":"fx_login","hooks":{"run":"private"},"workspaces":{"private":"config"}}"#.utf8), named: "settings.json")
        try source.writeData(Data("private MCP".utf8), named: "mcp.json")
        try RestrictedHarnessStorage.prepare(provider: .fx, workspace: workspace, loginHome: home, secret: { service, account in
            XCTAssertEqual(service, "FX_OAUTH_SESSION_V1"); XCTAssertEqual(account, NSUserName())
            return Data("fixture-login".utf8)
        })
        let target = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.fx")
        XCTAssertFalse(target.contains("mcp.json"))
        let settings = try String(decoding: target.read("settings.json", limit: 4096), as: UTF8.self)
        XCTAssertFalse(settings.contains("hooks")); XCTAssertFalse(settings.contains("workspaces"))
        let environment = try RestrictedAgentSandbox.environment(provider: .fx, home: home, workspace: workspace)
        XCTAssertEqual(environment["FX_DISABLE_KEYCHAIN"], "1")
        XCTAssertTrue(try XCTUnwrap(environment["HOME"]).hasPrefix(workspace.path + "/"))
    }

    func testRedirectedPrivateHomeCannotReceiveCredentials() throws {
        let (home, workspace, other) = try fixture()
        let noodle = try WorkspaceMailbox(workspace: workspace, path: ".noodle", create: true)
        try noodle.symlink("home", destination: other.path)
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent(".codex").path))
    }
}
