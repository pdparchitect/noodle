import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor final class MuseWireFixture: MuseRuntimeConnection {
    let workspace: URL
    var onData: ((Data, Bool) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onFailure: ((String) -> Void)?
    var calls: [(String, [String: Any])] = []
    var session = UUID().uuidString
    var turn: String?
    var extendedAccess: Bool?
    var finishBeforeAcknowledgement = false
    var invalidAcknowledgement = false
    var invalidWorkspace = false
    var terminalErrors: [String] = []
    var invalidations = 0
    var stops = 0
    init(workspace: URL) { self.workspace = workspace }
    func startMuse(agentID: UUID, executablePath: String, modelIdentifier: String?, effortIdentifier: String?,
                   extendedAccess: Bool, reply: @escaping (Int32, String?) -> Void) {
        self.extendedAccess = extendedAccess
        reply(12345, nil)
    }
    func write(_ data: Data) {
        do {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let method = try XCTUnwrap(object["method"] as? String)
            let params = object["params"] as? [String: Any] ?? [:]
            calls.append((method, params))
            guard let id = object["id"] as? Int else { return }
            let result: [String: Any]
            switch method {
            case "initialize":
                result = ["schema": ["version": 1], "serverInfo": ["name": "muse"], "sessionDurability": "durable"]
            case "session/start", "session/resume":
                session = method == "session/resume" ? try XCTUnwrap(params["sessionId"] as? String) : UUID().uuidString
                result = ["session": ["sessionId": session, "workspaceRoot": invalidWorkspace ? "/wrong/workspace" : workspace.path,
                    "activeTurnId": NSNull()], "pendingRequests": []]
            case "session/setModel", "approval/decide": result = ["status": "accepted"]
            case "turn/start":
                let turn = UUID().uuidString
                self.turn = turn
                result = ["commandId": invalidAcknowledgement ? "wrong-command" : params["commandId"]!,
                    "status": "accepted", "turnId": turn, "disposition": "started"]
                if !terminalErrors.isEmpty {
                    let kind = terminalErrors.removeFirst()
                    emit(["method": "turn/completed", "params": ["sessionId": session, "turnId": turn,
                        "terminal": "failed", "error": ["kind": kind, "retryable": false, "message": "Fixture failure"]]])
                } else if finishBeforeAcknowledgement { complete() }
            case "turn/steer":
                result = ["status": "accepted", "commandId": params["commandId"]!, "turnId": params["expectedTurnId"]!]
            default:
                XCTFail("Unexpected Muse request: \(method)")
                return
            }
            emit(["id": id, "result": result])
        } catch { XCTFail("Invalid Muse wire data: \(error)") }
    }
    func complete() {
        guard let turn else { return XCTFail("No active wire turn") }
        emit(["method": "turn/completed", "params": ["sessionId": session, "turnId": turn, "terminal": "completed"]])
    }
    func emit(_ object: [String: Any]) {
        do { onData?(try JSONSerialization.data(withJSONObject: object) + Data([10]), false) }
        catch { XCTFail("Invalid fixture response: \(error)") }
    }
    func count(_ method: String) -> Int { calls.filter { $0.0 == method }.count }
    func invalidate() { invalidations += 1 }
    func stop(reply: @escaping (Bool) -> Void) { stops += 1; reply(true) }
}

@MainActor final class MuseRuntimeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-muse-runtime-\(UUID())").resolvingSymlinksInPath()
    var workspace: URL { root.appendingPathComponent("workspace") }
    var processes: [MuseAgentProcess] = []
    var failures: [Bool] = []
    var heartbeats = 0
    init() throws { try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true) }
    func make(model: String = "fixture-model", extended: Bool = false, recovering: Bool = false) -> (MuseAgentProcess, MuseWireFixture) {
        let wire = MuseWireFixture(workspace: workspace)
        let agent = AgentRecord(displayName: "Muse fixture", harnessIdentifier: HarnessProvider.muse.rawValue,
            modelIdentifier: model, reasoningEffort: "high")
        let process = MuseAgentProcess(agent: agent, executableURL: URL(fileURLWithPath: "/fixture/muse"),
            workspaceURL: workspace, extendedAccess: extended, recoverInterruptedWork: recovering,
            onSnapshot: { _ in }, onHeartbeat: { [weak self] in self?.heartbeats += 1 },
            onUnexpectedTermination: { [weak self] _, _, recovery in self?.failures.append(recovery) },
            makeConnection: { wire })
        processes.append(process)
        return (process, wire)
    }
    func state(extended: Bool = false) -> URL {
        AgentStorageLayout(workspace: workspace).sessionState(provider: .muse, extendedAccess: extended)
    }
    func saved(extended: Bool = false) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state(extended: extended))) as? [String: Any])
    }
    func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Muse runtime did not reach expected state"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func cleanUp() {
        processes.forEach { $0.stop { _ in } }
        try? FileManager.default.removeItem(at: root)
    }
}
