import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class RuntimeProcessFixture: AgentRuntimeProcess {
    let launch: AgentRuntimeLaunch
    var configuration: AgentRecord { launch.agent }
    var snapshot: AgentRuntimeSnapshot
    var isAlive = false
    var hasInterruptedWork = false
    var canReceiveHeartbeat = false
    var automaticallyStops = true
    var starts = 0
    var stops = 0
    var heartbeats = 0
    var notifications: [Bool] = []
    var resolved: [(UUID, Bool, [String: String])] = []
    private var stopCompletions: [(Bool) -> Void] = []

    init(_ launch: AgentRuntimeLaunch) {
        self.launch = launch
        snapshot = .init(agentID: launch.agent.id, phase: .offline, detail: "Fixture")
    }
    func transition(_ phase: AgentRuntimePhase, detail: String = "Fixture") {
        snapshot.phase = phase
        snapshot.detail = detail
        launch.onSnapshot(snapshot)
    }
    func start() { starts += 1; isAlive = true; transition(.ready) }
    func stop(completion: @escaping (Bool) -> Void) {
        stops += 1
        stopCompletions.append(completion)
        if automaticallyStops { finishStop(true) }
    }
    func finishStop(_ success: Bool) {
        if success { isAlive = false; transition(.offline) }
        let pending = stopCompletions
        stopCompletions = []
        pending.forEach { $0(success) }
    }
    func crash(needsRecovery: Bool = false) {
        isAlive = false
        launch.onUnexpectedTermination(self, "Fixture exited", needsRecovery)
    }
    @discardableResult func notify(immediately: Bool) -> UUID {
        notifications.append(immediately)
        return UUID()
    }
    func promoteNotification(_ id: UUID) { XCTFail("Explicit delivery should not need a classifier") }
    func heartbeat() { heartbeats += 1; launch.onHeartbeat() }
    func resolveApproval(_ approval: AgentApprovalRequest, allow: Bool, answers: [String: String]) {
        resolved.append((approval.id, allow, answers))
    }
}

@MainActor final class RuntimeFactoryFixture {
    var processes: [RuntimeProcessFixture] = []
    func make(_ launch: AgentRuntimeLaunch) -> any AgentRuntimeProcess {
        let process = RuntimeProcessFixture(launch)
        processes.append(process)
        return process
    }
}

@MainActor final class RuntimeCoordinatorFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-runtime-\(UUID())").resolvingSymlinksInPath()
    let suite = "Noodle.RuntimeCoordinatorTests.\(UUID())"
    let defaults: UserDefaults
    let repository: WorkspaceRepository
    let discovery: HarnessDiscovery
    let factory = RuntimeFactoryFixture()
    let clock = RuntimeClockFixture()
    let runtime: AgentRuntimeCoordinator

    init() throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(MessageDeliveryMode.queue.rawValue, forKey: MessageDeliveryMode.defaultsKey)
        repository = WorkspaceRepository(rootURL: root.appendingPathComponent("library"))
        try repository.prepare()
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["codex", "claude"] {
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 99\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        discovery = HarnessDiscovery(homeDirectory: root, applicationsDirectory: root,
            executableSearchDirectories: [bin], applicationBundleURL: root, environment: [:])
        let factory = factory, clock = clock
        runtime = AgentRuntimeCoordinator(discovery: discovery, defaults: defaults,
            makeProcess: { factory.make($0) }, sleep: { try await clock.sleep($0) }, now: { clock.date })
    }
    func agent(_ name: String = "Fixture bot", harness: HarnessProvider? = .codex) throws -> AgentRecord {
        try repository.createAgent(named: name, harnessIdentifier: harness?.rawValue).agent
    }
    @discardableResult func start(_ agent: AgentRecord) throws -> RuntimeProcessFixture {
        runtime.start(agent: agent, repository: repository)
        return try XCTUnwrap(factory.processes.last { $0.configuration.id == agent.id })
    }
    func cleanUp() {
        runtime.stopAll()
        clock.releaseAll()
        for process in factory.processes { process.finishStop(true) }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Suspensions finish only when released, even if cancelled, to model late callbacks.
@MainActor final class RuntimeClockFixture {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var waits: [(Duration, RoutingGate<Void>)] = []
    func sleep(_ duration: Duration) async throws {
        let gate = RoutingGate<Void>()
        waits.append((duration, gate))
        try await gate.value()
    }
    func next(_ duration: Duration, after index: Int = 0) async throws -> RoutingGate<Void> {
        try await waitUntil { self.waits.dropFirst(index).contains { $0.0 == duration } }
        return waits.dropFirst(index).first { $0.0 == duration }!.1
    }
    func releaseAll() { waits.forEach { $0.1.resolve(.failure(CancellationError())) } }
    func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Runtime transition did not complete")
                throw CancellationError()
            }
            await Task.yield()
        }
    }
}
