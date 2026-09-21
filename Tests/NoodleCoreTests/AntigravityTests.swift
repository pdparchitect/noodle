import XCTest
@testable import NoodleCore

final class AntigravityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-antigravity-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testProviderIsDiscoveredAtGooglesInstallLocation() throws {
        XCTAssertEqual(HarnessProvider(rawValue: "antigravity"), .antigravity)
        XCTAssertEqual(HarnessProvider.antigravity.displayName, "Antigravity")
        XCTAssertTrue(HarnessProvider.antigravity.supportsRestrictedAccess)
        XCTAssertTrue(HarnessProvider.antigravity.supportsProfiles)
        XCTAssertFalse(HarnessProvider.antigravity.supportsAccountApps)

        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let discovery = HarnessDiscovery(homeDirectory: root, applicationsDirectory: root, executableSearchDirectories: [],
                                         applicationBundleURL: root, environment: [:])
        XCTAssertFalse(discovery.discover(.antigravity).isAvailable)
        let agy = bin.appendingPathComponent("agy")
        try Data("#!/bin/sh\n".utf8).write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
        XCTAssertEqual(discovery.discover(.antigravity).executablePath, agy.path)
    }

    func testTrustAcceptsOnlyTheUnredirectedOfficialPath() throws {
        XCTAssertThrowsError(try AntigravityExecutableTrust.executable(at: "/usr/local/bin/agy", home: root))
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("agy"), withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertThrowsError(try AntigravityExecutableTrust.executable(at: bin.appendingPathComponent("agy").path, home: root))
        // Apple's signature is not Google's.
        XCTAssertThrowsError(try AntigravityExecutableTrust.verifySignature(URL(fileURLWithPath: "/bin/sh")))
    }

    func testLaunchKeepsOneStreamingSessionAndResumesTheSavedConversation() throws {
        let fresh = try AntigravityProtocol.launchArguments(conversationID: nil, model: nil)
        XCTAssertEqual(fresh, ["--input-format", "stream-json", "--output-format", "stream-json",
                               "--dangerously-skip-permissions", "--print-timeout", "0s"])
        let id = UUID()
        let resumed = try AntigravityProtocol.launchArguments(conversationID: id, model: "gemini-3.8-flash-high")
        XCTAssertEqual(Array(resumed.suffix(4)), ["--conversation", id.uuidString.lowercased(), "--model", "gemini-3.8-flash-high"])
        XCTAssertThrowsError(try AntigravityProtocol.launchArguments(conversationID: nil, model: "--sandbox"))
        XCTAssertThrowsError(try AntigravityProtocol.launchArguments(conversationID: nil, model: "two words"))
    }

    func testPromptIsOneUserEventPerLine() throws {
        let data = AntigravityProtocol.userMessage("check\nmessages")
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "user")
        let content = (object["message"] as? [String: Any])?["content"] as? [[String: String]]
        XCTAssertEqual(content, [["type": "text", "text": "check\nmessages"]])
    }

    func testModelCatalogueComesFromTheTabSeparatedListing() throws {
        let listing = "gemini-3.8-flash-high\tGemini 3.8 Flash (High)\nclaude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)\n" +
            "gemini-3.8-flash-high\tDuplicate\n--bad\tRejected\nno-name\n\n"
        let models = AntigravityProtocol.models(from: listing)
        XCTAssertEqual(models.map(\.id), ["gemini-3.8-flash-high", "claude-sonnet-4-6"])
        XCTAssertEqual(models.map(\.displayName), ["Gemini 3.8 Flash (High)", "Claude Sonnet 4.6 (Thinking)"])
        XCTAssertEqual(models.map(\.isDefault), [true, false])
        XCTAssertTrue(models[0].supportedEfforts.isEmpty)
        XCTAssertTrue(AntigravityProtocol.models(from: "Fetching available models...\n").isEmpty)
    }

    func testStreamEventsNameTheConversationAndTheTurnOutcome() throws {
        func object(_ text: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let id = "8dd9b97a-fa4d-41e8-932b-b2446bfde88a"
        let initial = try object(#"{"event":"init","conversation_id":"\#(id)","init":{"cwd":"/w","tools":["run_command"],"permission_mode":"always-proceed"}}"#)
        XCTAssertEqual(AntigravityProtocol.conversationID(initialization: initial), UUID(uuidString: id))
        XCTAssertNil(AntigravityProtocol.conversationID(initialization: try object(#"{"event":"result","conversation_id":"\#(id)"}"#)))
        XCTAssertNil(AntigravityProtocol.conversationID(initialization: try object(#"{"event":"init","conversation_id":"not-a-uuid"}"#)))

        let done = try object(#"{"event":"result","result":{"conversation_id":"\#(id)","status":"SUCCESS","response":"hello\n","num_turns":2}}"#)
        XCTAssertEqual(AntigravityProtocol.turnResult(done), .init(succeeded: true, detail: nil))
        let failed = try object(#"{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"authentication failed or timed out"}}"#)
        XCTAssertEqual(AntigravityProtocol.turnResult(failed), .init(succeeded: false, detail: "authentication failed or timed out"))
        let interrupted = try object(#"{"event":"result","result":{"status":"INTERRUPTED","response":""}}"#)
        XCTAssertEqual(AntigravityProtocol.turnResult(interrupted), .init(succeeded: false, detail: nil))
        XCTAssertNil(AntigravityProtocol.turnResult(try object(#"{"event":"step_update","step_update":{"state":"DONE"}}"#)))
    }

    func testOnlyTheCLIsOwnSignInMessagesCountAsSignedOut() {
        XCTAssertTrue(AntigravityProtocol.isAuthenticationFailure("Error: authentication required. Run 'agy' to log in, then retry."))
        XCTAssertTrue(AntigravityProtocol.isAuthenticationFailure("Error: Please sign in to view available models. Launch the CLI without arguments to sign in."))
        XCTAssertTrue(AntigravityProtocol.isAuthenticationFailure("error getting token source: You are not logged into Antigravity."))
        XCTAssertFalse(AntigravityProtocol.isAuthenticationFailure("listen tcp 127.0.0.1:0: bind: operation not permitted"))
        XCTAssertFalse(AntigravityProtocol.isAuthenticationFailure(""))
    }

    func testKeychainLoginIsDecodedIntoTheFileLoginFormat() {
        let token = Data(#"{"refresh_token":"r"}"#.utf8)
        XCTAssertEqual(AntigravityProtocol.fileLogin(fromKeychain: Data(("go-keyring-base64:" + token.base64EncodedString()).utf8)), token)
        XCTAssertEqual(AntigravityProtocol.fileLogin(fromKeychain: token), token)
        XCTAssertNil(AntigravityProtocol.fileLogin(fromKeychain: Data("go-keyring-base64:%%%".utf8)))
        XCTAssertNil(AntigravityProtocol.fileLogin(fromKeychain: Data()))
    }

    func testKeychainLoginIsReadThroughTheToolThatWroteIt() throws {
        // The CLI's keyring library writes the item with /usr/bin/security, so only
        // that tool stays trusted. A direct read would prompt on every bot start.
        var calls: [[String]] = []
        let wrapped = "go-keyring-base64:" + Data(#"{"token":{}}"#.utf8).base64EncodedString()
        let secret = try RestrictedHarnessStorage.readSecret(service: "gemini", account: "antigravity") { arguments in
            calls.append(arguments)
            return (0, Data((wrapped + "\n").utf8))
        }
        XCTAssertEqual(calls, [["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]])
        XCTAssertEqual(secret.flatMap(AntigravityProtocol.fileLogin), Data(#"{"token":{}}"#.utf8))
        XCTAssertNil(try RestrictedHarnessStorage.readSecret(service: "gemini", account: "antigravity") { _ in (44, Data()) })
    }

    func testSessionStateFollowsTheConversationTheCLIReports() throws {
        let url = root.appendingPathComponent("runtime/antigravity-runtime.json")
        var state = AntigravitySessionState(url: url)
        XCTAssertNil(state.conversationID)
        let first = UUID(), replacement = UUID()
        try state.confirm(conversationID: first)
        XCTAssertEqual(AntigravitySessionState(url: url).conversationID, first)
        // An unknown conversation is silently replaced by the CLI; keep its answer.
        try state.confirm(conversationID: replacement)
        XCTAssertEqual(AntigravitySessionState(url: url).conversationID, replacement)
        try Data("{}".utf8).write(to: url)
        XCTAssertNil(AntigravitySessionState(url: url).conversationID)
    }

    func testVersionPolicyReadsGooglesManifestAndFlagHelp() {
        let manifest = Data(#"{"version":"1.2.7","url":"https://storage.googleapis.com/antigravity-public/antigravity-cli/1.2.7-1/darwin-arm/cli_mac_arm64.tar.gz","sha512":"ab"}"#.utf8)
        XCTAssertEqual(HarnessVersionPolicy.latestVersion(provider: .antigravity, data: manifest), "1.2.7")
        XCTAssertNil(HarnessVersionPolicy.latestVersion(provider: .antigravity, data: Data("1.2.7".utf8)))
        let installation = HarnessInstallation(provider: .antigravity, executablePath: "/Users/me/.local/bin/agy")
        XCTAssertEqual(HarnessVersionPolicy.latestURL(for: installation)?.host, "antigravity-cli-auto-updater-974169037036.us-central1.run.app")
        XCTAssertEqual(HarnessVersionPolicy.updateGuide(for: installation).command, "agy update")

        let help = "Usage of agy:\n  --conversation  Resume\n  --dangerously-skip-permissions  Auto-approve\n  --input-format  In\n  --output-format  Out\n"
        XCTAssertTrue(HarnessVersionPolicy.hasUsage(provider: .antigravity, help: help))
        XCTAssertNil(HarnessVersionPolicy.compatibilityIssue(provider: .antigravity, help: help))
        let old = "Usage of agy:\n  --output-format  Out\n"
        XCTAssertEqual(HarnessVersionPolicy.compatibilityIssue(provider: .antigravity, help: old)?.contains("--input-format"), true)
    }

    func testReleaseRecipeMatchesGooglesInstaller() throws {
        let distribution = try XCTUnwrap(HarnessDistribution(.antigravity))
        XCTAssertEqual(distribution.executablePath, "antigravity")
        let artifact = "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.2.7-6731160148115456/darwin-arm/cli_mac_arm64.tar.gz"
        let digest = String(repeating: "e2", count: 64)
        func manifest(version: String = "1.2.7", url: String = artifact, sha512: String = digest) -> Data {
            Data(#"{"version":"\#(version)","url":"\#(url)","sha512":"\#(sha512)"}"#.utf8)
        }
        let release = try XCTUnwrap(distribution.release(from: manifest()))
        XCTAssertEqual(release.version, "1.2.7")
        XCTAssertEqual(release.artifact.absoluteString, artifact)
        XCTAssertEqual(release.checksums, distribution.latest)
        XCTAssertTrue(distribution.allows(release.artifact))
        XCTAssertEqual(distribution.expectation(release, manifest()), .init(algorithm: .sha512, digest: digest, byteCount: nil))

        // The manifest may only name Google's own release bucket, and the second read must agree with the first.
        XCTAssertNil(distribution.release(from: manifest(url: "https://storage.googleapis.com/other-bucket/cli_mac_arm64.tar.gz")))
        XCTAssertNil(distribution.release(from: manifest(url: "https://example.com/antigravity-public/antigravity-cli/x.tar.gz")))
        XCTAssertNil(distribution.expectation(release, manifest(version: "1.2.8")))
        XCTAssertNil(distribution.expectation(release, manifest(url: artifact + "x")))
        XCTAssertNil(distribution.expectation(release, manifest(sha512: "abcd")))
    }

    func testProfileIsAPrivateHomeWithTheLoginInAFile() throws {
        let store = HarnessProfileStore(root: root)
        let profile = try store.create(provider: .antigravity, named: "Work")
        XCTAssertEqual(store.environment(profile), ["HOME": store.loginHome(profile).path])
        XCTAssertEqual(store.accountHome(profile).path, store.loginHome(profile).path + "/.gemini/antigravity-cli")
        XCTAssertEqual(try store.validated(profile.id), profile)
        XCTAssertNil(HarnessProfileLogin.arguments(.antigravity))
    }

    func testRestrictedBotReceivesOnlyTheLoginFile() throws {
        let layout = AgentStorageLayout(package: root.appendingPathComponent("agent"))
        try layout.create()
        let login = Data(#"{"refresh_token":"system"}"#.utf8)
        var asked: [String] = []
        try RestrictedHarnessStorage.prepare(provider: .antigravity, workspace: layout.workspace, loginHome: root) { service, account in
            asked.append(service + "/" + account)
            return Data(("go-keyring-base64:" + login.base64EncodedString()).utf8)
        }
        XCTAssertEqual(asked, ["gemini/antigravity"])
        let seeded = layout.workspace.appendingPathComponent(".noodle/home/.gemini/antigravity-cli/antigravity-oauth-token")
        XCTAssertEqual(try Data(contentsOf: seeded), login)

        // A profile's login is its file alone.
        let profileHome = root.appendingPathComponent("profile-home")
        let account = profileHome.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        try Data("profile-login".utf8).write(to: account.appendingPathComponent("antigravity-oauth-token"))
        try Data("{}".utf8).write(to: account.appendingPathComponent("settings.json"))
        try RestrictedHarnessStorage.prepare(provider: .antigravity, workspace: layout.workspace, loginHome: profileHome) { _, _ in nil }
        XCTAssertEqual(try Data(contentsOf: seeded), Data("profile-login".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.deletingLastPathComponent().appendingPathComponent("settings.json").path))

        let empty = root.appendingPathComponent("empty-home")
        try FileManager.default.createDirectory(at: empty.appendingPathComponent(".gemini/antigravity-cli"), withIntermediateDirectories: true)
        let other = AgentStorageLayout(package: root.appendingPathComponent("other"))
        try other.create()
        XCTAssertThrowsError(try RestrictedHarnessStorage.prepare(provider: .antigravity, workspace: other.workspace, loginHome: empty) { _, _ in nil })
    }

    func testRestrictedSandboxUsesAPrivateHomeAndLetsOnlyTheCLIListenLocally() throws {
        let layout = AgentStorageLayout(package: root.appendingPathComponent("agent"))
        try layout.create()
        try RestrictedHarnessStorage.prepare(provider: .antigravity, workspace: layout.workspace, loginHome: root) { _, _ in Data("login".utf8) }
        let home = RestrictedHarnessStorage.home(workspace: layout.workspace)
        XCTAssertEqual(try RestrictedAgentSandbox.environment(provider: .antigravity, home: root, workspace: layout.workspace),
                       ["HOME": home.path, "AGY_CLI_DISABLE_AUTO_UPDATE": "true"])
        let executable = root.appendingPathComponent(".local/bin/agy")
        let profile = try RestrictedAgentSandbox.profile(provider: .antigravity, workspace: layout.workspace, repository: root,
            home: root, executable: executable, application: root.appendingPathComponent("Noodle.app"),
            temporary: layout.workspace.appendingPathComponent(".noodle/tmp"))
        XCTAssertTrue(profile.contains("(deny default)"))
        XCTAssertTrue(profile.contains("(allow network-bind network-inbound"))
        XCTAssertTrue(profile.contains("(process-path \"\(RestrictedAgentSandbox.sandboxPath(executable.path))\")"))
        XCTAssertFalse(profile.contains("com.apple.SecurityServer"))
        XCTAssertEqual(layout.sessionState(provider: .antigravity, extendedAccess: false).lastPathComponent, "antigravity-runtime.json")
    }

    func testInspectionReportsSignInFromTheModelListing() throws {
        func fixture(_ body: String) throws -> URL {
            let url = root.appendingPathComponent("agy-\(UUID().uuidString)")
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        let signedIn = try fixture(#"[ "$1" = models ] || exit 9; echo "Fetching available models..." >&2; printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n'"#)
        let result = try AntigravityInspection.inspect(executable: signedIn, installationPath: "/x/agy", environment: [:])
        XCTAssertEqual(result.executablePath, "/x/agy")
        XCTAssertTrue(result.authenticated)
        XCTAssertEqual(result.models.map(\.id), ["gemini-3.8-flash-high"])

        let signedOut = try fixture(#"echo "Error: Please sign in to view available models. Launch the CLI without arguments to sign in." >&2; exit 1"#)
        let missing = try AntigravityInspection.inspect(executable: signedOut, installationPath: "/x/agy", environment: [:])
        XCTAssertFalse(missing.authenticated)
        XCTAssertTrue(missing.models.isEmpty)

        let broken = try fixture(#"echo "network unreachable token=secret" >&2; exit 1"#)
        XCTAssertThrowsError(try AntigravityInspection.inspect(executable: broken, installationPath: "/x/agy", environment: [:])) {
            XCTAssertFalse($0.localizedDescription.contains("secret"))
        }
        XCTAssertNil(try AntigravityInspection.inspect(home: root, environment: [:]).executablePath)
    }
}
