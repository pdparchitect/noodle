import Foundation
import XCTest
@testable import NoodleCore
@testable import Noodle
@testable import NoodleRuntime

@MainActor final class HarnessSelectionTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "noodle-harness-selection-\(UUID())"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    func testAFreshInstallTurnsOnOnlyTheHarnessesTheWelcomeOffers() {
        let selection = HarnessSelection(defaults: defaults())
        XCTAssertEqual(HarnessProvider.allCases.filter(selection.isOn), [.codex, .claudeCode, .muse, .grokBuild])
        XCTAssertEqual(FirstBotSetup.featured, HarnessProvider.allCases.filter(\.isOnByDefault))
    }

    func testANewInstallKeepsItsDefaultsOnceItHasBeenUsed() {
        let defaults = defaults()
        _ = HarnessSelection(defaults: defaults)
        defaults.set([UUID().uuidString: Date().timeIntervalSince1970], forKey: "Noodle.session.startDates")
        XCTAssertFalse(HarnessSelection(defaults: defaults).isOn(.fx))
    }

    func testAnEarlierInstallKeepsEveryHarnessOn() {
        let settingsOpened = defaults(), botsRan = defaults()
        HarnessPresentationCache.save([.fx: .init(installation: .init(provider: .fx, executablePath: "/fixtures/fx"),
                                                  authentication: .authenticated)], to: settingsOpened)
        botsRan.set([UUID().uuidString: Date().timeIntervalSince1970], forKey: "Noodle.session.startDates")
        for earlier in [settingsOpened, botsRan] {
            XCTAssertEqual(HarnessProvider.allCases.filter(HarnessSelection(defaults: earlier).isOn), HarnessProvider.allCases)
        }
    }

    func testChoicesAreKept() {
        let defaults = defaults()
        let selection = HarnessSelection(defaults: defaults)
        selection.set(.fx, on: true)
        selection.set(.codex, on: false)
        let reloaded = HarnessSelection(defaults: defaults)
        XCTAssertTrue(reloaded.isOn(.fx))
        XCTAssertFalse(reloaded.isOn(.codex))
        XCTAssertTrue(reloaded.isOn(.claudeCode))
        XCTAssertFalse(reloaded.isOn(.openCode))
    }

    func testATurnedOffHarnessIsNotOfferedAndItsBotsDoNotStart() throws {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        let selection = HarnessSelection(defaults: f.defaults)
        let runtime = AgentRuntimeCoordinator(discovery: f.discovery, defaults: f.defaults, harnesses: selection,
            makeProcess: { f.factory.make($0) }, inspectHost: { _ in throw CancellationError() })
        addTeardownBlock { @MainActor in runtime.stopAll() }
        XCTAssertTrue(runtime.availableInstallations.contains { $0.provider == .codex })
        XCTAssertFalse(runtime.availableInstallations.contains { $0.provider == .openCode }, "OpenCode starts off on a new Mac.")

        runtime.setHarness(.codex, on: false)
        XCTAssertFalse(runtime.availableInstallations.contains { $0.provider == .codex })
        let agent = try f.agent(harness: .codex)
        runtime.start(agent: agent, repository: f.repository)
        XCTAssertTrue(f.factory.processes.isEmpty)
        XCTAssertEqual(runtime.snapshot(for: agent.id).detail, "Codex is turned off. Turn it on in Settings → Harness.")

        runtime.setHarness(.codex, on: true)
        runtime.start(agent: agent, repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 1)
    }
}
