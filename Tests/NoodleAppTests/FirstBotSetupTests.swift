import Foundation
import XCTest
@testable import NoodleCore
@testable import Noodle
@testable import NoodleRuntime

@MainActor private final class SetupInstaller: HarnessInstalling {
    let store: ManagedHarnessStore
    var calls = 0
    init(store: ManagedHarnessStore) { self.store = store }
    func manages(_ installation: HarnessInstallation) -> Bool { store.manages(installation) }
    func install(_ provider: HarnessProvider, progress: @escaping @MainActor (HarnessDownloadProgress) -> Void) async throws {
        calls += 1
        let executable = store.directory.appendingPathComponent("\(provider.rawValue)/1.0.0/\(HarnessDistribution(provider)!.executablePath)")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    func remove(_ provider: HarnessProvider) throws { try store.remove(provider) }
    func versions(_ provider: HarnessProvider) -> [String] { store.versions(provider).map(\.text) }
    func remove(_ provider: HarnessProvider, version: String) throws { try store.remove(provider, version: version) }
}

@MainActor private final class SetupAccount: HarnessSetupProviding {
    let installationGuide = HarnessInstallationGuide(command: nil, instructions: "", documentationURL: URL(string: "https://example.invalid")!)
    var signedIn = false
    var signIns = 0
    /// Why the next sign-in fails, as when the person closes the browser page.
    var failure: String?
    /// Why checking the sign-in fails, leaving it unknown.
    var statusFailure: String?
    /// Holds a sign-in open until the test cancels it, as a browser page left waiting does.
    var waits = false
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        if let statusFailure { throw HarnessSetupError(statusFailure) }
        return signedIn ? .authenticated : .unauthenticated
    }
    func signIn(for installation: HarnessInstallation,
                onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        signIns += 1
        if waits { try await Task.sleep(for: .seconds(60)) }
        if let failure { throw HarnessSetupError(failure) }
        signedIn = true
        return .authenticated
    }
}

@MainActor final class FirstBotSetupTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var installer: SetupInstaller!
    private let claude = SetupAccount(), codex = SetupAccount(), fx = SetupAccount()
    private var controller: HarnessSetupController!
    private var runtime: AgentRuntimeCoordinator!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-first-bot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "noodle-first-bot-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        let store = ManagedHarnessStore(root: root)
        installer = SetupInstaller(store: store)
        controller = HarnessSetupController(providers: [.claudeCode: claude, .codex: codex, .fx: fx], defaults: defaults, installer: installer)
        // Simulation keeps the test away from this Mac's harnesses and the Agent Host.
        runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(homeDirectory: root, applicationsDirectory: root,
            executableSearchDirectories: [], applicationBundleURL: root, managedHarnesses: store,
            environment: ["NOODLE_SIMULATE_NO_HARNESSES": "1"]), defaults: defaults)
    }

    override func tearDown() async throws {
        controller.cancelAll()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testAFreshMacIsOfferedTheFirstAccount() {
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        XCTAssertEqual(setup.readiness(.codex), .install)
        XCTAssertEqual(setup.preferred, .codex)
        XCTAssertTrue(setup.canContinue)
    }

    func testOnlyTheFourAccountsAreOffered() async throws {
        XCTAssertEqual(FirstBotSetup.featured, [.codex, .claudeCode, .muse, .grokBuild])
        // A harness set up outside the four is left to Settings, even when it is the one ready.
        fx.signedIn = true
        try await installer.install(.fx) { _ in }
        await controller.refreshAll(runtime)
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        XCTAssertEqual(setup.preferred, .codex)
    }

    func testAHarnessThatIsReadyGoesStraightToNamingTheBot() async throws {
        claude.signedIn = true
        try await installer.install(.claudeCode) { _ in }
        await controller.refreshAll(runtime)
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        XCTAssertEqual(setup.readiness(.claudeCode), .ready)
        XCTAssertEqual(setup.preferred, .claudeCode, "Ready beats the accounts listed before it.")
        setup.proceed()
        XCTAssertEqual(setup.step, .team)
        XCTAssertEqual(installer.calls, 1, "Nothing more is installed.")
    }

    func testEachAccountIsNamedWithItsMaker() {
        XCTAssertEqual(FirstBotSetup.featured.map(FirstBotSetup.accountName), ["Codex", "Claude", "Muse", "Grok"])
        XCTAssertEqual(FirstBotSetup.featured.map(FirstBotSetup.maker), ["OpenAI", "Anthropic", "Meta", "xAI"])
        XCTAssertNil(FirstBotSetup.accountName(.antigravity), "Only the featured accounts are offered by name.")
    }

    func testChoosingAMissingHarnessInstallsItThenSignsInWithoutAnotherClick() async throws {
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        setup.chosen = .claudeCode
        setup.proceed()
        XCTAssertEqual(setup.step, .prepare)
        XCTAssertTrue(setup.isBusy)
        await controller.operations[.claudeCode]?.value
        XCTAssertEqual(installer.calls, 1)
        XCTAssertEqual(setup.readiness(.claudeCode), .signIn)
        // The sheet calls this as the download finishes.
        setup.advanceIfReady()
        XCTAssertEqual(setup.step, .prepare, "Installed is not yet usable.")
        XCTAssertTrue(setup.isBusy, "Sign-in starts on its own.")
        await controller.operations[.claudeCode]?.value
        XCTAssertEqual(claude.signIns, 1)
        XCTAssertEqual(setup.readiness(.claudeCode), .ready)
        setup.advanceIfReady()
        XCTAssertEqual(setup.step, .team)
        XCTAssertEqual(setup.selection, .claudeCode)
    }

    func testChoosingAnInstalledHarnessThatIsSignedOutStartsSignIn() async throws {
        try await installer.install(.claudeCode) { _ in }
        await controller.refreshAll(runtime)
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        setup.chosen = .claudeCode
        XCTAssertEqual(setup.readiness(.claudeCode), .signIn)
        setup.proceed()
        XCTAssertEqual(setup.step, .prepare)
        await controller.operations[.claudeCode]?.value
        XCTAssertEqual(claude.signIns, 1)
        XCTAssertEqual(installer.calls, 1, "Nothing more is installed.")
        setup.advanceIfReady()
        XCTAssertEqual(setup.step, .team)
    }

    func testAFailedSignInIsNotRetriedUntilThePersonAsks() async throws {
        claude.failure = "Sign-in was cancelled."
        try await installer.install(.claudeCode) { _ in }
        await controller.refreshAll(runtime)
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        setup.chosen = .claudeCode
        setup.proceed()
        await controller.operations[.claudeCode]?.value
        setup.advanceIfReady()
        XCTAssertFalse(setup.isBusy)
        XCTAssertEqual(claude.signIns, 1, "A browser page closed on purpose does not reopen.")
        XCTAssertEqual(controller.errors[.claudeCode], "Sign-in was cancelled.")

        claude.failure = nil
        setup.signIn()
        await controller.operations[.claudeCode]?.value
        XCTAssertEqual(claude.signIns, 2)
        setup.advanceIfReady()
        XCTAssertEqual(setup.step, .team)
    }

    func testContinuingAgainAfterBackStartsSignInAgain() async throws {
        claude.failure = "Sign-in was cancelled."
        try await installer.install(.claudeCode) { _ in }
        await controller.refreshAll(runtime)
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        setup.chosen = .claudeCode
        setup.proceed()
        await controller.operations[.claudeCode]?.value
        setup.back()
        claude.failure = nil
        setup.proceed()
        await controller.operations[.claudeCode]?.value
        XCTAssertEqual(claude.signIns, 2)
        setup.advanceIfReady()
        XCTAssertEqual(setup.step, .team)
    }

    func testCancellingASignInWhoseStateIsUnknownLeavesItReadyToTryAgain() async throws {
        codex.statusFailure = "Codex did not answer."
        codex.waits = true
        try await installer.install(.codex) { _ in }
        await controller.refreshAll(runtime)
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        setup.chosen = .codex
        XCTAssertEqual(setup.readiness(.codex), .signIn)
        setup.proceed()
        XCTAssertTrue(setup.isBusy)
        XCTAssertNotEqual(setup.readiness(.codex), .checking, "Signing in is not checking.")
        setup.back()
        XCTAssertEqual(setup.readiness(.codex), .signIn, "Nothing is being checked once it is cancelled.")
        XCTAssertTrue(setup.canContinue)
    }

    func testChoosingAnAccountStartsItWithNoOtherClick() async throws {
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        setup.choose(.claudeCode)
        XCTAssertEqual(setup.selection, .claudeCode)
        XCTAssertEqual(setup.step, .prepare)
        XCTAssertTrue(setup.isBusy, "The download starts at once.")
        await controller.operations[.claudeCode]?.value
        setup.advanceIfReady()
        await controller.operations[.claudeCode]?.value
        setup.advanceIfReady()
        XCTAssertEqual(setup.step, .team)
    }

    func testBackReturnsToTheAccountsAndChoosingAgainStartsOver() async throws {
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        setup.choose(.codex)
        XCTAssertTrue(setup.isBusy)
        setup.back()
        XCTAssertEqual(setup.step, .harness)
        XCTAssertFalse(setup.isBusy)
        XCTAssertNil(controller.operations[.codex])
        setup.choose(.codex)
        XCTAssertEqual(setup.step, .prepare)
        XCTAssertTrue(setup.isBusy)
    }

    func testTheWelcomeIsOfferedOnceToSomeoneWithNoBots() throws {
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("storage"))
        try repository.prepare()
        let store = NoodleStore(repository: repository, runtime: runtime, connectsServices: false)
        addTeardownBlock { @MainActor in store.stopMonitoring() }
        store.offerFirstBotSetup(defaults: defaults)
        XCTAssertTrue(store.showsWelcome)
        store.finishFirstBotSetup(defaults: defaults)
        XCTAssertFalse(store.showsWelcome)
        store.offerFirstBotSetup(defaults: defaults)
        XCTAssertFalse(store.showsWelcome, "Not Now is remembered; the empty window still offers it.")
    }

    func testTheHelpMenuBringsTheWelcomeBackEvenWithBots() throws {
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("storage"))
        try repository.prepare()
        _ = try repository.createAgent(named: "Existing Bot")
        let store = NoodleStore(repository: repository, runtime: runtime, connectsServices: false)
        addTeardownBlock { @MainActor in store.stopMonitoring() }
        store.finishFirstBotSetup(defaults: defaults)
        store.showWelcome()
        XCTAssertTrue(store.showsWelcome)
    }

    func testSomeoneWithABotIsNotInterrupted() throws {
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("storage"))
        try repository.prepare()
        _ = try repository.createAgent(named: "Existing Bot")
        let store = NoodleStore(repository: repository, runtime: runtime, connectsServices: false)
        addTeardownBlock { @MainActor in store.stopMonitoring() }
        store.offerFirstBotSetup(defaults: defaults)
        XCTAssertFalse(store.showsWelcome)
    }
}
