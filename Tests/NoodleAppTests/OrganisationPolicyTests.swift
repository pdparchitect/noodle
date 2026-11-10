import BrowserBridge
import ComputerBridge
import Foundation
import HubCore
import HubLink
import NoodleCore
import Sparkle
import XCTest
@testable import Noodle
@testable import NoodleRuntime
@testable import NoodleRuntimeSettings

/// An organisation's policy as a test sets it: what it forbids, and the settings it fixes.
struct TestOrganisationPolicy: OrganisationPolicy {
    var forbids: @Sendable (OrganisationAction) -> Bool = { _ in false }
    var fixed: [OrganisationSetting: Bool] = [:]
    func allows(_ action: OrganisationAction) -> Bool { !forbids(action) }
    func value(of setting: OrganisationSetting) -> Bool? { fixed[setting] }
    var rules: [OrganisationRule] { [OrganisationRule(title: "Test", value: "Set")] }

    @MainActor static func enforce(forbidding forbids: @escaping @Sendable (OrganisationAction) -> Bool,
                                   fixing fixed: [OrganisationSetting: Bool] = [:]) {
        Organisation.enforce(TestOrganisationPolicy(forbids: forbids, fixed: fixed))
    }
}

/// Every check happens where the action does, so neither the person nor a bot can go around a policy,
/// and lifting a policy brings back what it stopped.
@MainActor final class OrganisationPolicyRuntimeTests: XCTestCase {
    private func fixture() throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture()
        addTeardownBlock { @MainActor in
            f.cleanUp()
            Organisation.enforce(UnmanagedPolicy())
        }
        return f
    }

    func testABlockedHarnessIsOffEverywhereAndItsBotsDontStart() throws {
        let f = try fixture(), agent = try f.agent()
        TestOrganisationPolicy.enforce { $0 == .harness(.codex) }
        XCTAssertFalse(f.runtime.harnesses.isOn(.codex))
        XCTAssertTrue(f.runtime.harnesses.isOn(.claudeCode))
        XCTAssertFalse(HarnessSelection(defaults: f.defaults).isOn(.codex))
        f.runtime.start(agent: agent, repository: f.repository)
        XCTAssertTrue(f.factory.processes.isEmpty)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).detail, "Your organisation doesn't allow Codex.")
        // The person's own choice is kept for when the policy goes.
        f.runtime.setHarness(.codex, on: false)
        Organisation.enforce(UnmanagedPolicy())
        XCTAssertTrue(f.runtime.harnesses.isOn(.codex))
    }

    func testARunningBotStopsWhenItsHarnessIsBlockedAndStartsAgainWhenAllowed() async throws {
        let f = try fixture(), agent = try f.agent(), process = try f.start(agent)
        TestOrganisationPolicy.enforce { $0 == .harness(.codex) }
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        XCTAssertEqual(process.stops, 1)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).phase, .failed)
        XCTAssertEqual(f.runtime.snapshot(for: agent.id).detail, "Your organisation doesn't allow Codex.")
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        XCTAssertEqual(f.factory.processes.count, 1, "It stays stopped while blocked")

        Organisation.enforce(UnmanagedPolicy())
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        try await f.clock.waitUntil { f.factory.processes.count == 2 }
        XCTAssertEqual(f.factory.processes.count, 2)
    }

    func testUnrestrictedAccessIsWithheldWhileForbiddenAndComesBackWhenAllowed() throws {
        let f = try fixture(), agent = try f.agent(), other = try f.agent("Other")
        f.runtime.setExtendedAccess(true, agent: agent, repository: f.repository)
        XCTAssertTrue(try XCTUnwrap(f.factory.processes.last).launch.extendedAccess)

        TestOrganisationPolicy.enforce { $0 == .unrestrictedAccess }
        XCTAssertFalse(f.runtime.accessConfiguration.isExtended(for: agent))
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        let sandboxed = try XCTUnwrap(f.factory.processes.last)
        XCTAssertEqual(f.factory.processes.count, 2, "The bot restarts sandboxed")
        XCTAssertFalse(sandboxed.launch.extendedAccess)

        f.runtime.setExtendedAccess(true, agent: other, repository: f.repository)
        XCTAssertFalse(f.runtime.accessConfiguration.isExtended(for: other))
        XCTAssertEqual(f.factory.processes.count, 2, "Nothing starts with access the organisation forbids")

        Organisation.enforce(UnmanagedPolicy())
        XCTAssertTrue(f.runtime.accessConfiguration.isExtended(for: agent), "The person's grant was kept")
        f.runtime.reconcile(agents: [agent], repository: f.repository, immediately: true)
        XCTAssertEqual(f.factory.processes.count, 3)
        XCTAssertTrue(try XCTUnwrap(f.factory.processes.last).launch.extendedAccess)
    }
}

@MainActor final class OrganisationPolicyToolTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run { Organisation.enforce(UnmanagedPolicy()) }
    }

    private func repository() throws -> WorkspaceRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
        return repository
    }

    func testBotsLoseBrowsersComputersAndToolConnectionsTheOrganisationTurnsOff() {
        let store = ToolAssignmentStore(), agent = UUID()
        for kind in ["browser", "computer", ConnectionToolProvider.grantKind, "calendar"] { store.replace(kind, with: [agent: ["one"]]) }
        XCTAssertEqual(store.assignments(for: agent).resources.count, 4)
        TestOrganisationPolicy.enforce { [.browsers, .computers, .toolConnections].contains($0) }
        XCTAssertEqual(store.assignments(for: agent), ["calendar": ["one"]])
        Organisation.enforce(UnmanagedPolicy())
        XCTAssertEqual(store.assignments(for: agent).resources.count, 4, "Assignments come back with the policy gone")
    }

    func testNoodleNeitherListsNorOpensBrowsersOrComputersTheOrganisationTurnsOff() async throws {
        let repository = try repository()
        let browsers = BrowserController(repository: repository, connection: { _ in
            var response = BrowserResponse(); response.browsers = [RemoteBrowser(id: UUID(), name: "Work")]; return response
        })
        let computers = ComputerController(repository: repository, applicationLookup: { nil }, connection: { _ in
            var response = ComputerResponse(); response.capabilities = ComputerCapabilities(); return response
        })
        TestOrganisationPolicy.enforce { [.browsers, .computers].contains($0) }
        await browsers.refresh(launchIfNeeded: true)
        XCTAssertFalse(browsers.available)
        XCTAssertEqual(browsers.failure, "Your organisation doesn't allow Noodle Browser.")
        do { _ = try await computers.call(ComputerRequest(.list)); XCTFail("Computer was reached") }
        catch { XCTAssertEqual(error.localizedDescription, "Your organisation doesn't allow Noodle Computer.") }
    }

    func testAToolConnectionTheOrganisationBlocksCannotBeAddedOrReachBots() throws {
        let repository = try repository()
        let controller = MCPController(repository: repository)
        let blocked = try MCPConnectionRecord(name: "Blocked", endpoint: URL(string: "https://blocked.example/mcp")!)
        let allowed = try MCPConnectionRecord(name: "Allowed", endpoint: URL(string: "https://allowed.example/mcp")!)
        try controller.save(blocked)
        try controller.save(allowed)
        let agent = try repository.createAgent(named: "Fixture").agent
        try controller.assign([blocked.id, allowed.id], to: agent, synchronizeWorkspace: false)
        var granted: [UUID: Set<String>] = [:]
        controller.onAssignmentsChange = { granted = $0 }
        XCTAssertEqual(granted[agent.id]?.count, 2)

        TestOrganisationPolicy.enforce {
            if case .toolConnection(_, let endpoint) = $0 { return endpoint.host == "blocked.example" }
            return false
        }
        controller.applyOrganisationPolicy()
        XCTAssertEqual(granted[agent.id], [allowed.id.uuidString])
        let another = try MCPConnectionRecord(name: "Another", endpoint: URL(string: "https://blocked.example/other")!)
        XCTAssertThrowsError(try controller.save(another)) {
            XCTAssertEqual($0.localizedDescription, "Your organisation doesn't allow this tool connection.")
        }
        XCTAssertEqual(controller.registry.connections.count, 2, "Nothing is deleted")
    }
}

@MainActor final class OrganisationPolicyHubTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run { Organisation.enforce(UnmanagedPolicy()) }
    }

    func testThisMacStopsServingDevicesWhileForbiddenAndComesBackAfter() async throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-this-mac-policy-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        f.store.thisMac.placement = .init(directory: root, port: 0, router: nil, localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await f.store.thisMac.setOn(true)
        addTeardownBlock { await f.store.thisMac.setOn(false) }
        XCTAssertTrue(f.store.thisMac.isOn)

        TestOrganisationPolicy.enforce { $0 == .hubHosting }
        try await waitUntil { !f.store.thisMac.isOn }
        await f.store.thisMac.setOn(true)
        XCTAssertFalse(f.store.thisMac.isOn, "It can't be turned on while forbidden")

        Organisation.enforce(UnmanagedPolicy())
        try await waitUntil { f.store.thisMac.isOn }
    }

    func testJoinedHubsAreRefusedAtAddressesTheOrganisationBlocks() async throws {
        let f = try StoreFixture()
        defer { f.cleanUp() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-hub-policy-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let studio = Hub(root: root.appendingPathComponent("Studio"), messenger: nil)
        try studio.repository.prepare()
        let link = HubLinkService(hubName: "Studio", directory: root.appendingPathComponent("Studio/Link"),
                                  access: studio.access, profiles: studio.harnessProfiles, bots: studio.bots, port: 0,
                                  localEndpoints: { [LinkEndpoint(host: "::1", port: $0)] })
        await link.start()
        addTeardownBlock { await MainActor.run { link.stop() } }
        guard case .listening = link.state else { throw XCTSkip("Could not listen: \(link.state)") }
        let ada = try studio.access.addUser(named: "Ada")

        TestOrganisationPolicy.enforce { $0 == .hubAddress("::1") }
        await f.store.joinHub(link.invite(ada).url().absoluteString)
        XCTAssertTrue(f.store.hubs.hubs.isEmpty)
        XCTAssertEqual(f.store.hubs.joinError, "Your organisation doesn't allow this Noodle Hub.")

        Organisation.enforce(UnmanagedPolicy())
        await f.store.joinHub(link.invite(ada).url().absoluteString)
        let joined = try XCTUnwrap(f.store.hubs.hubs.first)
        TestOrganisationPolicy.enforce { $0 == .hubConnections || $0 == .hubAddress("::1") }
        await joined.refresh()
        XCTAssertEqual(joined.error, "Your organisation doesn't allow this Noodle Hub.")
        XCTAssertEqual(f.store.hubs.hubs.count, 1, "Nothing is left or deleted")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor final class OrganisationPolicyUpdateTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run { Organisation.enforce(UnmanagedPolicy()) }
    }

    func testSparkleMayNotCheckWhenTheOrganisationLeavesUpdatesToItsMDM() throws {
        let updater = AppUpdater()
        XCTAssertTrue(updater.updatesAllowed)
        TestOrganisationPolicy.enforce { $0 == .updates }
        XCTAssertFalse(updater.updatesAllowed)
        XCTAssertFalse(updater.canCheckForUpdates)
        // Sparkle checks by itself only while its own setting is on, so that is turned off, and back after.
        XCTAssertEqual(updater.fixedValue(of: .automaticUpdateChecks), false)
        XCTAssertEqual(updater.fixedValue(of: .automaticUpdateInstalls), false)
        // Nothing may veto Sparkle; see UpdateRelaunchTests.
        XCTAssertFalse(updater.responds(to: #selector(SPUUpdaterDelegate.updater(_:mayPerform:))))
        Organisation.enforce(UnmanagedPolicy())
        XCTAssertNil(updater.fixedValue(of: .automaticUpdateChecks))
    }

    func testFixedAutomaticUpdateSettingsWinOverThePersons() {
        XCTAssertTrue(AppUpdater.effective(person: true, fixed: nil))
        XCTAssertFalse(AppUpdater.effective(person: true, fixed: false))
        XCTAssertTrue(AppUpdater.effective(person: false, fixed: true))
    }

    func testTheProfileReplacesThePersonsUpdateSettingAndRemovingItPutsTheirsBack() {
        var settled = AppUpdater.settle(current: true, fixed: false, kept: nil)
        XCTAssertEqual(settled.value, false)
        XCTAssertEqual(settled.kept, true)
        settled = AppUpdater.settle(current: settled.value, fixed: false, kept: settled.kept)
        XCTAssertEqual(settled.kept, true, "Their own is kept once, not replaced by the fixed value")
        settled = AppUpdater.settle(current: settled.value, fixed: nil, kept: settled.kept)
        XCTAssertEqual(settled.value, true)
        XCTAssertNil(settled.kept)
        settled = AppUpdater.settle(current: false, fixed: nil, kept: nil)
        XCTAssertEqual(settled.value, false, "Without a profile the person's setting is left alone")
    }
}
