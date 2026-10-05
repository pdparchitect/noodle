import Foundation
import HubCore
import NoodleCore
import NoodleRuntime
import XCTest

/// Stands in for a harness, so the Mac's own runtime can be told to fail and seen to restart.
final class FakeProcess: AgentRuntimeProcess {
    let launch: AgentRuntimeLaunch
    var configuration: AgentRecord { launch.agent }
    var snapshot: AgentRuntimeSnapshot
    var isAlive = false
    var hasInterruptedWork: Bool { false }
    var canReceiveHeartbeat: Bool { false }
    var stops = 0
    var callRequests: [VoiceCallRequest] = []
    var callEvents: (@MainActor (VoiceCallEvent) -> Void)?
    var callTexts: [String] = []
    var callEnds = 0

    init(_ launch: AgentRuntimeLaunch) {
        self.launch = launch
        snapshot = AgentRuntimeSnapshot(agentID: launch.agent.id, phase: .offline, detail: "")
    }
    func set(_ phase: AgentRuntimePhase, failure: AgentRuntimeFailure? = nil) {
        snapshot.phase = phase
        snapshot.failure = failure
        launch.onSnapshot(snapshot)
    }
    func start() { isAlive = true; set(.ready) }
    func stop(completion: @escaping (Bool) -> Void) { stops += 1; isAlive = false; set(.offline); completion(true) }
    func notify(immediately: Bool) -> UUID { UUID() }
    func promoteNotification(_ id: UUID) {}
    func heartbeat() {}
    func startVoiceCall(_ request: VoiceCallRequest, events: @escaping @MainActor (VoiceCallEvent) -> Void) throws {
        callRequests.append(request)
        callEvents = events
    }
    func sendToVoiceCall(_ text: String) { callTexts.append(text) }
    func endVoiceCall() { callEnds += 1; callEvents = nil }
}

extension XCTestCase {
    /// Noodle's own runtime, with a harness that is only a file and processes that are fakes.
    @MainActor func fakeRuntime() throws -> (AgentRuntimeCoordinator, () -> [FakeProcess]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-personal-runtime-\(UUID())").resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin"), codex = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        let suite = "Noodle.PersonalHubTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        var processes: [FakeProcess] = []
        let runtime = AgentRuntimeCoordinator(
            discovery: HarnessDiscovery(homeDirectory: root, applicationsDirectory: root, executableSearchDirectories: [bin],
                                        applicationBundleURL: root, environment: [:]),
            defaults: defaults, makeProcess: { launch in
                let process = FakeProcess(launch)
                processes.append(process)
                return process
            })
        addTeardownBlock { await MainActor.run { runtime.stopAll() } }
        return (runtime, { processes })
    }
}
