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

    /// A bot that was never signed in pauses for sign-in and comes back by itself once it is,
    /// instead of restarting over and over.
    func testAMissingLoginReadsAsASignInFailure() throws {
        for provider in [HarnessProvider.claudeCode, .antigravity] {
            let (home, workspace, _) = try fixture()
            // As a default profile's folders are laid out, before anyone signs in.
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: provider, workspace: workspace, loginHome: home,
                secret: { _, _ in nil })) {
                let text = $0.localizedDescription
                XCTAssertTrue(provider == .claudeCode ? ClaudeProtocol.isAuthenticationFailure(text)
                              : AntigravityProtocol.isAuthenticationFailure(text), text)
            }
        }
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

    func testCodexAndGrokCopyOnlyLoginAndHandARefreshBackToEveryBot() throws {
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
            // A refresh spends the refresh token every copy holds. The new login
            // must reach the source and the other bot, or they are left signed out.
            try a.writeData(Data("refreshed".utf8), named: "auth.json")
            try RestrictedHarnessStorage.prepare(provider: provider, workspace: first, loginHome: home, secret: { _, _ in nil })
            XCTAssertEqual(try a.read("auth.json", limit: 100), Data("refreshed".utf8))
            XCTAssertEqual(try source.read("auth.json", limit: 100), Data("refreshed".utf8))
            try RestrictedHarnessStorage.prepare(provider: provider, workspace: second, loginHome: home, secret: { _, _ in nil })
            XCTAssertEqual(try b.read("auth.json", limit: 100), Data("refreshed".utf8))
            try source.writeData(Data("new-sign-in".utf8), named: "auth.json")
            try RestrictedHarnessStorage.prepare(provider: provider, workspace: first, loginHome: home, secret: { _, _ in nil })
            XCTAssertEqual(try a.read("auth.json", limit: 100), Data("new-sign-in".utf8))
        }
    }

    /// Custom models route through the provider the person chose, so a restricted
    /// bot gets that choice and its catalogue, but no commands, servers or hooks.
    /// A bot on the app's default Codex login keeps the person's model routing, which is not a login.
    func testCodexRoutingCanComeFromAnotherHomeThanTheLogin() throws {
        let (root, workspace, _) = try fixture()
        let login = root.appendingPathComponent("default"), settings = root.appendingPathComponent("person")
        for home in [login, settings] { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        try WorkspaceMailbox(workspace: login, path: ".codex", create: true).writeData(Data("app-login".utf8), named: "auth.json")
        let person = try WorkspaceMailbox(workspace: settings, path: ".codex", create: true)
        try person.writeData(Data("person-login".utf8), named: "auth.json")
        try person.writeData(Data("model_provider = \"opencodex\"\n".utf8), named: "config.toml")
        try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: login, settingsHome: settings)
        let copy = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.codex")
        XCTAssertEqual(try copy.read("auth.json", limit: 100), Data("app-login".utf8))
        XCTAssertTrue(String(decoding: try copy.read("config.toml", limit: 4096), as: UTF8.self).contains("model_provider = \"opencodex\""))
    }

    func testCodexCarriesOnlyModelRoutingIntoTheBotsConfig() throws {
        let (home, workspace, _) = try fixture()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = try WorkspaceMailbox(workspace: home, path: ".codex", create: true)
        try source.writeData(Data("login".utf8), named: "auth.json")
        let catalogue = home.appendingPathComponent("catalogue.json")
        try Data(#"{"models":[{"slug":"ollama-cloud/deepseek"}]}"#.utf8).write(to: catalogue)
        try source.writeData(Data("""
            model = "gpt-5"
            model_provider = "opencodex"
            model_catalog_json = "\(catalogue.path)"
            notify = ["/bin/sh", "-c", "private notify"]

            [mcp_servers.private]
            command = "private-server"

            [model_providers.opencodex]
            name = "OpenCodeX"
            base_url = "http://127.0.0.1:10100/v1"
            wire_api = "responses"

            [model_providers.opencodex.http_headers]
            X-Route = "ollama"

            [model_providers.opencodex.auth]
            command = "private-token-command"

            [projects."/private/project"]
            trust_level = "trusted"
            """.utf8), named: "config.toml")
        try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: home)
        let copy = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.codex")
        let config = String(decoding: try copy.read("config.toml", limit: 10_000), as: UTF8.self)
        XCTAssertEqual(config, """
            cli_auth_credentials_store = "file"
            model_provider = "opencodex"
            model_catalog_json = "\(copy.url.appendingPathComponent("model-catalog.json").path)"

            [model_providers.opencodex]
            name = "OpenCodeX"
            base_url = "http://127.0.0.1:10100/v1"
            wire_api = "responses"

            [model_providers.opencodex.http_headers]
            X-Route = "ollama"

            """)
        XCTAssertEqual(try copy.read("model-catalog.json", limit: 1000), try Data(contentsOf: catalogue))
    }

    func testANewSignInWinsOverARefreshMadeFromTheOldLogin() throws {
        let (home, workspace, _) = try fixture()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = try WorkspaceMailbox(workspace: home, path: ".codex", create: true)
        try source.writeData(Data("old-login".utf8), named: "auth.json")
        try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: home)
        let copy = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.codex")
        try copy.writeData(Data("old-login-refreshed".utf8), named: "auth.json")
        try source.writeData(Data("new-sign-in".utf8), named: "auth.json")
        try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: home)
        XCTAssertEqual(try copy.read("auth.json", limit: 100), Data("new-sign-in".utf8))
        XCTAssertEqual(try source.read("auth.json", limit: 100), Data("new-sign-in".utf8))
    }

    func testARunningBotsRefreshReachesTheOtherRunningBotsWithoutARestart() throws {
        let (home, first, second) = try fixture()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = try WorkspaceMailbox(workspace: home, path: ".codex", create: true)
        try source.writeData(Data("login-one".utf8), named: "auth.json")
        for workspace in [first, second] { try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: home) }
        let a = try WorkspaceMailbox(workspace: first, path: ".noodle/home/.codex")
        let b = try WorkspaceMailbox(workspace: second, path: ".noodle/home/.codex")
        try a.writeData(Data("refreshed".utf8), named: "auth.json")
        for workspace in [first, second] { try RestrictedHarnessStorage.exchange(provider: .codex, workspace: workspace, loginHome: home) }
        XCTAssertEqual(try b.read("auth.json", limit: 100), Data("refreshed".utf8))
        XCTAssertEqual(try source.read("auth.json", limit: 100), Data("refreshed".utf8))
        // A bot on another login is left alone.
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: other) }
        try RestrictedHarnessStorage.exchange(provider: .codex, workspace: second, loginHome: other)
        XCTAssertEqual(try b.read("auth.json", limit: 100), Data("refreshed".utf8))
    }

    func testKeychainLoginsHandARefreshToTheOtherBotsWithoutRewritingTheItem() throws {
        let (home, first, second) = try fixture()
        var login = Data(#"{"claudeAiOauth":{"accessToken":"first","refreshToken":"one"}}"#.utf8)
        func prepare(_ workspace: URL) throws {
            try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: home) { _, _ in login }
        }
        try prepare(first); try prepare(second)
        let a = try WorkspaceMailbox(workspace: first, path: ".noodle/home/.claude")
        let b = try WorkspaceMailbox(workspace: second, path: ".noodle/home/.claude")
        let refreshed = Data(#"{"claudeAiOauth":{"accessToken":"refreshed","refreshToken":"two"}}"#.utf8)
        try a.writeData(refreshed, named: ".credentials.json")
        try prepare(first); try prepare(second)
        XCTAssertEqual(try b.read(".credentials.json", limit: 4096), refreshed)
        // Signing in again changes the item, and that login replaces every copy.
        login = Data(#"{"claudeAiOauth":{"accessToken":"new-sign-in"}}"#.utf8)
        try prepare(second)
        XCTAssertTrue(String(decoding: try b.read(".credentials.json", limit: 4096), as: UTF8.self).contains("new-sign-in"))
    }

    func testALoginThatFailedIsNotStartedAgainUntilItChanges() throws {
        let (home, first, second) = try fixture()
        var login = Data(#"{"claudeAiOauth":{"accessToken":"first","refreshToken":"spent"}}"#.utf8)
        func prepare(_ workspace: URL) throws {
            try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: home) { _, _ in login }
        }
        // Asked before the start, without changing any copy.
        func refused() -> Bool {
            RestrictedHarnessStorage.refusedAgain(provider: .claudeCode, workspace: first, loginHome: home) { _, _ in login }
        }
        try prepare(first); try prepare(second)
        XCTAssertFalse(refused())
        try RestrictedHarnessStorage.loginFailed(provider: .claudeCode, workspace: first)
        XCTAssertTrue(refused())
        XCTAssertThrowsError(try prepare(first)) {
            XCTAssertTrue(ClaudeProtocol.isAuthenticationFailure($0.localizedDescription), "\($0.localizedDescription)")
        }
        // Another bot's refresh is a different login, so it gets a start.
        let b = try WorkspaceMailbox(workspace: second, path: ".noodle/home/.claude")
        try b.writeData(Data(#"{"claudeAiOauth":{"accessToken":"bot","refreshToken":"two"}}"#.utf8), named: ".credentials.json")
        try RestrictedHarnessStorage.exchange(provider: .claudeCode, workspace: second, loginHome: home)
        XCTAssertFalse(refused())
        try prepare(first)
        // And so does a new sign-in, once the refreshed login failed too.
        try RestrictedHarnessStorage.loginFailed(provider: .claudeCode, workspace: first)
        XCTAssertThrowsError(try prepare(first))
        XCTAssertTrue(refused())
        login = Data(#"{"claudeAiOauth":{"accessToken":"new-sign-in","refreshToken":"three"}}"#.utf8)
        XCTAssertFalse(refused())
        try prepare(first)
        try prepare(first)
    }

    /// A refusal can be the vendor's passing trouble, so the same login is started again after a
    /// while: five minutes, twice as long after each further refusal, never more than four hours.
    func testARefusedLoginIsStartedAgainAfterAWhileThatGrowsWithEachRefusal() throws {
        let (home, first, _) = try fixture()
        let login = Data(#"{"claudeAiOauth":{"accessToken":"first","refreshToken":"spent"}}"#.utf8)
        let failure = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { failure.addingTimeInterval(minutes * 60) }
        func refused(_ minutes: Double) -> Bool {
            RestrictedHarnessStorage.refusedAgain(provider: .claudeCode, workspace: first, loginHome: home, now: at(minutes)) { _, _ in login }
        }
        func prepare(_ minutes: Double) throws {
            try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: first, loginHome: home, now: at(minutes)) { _, _ in login }
        }
        try prepare(0)
        try RestrictedHarnessStorage.loginFailed(provider: .claudeCode, workspace: first, now: at(0))
        XCTAssertEqual(RestrictedHarnessStorage.refusedUntil(provider: .claudeCode, workspace: first), at(5))
        XCTAssertTrue(refused(4.9))
        XCTAssertThrowsError(try prepare(4.9))
        XCTAssertFalse(refused(5))
        try prepare(5)
        // Refused again on the same login: twice as long.
        try RestrictedHarnessStorage.loginFailed(provider: .claudeCode, workspace: first, now: at(5))
        XCTAssertTrue(refused(14.9))
        XCTAssertFalse(refused(15))
        try prepare(15)
        for _ in 0..<10 { try RestrictedHarnessStorage.loginFailed(provider: .claudeCode, workspace: first, now: at(15)) }
        XCTAssertTrue(refused(15 + 4 * 60 - 0.1))
        XCTAssertFalse(refused(15 + 4 * 60))
        // Retry Now forgets the refusal at once.
        RestrictedHarnessStorage.forgetRefusedLogin(provider: .claudeCode, workspace: first)
        XCTAssertNil(RestrictedHarnessStorage.refusedUntil(provider: .claudeCode, workspace: first))
        XCTAssertFalse(refused(16))
        try prepare(16)
        // And a refusal after that starts again from five minutes.
        try RestrictedHarnessStorage.loginFailed(provider: .claudeCode, workspace: first, now: at(16))
        XCTAssertTrue(refused(20.9))
        XCTAssertFalse(refused(21))
    }

    /// Claude Code refreshes a login whose access token expired, so that is a good time to try it again.
    func testARefusedLoginIsStartedAgainOnceItsAccessTokenExpires() throws {
        let (home, first, _) = try fixture()
        let failure = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = Int64(failure.addingTimeInterval(2 * 60).timeIntervalSince1970 * 1000)
        let login = Data(#"{"claudeAiOauth":{"accessToken":"first","refreshToken":"spent","expiresAt":\#(expiry)}}"#.utf8)
        func refused(_ minutes: Double) -> Bool {
            RestrictedHarnessStorage.refusedAgain(provider: .claudeCode, workspace: first, loginHome: home,
                                                  now: failure.addingTimeInterval(minutes * 60)) { _, _ in login }
        }
        try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: first, loginHome: home, now: failure) { _, _ in login }
        try RestrictedHarnessStorage.loginFailed(provider: .claudeCode, workspace: first, now: failure)
        XCTAssertTrue(refused(1.9))
        XCTAssertFalse(refused(2))
    }

    /// The host checks a bot on a profile against the profile's own login item, never the person's.
    func testABotOnAProfileIsRefusedUntilItsProfileSignsInAgain() throws {
        let (home, first, _) = try fixture()
        let profiles = HarnessProfileStore(root: home.deletingLastPathComponent().appendingPathComponent("Profiles"))
        let profile = try profiles.create(provider: .claudeCode, named: "Work")
        var person = Data(#"{"claudeAiOauth":{"accessToken":"person","refreshToken":"one"}}"#.utf8)
        var work = Data(#"{"claudeAiOauth":{"accessToken":"work","refreshToken":"spent"}}"#.utf8)
        var items: [String] = []
        let secret = profiles.loginSecret(profile) { service, _ in
            items.append(service)
            return service == "Claude Code-credentials" ? person : work
        }
        let loginHome = profiles.loginHome(profile)
        try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: first, loginHome: loginHome, secret: secret)
        XCTAssertTrue(items.allSatisfy { $0.hasPrefix("Claude Code-credentials-") }, "\(items)")
        let copy = try WorkspaceMailbox(workspace: first, path: ".noodle/home/.claude").read(".credentials.json", limit: 4096)
        XCTAssertTrue(String(decoding: copy, as: UTF8.self).contains("work"))
        try RestrictedHarnessStorage.loginFailed(provider: .claudeCode, workspace: first)
        func refused() -> Bool {
            RestrictedHarnessStorage.refusedAgain(provider: .claudeCode, workspace: first, loginHome: loginHome, secret: secret)
        }
        XCTAssertTrue(refused())
        person = Data(#"{"claudeAiOauth":{"accessToken":"person-again","refreshToken":"two"}}"#.utf8)
        XCTAssertTrue(refused(), "The person's own sign-in is not the profile's")
        work = Data(#"{"claudeAiOauth":{"accessToken":"work-again","refreshToken":"three"}}"#.utf8)
        XCTAssertFalse(refused())
        try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: first, loginHome: loginHome, secret: secret)
        XCTAssertNil(RestrictedHarnessStorage.refusedUntil(provider: .claudeCode, workspace: first))
    }

    /// A bot keeps no copy of a login it no longer uses, such as the one the harness's CLI keeps,
    /// even when there is no new login yet to replace it.
    func testACopyOfAnotherLoginIsDroppedEvenWithNoLoginToReplaceIt() throws {
        let (root, workspace, _) = try fixture()
        let cli = root.appendingPathComponent("cli"), own = root.appendingPathComponent("own")
        try WorkspaceMailbox(workspace: try made(cli), path: ".codex", create: true).writeData(Data("cli-login".utf8), named: "auth.json")
        _ = try WorkspaceMailbox(workspace: try made(own), path: ".codex", create: true)
        try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: cli)
        let copy = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.codex")
        XCTAssertTrue(copy.contains("auth.json"))
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .codex, workspace: workspace, loginHome: own))
        XCTAssertFalse(copy.contains("auth.json"))
    }

    private func made(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAClaudeLoginIsDueHalfAnHourBeforeItExpires() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func login(expiresIn seconds: TimeInterval) -> Data {
            Data(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":\#(Int((now.timeIntervalSince1970 + seconds) * 1000))}}"#.utf8)
        }
        XCTAssertTrue(ClaudeLoginRefresh.isDue(login(expiresIn: 29 * 60), now: now))
        XCTAssertFalse(ClaudeLoginRefresh.isDue(login(expiresIn: 31 * 60), now: now))
        XCTAssertFalse(ClaudeLoginRefresh.isDue(Data(#"{"claudeAiOauth":{"accessToken":"a"}}"#.utf8), now: now), "Nothing to renew with")
    }

    /// Every bot would otherwise refresh in the same minute before the login expires, and only one can win.
    func testTheHostRenewsAClaudeLoginOnceAndEveryBotGetsIt() throws {
        let (home, first, second) = try fixture()
        let soon = Int((Date().timeIntervalSince1970 + 20 * 60) * 1000)
        let login = Data(#"{"claudeAiOauth":{"accessToken":"one","refreshToken":"r1","expiresAt":\#(soon)}}"#.utf8)
        let secret: (String, String) throws -> Data? = { _, _ in login }
        for workspace in [first, second] {
            try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: home, secret: secret)
        }
        // Stands in for Claude Code, which renews a login it finds about to expire when it starts.
        let claude = home.deletingLastPathComponent().appendingPathComponent("claude")
        try Data(#"""
            #!/bin/sh
            f="$CLAUDE_CONFIG_DIR/.credentials.json"
            [ "$CLAUDE_CONFIG_DIR" = "$HOME/.claude" ] || exit 1
            /usr/bin/grep -q '"refreshToken":"r1"' "$f" && printf '%s' '{"claudeAiOauth":{"accessToken":"two","refreshToken":"r2","expiresAt":1}}' > "$f"
            exec /bin/sleep 30
            """#.utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        XCTAssertTrue(try RestrictedHarnessStorage.refreshLogin(provider: .claudeCode, workspace: first) {
            ClaudeLoginRefresh.isDue($0) ? try ClaudeLoginRefresh.refresh($0, executable: claude, timeout: 10) : nil
        })
        for workspace in [first, second] {
            try RestrictedHarnessStorage.exchange(provider: .claudeCode, workspace: workspace, loginHome: home, secret: secret)
        }
        let b = try WorkspaceMailbox(workspace: second, path: ".noodle/home/.claude")
        XCTAssertTrue(String(decoding: try b.read(".credentials.json", limit: 4096), as: UTF8.self).contains("r2"))
        // A renewal that changes nothing is not passed on.
        XCTAssertFalse(try RestrictedHarnessStorage.refreshLogin(provider: .claudeCode, workspace: second) { _ in nil })
    }

    /// Claude Code saves a renewal to the Keychain first, through `security`. With the
    /// private home there is no keychain, so macOS asks the person to reset theirs, and the
    /// renewal may never reach the file. Bots cannot run `security` either.
    func testARenewalCannotReachTheKeychain() throws {
        let login = Data(#"{"claudeAiOauth":{"accessToken":"one","refreshToken":"r1","expiresAt":1}}"#.utf8)
        let claude = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID())")
        defer { try? FileManager.default.removeItem(at: claude) }
        try Data(#"""
            #!/bin/sh
            command -v security >/dev/null && exit 1
            printf '%s' '{"claudeAiOauth":{"accessToken":"two","refreshToken":"r2","expiresAt":1}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
            exec /bin/sleep 30
            """#.utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let renewed = try ClaudeLoginRefresh.refresh(login, executable: claude, timeout: 10)
        XCTAssertTrue(String(decoding: try XCTUnwrap(renewed), as: UTF8.self).contains("r2"))
    }

    /// Claude Code clears its login when a refresh is refused, as it is when another copy
    /// spent the token. That copy must never replace a working login, least of all the renewal
    /// that spent the token, which an exchange of the clearing bot would otherwise get to first.
    func testALoginClaudeCodeClearedNeverReplacesAWorkingOne() throws {
        let (home, first, second) = try fixture()
        let login = Data(#"{"claudeAiOauth":{"accessToken":"one","refreshToken":"r1","expiresAt":1800000000000}}"#.utf8)
        let secret: (String, String) throws -> Data? = { _, _ in login }
        for workspace in [first, second] {
            try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: home, secret: secret)
        }
        let a = try WorkspaceMailbox(workspace: first, path: ".noodle/home/.claude")
        let b = try WorkspaceMailbox(workspace: second, path: ".noodle/home/.claude")
        let renewed = Data(#"{"claudeAiOauth":{"accessToken":"two","refreshToken":"r2","expiresAt":1800028800000}}"#.utf8)
        let cleared = Data(#"{"claudeAiOauth":{"accessToken":"one","refreshToken":"","expiresAt":0}}"#.utf8)
        try a.writeData(renewed, named: ".credentials.json")
        try b.writeData(cleared, named: ".credentials.json")
        for workspace in [second, first, second] {
            try RestrictedHarnessStorage.exchange(provider: .claudeCode, workspace: workspace, loginHome: home, secret: secret)
        }
        XCTAssertEqual(try a.read(".credentials.json", limit: 4096), renewed)
        XCTAssertEqual(try b.read(".credentials.json", limit: 4096), renewed)

        // Alone, a cleared copy is not passed on either; its bot gets the shared login back.
        try b.writeData(cleared, named: ".credentials.json")
        for workspace in [second, first] {
            try RestrictedHarnessStorage.exchange(provider: .claudeCode, workspace: workspace, loginHome: home, secret: secret)
        }
        XCTAssertEqual(try a.read(".credentials.json", limit: 4096), renewed)
        XCTAssertEqual(try b.read(".credentials.json", limit: 4096), renewed)
    }

    func testALoginRefreshedInTheKeychainReachesRunningBotsWithoutARestart() throws {
        let (home, first, second) = try fixture()
        var login = Data(#"{"claudeAiOauth":{"accessToken":"first","refreshToken":"one"}}"#.utf8)
        let secret: (String, String) throws -> Data? = { _, _ in login }
        for workspace in [first, second] {
            try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: home, secret: secret)
        }
        // The person's own Claude Code refreshed, spending the token the bots hold.
        login = Data(#"{"claudeAiOauth":{"accessToken":"second","refreshToken":"two"}}"#.utf8)
        for workspace in [first, second] {
            try RestrictedHarnessStorage.exchange(provider: .claudeCode, workspace: workspace, loginHome: home, secret: secret)
            let copy = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.claude")
            XCTAssertTrue(String(decoding: try copy.read(".credentials.json", limit: 4096), as: UTF8.self).contains("second"))
        }
        // A bot's own refresh is still handed to the others while the item is unchanged.
        let a = try WorkspaceMailbox(workspace: first, path: ".noodle/home/.claude")
        let refreshed = Data(#"{"claudeAiOauth":{"accessToken":"bot","refreshToken":"three"}}"#.utf8)
        try a.writeData(refreshed, named: ".credentials.json")
        for workspace in [first, second] {
            try RestrictedHarnessStorage.exchange(provider: .claudeCode, workspace: workspace, loginHome: home, secret: secret)
        }
        let b = try WorkspaceMailbox(workspace: second, path: ".noodle/home/.claude")
        XCTAssertEqual(try b.read(".credentials.json", limit: 4096), refreshed)
    }

    func testABotsRefreshIsWrittenBackIntoTheKeychainItemOnlyWhenItIsSafe() throws {
        func oauth(_ data: Data) throws -> [String: String] {
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(payload["claudeAiOauth"] as? [String: String])
        }
        let (home, workspace, _) = try fixture()
        var item = Data(#"{"claudeAiOauth":{"accessToken":"first","refreshToken":"one"},"mcpOAuth":{"kept":"yes"}}"#.utf8)
        var writes: [(String, String, Data)] = []
        let secret: (String, String) throws -> Data? = { _, _ in item }
        let write: (String, String, Data) throws -> Void = { service, account, data in writes.append((service, account, data)); item = data }
        func exchange(writeBack: Bool = true) throws {
            try RestrictedHarnessStorage.exchange(provider: .claudeCode, workspace: workspace, loginHome: home, secret: secret,
                                                  writeSecret: writeBack ? write : nil)
        }
        try RestrictedHarnessStorage.prepare(provider: .claudeCode, workspace: workspace, loginHome: home, secret: secret)
        let copy = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.claude")

        // Where nobody may write the Keychain, a bot's refresh stays among the bots.
        try copy.writeData(Data(#"{"claudeAiOauth":{"accessToken":"hub","refreshToken":"hub"}}"#.utf8), named: ".credentials.json")
        try exchange(writeBack: false)
        XCTAssertTrue(writes.isEmpty)

        try copy.writeData(Data(#"{"claudeAiOauth":{"accessToken":"second","refreshToken":"two"}}"#.utf8), named: ".credentials.json")
        try exchange()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "Claude Code-credentials")
        XCTAssertEqual(writes.first?.1, NSUserName())
        XCTAssertEqual(try oauth(item), ["accessToken": "second", "refreshToken": "two"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: item) as? [String: Any])
        XCTAssertEqual(payload["mcpOAuth"] as? [String: String], ["kept": "yes"], "Only the Claude.ai login is replaced")
        try exchange()
        XCTAssertEqual(writes.count, 1, "The written login is not mistaken for a new sign-in")
        XCTAssertEqual(try oauth(copy.read(".credentials.json", limit: 4096)), ["accessToken": "second", "refreshToken": "two"])

        // Nothing malformed, or that kept the old refresh token, is written.
        for bad in [#"{"claudeAiOauth":{"accessToken":"third"}}"#, #"{"claudeAiOauth":{"accessToken":"third","refreshToken":"two"}}"#, "junk"] {
            try copy.writeData(Data(bad.utf8), named: ".credentials.json")
            try exchange()
        }
        XCTAssertEqual(writes.count, 1)

        // A new sign-in in the Keychain wins over a bot's refresh made from the old login.
        try copy.writeData(Data(#"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"three"}}"#.utf8), named: ".credentials.json")
        item = Data(#"{"claudeAiOauth":{"accessToken":"new-sign-in","refreshToken":"four"}}"#.utf8)
        try exchange()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(try oauth(copy.read(".credentials.json", limit: 4096))["accessToken"], "new-sign-in")
    }

    func testEveryCopiedLoginIsHandedBackAndNotOnlyCodex() throws {
        // Muse, FX and Antigravity rotate refresh tokens in their copies too.
        let cases: [(HarnessProvider, String, String, (String, String) throws -> Data?)] = [
            (.muse, ".config/muse", "auth.json", { _, _ in nil }),
            (.fx, ".fx", "auth.json", { _, _ in Data("fx-session".utf8) }),
            (.antigravity, ".gemini/antigravity-cli", "antigravity-oauth-token", { _, _ in Data("agy-login".utf8) }),
        ]
        for (provider, path, name, secret) in cases {
            let (home, first, second) = try fixture()
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let source = try WorkspaceMailbox(workspace: home, path: path, create: true)
            if provider == .muse {
                try source.writeData(Data(#"{"providers":{"meta":{"storage":"file","access_token":"one"}}}"#.utf8), named: "auth.json")
            }
            for workspace in [first, second] {
                try RestrictedHarnessStorage.prepare(provider: provider, workspace: workspace, loginHome: home, secret: secret)
            }
            let a = try WorkspaceMailbox(workspace: first, path: ".noodle/home/" + path)
            let b = try WorkspaceMailbox(workspace: second, path: ".noodle/home/" + path)
            try a.writeData(Data("refreshed-\(provider.rawValue)".utf8), named: name)
            try RestrictedHarnessStorage.prepare(provider: provider, workspace: first, loginHome: home, secret: secret)
            try RestrictedHarnessStorage.prepare(provider: provider, workspace: second, loginHome: home, secret: secret)
            XCTAssertEqual(try b.read(name, limit: 4096), Data("refreshed-\(provider.rawValue)".utf8), provider.rawValue)
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
