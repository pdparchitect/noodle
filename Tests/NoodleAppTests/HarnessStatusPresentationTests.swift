import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

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
        _ = try await control("Update Instructions…", in: view)
        XCTAssertFalse(hasControl(error, in: view))
        XCTAssertFalse(hasControl("Checking for updates…", in: view))
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
