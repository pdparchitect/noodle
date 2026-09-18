import Foundation
import XCTest
@testable import NoodleCore
@testable import Noodle

@MainActor private final class SetupProviderFixture: HarnessSetupProviding {
    let installationGuide = HarnessInstallationGuide(command: nil, instructions: "Fixture instructions", documentationURL: URL(string: "https://example.invalid/setup")!)
    var statusResult: HarnessAuthenticationStatus = .unauthenticated
    var statusError: Error?
    var statusGate: RoutingGate<HarnessAuthenticationStatus>?
    var statusCalls: [HarnessInstallation] = []
    var signIns: [(HarnessInstallation, (HarnessSignInChallenge) -> Void, RoutingGate<HarnessAuthenticationStatus>)] = []
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus {
        statusCalls.append(installation)
        if let gate = statusGate { statusGate = nil; return try await gate.value() }
        if let statusError { throw statusError }
        return statusResult
    }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus {
        let gate = RoutingGate<HarnessAuthenticationStatus>()
        signIns.append((installation, onChallenge, gate))
        return try await gate.value()
    }
    func cleanUp() { statusGate?.resolve(.failure(CancellationError())); signIns.forEach { $0.2.resolve(.failure(CancellationError())) } }
}

@MainActor private final class SetupVersionFixture: HarnessVersionChecking {
    var gate: RoutingGate<HarnessVersionReport>?
    var error: Error?
    var calls: [(HarnessInstallation, HarnessVersionReport?, Bool)] = []
    var report = HarnessVersionReport(installedVersion: "2.0.0", latestVersion: "3.0.0")
    func check(_ installation: HarnessInstallation, previous: HarnessVersionReport?, forceLatest: Bool) async throws -> HarnessVersionReport {
        calls.append((installation, previous, forceLatest))
        if let gate { self.gate = nil; return try await gate.value() }
        if let error { throw error }; return report
    }
}

@MainActor private final class SetupControllerFixture {
    let installation = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
    let claude = HarnessInstallation(provider: .claudeCode, executablePath: "/fixtures/claude")
    let suite = "noodle-setup-\(UUID())"
    let defaults: UserDefaults
    let provider = SetupProviderFixture(), other = SetupProviderFixture(), versions = SetupVersionFixture()
    let controller: HarnessSetupController
    let clock = RuntimeClockFixture()
    var gates: [RoutingGate<HarnessAuthenticationStatus>] = []
    init() {
        defaults = UserDefaults(suiteName: suite)!
        HarnessPresentationCache.save([.codex: .init(installation: installation, authentication: .authenticated,
            version: .init(installedVersion: "1.0.0", latestVersion: "2.0.0"))], to: defaults)
        controller = HarnessSetupController(providers: [.codex: provider, .claudeCode: other], defaults: defaults, versionChecker: versions)
    }
    func heldStatus() -> RoutingGate<HarnessAuthenticationStatus> {
        let gate = RoutingGate<HarnessAuthenticationStatus>(); gates.append(gate); provider.statusGate = gate; return gate
    }
    var challenge: HarnessSignInChallenge { .init(url: URL(string: "https://example.invalid/login")!, code: "TEST-ONLY") }
    func cleanUp() {
        controller.cancelAll(); provider.cleanUp(); other.cleanUp()
        gates.forEach { $0.resolve(.failure(CancellationError())) }; versions.gate?.resolve(.failure(CancellationError()))
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor final class HarnessSetupControllerTests: XCTestCase {
    private func fixture() -> SetupControllerFixture {
        let f = SetupControllerFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }
    func testNeedsAttentionCoversUpdatesCompatibilityAndErrorsButNotMissingOrSignedOutHarnesses() async {
        let f = fixture(), c = f.controller
        XCTAssertTrue(c.needsAttention(.codex), "The cached report has a newer release")
        XCTAssertFalse(c.needsAttention(.claudeCode), "An unchecked harness is not a warning")
        f.versions.report = .init(installedVersion: "3.0.0", latestVersion: "3.0.0")
        await c.refreshVersions([f.installation])
        XCTAssertFalse(c.needsAttention(.codex))
        f.versions.report = .init(installedVersion: "3.0.0", latestVersion: "3.0.0", compatibilityIssue: "Missing protocol")
        await c.refreshVersions([f.installation])
        XCTAssertTrue(c.needsAttention(.codex))
        // A failed latest-release lookup alone is not actionable.
        f.versions.report = .init(installedVersion: "3.0.0", checkError: "Offline")
        await c.refreshVersions([f.installation])
        XCTAssertFalse(c.needsAttention(.codex))
        await c.refresh([f.claude])
        XCTAssertEqual(c.authentication[.claudeCode], .unauthenticated)
        XCTAssertFalse(c.needsAttention(.claudeCode), "Sign-in required is shown as neutral status")
        await c.refresh([.init(provider: .claudeCode, executablePath: nil)])
        XCTAssertFalse(c.needsAttention(.claudeCode), "Not installed is not a warning")
        f.provider.statusError = HarnessSetupError("Account unavailable")
        await c.refresh([.init(provider: .codex, executablePath: "/fixtures/codex-2")])
        XCTAssertTrue(c.needsAttention(.codex))
    }

    func testCachedPresentationSurvivesDiscoveryAndAccountCheckFailures() async {
        let f = fixture(), c = f.controller, before = c.snapshots
        await c.refresh([.init(provider: .codex, executablePath: nil)], discoveryErrors: [.codex: "Discovery unavailable"])
        XCTAssertEqual(c.snapshots, before); XCTAssertEqual(f.provider.statusCalls.count, 0)
        f.provider.statusError = HarnessSetupError("Account unavailable")
        await c.refresh([f.installation])
        XCTAssertEqual(c.authentication[.codex], .authenticated)
        XCTAssertEqual(c.snapshots, before); XCTAssertEqual(c.errors[.codex], "Account unavailable")
        XCTAssertEqual(c.installationGuide(for: .codex), f.provider.installationGuide)
        XCTAssertEqual(c.displayedInstallations.count, HarnessProvider.allCases.count)
    }

    func testConfirmedUninstallationClearsAuthenticationAndCachedVersion() async {
        let f = fixture(), removed = HarnessInstallation(provider: .codex, executablePath: nil)
        await f.controller.refresh([removed])
        XCTAssertEqual(f.controller.snapshots[.codex]?.installation, removed)
        XCTAssertNil(f.controller.authentication[.codex]); XCTAssertNil(f.controller.snapshots[.codex]?.version)
        XCTAssertEqual(HarnessPresentationCache.load(from: f.defaults), f.controller.snapshots)
    }

    func testDuplicateStatusRefreshUsesSingleProviderCall() async {
        let f = fixture(), gate = f.heldStatus()
        let first = Task { await f.controller.refresh([f.installation]) }
        await fulfillment(of: [gate.entered], timeout: 2)
        await f.controller.refresh([f.installation])
        XCTAssertEqual(f.provider.statusCalls.count, 1)
        gate.resolve(.success(.authenticated)); await first.value
        XCTAssertTrue(f.controller.checking.isEmpty)
    }

    func testStatusStartedBeforeSignInCannotOverwriteSuccessfulAuthentication() async throws {
        let f = fixture(), gate = f.heldStatus(), c = f.controller
        let refresh = Task { await c.refresh([f.installation]) }
        await fulfillment(of: [gate.entered], timeout: 2)
        c.signIn(f.installation)
        let signIn = try XCTUnwrap(c.operations[.codex])
        try await f.clock.waitUntil { f.provider.signIns.count == 1 }
        f.provider.signIns[0].2.resolve(.success(.authenticated)); await signIn.value
        gate.resolve(.success(.unauthenticated)); await refresh.value
        XCTAssertEqual(c.authentication[.codex], .authenticated)
        XCTAssertEqual(HarnessPresentationCache.load(from: f.defaults)[.codex]?.authentication, .authenticated)
    }

    func testNewInstallationSupersedesPendingStatusFromOldPath() async {
        let f = fixture(), gate = f.heldStatus(), c = f.controller
        let refresh = Task { await c.refresh([f.installation]) }
        await fulfillment(of: [gate.entered], timeout: 2)
        let replacement = HarnessInstallation(provider: .codex, executablePath: "/fixtures/new-codex")
        f.provider.statusResult = .authenticated
        await c.refresh([replacement])
        gate.resolve(.success(.unauthenticated)); await refresh.value
        XCTAssertEqual(c.snapshots[.codex]?.installation, replacement)
        XCTAssertEqual(c.authentication[.codex], .authenticated)
        XCTAssertEqual(f.provider.statusCalls.count, 2)
    }

    func testCancelledSignInImmediatelyClearsChallengeAndAllowsRetry() async throws {
        let f = fixture(), c = f.controller
        c.signIn(f.installation); let first = try XCTUnwrap(c.operations[.codex])
        try await f.clock.waitUntil { f.provider.signIns.count == 1 }
        f.provider.signIns[0].1(f.challenge)
        XCTAssertEqual(c.challenges[.codex], f.challenge)
        c.cancel(.codex)
        XCTAssertNil(c.activity[.codex]); XCTAssertNil(c.challenges[.codex])
        c.signIn(f.installation)
        let retry = c.operations[.codex]
        // Return the cancelled provider only after requesting the replacement.
        f.provider.signIns[0].2.resolve(.success(.unauthenticated)); await first.value
        try await f.clock.waitUntil { f.provider.signIns.count >= 2 || c.operations[.codex] == nil }
        XCTAssertEqual(f.provider.signIns.count, 2)
        if f.provider.signIns.count == 2 {
            XCTAssertNotNil(c.activity[.codex])
            f.provider.signIns[0].1(f.challenge)
            XCTAssertNil(c.challenges[.codex], "Retired challenge reached replacement sign-in")
            f.provider.signIns[1].2.resolve(.success(.authenticated)); await retry?.value
        }
        XCTAssertEqual(c.authentication[.codex], .authenticated)
    }

    func testChallengeDeliveredAfterSignInCompletionIsIgnored() async throws {
        let f = fixture(), c = f.controller
        c.signIn(f.installation); let operation = try XCTUnwrap(c.operations[.codex])
        try await f.clock.waitUntil { f.provider.signIns.count == 1 }
        f.provider.signIns[0].2.resolve(.success(.authenticated)); await operation.value
        f.provider.signIns[0].1(f.challenge)
        XCTAssertNil(c.challenges[.codex]); XCTAssertNil(c.activity[.codex])
    }

    func testInstallationRemovalCancelsPendingSignInAndRejectsLateSuccess() async throws {
        let f = fixture(), c = f.controller
        c.signIn(f.installation); let operation = try XCTUnwrap(c.operations[.codex])
        try await f.clock.waitUntil { f.provider.signIns.count == 1 }
        let removed = HarnessInstallation(provider: .codex, executablePath: nil)
        await c.refresh([removed])
        f.provider.signIns[0].2.resolve(.success(.authenticated)); await operation.value
        XCTAssertEqual(c.snapshots[.codex]?.installation, removed)
        XCTAssertNil(c.authentication[.codex]); XCTAssertNil(c.activity[.codex])
    }

    func testSignInFailureCanRetryAndDoesNotDisturbAnotherProvider() async throws {
        let f = fixture(), c = f.controller
        c.signIn(f.installation); c.signIn(f.claude); c.signIn(f.installation)
        let codex = try XCTUnwrap(c.operations[.codex]), claude = try XCTUnwrap(c.operations[.claudeCode])
        try await f.clock.waitUntil { f.provider.signIns.count == 1 && f.other.signIns.count == 1 }
        f.provider.signIns[0].2.resolve(.failure(HarnessSetupError("Sign-in failed"))); await codex.value
        XCTAssertEqual(c.errors[.codex], "Sign-in failed"); XCTAssertNotNil(c.activity[.claudeCode])
        c.signIn(f.installation); let retry = try XCTUnwrap(c.operations[.codex])
        try await f.clock.waitUntil { f.provider.signIns.count == 2 }
        f.provider.signIns[1].2.resolve(.success(.authenticated)); f.other.signIns[0].2.resolve(.success(.managedExternally))
        await retry.value; await claude.value
        XCTAssertNil(c.errors[.codex]); XCTAssertEqual(c.authentication[.claudeCode], .managedExternally)
    }

    func testVersionResultCannotAttachToReplacementInstallation() async {
        let f = fixture(), c = f.controller, gate = RoutingGate<HarnessVersionReport>()
        f.versions.gate = gate
        let version = Task { await c.refreshVersions([f.installation], forceLatest: true) }
        await fulfillment(of: [gate.entered], timeout: 2)
        let replacement = HarnessInstallation(provider: .codex, executablePath: "/fixtures/new-codex")
        await c.refresh([replacement])
        gate.resolve(.success(f.versions.report)); await version.value
        XCTAssertNil(c.snapshots[.codex]?.version); XCTAssertFalse(c.checkingVersions)
        XCTAssertTrue(f.versions.calls[0].2)
    }

    func testVersionFailurePreservesLastKnownReportAndAuthentication() async {
        let f = fixture(), c = f.controller
        f.versions.error = HarnessSetupError("Probe unavailable")
        await c.refreshVersions([f.installation])
        XCTAssertEqual(c.snapshots[.codex]?.version?.installedVersion, "1.0.0")
        XCTAssertEqual(c.snapshots[.codex]?.version?.latestVersion, "2.0.0")
        XCTAssertNotNil(c.snapshots[.codex]?.version?.checkError)
        XCTAssertEqual(c.authentication[.codex], .authenticated)
    }

    func testCancelledVersionCheckDoesNotPublishLateReport() async {
        let f = fixture(), c = f.controller, gate = RoutingGate<HarnessVersionReport>()
        f.versions.gate = gate; let before = c.snapshots
        let operation = Task { await c.refreshVersions([f.installation]) }
        await fulfillment(of: [gate.entered], timeout: 2)
        await c.refreshVersions([f.installation]); XCTAssertEqual(f.versions.calls.count, 1)
        operation.cancel(); gate.resolve(.success(f.versions.report)); await operation.value
        XCTAssertEqual(c.snapshots, before); XCTAssertFalse(c.checkingVersions)
    }
}
