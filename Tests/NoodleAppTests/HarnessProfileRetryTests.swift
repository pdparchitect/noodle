import Foundation
import NoodleCore
import XCTest
@testable import NoodleRuntime

@MainActor final class HarnessProfileRetryTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in f.cleanUp() }
        return f
    }

    private func runtime(_ f: RuntimeCoordinatorFixture, eligible: [HarnessProfile]) -> AgentRuntimeCoordinator {
        f.defaults.set(eligible.map { "\($0.provider.rawValue)/\($0.id.uuidString)" }, forKey: "Noodle.harness.usageRetryProfiles")
        let runtime = AgentRuntimeCoordinator(discovery: f.discovery, defaults: f.defaults,
            harnesses: HarnessSelection(defaults: f.defaults), makeProcess: { f.factory.make($0) },
            inspectHost: { _ in throw CancellationError() }, sleep: { try await f.clock.sleep($0) }, now: { f.clock.date })
        addTeardownBlock { @MainActor in runtime.stopAll() }
        return runtime
    }

    func testEligibleProfileRetriesOnTheSameHarnessWhileHarnessFallbackIsOff() throws {
        let f = try fixture()
        let backup = try f.repository.harnessProfiles.create(provider: .codex, named: "Backup")
        let runtime = runtime(f, eligible: [backup])
        var agent = try f.agent(harness: .codex)
        agent.modelIdentifier = "gpt-5.5"
        agent.reasoningEffort = "high"
        XCTAssertFalse(runtime.harnesses.fallbackIsOn)
        runtime.start(agent: agent, repository: f.repository)
        try XCTUnwrap(f.factory.processes.last).transition(.failed, failure: .usageLimit)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertEqual(f.factory.processes.last?.launch.profileOverride, backup.id)
        XCTAssertEqual(f.factory.processes.last?.configuration, agent)
        XCTAssertNil(try f.repository.loadAgentHarnessProfile(agent))
    }

    func testEligibleProfilesAreTriedBeforeTheOrderedHarnessFallbacks() throws {
        let f = try fixture()
        let backup = try f.repository.harnessProfiles.create(provider: .codex, named: "Backup")
        let other = try f.repository.harnessProfiles.create(provider: .claudeCode, named: "Other")
        let runtime = runtime(f, eligible: [backup, other])
        runtime.harnesses.setFallbacks([.claudeCode])
        runtime.harnesses.setFallback(on: true)
        let agent = try f.agent(harness: .codex)
        runtime.start(agent: agent, repository: f.repository)
        try XCTUnwrap(f.factory.processes.last).transition(.failed, failure: .usageLimit)
        XCTAssertEqual(f.factory.processes.last?.launch.profileOverride, backup.id)
        XCTAssertEqual(f.factory.processes.last?.launch.provider, .codex)
        try XCTUnwrap(f.factory.processes.last).transition(.failed, failure: .usageLimit)
        XCTAssertEqual(f.factory.processes.last?.launch.provider, .claudeCode)
        XCTAssertEqual(f.factory.processes.last?.launch.profileOverride, HarnessProfileStore.defaultID(.claudeCode))
        XCTAssertEqual(f.factory.processes.count, 3)
    }

    func testUnmarkedProfilesAndOtherHarnessesAreNeverUsedForLocalRetries() throws {
        let f = try fixture()
        _ = try f.repository.harnessProfiles.create(provider: .codex, named: "Private")
        let other = try f.repository.harnessProfiles.create(provider: .claudeCode, named: "Other")
        let runtime = runtime(f, eligible: [other])
        let agent = try f.agent(harness: .codex)
        runtime.start(agent: agent, repository: f.repository)
        try XCTUnwrap(f.factory.processes.last).transition(.failed, failure: .usageLimit)
        XCTAssertEqual(f.factory.processes.count, 1)
        XCTAssertEqual(runtime.snapshot(for: agent.id).failure, .usageLimit)
    }

    func testOptedOutExhaustedAndDeletedProfilesAreSkipped() throws {
        let f = try fixture()
        let optedOut = try f.repository.harnessProfiles.create(provider: .codex, named: "Opted Out")
        let exhausted = try f.repository.harnessProfiles.create(provider: .codex, named: "Exhausted")
        let deleted = try f.repository.harnessProfiles.create(provider: .codex, named: "Deleted")
        let available = try f.repository.harnessProfiles.create(provider: .codex, named: "Available")
        let runtime = runtime(f, eligible: [optedOut, exhausted, deleted, available])
        runtime.harnesses.setUsageRetries(.init(provider: .codex, profile: optedOut.id), on: false)
        try f.repository.harnessProfiles.delete(deleted)
        runtime.subscriptionUsage.record(SubscriptionUsage(windows: [SubscriptionUsageWindow(id: "primary", minutes: 300,
            usedPercent: 100, resetsAt: f.clock.date.addingTimeInterval(3600))], updatedAt: f.clock.date),
            provider: .codex, profile: exhausted.id)
        let agent = try f.agent(harness: .codex)
        runtime.start(agent: agent, repository: f.repository)
        try XCTUnwrap(f.factory.processes.last).transition(.failed, failure: .usageLimit)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertEqual(f.factory.processes.last?.launch.profileOverride, available.id)
    }

    func testLocalRetryReturnsToTheSavedLoginAfterUsageResets() throws {
        let f = try fixture()
        let backup = try f.repository.harnessProfiles.create(provider: .codex, named: "Backup")
        let runtime = runtime(f, eligible: [backup])
        let agent = try f.agent(harness: .codex)
        runtime.start(agent: agent, repository: f.repository)
        try XCTUnwrap(f.factory.processes.last).transition(.failed, failure: .usageLimit,
            usageResetsAt: f.clock.date.addingTimeInterval(60))
        try XCTUnwrap(f.factory.processes.last).canReceiveHeartbeat = true
        f.clock.date += 31 * 60
        runtime.reconcile(agents: [agent], repository: f.repository)
        XCTAssertEqual(f.factory.processes.count, 3)
        XCTAssertNil(f.factory.processes.last?.launch.profileOverride)
        XCTAssertNil(runtime.runningHarness(for: agent.id))
    }

    func testDefaultLoginCanBeExplicitlyAllowedForLocalRetries() throws {
        let f = try fixture()
        let work = try f.repository.harnessProfiles.create(provider: .codex, named: "Work")
        let runtime = runtime(f, eligible: [HarnessProfileStore.defaultRecord(.codex)])
        let agent = try f.agent(harness: .codex)
        try f.repository.updateAgentHarnessProfile(agent, profile: work.id)
        runtime.start(agent: agent, repository: f.repository)
        try XCTUnwrap(f.factory.processes.last).transition(.failed, failure: .usageLimit)
        XCTAssertEqual(f.factory.processes.count, 2)
        XCTAssertEqual(f.factory.processes.last?.launch.profileOverride, HarnessProfileStore.defaultID(.codex))
    }
}
