import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle
@testable import NoodleRuntimeSettings
import NoodleRuntime

@MainActor final class HarnessProfilesViewTests: HiddenViewTests {
    func testUsageRetryControlOptsInOnlyItsOwnProfileAndCanBeTurnedOff() async throws {
        let f = try fixture()
        let work = try f.store.harnessProfiles.create(provider: .codex, named: "Work")
        let privateProfile = try f.store.harnessProfiles.create(provider: .codex, named: "Private")
        let selection = f.store.runtime.harnesses
        let target = HarnessFallbackTarget(provider: .codex, profile: work.id)
        let view = host(HarnessUsageRetryToggle(harnesses: selection, target: target).toggleStyle(.switch))
        try await wait { self.elements(view).contains { $0 is NSSwitch } }
        let toggle = try XCTUnwrap(elements(view).compactMap { $0 as? NSSwitch }.first)
        XCTAssertFalse(selection.allowsUsageRetries(target))
        toggle.performClick(nil)
        try await wait { selection.allowsUsageRetries(target) }
        XCTAssertFalse(selection.allowsUsageRetries(.init(provider: .codex, profile: privateProfile.id)))
        XCTAssertFalse(selection.fallbackIsOn)
        XCTAssertTrue(selection.fallbackTargets.isEmpty)
        toggle.performClick(nil)
        try await wait { !selection.allowsUsageRetries(target) }
    }

    func testFallbackRowsShowAndUpdateTheirSelectedProfile() async throws {
        let f = try fixture()
        let work = try f.store.harnessProfiles.create(provider: .codex, named: "Work")
        let selection = f.store.runtime.harnesses
        for provider in HarnessProvider.allCases { selection.set(provider, on: provider == .codex) }
        selection.setFallback(on: true)
        selection.setFallbackTargets([.init(provider: .codex, profile: work.id)])
        let form = host(Form { HarnessFallbackSection(store: f.store) }.formStyle(.grouped))
        _ = try await control("Work", in: form)
        selection.setFallbackTargets([.init(provider: .codex)])
        _ = try await control("Default", in: form)
        XCTAssertFalse(hasControl("Work", in: form))
    }

    func testProfileRowsOfferSignInWhileTheirStatusIsUnknown() async throws {
        let f = try fixture()
        _ = try f.store.harnessProfiles.create(provider: .codex, named: "Work")
        // No executable: the status check cannot run, and sign-in must stay reachable.
        let sheet = host(HarnessProfilesView(store: f.store, installation: HarnessInstallation(provider: .codex, executablePath: nil))
            .environment(f.store))
        _ = try await control("Codex Profiles", in: sheet)
        _ = try await control("Work", in: sheet)
        for name in ["Sign In…", "Add Profile…", "Done"] {
            let button = try await control(name, in: sheet)
            XCTAssertTrue(enabled(button), name)
        }
    }

    /// A bot's Profile chooser names the Default login by its account, and keeps it first.
    func testProfileChooserNamesTheDefaultLoginByItsAccount() async throws {
        let f = try fixture()
        let work = try f.store.harnessProfiles.create(provider: .codex, named: "Work")
        let chooser = host(HarnessProfileChooser(profiles: [work], defaultName: "pdp@example.com · Default",
                                                 selection: .constant(nil)).environment(f.store))
        _ = try await control("pdp@example.com · Default", in: chooser)
        _ = try await control("Work", in: chooser)
        XCTAssertFalse(hasControl("Default", in: chooser), "The account names the Default login")
    }

    /// Signing a login out restarts the bots it signs in: those on the profile, or for the
    /// Default login those that chose none.
    func testTheBotsALoginSignsInAreThoseThatUseIt() throws {
        let f = try fixture()
        let work = try f.store.harnessProfiles.create(provider: .codex, named: "Work")
        try f.repository.updateAgentHarnessProfile(f.b, profile: work.id)
        let host: any BotSettingsHost = f.store
        XCTAssertEqual(host.agents(signedInWith: work).map(\.id), [f.b.id])
        XCTAssertEqual(host.agents(signedInWith: HarnessProfileStore.defaultRecord(.codex)).map(\.id), [f.a.id])
        XCTAssertEqual(host.agents(signedInWith: HarnessProfileStore.defaultRecord(.claudeCode)).map(\.id), [])
    }

    /// The sign-in check only reads the saved login, so a bot on the profile that the vendor
    /// refused is what tells that the profile needs signing in again.
    func testAProfileWhoseBotWasRefusedItsLoginSaysSignInIsRequired() async throws {
        let f = try fixture()
        let profile = try f.store.harnessProfiles.create(provider: .codex, named: "Work")
        let other = try f.store.harnessProfiles.create(provider: .codex, named: "Home")
        try f.repository.updateAgentHarnessProfile(f.a, profile: profile.id)
        try f.repository.updateAgentHarnessProfile(f.b, profile: other.id)
        let bot = try f.runtime.start(f.a)
        try f.runtime.start(f.b).transition(.failed, failure: .usageLimit)
        let sheet = host(HarnessProfilesView(store: f.store, installation: HarnessInstallation(provider: .codex, executablePath: nil))
            .environment(f.store))
        _ = try await control("Work", in: sheet)
        XCTAssertFalse(hasControl("Sign-in required", in: sheet))
        bot.transition(.failed, failure: .authenticationRequired)
        _ = try await control("Sign-in required", in: sheet)
        bot.transition(.ready)
        try await wait { !self.hasControl("Sign-in required", in: sheet) }
    }
}
