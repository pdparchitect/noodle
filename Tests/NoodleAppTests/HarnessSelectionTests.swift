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

    func testFallbackProfilesKeepTheirOrderAndHarnessDefaultChoicesRemainValid() {
        let defaults = defaults()
        defaults.set([HarnessProvider.codex.rawValue, HarnessProvider.claudeCode.rawValue], forKey: HarnessSelection.fallbacksDefaultsKey)
        let selection = HarnessSelection(defaults: defaults)
        XCTAssertEqual(selection.fallbackTargets, [.init(provider: .codex), .init(provider: .claudeCode)])
        let work = HarnessFallbackTarget(provider: .codex, profile: UUID())
        let home = HarnessFallbackTarget(provider: .codex, profile: UUID())
        let defaultCodex = HarnessFallbackTarget(provider: .codex, profile: HarnessProfileStore.defaultID(.codex))
        selection.setFallbackTargets([work, home, work, defaultCodex, .init(provider: .claudeCode)])
        selection.setFallback(on: true)
        selection.setFallback(on: false)
        let reloaded = HarnessSelection(defaults: defaults)
        XCTAssertFalse(reloaded.fallbackIsOn)
        XCTAssertEqual(reloaded.fallbackTargets, [work, home, .init(provider: .codex), .init(provider: .claudeCode)])
    }

    func testUsageRetryEligibilityIsOptInPersistedAndIndependentOfTheFallbackList() {
        let defaults = defaults()
        let selection = HarnessSelection(defaults: defaults)
        let work = HarnessFallbackTarget(provider: .codex, profile: UUID())
        let home = HarnessFallbackTarget(provider: .codex, profile: UUID())
        XCTAssertFalse(selection.allowsUsageRetries(work))
        XCTAssertFalse(selection.allowsUsageRetries(home))
        selection.setUsageRetries(work, on: true)
        selection.setUsageRetries(.init(provider: .codex, profile: HarnessProfileStore.defaultID(.codex)), on: true)
        selection.setFallbacks([.claudeCode])
        selection.setFallback(on: true)
        selection.setFallback(on: false)
        let reloaded = HarnessSelection(defaults: defaults)
        XCTAssertTrue(reloaded.allowsUsageRetries(work))
        XCTAssertTrue(reloaded.allowsUsageRetries(.init(provider: .codex)))
        XCTAssertFalse(reloaded.allowsUsageRetries(home))
        XCTAssertFalse(reloaded.fallbackIsOn)
        XCTAssertEqual(reloaded.fallbackTargets, [.init(provider: .claudeCode)])
        reloaded.setUsageRetries(work, on: false)
        XCTAssertFalse(HarnessSelection(defaults: defaults).allowsUsageRetries(work))
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
