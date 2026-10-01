import Foundation
import XCTest
@testable import NoodleCore
@testable import NoodleRuntime

@MainActor final class HarnessProfilesControllerTests: XCTestCase {
    private func controller() throws -> (HarnessProfilesController, HarnessProfileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-profiles-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = HarnessProfileStore(root: root)
        return (HarnessProfilesController(store: store), store)
    }

    private func settle(_ controller: HarnessProfilesController, _ profile: HarnessProfile) async {
        for _ in 0..<200 where controller.activity[profile.id] != nil { await Task.yield() }
    }

    func testProfilesFollowTheStoreThroughCreateRenameAndDelete() throws {
        let (controller, store) = try controller()
        let work = try controller.create(provider: .codex, named: "Work")
        let home = try controller.create(provider: .claudeCode, named: "Home")
        XCTAssertEqual(Set(controller.profiles.map(\.id)), [work.id, home.id])
        XCTAssertEqual(controller.profiles(for: .codex).map(\.id), [work.id])
        XCTAssertEqual(controller.profile(home.id)?.displayName, "Home")
        XCTAssertNil(controller.profile(nil))

        try controller.rename(work, to: "Client")
        XCTAssertEqual(controller.profile(work.id)?.displayName, "Client")
        XCTAssertEqual(HarnessProfilesController(store: store).profile(work.id)?.displayName, "Client", "Renames are stored")

        try controller.delete(home)
        XCTAssertNil(controller.profile(home.id))
        XCTAssertEqual(try store.load().map(\.id), [work.id])
    }

    func testSignInNeedsAnInstalledHarnessThatProfilesSupport() throws {
        let (controller, _) = try controller()
        let codex = try controller.create(provider: .codex, named: "Work")
        XCTAssertThrowsError(try controller.create(provider: .apple, named: "Other"))
        XCTAssertEqual(controller.profiles.map(\.id), [codex.id])
        controller.signIn(codex, installation: HarnessInstallation(provider: .codex, executablePath: nil))
        XCTAssertTrue(controller.activity.isEmpty)
        XCTAssertTrue(controller.errors.isEmpty)
    }

    func testAntigravitySignInSendsThePersonToTerminalWithTheProfilesHome() throws {
        let (controller, store) = try controller()
        let profile = try controller.create(provider: .antigravity, named: "Work")
        controller.signIn(profile, installation: HarnessInstallation(provider: .antigravity, executablePath: "/fixtures/agy"))
        XCTAssertNil(controller.activity[profile.id])
        XCTAssertNil(controller.authentication[profile.id])
        XCTAssertNil(controller.errors[profile.id], "A Terminal sign-in is a command to copy, not an error")
        XCTAssertEqual(controller.terminalSignIns[profile.id], "HOME='\(store.loginHome(profile).path)' '/fixtures/agy'")
    }

    func testFxSignInGoesThroughTheAgentHostNotTerminal() async throws {
        let (controller, _) = try controller()
        let profile = try controller.create(provider: .fx, named: "Work")
        controller.signIn(profile, installation: HarnessInstallation(provider: .fx, executablePath: "/fixtures/fx"))
        XCTAssertEqual(controller.activity[profile.id], "Starting sign-in…")
        await settle(controller, profile)
        // Tests have no signed Agent Host to reach, so the host sign-in stops there.
        let error = try XCTUnwrap(controller.errors[profile.id])
        XCTAssertTrue(error.contains("Agent Host"), error)
        XCTAssertFalse(error.contains("Terminal"), error)
    }

    func testOpenCodeSignInSendsThePersonToTerminalWithTheProfilesFolders() throws {
        let (controller, store) = try controller()
        let profile = try controller.create(provider: .openCode, named: "Work")
        controller.signIn(profile, installation: HarnessInstallation(provider: .openCode, executablePath: "/fixtures/opencode"))
        XCTAssertNil(controller.authentication[profile.id])
        XCTAssertNil(controller.errors[profile.id])
        let home = store.loginHome(profile).path
        XCTAssertEqual(controller.terminalSignIns[profile.id], "XDG_CACHE_HOME='\(home)/.cache' XDG_CONFIG_HOME='\(home)/.config' XDG_DATA_HOME='\(home)/.local/share' XDG_STATE_HOME='\(home)/.local/state' '/fixtures/opencode' auth login --standalone")
    }

    func testRefreshWithoutAnInstallationClearsStatusAndDeleteClearsErrors() async throws {
        let (controller, _) = try controller()
        let profile = try controller.create(provider: .antigravity, named: "Work")
        let installation = HarnessInstallation(provider: .antigravity, executablePath: "/fixtures/agy")
        controller.signIn(profile, installation: installation)
        XCTAssertNotNil(controller.terminalSignIns[profile.id])

        await controller.refresh(HarnessInstallation(provider: .antigravity, executablePath: nil))
        XCTAssertNil(controller.authentication[profile.id])

        try controller.delete(profile)
        XCTAssertNil(controller.errors[profile.id])
        XCTAssertNil(controller.terminalSignIns[profile.id])
        XCTAssertTrue(controller.profiles.isEmpty)
    }

    func testCancelWithoutASignInChangesNothing() throws {
        let (controller, _) = try controller()
        let profile = try controller.create(provider: .codex, named: "Work")
        controller.cancel(profile)
        controller.cancelAll()
        XCTAssertEqual(controller.profiles.map(\.id), [profile.id])
        XCTAssertTrue(controller.activity.isEmpty)
    }
}
