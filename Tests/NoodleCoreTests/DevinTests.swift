import XCTest
@testable import NoodleCore

final class DevinTests: XCTestCase {
    /// As a signed-in Devin 3000.15.14 answers session/new: models only as the "model" option, default as its value.
    private let session: [String: Any] = [
        "sessionId": "mewing-banana", "privateAccount": "fixture-secret",
        "configOptions": [
            ["id": "mode", "type": "select", "currentValue": "accept-edits",
             "options": [["value": "accept-edits", "name": "Code"], ["value": "bypass", "name": "Bypass Permissions"]]],
            ["id": "model", "type": "select", "currentValue": "swe-2-high", "options": [
                ["value": "adaptive", "name": "Adaptive", "_meta": ["cognition.ai/supportsImages": true]],
                ["value": "swe-2-high", "name": "SWE-2"],
                ["value": "claude-opus-5-5-medium", "name": "Claude Opus 5.5"],
                ["value": "swe-2-high", "name": "SWE-2"],
                ["value": "--unsafe", "name": "Unsafe"]
            ]]
        ]
    ]

    func testSignedInInspectionListsTheSessionsModelsOnceAndNothingPrivate() throws {
        let fixture = try peer(session: ["result": session])
        let result = try inspect(fixture)
        XCTAssertTrue(result.authenticated)
        XCTAssertEqual(result.executablePath, "/reported/devin")
        XCTAssertEqual(result.models.map(\.id), ["adaptive", "swe-2-high", "claude-opus-5-5-medium"])
        XCTAssertEqual(result.models.map(\.displayName), ["Adaptive", "SWE-2", "Claude Opus 5.5"])
        XCTAssertEqual(result.models.map(\.isDefault), [false, true, false])
        XCTAssertTrue(result.models.allSatisfy(\.supportedEfforts.isEmpty))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("fixture-secret"))
        XCTAssertEqual(try fixture.arguments, ["acp", "--process-model", "in-process"],
                       "Otherwise Devin hands the session to a background daemon that outlives the check.")
        XCTAssertEqual(try fixture.requests.compactMap { $0["method"] as? String }, ["initialize", "session/new"])
        try fixture.assertStopped()
    }

    /// Without a login Devin still opens a session, with no models in it; a rejected login refuses the session.
    func testSignedOutInspectionReportsNoModels() throws {
        let empty: [String: Any] = ["sessionId": "s", "configOptions": [["id": "model", "type": "select",
                                                                          "currentValue": "swe-1-6-fast", "options": []]]]
        for answer: [String: Any] in [["result": empty],
                                      ["error": ["code": -32000, "message": "Authentication failed: that API key was rejected"]]] {
            let fixture = try peer(session: answer)
            let result = try inspect(fixture)
            XCTAssertFalse(result.authenticated)
            XCTAssertTrue(result.models.isEmpty)
            try fixture.assertStopped()
        }
    }

    func testOtherSessionFailuresAreErrorsWithoutTheHarnessesWords() throws {
        let fixture = try peer(session: ["error": ["code": -32603, "message": "fixture-secret"]])
        XCTAssertThrowsError(try inspect(fixture)) {
            XCTAssertTrue($0 is HarnessSetupError)
            XCTAssertFalse($0.localizedDescription.contains("fixture-secret"))
        }
        try fixture.assertStopped()
    }

    /// Devin's own words: a session opened without a login fails at the prompt, a rejected login at session/new.
    func testSignInFailuresDevinReports() {
        XCTAssertTrue(DevinProtocol.authenticationRequired(["code": -32000,
            "message": "Please log in to use Devin. Use `/login` to authenticate again."]))
        XCTAssertTrue(DevinProtocol.authenticationRequired(["code": -32000,
            "message": "Authentication failed: that API key was rejected by the Windsurf API server: Invalid token"]))
        XCTAssertFalse(DevinProtocol.authenticationRequired(["code": -32000, "message": "Something else"]))
        XCTAssertFalse(DevinProtocol.authenticationRequired(["code": -32603, "message": "Please log in to use Devin."]))
        XCTAssertFalse(DevinProtocol.authenticationFailureDescription.contains("/login"))
    }

    /// A session Devin never ran a turn in is not saved, so it is gone after a restart; the bot opens a new one.
    func testAMissingSessionIsReplacedNotRecovered() {
        XCTAssertFalse(HarnessProvider.devin.recoversACPSessions)
    }

    func testPublicInspectionRejectsUnsignedInstallationWithoutLaunchingIt() throws {
        let fixture = try InspectionProcessFixture(script: "exit 1")
        let release = fixture.home.appendingPathComponent(".local/share/devin/cli/_versions/3000.15.14/bin/devin")
        try FileManager.default.createDirectory(at: release.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.executable, to: release)
        let link = fixture.home.appendingPathComponent(".local/bin/devin")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: release)
        XCTAssertThrowsError(try DevinInspection.inspect(home: fixture.home, environment: fixture.environment)) {
            XCTAssertTrue($0.localizedDescription.contains("signature"), $0.localizedDescription)
        }
        XCTAssertFalse(fixture.wasLaunched)
        let missing = try DevinInspection.inspect(home: fixture.home.appendingPathComponent("elsewhere"), environment: [:])
        XCTAssertNil(missing.executablePath)
    }

    /// Devin's installer links ~/.local/bin/devin to one version folder; nothing else is run.
    func testOnlyTheOfficialInstallationLayoutIsTrusted() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("devin-trust-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: home) }
        for path in ["/opt/homebrew/bin/devin", home.appendingPathComponent("bin/devin").path] {
            XCTAssertThrowsError(try DevinExecutableTrust.executable(at: path, home: home)) {
                XCTAssertTrue($0.localizedDescription.contains("~/.local/bin/devin"), $0.localizedDescription)
            }
        }
        let link = home.appendingPathComponent(".local/bin/devin")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let elsewhere = home.appendingPathComponent("elsewhere/bin/devin")
        let renamed = home.appendingPathComponent(".local/share/devin/cli/_versions/not-a-version/bin/devin")
        let release = home.appendingPathComponent(".local/share/devin/cli/_versions/3000.15.14/bin/devin")
        for target in [elsewhere, renamed, release] {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: target)
        }
        for target in [elsewhere, renamed] {
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try DevinExecutableTrust.executable(at: link.path, home: home)) {
                XCTAssertTrue($0.localizedDescription.contains("redirected"), $0.localizedDescription)
            }
        }
        // The installer's own layout reaches the signature check, which a stand-in fails.
        try FileManager.default.removeItem(at: link)
        let current = home.appendingPathComponent(".local/share/devin/cli/_versions/current")
        try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: "3000.15.14")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: current.appendingPathComponent("bin/devin"))
        XCTAssertThrowsError(try DevinExecutableTrust.executable(at: link.path, home: home)) {
            XCTAssertTrue($0.localizedDescription.contains("signature"), $0.localizedDescription)
        }
    }

    /// Sign-in is Devin's own ACP method, which opens the browser itself and replies once the person signed in.
    func testSignInRunsDevinsBrowserSignInAndWaitsForIt() throws {
        let fixture = try InspectionProcessFixture(script: """
        read_request
        \(reply(1, ["result": ["protocolVersion": 1, "authMethods": [["id": "devin-browser", "name": "Log in with browser"]]]]))
        read_request
        \(reply(2, ["result": [:]]))
        """)
        try DevinSignIn(executable: fixture.executable, environment: fixture.environment, timeout: 3).run()
        XCTAssertEqual(try fixture.arguments, ["acp", "--process-model", "in-process"])
        let requests = try fixture.requests
        XCTAssertEqual(requests.compactMap { $0["method"] as? String }, ["initialize", "authenticate"])
        XCTAssertEqual((requests.last?["params"] as? [String: Any])?["methodId"] as? String, "devin-browser")
        try fixture.assertStopped()
    }

    func testFailedSignInIsAnErrorWithoutTheHarnessesWords() throws {
        let fixture = try InspectionProcessFixture(script: """
        read_request
        \(reply(1, ["result": ["protocolVersion": 1]]))
        read_request
        \(reply(2, ["error": ["code": -32603, "message": "fixture-secret"]]))
        """)
        XCTAssertThrowsError(try DevinSignIn(executable: fixture.executable, environment: fixture.environment, timeout: 3).run()) {
            XCTAssertFalse($0.localizedDescription.contains("fixture-secret"))
        }
        try fixture.assertStopped()
    }

    /// Cancelling ends the sign-in Devin is waiting on, as when the person closes the sign-in sheet.
    func testCancelledSignInStopsDevin() throws {
        let fixture = try InspectionProcessFixture(script: """
        read_request
        \(reply(1, ["result": ["protocolVersion": 1]]))
        read_request
        """)
        let signIn = DevinSignIn(executable: fixture.executable, environment: fixture.environment, timeout: 30)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { signIn.cancel() }
        let started = Date()
        XCTAssertThrowsError(try signIn.run())
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        try fixture.assertStopped()
    }

    /// Devin has no switch for its reports, which go to the same service as its requests; the silo admits only that.
    func testTheSiloAdmitsOnlyItsService() {
        XCTAssertEqual(HarnessProvider.devin.siloAllowlist(appsEnabled: false), ["server.codeium.com:443"])
        XCTAssertEqual(HarnessProvider.devin.reportingOffEnvironment["DO_NOT_TRACK"], "1")
        XCTAssertFalse(HarnessProvider.devin.isOnByDefault)
        XCTAssertEqual(HarnessProvider.devin.displayName, "Devin")
    }

    func testReleaseRecipeMatchesDevinsInstaller() throws {
        let devin = try XCTUnwrap(HarnessDistribution(.devin))
        let release = try XCTUnwrap(devin.release(from: Data(#"{"version":"3000.15.14","platforms":{}}"#.utf8)))
        XCTAssertEqual(release.version, "3000.15.14")
        XCTAssertEqual(release.artifact.absoluteString,
                       "https://static.devin.ai/cli/3000.15.14/devin-3000.15.14-aarch64-apple-darwin.tar.gz")
        XCTAssertEqual(release.checksums?.absoluteString, "https://static.devin.ai/cli/3000.15.14/manifest.json")
        func manifest(version: String = "3000.15.14", url: String? = nil, digest: String = String(repeating: "A", count: 64)) -> Data {
            let artifact = url ?? release.artifact.absoluteString
            return Data(#"{"version":"\#(version)","platforms":{"x86_64-apple-darwin":{"url":"https://static.devin.ai/x","sha256":"\#(String(repeating: "c", count: 64))"},"aarch64-apple-darwin":{"url":"\#(artifact)","sha256":"\#(digest)"}}}"#.utf8)
        }
        XCTAssertEqual(devin.expectation(release, manifest())?.digest, String(repeating: "a", count: 64))
        XCTAssertNil(devin.expectation(release, manifest(version: "3000.15.13")), "A manifest for another version")
        XCTAssertNil(devin.expectation(release, manifest(url: "https://elsewhere.example/devin.tar.gz")),
                     "A manifest pointing elsewhere is a layout Noodle does not know")
        XCTAssertNil(devin.expectation(release, manifest(digest: "short")))
        XCTAssertNil(devin.release(from: Data(#"{"platforms":{}}"#.utf8)))
        XCTAssertEqual(devin.executablePath, "bin/devin")
        XCTAssertFalse(devin.allows(URL(string: "https://github.com/x")!))
    }

    /// Each profile keeps its own login and sessions in its own home, never updates Devin into it,
    /// and leaves out the plugins and MCP servers kept with the person's Devin account.
    func testProfileKeepsItsOwnLoginWithUpdatesAndAccountPluginsOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devin-profiles-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarnessProfileStore(root: root)
        let work = try store.create(provider: .devin, named: "Work")
        let personal = try store.create(provider: .devin, named: "Personal")
        XCTAssertEqual(store.environment(work)["HOME"], store.loginHome(work).path)
        XCTAssertNotEqual(store.environment(work)["HOME"], store.environment(personal)["HOME"])
        XCTAssertEqual(store.accountHome(work), store.loginHome(work).appendingPathComponent(".local/share/devin", isDirectory: true))
        func configuration(_ profile: HarnessProfile) throws -> [String: Any] {
            let data = try Data(contentsOf: store.loginHome(profile).appendingPathComponent(".config/devin/config.json"))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(try configuration(work)["auto_update"] as? Bool, false, "Devin would otherwise download a copy of itself into every login")
        XCTAssertEqual((try configuration(work)["read_config_from"] as? [String: Any])?["cloud"] as? Bool, false)
        try store.signOut(work, deleteSecret: { _, _ in })
        XCTAssertEqual(try configuration(work)["auto_update"] as? Bool, false, "Signing out leaves the profile ready to sign in again")
        XCTAssertEqual((try configuration(work)["read_config_from"] as? [String: Any])?["cloud"] as? Bool, false)
    }

    /// A restricted bot gets a copy of the login and its own home, with updates and account plugins off, never the shared one.
    /// Noodle's settings are put back at every start, keeping what Devin wrote beside them.
    func testRestrictedBotGetsACopyOfTheLoginInItsOwnHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devin-restricted-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let workspace = repository.directory(for: try repository.createAgent(named: "Devin").agent)
        let store = HarnessProfileStore(root: root)
        let profile = try store.defaultProfile(.devin)
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .devin, workspace: workspace,
                                                                  loginHome: store.loginHome(profile), secret: { _, _ in nil }),
                             "With no login there is nothing to run on.")
        let login = Data("windsurf_api_key = \"fixture\"\napi_server_url = \"https://server.codeium.com\"\n".utf8)
        try login.write(to: store.accountHome(profile).appendingPathComponent("credentials.toml"))
        try RestrictedHarnessStorage.prepare(provider: .devin, workspace: workspace, loginHome: store.loginHome(profile),
                                             secret: { _, _ in nil })
        let privateHome = RestrictedHarnessStorage.home(workspace: workspace)
        XCTAssertEqual(try Data(contentsOf: privateHome.appendingPathComponent(".local/share/devin/credentials.toml")), login)
        let file = privateHome.appendingPathComponent(".config/devin/config.json")
        func configuration() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]) }
        XCTAssertEqual(try configuration()["auto_update"] as? Bool, false)
        XCTAssertEqual((try configuration()["read_config_from"] as? [String: Any])?["cloud"] as? Bool, false)
        try Data(#"{"version": 1, "auto_update": true, "read_config_from": {"cloud": true, "claude": false}}"#.utf8).write(to: file)
        try RestrictedHarnessStorage.prepare(provider: .devin, workspace: workspace, loginHome: store.loginHome(profile),
                                             secret: { _, _ in nil })
        XCTAssertEqual(try configuration()["auto_update"] as? Bool, false)
        XCTAssertEqual(try configuration()["version"] as? Int, 1)
        XCTAssertEqual(try configuration()["read_config_from"] as? [String: Bool], ["cloud": false, "claude": false])
        let environment = try RestrictedAgentSandbox.environment(provider: .devin, home: root, workspace: workspace)
        XCTAssertEqual(environment["HOME"], privateHome.path)
    }

    /// Devin runs from its version folder, which a restricted bot may read but never change.
    func testRestrictedBotReadsItsVersionFolderButCannotChangeIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devin-package-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        let workspace = repository.directory(for: try repository.createAgent(named: "Devin").agent)
        let version = root.appendingPathComponent("home/.local/share/devin/cli/_versions/3000.15.14", isDirectory: true)
        let executable = version.appendingPathComponent("bin/devin")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(DevinLaunch.package(executable: executable), version)
        let policy = try RestrictedAgentSandbox.profile(provider: .devin, workspace: workspace, repository: root, home: root,
            executable: executable, package: DevinLaunch.package(executable: executable), application: workspace, temporary: workspace)
        let quoted = "(subpath \"\(RestrictedAgentSandbox.sandboxPath(version.path))\")"
        XCTAssertEqual(policy.components(separatedBy: quoted).count - 1, 1, "Read once, and never in the writable list")
        let writes = try XCTUnwrap(policy.range(of: "(allow file-write*"))
        XCTAssertLessThan(try XCTUnwrap(policy.range(of: quoted)).lowerBound, writes.lowerBound)
        XCTAssertFalse(policy.contains("com.apple.SecurityServer"))
    }

    /// As `devin auth status` 3000.15.14 prints it: the email names the account, and nothing else crosses.
    func testAccountNameIsTheEmailDevinReports() throws {
        let signedIn = """
        Logged in (via Devin).

        Credentials:
          File:              /fixture/.local/share/devin/credentials.toml
          API server:        https://server.codeium.com

        User:
          Name:              Fixture Person
          Email:             person@example.com
          User ID:           google-oauth2|fixture-secret

        Account:
          Tier:              Devin Pro
        """
        XCTAssertEqual(DevinProtocol.accountName(fromStatus: signedIn), "person@example.com")
        XCTAssertEqual(DevinProtocol.accountName(fromStatus: signedIn.replacingOccurrences(of: "  Email:             person@example.com\n", with: "")),
                       "Fixture Person", "Without an email, the name")
        XCTAssertNil(DevinProtocol.accountName(fromStatus: "Not logged in.\n  Credentials path: /fixture\nRun `devin auth login` to authenticate.\n"))
        XCTAssertNil(DevinProtocol.accountName(fromStatus: "Logged in (via Devin).\n"))

        let fixture = try InspectionProcessFixture(script: "printf '%s\\n' 'Logged in (via Devin).' '' 'User:' '  Email:             person@example.com'")
        XCTAssertEqual(try DevinInspection.accountName(executable: fixture.executable, environment: fixture.environment), "person@example.com")
        XCTAssertEqual(try fixture.arguments, ["auth", "status", "--process-model", "in-process"])
    }

    private func inspect(_ fixture: InspectionProcessFixture) throws -> DevinInspectionResult {
        try DevinInspection.inspect(executable: fixture.executable, installationPath: "/reported/devin",
                                    environment: fixture.environment, requestTimeout: 3, terminationGrace: 0.2)
    }

    private func peer(session: [String: Any]) throws -> InspectionProcessFixture {
        try InspectionProcessFixture(script: """
        read_request
        \(reply(1, ["result": ["protocolVersion": 1, "agentInfo": ["name": "affogato", "title": "Devin Agent"]]]))
        read_request
        \(reply(2, session))
        """)
    }

    private func reply(_ id: Int, _ payload: [String: Any]) throws -> String {
        try InspectionProcessFixture.emit(payload.merging(["jsonrpc": "2.0", "id": id]) { _, new in new })
    }
}
