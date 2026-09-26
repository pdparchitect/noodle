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
        XCTAssertThrowsError(try controller.create(provider: .openCode, named: "Other"))
        XCTAssertEqual(controller.profiles.map(\.id), [codex.id])
        controller.signIn(codex, installation: HarnessInstallation(provider: .codex, executablePath: nil))
        XCTAssertTrue(controller.activity.isEmpty)
        XCTAssertTrue(controller.errors.isEmpty)
    }

    func testAntigravitySignInSendsThePersonToTerminalWithTheProfilesHome() async throws {
        let (controller, store) = try controller()
        let profile = try controller.create(provider: .antigravity, named: "Work")
        controller.signIn(profile, installation: HarnessInstallation(provider: .antigravity, executablePath: "/fixtures/agy"))
        XCTAssertEqual(controller.activity[profile.id], "Starting sign-in…")
        await settle(controller, profile)
        XCTAssertNil(controller.activity[profile.id])
        XCTAssertNil(controller.authentication[profile.id])
        let error = try XCTUnwrap(controller.errors[profile.id])
        XCTAssertTrue(error.contains("HOME='\(store.loginHome(profile).path)' '/fixtures/agy'"), error)
        XCTAssertTrue(error.contains("Check Again"), error)
    }

    func testRefreshWithoutAnInstallationClearsStatusAndDeleteClearsErrors() async throws {
        let (controller, _) = try controller()
        let profile = try controller.create(provider: .antigravity, named: "Work")
        let installation = HarnessInstallation(provider: .antigravity, executablePath: "/fixtures/agy")
        controller.signIn(profile, installation: installation)
        await settle(controller, profile)
        XCTAssertNotNil(controller.errors[profile.id])

        await controller.refresh(HarnessInstallation(provider: .antigravity, executablePath: nil))
        XCTAssertNil(controller.authentication[profile.id])

        try controller.delete(profile)
        XCTAssertNil(controller.errors[profile.id])
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
