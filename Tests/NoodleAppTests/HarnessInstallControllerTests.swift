import Foundation
import XCTest
@testable import NoodleCore
@testable import Noodle

@MainActor private final class InstallerFixture: HarnessInstalling {
    let store: ManagedHarnessStore
    var gate = RoutingGate<Void>()
    var calls = 0
    init(store: ManagedHarnessStore) { self.store = store }

    func manages(_ installation: HarnessInstallation) -> Bool { store.manages(installation) }

    func install(_ provider: HarnessProvider, progress: @escaping @MainActor (HarnessDownloadProgress) -> Void) async throws {
        calls += 1
        progress(.init(phase: .downloading, completedBytes: 1, totalBytes: 4))
        try await gate.value()
        let executable = store.directory.appendingPathComponent("\(provider.rawValue)/1.2.3/\(HarnessDistribution(provider)!.executablePath)")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func remove(_ provider: HarnessProvider) throws { try store.remove(provider) }
    func versions(_ provider: HarnessProvider) -> [String] { store.versions(provider).map(\.text) }
    func remove(_ provider: HarnessProvider, version: String) throws { try store.remove(provider, version: version) }
}

/// Reports the version folder as installed, 1.2.3 as the vendor's latest, and optionally refuses one version.
@MainActor private final class ManagedVersionFixture: HarnessVersionChecking {
    var incompatible: String?
    func check(_ installation: HarnessInstallation, previous: HarnessVersionReport?, forceLatest: Bool) async throws -> HarnessVersionReport {
        let installed = installation.executablePath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }
        return HarnessVersionReport(installedVersion: installed, latestVersion: "1.2.3",
                                    compatibilityIssue: installed == incompatible ? "FX does not support a command option required by Noodle." : nil)
    }
}

@MainActor private final class SignedOutProvider: HarnessSetupProviding {
    let installationGuide = HarnessInstallationGuide(command: nil, instructions: "", documentationURL: URL(string: "https://example.invalid")!)
    var statusGate: RoutingGate<HarnessAuthenticationStatus>?
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        if let gate = statusGate { statusGate = nil; return try await gate.value() }
        return .unauthenticated
    }
    func signIn(for installation: HarnessInstallation,
                onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus { .authenticated }
}

@MainActor final class HarnessInstallControllerTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var installer: InstallerFixture!
    private let versions = ManagedVersionFixture()
    private let claude = SignedOutProvider()
    private var controller: HarnessSetupController!
    private var runtime: AgentRuntimeCoordinator!
    private let clock = RuntimeClockFixture()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-install-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "noodle-install-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ManagedHarnessStore(root: root)
        installer = InstallerFixture(store: store)
        controller = HarnessSetupController(providers: [.fx: SignedOutProvider(), .claudeCode: claude], defaults: defaults, versionChecker: versions, installer: installer)
        // Simulation keeps the test away from this Mac's harnesses and the Agent Host.
        runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(homeDirectory: root, applicationsDirectory: root,
            executableSearchDirectories: [], applicationBundleURL: root, managedHarnesses: store,
            environment: ["NOODLE_SIMULATE_NO_HARNESSES": "1"]), defaults: defaults)
    }

    override func tearDown() async throws {
        controller.cancelAll()
        installer.gate.resolve(.failure(CancellationError()))
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testInstallShowsProgressThenTheHarnessAsNoodlesOwnAndChecksSignIn() async throws {
        XCTAssertTrue(controller.canInstall(.fx))
        XCTAssertFalse(controller.canInstall(.apple))
        controller.install(.fx, runtime: runtime)
        let operation = try XCTUnwrap(controller.operations[.fx])
        try await clock.waitUntil { self.controller.installProgress[.fx] != nil }
        XCTAssertEqual(controller.installProgress[.fx], 0.25)
        XCTAssertEqual(controller.activity[.fx], "Downloading…")
        controller.install(.fx, runtime: runtime)
        XCTAssertEqual(installer.calls, 1, "One install at a time.")

        installer.gate.resolve(.success(()))
        await operation.value
        XCTAssertNil(controller.activity[.fx]); XCTAssertNil(controller.installProgress[.fx]); XCTAssertNil(controller.operations[.fx])
        let installed = try XCTUnwrap(controller.snapshots[.fx]?.installation)
        XCTAssertTrue(installed.isAvailable)
        XCTAssertTrue(controller.isManaged(installed))
        XCTAssertEqual(controller.authentication[.fx], .unauthenticated)

        controller.removeManaged(.fx, runtime: runtime)
        try await clock.waitUntil { self.controller.snapshots[.fx]?.installation.isAvailable == false }
        XCTAssertNil(controller.errors[.fx])
    }

    /// Opening Settings starts a slow refresh that looked before a quick install
    /// finished. The install shows at once, and the earlier look cannot undo it.
    func testInstallFinishingDuringAnotherRefreshStillAppears() async throws {
        let existing = installer.store.directory.appendingPathComponent("claude-code/2.0.0/claude")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: existing.path)
        let held = RoutingGate<HarnessAuthenticationStatus>()
        claude.statusGate = held
        let opening = Task { await self.controller.refreshAll(self.runtime) }
        await fulfillment(of: [held.entered], timeout: 5)
        XCTAssertTrue(controller.refreshingAll)

        installer.gate.resolve(.success(()))
        controller.install(.fx, runtime: runtime)
        let operation = try XCTUnwrap(controller.operations[.fx])
        await operation.value
        XCTAssertTrue(controller.refreshingAll, "The install does not wait for the other harnesses.")
        XCTAssertEqual(controller.snapshots[.fx]?.installation.isAvailable, true)
        XCTAssertNil(controller.activity[.fx])
        held.resolve(.success(.authenticated))
        await opening.value
        XCTAssertEqual(controller.snapshots[.fx]?.installation.isAvailable, true, "The earlier refresh looked too soon to know.")
        XCTAssertEqual(runtime.installations.first { $0.provider == .fx }?.isAvailable, true)
    }

    private func placeInstalled(_ version: String) async throws {
        let executable = installer.store.directory.appendingPathComponent("fx/\(version)/fx")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        await runtime.refreshInstallations()
    }

    func testNoodlesOwnCopyIsUpdatedAutomaticallyUnlessTurnedOff() async throws {
        try await placeInstalled("1.2.2")
        installer.gate.resolve(.success(()))
        controller.automaticUpdates = false
        await controller.updateManagedHarnesses(runtime)
        XCTAssertEqual(installer.calls, 0)

        controller.automaticUpdates = true
        await controller.updateManagedHarnesses(runtime)
        await controller.operations[.fx]?.value
        XCTAssertEqual(installer.calls, 1)
        XCTAssertEqual(controller.snapshots[.fx]?.version?.installedVersion, "1.2.3")
        XCTAssertEqual(controller.snapshots[.fx]?.version?.updateAvailable, false)
        await controller.updateManagedHarnesses(runtime)
        XCTAssertEqual(installer.calls, 1, "Nothing newer to fetch.")
    }

    func testAnIncompatibleUpdateIsRolledBackAndNotFetchedAgain() async throws {
        try await placeInstalled("1.2.2")
        installer.gate.resolve(.success(()))
        versions.incompatible = "1.2.3"
        await controller.updateManagedHarnesses(runtime)
        await controller.operations[.fx]?.value
        XCTAssertEqual(installer.versions(.fx), ["1.2.2"])
        XCTAssertEqual(controller.snapshots[.fx]?.version?.installedVersion, "1.2.2")
        XCTAssertEqual(controller.errors[.fx], "FX 1.2.3 does not work with this version of Noodle. The previous version was kept.")
        await controller.updateManagedHarnesses(runtime)
        await controller.operations[.fx]?.value
        XCTAssertEqual(installer.calls, 1, "A rejected release is not downloaded every six hours.")
    }

    func testFailedInstallReportsTheErrorAndCanBeRetried() async throws {
        controller.install(.fx, runtime: runtime)
        let operation = try XCTUnwrap(controller.operations[.fx])
        installer.gate.resolve(.failure(HarnessSetupError("FX’s Vercel signature could not be verified.")))
        await operation.value
        XCTAssertEqual(controller.errors[.fx], "FX’s Vercel signature could not be verified.")
        await controller.refreshAll(runtime)
        XCTAssertEqual(controller.errors[.fx], "FX’s Vercel signature could not be verified.",
                       "Returning to the window refreshes; the reason must still be there.")
        XCTAssertNil(controller.activity[.fx])
        XCTAssertNotEqual(controller.snapshots[.fx]?.installation.isAvailable, true)

        installer.gate = RoutingGate<Void>()
        installer.gate.resolve(.success(()))
        controller.install(.fx, runtime: runtime)
        await controller.operations[.fx]?.value
        XCTAssertNil(controller.errors[.fx])
        XCTAssertEqual(controller.snapshots[.fx]?.installation.isAvailable, true)
    }

    func testCancelledInstallClearsTheRowWithoutAnError() async throws {
        controller.install(.fx, runtime: runtime)
        let operation = try XCTUnwrap(controller.operations[.fx])
        try await clock.waitUntil { self.controller.installProgress[.fx] != nil }
        controller.cancel(.fx)
        XCTAssertNil(controller.activity[.fx]); XCTAssertNil(controller.installProgress[.fx]); XCTAssertNil(controller.operations[.fx])
        installer.gate.resolve(.failure(CancellationError()))
        await operation.value
        XCTAssertNil(controller.errors[.fx])
        XCTAssertNotEqual(controller.snapshots[.fx]?.installation.isAvailable, true)
    }
}
