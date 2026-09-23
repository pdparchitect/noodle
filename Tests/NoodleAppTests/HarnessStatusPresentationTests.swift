import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class HarnessStatusPresentationTests: HiddenViewTests {
    func testCachedUpdateErrorIsReplacedWhileRefreshingAndClearsOnSuccess() async throws {
        let f = try fixture()
        let installation = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
        let error = "Could not check the latest release. Try Check Again."
        HarnessPresentationCache.save([.codex: .init(installation: installation, authentication: .authenticated,
            version: .init(installedVersion: "0.153.4", checkError: error))], to: f.runtime.defaults)
        let checker = HarnessVersionChecker(inspect: { _ in .init(installedVersion: "0.153.4") },
            fetch: { _ in Data(#"{"tag_name":"rust-v0.154.0"}"#.utf8) })
        let setup = HarnessSetupController(providers: [:], defaults: f.runtime.defaults, versionChecker: checker)
        let row = { (refreshing: Bool) in
            HarnessInstallationRow(installation: installation, liveInstallation: installation,
                isRefreshing: refreshing, setup: setup, install: {}).environment(f.store)
        }
        let view = host(row(false))
        _ = try await control(error, in: view)
        _ = try await control("Version 0.153.4", in: view)
        view.rootView = row(true)
        _ = try await control("Checking for updates…", in: view)
        XCTAssertFalse(hasControl(error, in: view))
        _ = try await control("Version 0.153.4", in: view)
        // A check that still fails must show the error again once it finishes.
        view.rootView = row(false)
        _ = try await control(error, in: view)
        view.rootView = row(true)
        await setup.refreshVersions([installation], forceLatest: true)
        view.rootView = row(false)
        _ = try await control("Update available — 0.154.0", in: view)
        _ = try await control("Update Instructions", in: view)
        XCTAssertFalse(hasControl(error, in: view))
        XCTAssertFalse(hasControl("Checking for updates…", in: view))
    }

    func testSignInSharesTheRowOfTheOtherHarnessButtons() async throws {
        let f = try fixture()
        let installation = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
        HarnessPresentationCache.save([.codex: .init(installation: installation, authentication: .unauthenticated,
            version: .init(installedVersion: "0.153.4"))], to: f.runtime.defaults)
        let setup = HarnessSetupController(providers: [:], defaults: f.runtime.defaults)
        let view = host(HarnessInstallationRow(installation: installation, liveInstallation: installation,
            isRefreshing: false, setup: setup, install: {}).environment(f.store))
        let frame = { (node: NSObject) in (node.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
        let profilesButton = try await control("Profiles", in: view), signInButton = try await control("Sign In", in: view)
        let profiles = try XCTUnwrap(frame(profilesButton)), signIn = try XCTUnwrap(frame(signInButton))
        XCTAssertEqual(profiles.midY, signIn.midY, accuracy: 1)
        XCTAssertGreaterThan(signIn.minX, profiles.maxX)
    }

    func testSignInStaysEnabledWhileOtherHarnessesRefresh() async throws {
        let f = try fixture()
        let installation = HarnessInstallation(provider: .claudeCode, executablePath: "/fixtures/claude")
        HarnessPresentationCache.save([.claudeCode: .init(installation: installation, authentication: .unauthenticated,
            version: .init(installedVersion: "2.1.278"))], to: f.runtime.defaults)
        let provider = StalledSetupProvider()
        addTeardownBlock { @MainActor in provider.gate.resolve(.failure(CancellationError())) }
        let setup = HarnessSetupController(providers: [.claudeCode: provider], defaults: f.runtime.defaults)
        let row = { (refreshing: Bool) in
            HarnessInstallationRow(installation: installation, liveInstallation: installation,
                isRefreshing: refreshing, setup: setup, install: {}).environment(f.store)
        }
        // Version lookups and the other harnesses' checks must not lock this row's Sign In.
        let view = host(row(true))
        let idle = try await control("Sign In", in: view)
        XCTAssertTrue(enabled(idle))
        // Its own sign-in check may still flip the row to signed in.
        let check = Task { await setup.refresh([installation]) }
        try await wait { setup.checking.contains(.claudeCode) }
        view.rootView = row(false)
        let signIn = try await control("Sign In", in: view)
        try await wait { !self.enabled(signIn) }
        provider.gate.resolve(.success(.unauthenticated))
        await check.value
        try await wait { self.enabled(signIn) }
    }

    func testReconnectingAgentsShowElapsedTimeAndKickWithFailureTakingHeaderPriority() async throws {
        let f = try fixture(), first = try f.runtime.start(f.a), second = try f.runtime.start(f.b)
        let installed = HarnessInstallation(provider: .codex, executablePath: "/fixtures/codex")
        HarnessPresentationCache.save([.codex: .init(installation: installed, authentication: .authenticated)], to: f.runtime.defaults)
        let setup = HarnessSetupController(providers: [:], defaults: f.runtime.defaults)
        first.transition(.working, reconnectingSince: Date().addingTimeInterval(-135))
        let view = host(HarnessInstallationRow(installation: installed, liveInstallation: installed,
            isRefreshing: false, setup: setup, install: {}).environment(f.store))
        // Popovers only present from a window that is ordered in (still offscreen).
        let window = try XCTUnwrap(view.window)
        window.orderFront(nil)
        _ = try await control("Reconnecting", in: view)
        XCTAssertFalse(hasControl(f.a.displayName, in: view), "Affected bots are listed in the status popover")
        // The status label opens the affected bots, their elapsed time, and Kick.
        press(try await control("Show affected bots", in: view))
        var popover: NSView?
        try await wait {
            popover = NSApp.windows.filter { $0.isVisible && $0 !== window && $0.sheetParent == nil }
                .compactMap(\.contentView).first { self.hasControl(f.a.displayName, in: $0) }
            return popover != nil
        }
        let issues = try XCTUnwrap(popover)
        try await wait { self.elements(issues).flatMap { self.labels($0) }.contains { $0.hasPrefix("Reconnecting… · 2m ") } }
        let kick = try await control("Kick", in: issues)
        XCTAssertTrue(enabled(kick))
        XCTAssertFalse(hasControl("Needs attention", in: view))
        second.transition(.failed, detail: "Fixture account failure")
        _ = try await control("Needs attention", in: view)
        second.transition(.ready)
        _ = try await control("Reconnecting", in: view)
        try await wait { self.elements(issues).filter { self.matches("Kick", node: $0) }.count == 1 }
        press(try await control("Kick", in: issues))
        try await wait { f.runtime.factory.processes.count == 3 }
        XCTAssertEqual(first.stops, 1)
        _ = try await control("Signed in", in: view)
        try await wait { issues.window?.isVisible != true }
        window.close()
    }
}

@MainActor private final class StalledSetupProvider: HarnessSetupProviding {
    let installationGuide = HarnessInstallationGuide(command: nil, instructions: "Fixture instructions", documentationURL: URL(string: "https://example.invalid/setup")!)
    let gate = RoutingGate<HarnessAuthenticationStatus>()
    func status(for installation: HarnessInstallation) async throws -> HarnessAuthenticationStatus { try await gate.value() }
    func signIn(for installation: HarnessInstallation, onChallenge: @escaping @MainActor (HarnessSignInChallenge) -> Void) async throws -> HarnessAuthenticationStatus { .authenticated }
}
