import Foundation
import XCTest
@testable import NoodleCore
@testable import Noodle

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
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus { signedIn ? .authenticated : .unauthenticated }
    func signIn(for installation: HarnessInstallation,
                onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        signedIn = true
        return .authenticated
    }
}

@MainActor final class FirstBotSetupTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var installer: SetupInstaller!
    private let claude = SetupAccount(), fx = SetupAccount()
    private var controller: HarnessSetupController!
    private var runtime: AgentRuntimeCoordinator!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-first-bot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "noodle-first-bot-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        let store = ManagedHarnessStore(root: root)
        installer = SetupInstaller(store: store)
        controller = HarnessSetupController(providers: [.claudeCode: claude, .fx: fx], defaults: defaults, installer: installer)
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

    func testAFreshMacIsOfferedAnInstallAndTheBuiltInHarnessIsNotPushed() {
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        XCTAssertEqual(setup.readiness(.codex), .install)
        XCTAssertEqual(setup.readiness(.apple), .unavailable, "Not bundled here, and Noodle cannot download it.")
        XCTAssertEqual(setup.preferred, .codex)
        XCTAssertTrue(setup.canContinue)
        setup.chosen = .apple
        XCTAssertFalse(setup.canContinue)
    }

    func testAHarnessThatIsReadyGoesStraightToNamingTheBot() async throws {
        fx.signedIn = true
        try await installer.install(.fx) { _ in }
        await controller.refreshAll(runtime)
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        XCTAssertEqual(setup.readiness(.fx), .ready)
        XCTAssertEqual(setup.preferred, .fx, "Ready beats the harnesses listed before it.")
        setup.proceed()
        XCTAssertEqual(setup.step, .bot)
        XCTAssertEqual(installer.calls, 1, "Nothing more is installed.")
    }

    func testChoosingAMissingHarnessInstallsItThenAsksForSignIn() async throws {
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        setup.chosen = .claudeCode
        setup.proceed()
        XCTAssertEqual(setup.step, .prepare)
        XCTAssertTrue(setup.isBusy)
        await controller.operations[.claudeCode]?.value
        XCTAssertEqual(installer.calls, 1)
        XCTAssertEqual(setup.readiness(.claudeCode), .signIn)
        setup.advanceIfReady()
        XCTAssertEqual(setup.step, .prepare, "Installed is not yet usable.")

        setup.signIn()
        await controller.operations[.claudeCode]?.value
        XCTAssertEqual(setup.readiness(.claudeCode), .ready)
        setup.advanceIfReady()
        XCTAssertEqual(setup.step, .bot)
        XCTAssertEqual(setup.selection, .claudeCode)
    }

    func testBackReturnsToTheListAndStopsWhatWasRunning() async throws {
        let setup = FirstBotSetup(setup: controller, runtime: runtime)
        setup.chosen = .fx
        setup.proceed()
        let operation = controller.operations[.fx]
        setup.back()
        XCTAssertEqual(setup.step, .harness)
        XCTAssertNil(controller.activity[.fx])
        await operation?.value
        setup.back()
        XCTAssertEqual(setup.step, .harness)
    }

    func testTheSheetIsOfferedOnceToSomeoneWithNoBots() throws {
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("storage"))
        try repository.prepare()
        let store = NoodleStore(repository: repository, runtime: runtime, connectsServices: false)
        addTeardownBlock { @MainActor in store.stopMonitoring() }
        store.offerFirstBotSetup(defaults: defaults)
        XCTAssertTrue(store.showsFirstBotSetup)
        store.finishFirstBotSetup(defaults: defaults)
        XCTAssertFalse(store.showsFirstBotSetup)
        store.offerFirstBotSetup(defaults: defaults)
        XCTAssertFalse(store.showsFirstBotSetup, "Not Now is remembered; the empty window still offers it.")
    }

    func testSomeoneWithABotIsNotInterrupted() throws {
        let repository = WorkspaceRepository(rootURL: root.appendingPathComponent("storage"))
        try repository.prepare()
        _ = try repository.createAgent(named: "Existing Bot")
        let store = NoodleStore(repository: repository, runtime: runtime, connectsServices: false)
        addTeardownBlock { @MainActor in store.stopMonitoring() }
        store.offerFirstBotSetup(defaults: defaults)
        XCTAssertFalse(store.showsFirstBotSetup)
    }
}
