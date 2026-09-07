import XCTest
@testable import NoodleCore

final class HarnessSetupTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-setup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testAccountStates() throws {
        XCTAssertEqual(try CodexAccountResponse.status(["account": ["type": "chatgpt"], "requiresOpenaiAuth": true]), .authenticated)
        XCTAssertEqual(try CodexAccountResponse.status(["account": ["type": "apiKey"]]), .authenticated)
        XCTAssertEqual(try CodexAccountResponse.status(["account": NSNull(), "requiresOpenaiAuth": true]), .unauthenticated)
        XCTAssertEqual(try CodexAccountResponse.status(["account": NSNull(), "requiresOpenaiAuth": false]), .notRequired)
    }

    func testUnsupportedAccountResponseIsNotTreatedAsSignedOut() {
        XCTAssertThrowsError(try CodexAccountResponse.status([:]))
        XCTAssertThrowsError(try CodexAccountResponse.status(["account": NSNull()]))
        XCTAssertThrowsError(try CodexAccountResponse.status(["account": "unexpected", "requiresOpenaiAuth": true]))
    }

    func testSignInURLMustBeOfficialHTTPSDeviceEndpoint() throws {
        let valid: [String: Any] = ["type": "chatgptDeviceCode", "verificationUrl": "https://auth.openai.com/codex/device", "userCode": "TEST-1234"]
        XCTAssertEqual(try CodexAccountResponse.challenge(valid).code, "TEST-1234")
        for url in ["http://auth.openai.com/codex/device", "https://example.com/codex/device", "https://auth.openai.com.evil.test/codex/device", "https://auth.openai.com/other", "https://user@auth.openai.com/codex/device"] {
            var result = valid
            result["verificationUrl"] = url
            XCTAssertThrowsError(try CodexAccountResponse.challenge(result))
        }
    }

    @MainActor func testOfficialInstallationGuide() {
        let guide = CodexSetupProvider(codexHome: root).installationGuide
        XCTAssertEqual(guide.command, "curl -fsSL https://chatgpt.com/codex/install.sh | sh")
        XCTAssertEqual(guide.documentationURL.host, "learn.chatgpt.com")
    }

    func testExternalInstallCheckNeverEnablesBundledFallbackInDebug() throws {
        let bundled = root.appendingPathComponent("ChatGPT.app/Contents/Resources/codex")
        let external = root.appendingPathComponent(".codex/packages/standalone/current/bin/codex")
        for url in [bundled, external] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        var discovery = HarnessDiscovery(homeDirectory: root, applicationsDirectory: root,
            executableSearchDirectories: [], environment: ["NOODLE_SIMULATE_NO_HARNESSES": "1"])
        #if DEBUG
        XCTAssertFalse(discovery.discover(.codex).isAvailable)
        discovery.checkExternalInstallationDuringSimulation(.codex)
        XCTAssertEqual(discovery.discover(.codex).executablePath, external.path)
        try FileManager.default.removeItem(at: external)
        XCTAssertFalse(discovery.discover(.codex).isAvailable)
        #else
        XCTAssertEqual(discovery.discover(.codex).executablePath, external.path)
        #endif
    }

    func testExtendedHostRejectsArbitraryOrUnsignedExecutable() throws {
        XCTAssertThrowsError(try CodexExecutableTrust.executable(at: "/bin/sh", home: root))
        let executable = root.appendingPathComponent(".local/bin/codex")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not signed".utf8).write(to: executable)
        XCTAssertThrowsError(try CodexExecutableTrust.executable(at: executable.path, home: root))
        XCTAssertThrowsError(try ClaudeExecutableTrust.executable(at: "/bin/sh", home: root))
    }

    func testOfficialClaudeCodeNativeInstallWhenFixtureProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_TEST_CLAUDE_EXECUTABLE"] else {
            throw XCTSkip("Set NOODLE_TEST_CLAUDE_EXECUTABLE to the official native Claude Code link.")
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let executable = try ClaudeExecutableTrust.executable(at: path, home: home)
        XCTAssertEqual(executable.deletingLastPathComponent().lastPathComponent, "versions")
    }

    @MainActor func testStatusUsesAccountRPCWithoutStartingATurn() async throws {
        let executable = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/sh
        IFS= read -r line
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r line
        IFS= read -r line
        case "$line" in
          *account*read*) printf '%s\\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}' ;;
          *) exit 2 ;;
        esac
        while IFS= read -r line; do :; done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let provider = CodexSetupProvider(codexHome: root)
        let status = try await provider.status(for: HarnessInstallation(provider: .codex, executablePath: executable.path))
        XCTAssertEqual(status, .unauthenticated)
    }

    @MainActor func testMissingInstallationDoesNotStartAccountProcess() async {
        let provider = CodexSetupProvider(codexHome: root)
        do {
            _ = try await provider.status(for: HarnessInstallation(provider: .codex, executablePath: nil))
            XCTFail("Expected missing installation error")
        } catch { XCTAssertEqual(error.localizedDescription, "Install the harness first.") }
    }

    @MainActor func testSignInCompletionRechecksAccountAndIgnoresOtherLoginIDs() async throws {
        let executable = try makeSignInHarness(completes: true)
        let provider = CodexSetupProvider(codexHome: root)
        var displayedCode: String?
        let status = try await provider.signIn(for: HarnessInstallation(provider: .codex, executablePath: executable.path)) {
            displayedCode = $0.code
        }
        XCTAssertEqual(displayedCode, "TEST-1234")
        XCTAssertEqual(status, .authenticated)
    }

    @MainActor func testWaitingSignInCanBeCancelled() async throws {
        let executable = try makeSignInHarness(completes: false)
        let provider = CodexSetupProvider(codexHome: root)
        let displayed = expectation(description: "Device code displayed")
        let operation = Task {
            try await provider.signIn(for: HarnessInstallation(provider: .codex, executablePath: executable.path)) { _ in displayed.fulfill() }
        }
        await fulfillment(of: [displayed], timeout: 5)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testRealCodexReportsSignedOutForAnEmptyAccountHomeWhenFixtureProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_TEST_CODEX_EXECUTABLE"] else {
            throw XCTSkip("Set NOODLE_TEST_CODEX_EXECUTABLE to a verified Codex binary to check real account RPC.")
        }
        try CodexExecutableTrust.verifySignature(URL(fileURLWithPath: path), identifier: "codex")
        let provider = CodexSetupProvider(codexHome: root)
        let status = try await provider.status(for: HarnessInstallation(provider: .codex, executablePath: path))
        XCTAssertEqual(status, .unauthenticated)
    }

    func testOfficialStandaloneSymlinksAndExtendedTrustWhenFixtureProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["NOODLE_TEST_INSTALLED_HOME"] else {
            throw XCTSkip("Set NOODLE_TEST_INSTALLED_HOME to a temporary home populated by the official installer.")
        }
        let home = URL(fileURLWithPath: path)
        let discovery = HarnessDiscovery(homeDirectory: home, applicationsDirectory: root,
            executableSearchDirectories: [], environment: [:])
        let installation = discovery.discover(.codex)
        let executable = try XCTUnwrap(installation.executablePath)
        XCTAssertTrue(executable.hasSuffix("/.codex/packages/standalone/current/bin/codex"))
        let trusted = try CodexExecutableTrust.executable(at: executable, home: home)
        XCTAssertEqual(trusted, URL(fileURLWithPath: executable).resolvingSymlinksInPath())
        let shellCommand = home.appendingPathComponent(".local/bin/codex")
        XCTAssertEqual(try CodexExecutableTrust.executable(at: shellCommand.path, home: home), trusted)
    }

    private func makeSignInHarness(completes: Bool) throws -> URL {
        let executable = root.appendingPathComponent("fake-login-codex")
        let script = #"""
        #!/bin/sh
        signed_in=0
        while IFS= read -r line; do
          case "$line" in
            *account*read*)
              if [ "$signed_in" = 1 ]; then
                printf '%s\n' '{"id":2,"result":{"account":{"type":"chatgpt"},"requiresOpenaiAuth":true}}'
              else
                printf '%s\n' '{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}'
              fi ;;
            *account*login*start*)
              printf '%s\n' '{"id":3,"result":{"type":"chatgptDeviceCode","loginId":"test-login","verificationUrl":"https://auth.openai.com/codex/device","userCode":"TEST-1234"}}'
              printf '%s\n' '{"method":"account/login/completed","params":{"loginId":"unrelated","success":false}}'
              if [ "\#(completes ? "yes" : "no")" = yes ]; then
                signed_in=1
                printf '%s\n' '{"method":"account/login/completed","params":{"loginId":"test-login","success":true}}'
              fi ;;
            *'"id":1'*) printf '%s\n' '{"id":1,"result":{}}' ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

}
