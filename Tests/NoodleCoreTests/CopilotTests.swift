import XCTest
@testable import NoodleCore

final class CopilotTests: XCTestCase {
    /// As a signed-in Copilot 1.0.116 answers session/new: Auto listed twice, once with plan details.
    private let session: [String: Any] = [
        "sessionId": "fixture-session", "privateAccount": "fixture-secret",
        "models": ["currentModelId": "auto", "availableModels": [
            ["modelId": "auto", "name": "Auto", "description": "Let Copilot pick the best model"],
            ["modelId": "auto", "name": "Auto", "description": "Auto", "_meta": ["copilotUsage": "1x"]],
            ["modelId": "claude-sonnet-5.5", "name": "Claude Sonnet 5.5"],
            ["modelId": "--unsafe"]
        ]]
    ]

    func testSignedInInspectionListsTheSessionsModelsOnceAndNothingPrivate() throws {
        let fixture = try peer(session: ["result": session])
        let result = try inspect(fixture)
        XCTAssertTrue(result.authenticated)
        XCTAssertEqual(result.executablePath, "/reported/copilot")
        XCTAssertEqual(result.models.map(\.id), ["auto", "claude-sonnet-5.5"])
        XCTAssertEqual(result.models.map(\.isDefault), [true, false])
        XCTAssertEqual(result.models.first?.description, "Let Copilot pick the best model")
        XCTAssertTrue(result.models.allSatisfy(\.supportedEfforts.isEmpty))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("fixture-secret"))
        XCTAssertEqual(try fixture.arguments, ["--acp"])
        XCTAssertEqual(try fixture.requests.compactMap { $0["method"] as? String }, ["initialize", "session/new"])
        XCTAssertEqual(try String(contentsOf: fixture.home.appendingPathComponent("auto-update"), encoding: .utf8), "false",
                       "Copilot must run the package in the executable that was verified, never one it downloaded.")
        try fixture.assertStopped()
    }

    func testSignedOutInspectionReportsNoModels() throws {
        let fixture = try peer(session: ["error": ["code": -32000, "message": "Authentication required"]])
        let result = try inspect(fixture)
        XCTAssertFalse(result.authenticated)
        XCTAssertTrue(result.models.isEmpty)
        try fixture.assertStopped()
    }

    func testOtherSessionFailuresAreErrorsWithoutTheHarnessesWords() throws {
        let fixture = try peer(session: ["error": ["code": -32603, "message": "fixture-secret"]])
        XCTAssertThrowsError(try inspect(fixture)) {
            XCTAssertTrue($0 is HarnessSetupError)
            XCTAssertFalse($0.localizedDescription.contains("fixture-secret"))
        }
        try fixture.assertStopped()
    }

    func testPublicInspectionRejectsUnsignedInstallationWithoutLaunchingIt() throws {
        let fixture = try InspectionProcessFixture(script: "exit 1")
        let installed = fixture.home.appendingPathComponent(".local/bin/copilot")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.executable, to: installed)
        XCTAssertThrowsError(try CopilotInspection.inspect(home: fixture.home, environment: fixture.environment)) {
            XCTAssertTrue($0.localizedDescription.contains("signature"))
        }
        XCTAssertFalse(fixture.wasLaunched)
        let missing = try CopilotInspection.inspect(home: fixture.home.appendingPathComponent("elsewhere"), environment: [:])
        XCTAssertNil(missing.executablePath)
    }

    func testOnlyTheOfficialInstallationWithoutRedirectsIsTrusted() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-trust-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        for path in ["/opt/homebrew/bin/copilot", home.appendingPathComponent("bin/copilot").path] {
            XCTAssertThrowsError(try CopilotExecutableTrust.executable(at: path, home: home)) {
                XCTAssertTrue($0.localizedDescription.contains("~/.local/bin/copilot"))
            }
        }
        let link = home.appendingPathComponent(".local/bin/copilot")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/usr/bin/true")
        XCTAssertThrowsError(try CopilotExecutableTrust.executable(at: link.path, home: home)) {
            XCTAssertTrue($0.localizedDescription.contains("without redirects"))
        }
    }

    /// The exact line `copilot login --device-code` prints; only GitHub's own page is offered.
    func testDeviceSignInOffersOnlyGitHubsPage() throws {
        let line = "To authenticate, visit https://github.com/login/device and enter code EF1E-7B5F\nWaiting for authorization...\n"
        let challenge = try XCTUnwrap(HarnessProfileLogin.challenge(provider: .copilot, text: line))
        XCTAssertEqual(challenge.url.absoluteString, "https://github.com/login/device")
        XCTAssertEqual(challenge.code, "EF1E-7B5F")
        XCTAssertNil(HarnessProfileLogin.challenge(provider: .copilot, text: "To authenticate, visit https://github.com/login/device and enter code EF1E"),
                     "A line still arriving is not read.")
        XCTAssertNil(HarnessProfileLogin.challenge(provider: .copilot,
            text: "To authenticate, visit https://github.com.example.com/login/device and enter code EF1E-7B5F\n"))
        XCTAssertNil(HarnessProfileLogin.challenge(provider: .copilot,
            text: "To authenticate, visit http://github.com/login/device and enter code EF1E-7B5F\n"))
        XCTAssertNotNil(HarnessProfileLogin.challenge(provider: .copilot, url: "https://github.com/login/device", code: "EF1E-7B5F"),
                        "The app accepts the same page when the Agent Host relays it.")
        XCTAssertEqual(HarnessProfileLogin.arguments(.copilot), ["login", "--device-code"])
    }

    func testSessionFailuresCopilotReports() {
        XCTAssertTrue(CopilotProtocol.authenticationRequired(["code": -32000, "message": "Authentication required"]))
        XCTAssertFalse(CopilotProtocol.authenticationRequired(["code": -32000, "message": "Something else"]))
        XCTAssertTrue(CopilotProtocol.missingSession(["code": -32002, "message": "Resource not found: Session abc not found"], sessionID: "abc"))
        XCTAssertFalse(CopilotProtocol.missingSession(["code": -32002, "message": "Resource not found: Session other not found"], sessionID: "abc"))
        XCTAssertTrue(HarnessProvider.copilot.recoversACPSessions)
    }

    /// The wordings people quote in github/copilot-cli issues #2336, #2696 and #2742, and the CLI's own.
    func testRateLimitsAreToldApartAndTheirResetRead() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hourly = "Error: 429 Sorry, you've hit a rate limit that restricts the number of Copilot model requests you can make within a specific time period. Please try again in 2 hours."
        XCTAssertTrue(CopilotProtocol.isUsageLimit(hourly))
        XCTAssertEqual(CopilotProtocol.usageLimitReset(hourly, now: now), now.addingTimeInterval(7200))
        let weekly = "Error: You've reached your weekly rate limit. Please wait for your limit to reset on April 19, 2026 at 9:00 PM or switch to auto model to continue."
        XCTAssertTrue(CopilotProtocol.isUsageLimit(weekly))
        let reset = try XCTUnwrap(CopilotProtocol.usageLimitReset(weekly, now: now))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reset)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 4, 19, 21, 0])
        XCTAssertTrue(CopilotProtocol.isUsageLimit("Error: You've hit the rate limit for this model. Please switch models or wait for your limit to reset"))
        XCTAssertNil(CopilotProtocol.usageLimitReset("Error: You've hit your rate limit. Please wait for your limit to reset", now: now))
        XCTAssertFalse(CopilotProtocol.isUsageLimit("Error: Execution failed: Model \"x\" is not available."))
        XCTAssertNil(CopilotProtocol.turnFailure(fromUpdate: ["sessionUpdate": "agent_message_chunk", "messageId": "m",
                                                              "content": ["type": "text", "text": hourly]]))
        XCTAssertEqual(CopilotProtocol.turnFailure(fromUpdate: ["sessionUpdate": "agent_message_chunk",
                                                                "content": ["type": "text", "text": hourly]]), hourly)
    }

    /// Copilot ignores DO_NOT_TRACK; its own switch was measured to stop its reports.
    func testReportsAreOffAndTheSiloAdmitsOnlyItsServices() {
        XCTAssertEqual(HarnessProvider.copilot.reportingOffEnvironment["COPILOT_TELEMETRY_DISABLED"], "true")
        XCTAssertEqual(HarnessProvider.copilot.reportingOffEnvironment["DO_NOT_TRACK"], "1")
        let allowed = HarnessProvider.copilot.siloAllowlist(appsEnabled: false)
        XCTAssertTrue(allowed.contains("api.individual.githubcopilot.com:443"))
        XCTAssertTrue(allowed.contains("api.github.com:443"))
        XCTAssertFalse(allowed.contains("telemetry.individual.githubcopilot.com:443"))
        XCTAssertFalse(allowed.contains("exp.individual.githubcopilot.com:443"))
        XCTAssertFalse(allowed.contains { $0.hasPrefix("*") })
        XCTAssertFalse(HarnessProvider.copilot.isOnByDefault)
    }

    func testReleaseRecipeMatchesGitHubsInstaller() throws {
        let copilot = try XCTUnwrap(HarnessDistribution(.copilot))
        let release = try XCTUnwrap(copilot.release(from: Data(#"{"tag_name":"v1.0.116"}"#.utf8)))
        XCTAssertEqual(release.version, "1.0.116")
        XCTAssertEqual(release.artifact.absoluteString,
                       "https://github.com/github/copilot-cli/releases/download/v1.0.116/copilot-darwin-arm64.tar.gz")
        XCTAssertEqual(release.checksums?.absoluteString, "https://github.com/github/copilot-cli/releases/download/v1.0.116/SHA256SUMS.txt")
        let sums = Data("\(String(repeating: "c", count: 64))  copilot-darwin-x64.tar.gz\n\(String(repeating: "A", count: 64))  copilot-darwin-arm64.tar.gz\n".utf8)
        XCTAssertEqual(copilot.expectation(release, sums)?.digest, String(repeating: "a", count: 64))
        XCTAssertNil(copilot.release(from: Data(#"{"tag_name":"v1.0.117","prerelease":true}"#.utf8)))
        XCTAssertTrue(copilot.allows(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1")!),
                      "GitHub serves release downloads from here.")
        XCTAssertEqual(copilot.executablePath, "copilot")
    }

    /// A profile's login stays in its own home, away from the person's Keychain; the package is unpacked once for all.
    func testProfileKeepsItsOwnLoginAndSharesTheUnpackedPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-profiles-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessProfileStore(root: root)
        let work = try store.create(provider: .copilot, named: "Work")
        let personal = try store.create(provider: .copilot, named: "Personal")
        let environment = store.environment(work)
        XCTAssertEqual(environment["HOME"], store.loginHome(work).path)
        XCTAssertEqual(store.accountHome(work), store.loginHome(work).appendingPathComponent(".copilot", isDirectory: true))
        XCTAssertEqual(environment["COPILOT_CACHE_HOME"], CopilotLaunch.cacheHome(root: root).path)
        XCTAssertEqual(environment["COPILOT_CACHE_HOME"], store.environment(personal)["COPILOT_CACHE_HOME"])
        XCTAssertNotEqual(environment["HOME"], store.environment(personal)["HOME"])
        XCTAssertEqual(environment["COPILOT_AUTO_UPDATE"], "false")
        // Out of reach of the Keychain, Copilot saves a sign-in only with this, and otherwise asks on a terminal it does not have.
        for profile in [work, personal] {
            let settings = try Data(contentsOf: store.accountHome(profile).appendingPathComponent("settings.json"))
            XCTAssertEqual(try JSONSerialization.jsonObject(with: settings) as? [String: Bool], ["storeTokenPlaintext": true])
        }
        try store.signOut(work, deleteSecret: { _, _ in })
        XCTAssertNoThrow(try Data(contentsOf: store.accountHome(work).appendingPathComponent("settings.json")),
                         "Signing out leaves the profile ready to sign in again")
    }

    /// A restricted bot gets a copy of the login and its own home, never the shared one.
    func testRestrictedBotGetsACopyOfTheLoginInItsOwnHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-restricted-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let workspace = repository.directory(for: try repository.createAgent(named: "Copilot").agent)
        let store = HarnessProfileStore(root: root)
        let profile = try store.defaultProfile(.copilot)
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .copilot, workspace: workspace,
                                                                  loginHome: store.loginHome(profile), secret: { _, _ in nil }),
                             "With no login there is nothing to run on.")
        let login = Data(#"{"loggedInUsers":[{"host":"https://github.com","login":"fixture"}]}"#.utf8)
        try login.write(to: store.accountHome(profile).appendingPathComponent("config.json"))
        try RestrictedHarnessStorage.prepare(provider: .copilot, workspace: workspace, loginHome: store.loginHome(profile),
                                             secret: { _, _ in nil })
        let privateHome = RestrictedHarnessStorage.home(workspace: workspace)
        XCTAssertEqual(try Data(contentsOf: privateHome.appendingPathComponent(".copilot/config.json")), login)
        let environment = try RestrictedAgentSandbox.environment(provider: .copilot, home: root, workspace: workspace)
        XCTAssertEqual(environment["HOME"], privateHome.path)
        XCTAssertEqual(environment["COPILOT_AUTO_UPDATE"], "false")
    }

    /// The package a restricted bot runs is readable to it and to nothing it may write.
    func testRestrictedBotReadsTheSharedPackageButCannotChangeIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-package-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let workspace = repository.directory(for: try repository.createAgent(named: "Copilot").agent)
        let package = CopilotLaunch.cacheHome(root: root).appendingPathComponent("pkg/darwin-arm64/1.0.116", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let policy = try RestrictedAgentSandbox.profile(provider: .copilot, workspace: workspace, repository: root, home: root,
            executable: URL(fileURLWithPath: "/usr/bin/true"), package: package, application: workspace, temporary: workspace)
        let quoted = "(subpath \"\(RestrictedAgentSandbox.sandboxPath(package.path))\")"
        XCTAssertEqual(policy.components(separatedBy: quoted).count - 1, 1, "Read once, and never in the writable list")
        let writes = try XCTUnwrap(policy.range(of: "(allow file-write*"))
        XCTAssertLessThan(try XCTUnwrap(policy.range(of: quoted)).lowerBound, writes.lowerBound)
    }

    /// Copilot checks certificates only through macOS's Security service, which also fronts the Keychain:
    /// the verified executable alone may reach it, never a tool it runs, and no other harness may.
    func testOnlyTheCopilotExecutableReachesTheSecurityService() throws {
        let executable = URL(fileURLWithPath: "/native/copilot")
        func policy(_ provider: HarnessProvider) throws -> String {
            try RestrictedAgentSandbox.profile(provider: provider, workspace: URL(fileURLWithPath: "/fixture/bot/workspace"),
                repository: URL(fileURLWithPath: "/fixture"), home: URL(fileURLWithPath: "/private-login"), executable: executable,
                application: URL(fileURLWithPath: "/app"), temporary: URL(fileURLWithPath: "/fixture/bot/workspace/tmp"))
        }
        let copilot = try policy(.copilot)
        let scoped = #"(allow mach-lookup (require-all (global-name "com.apple.SecurityServer") (process-path ""#
            + RestrictedAgentSandbox.sandboxPath(executable.path) + #"")))"#
        XCTAssertTrue(copilot.contains(scoped), copilot)
        XCTAssertEqual(copilot.components(separatedBy: "com.apple.SecurityServer").count - 1, 1, "Never granted unscoped")
        XCTAssertTrue(copilot.contains(#"(allow file-read-data (literal "/Library/Keychains/System.keychain"))"#))
        XCTAssertFalse(copilot.contains("login.keychain"))
        for provider in [HarnessProvider.claudeCode, .fx, .grokBuild, .muse, .openCode, .antigravity] {
            XCTAssertFalse(try policy(provider).contains("com.apple.SecurityServer"), provider.rawValue)
        }
    }

    /// `copilot --version` unpacks the package; the folder named after the version it reports is used.
    func testPackageIsTheUnpackedFolderOfTheReportedVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-unpack-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func executable(unpacks: Bool) throws -> URL {
            let url = root.appendingPathComponent("copilot-\(unpacks)")
            let unpack = unpacks ? #"mkdir -p "$COPILOT_CACHE_HOME/pkg/darwin-arm64/1.0.116" && touch "$COPILOT_CACHE_HOME/pkg/darwin-arm64/1.0.116/index.js""# : ":"
            try Data("#!/bin/sh\n[ \"$COPILOT_AUTO_UPDATE\" = false ] || exit 3\n\(unpack)\necho 'GitHub Copilot CLI 1.0.116.'\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let cache = CopilotLaunch.cacheHome(root: root)
        let package = try CopilotLaunch.package(executable: executable(unpacks: true), cacheHome: cache, environment: [:])
        XCTAssertEqual(package, cache.appendingPathComponent("pkg/darwin-arm64/1.0.116", isDirectory: true))
        try FileManager.default.removeItem(at: cache)
        XCTAssertThrowsError(try CopilotLaunch.package(executable: executable(unpacks: false), cacheHome: cache, environment: [:]))
    }

    /// Copilot keeps the signed-in GitHub login in its configuration file, which starts with comments.
    func testAccountNameIsTheSignedInLogin() {
        let config = """
        // User settings belong in settings.json.
        // This file is managed automatically.
        {
          "loggedInUsers": [{"host": "https://github.com", "login": "older", "kind": "githubDotCom"},
                            {"host": "https://github.com", "login": "fixture", "kind": "githubDotCom"}],
          "lastLoggedInUser": {"host": "https://github.com", "login": "fixture"},
          "authTokens": {"https://github.com:fixture": "fixture-secret"}
        }
        """
        XCTAssertEqual(CopilotProtocol.accountName(fromConfig: Data(config.utf8)), "fixture")
        let enterprise = #"{"lastLoggedInUser": {"host": "https://acme.ghe.com", "login": "fixture"}}"#
        XCTAssertEqual(CopilotProtocol.accountName(fromConfig: Data(enterprise.utf8)), "fixture on acme.ghe.com")
        let first = #"{"loggedInUsers": [{"host": "https://github.com", "login": "only"}]}"#
        XCTAssertEqual(CopilotProtocol.accountName(fromConfig: Data(first.utf8)), "only")
        XCTAssertNil(CopilotProtocol.accountName(fromConfig: Data(#"{"firstLaunchAt": "2026-07-24"}"#.utf8)))
        XCTAssertNil(CopilotProtocol.accountName(fromConfig: Data("not json".utf8)))
    }

    private func inspect(_ fixture: InspectionProcessFixture) throws -> CopilotInspectionResult {
        try CopilotInspection.inspect(executable: fixture.executable, installationPath: "/reported/copilot",
                                      environment: fixture.environment, requestTimeout: 3, terminationGrace: 0.2)
    }

    private func peer(session: [String: Any]) throws -> InspectionProcessFixture {
        try InspectionProcessFixture(script: """
        printf '%s' "$COPILOT_AUTO_UPDATE" > "$HOME/auto-update"
        read_request
        \(reply(1, ["result": ["protocolVersion": 1, "agentInfo": ["name": "Copilot"]]]))
        read_request
        \(reply(2, session))
        """)
    }

    private func reply(_ id: Int, _ payload: [String: Any]) throws -> String {
        try InspectionProcessFixture.emit(payload.merging(["jsonrpc": "2.0", "id": id]) { _, new in new })
    }
}
