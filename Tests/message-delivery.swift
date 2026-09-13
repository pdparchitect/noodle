import Foundation
import NoodleCore

/// Deterministic transports around the actual adapters. No account or external
/// process is used; completion and acknowledgement order are controlled here.
@MainActor final class ExtendedAgentConnection {
    static var current: ExtendedAgentConnection!
    static var workspace = ""
    static var rejectCodexResume = false
    static var acpLoadError: [String: Any]?
    static var acpCreateError: [String: Any]?
    var lastPromptText = ""
    var onData: ((Data, Bool) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onFailure: ((String) -> Void)?
    var provider: HarnessProvider = .codex
    var session = UUID().uuidString
    var turn = UUID().uuidString
    var prompts = 0
    var createdSessions = 0
    var steers = 0
    var cancels = 0
    var holdStartAck = false
    var heldStartAck: [String: Any]?
    var heldSteer: [String: Any]?
    var interruptID: String?
    var promptID: Int?
    var permissionReply: [String: Any]?
    var invalidated = false
    var restrictedACP = false
    var restrictedMuse = false
    init() throws { Self.current = self }
    func start(provider: HarnessProvider, agentID: UUID, executablePath: String,
               sessionID: UUID? = nil, resumeSession: Bool = false,
               modelIdentifier: String? = nil, effortIdentifier: String? = nil,
               reply: @escaping (Int32, String?) -> Void) {
        self.provider = provider
        if let sessionID { session = sessionID.uuidString }
        reply(12345, nil)
    }
    func startRestrictedCodex(agentID: UUID, executablePath: String, reply: @escaping (Int32, String?) -> Void) {
        start(provider: .codex, agentID: agentID, executablePath: executablePath, reply: reply)
    }
    func startRestrictedApple(agentID: UUID, reply: @escaping (Int32, String?) -> Void) {
        start(provider: .apple, agentID: agentID, executablePath: "/fixture/apple", reply: reply)
    }
    func startRestrictedACP(provider: HarnessProvider, agentID: UUID, executablePath: String,
                            modelIdentifier: String?, effortIdentifier: String?, reply: @escaping (Int32, String?) -> Void) {
        restrictedACP = true
        start(provider: provider, agentID: agentID, executablePath: executablePath,
              modelIdentifier: modelIdentifier, effortIdentifier: effortIdentifier, reply: reply)
    }
    func startRestrictedMuse(agentID: UUID, executablePath: String, modelIdentifier: String?, effortIdentifier: String?,
                             reply: @escaping (Int32, String?) -> Void) {
        restrictedMuse = true
        start(provider: .muse, agentID: agentID, executablePath: executablePath,
              modelIdentifier: modelIdentifier, effortIdentifier: effortIdentifier, reply: reply)
    }
    func write(_ data: Data) {
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        if object["type"] as? String == "user" {
            prompts += 1
            emit(["type": "system", "subtype": "init", "session_id": session])
            return
        }
        if object["type"] as? String == "control_request" {
            precondition((object["request"] as? [String: String])?["subtype"] == "interrupt")
            interruptID = object["request_id"] as? String
            cancels += 1
            return
        }
        guard let method = object["method"] as? String else { permissionReply = object; return }
        let params = object["params"] as? [String: Any] ?? [:]
        if method == "session/cancel" { cancels += 1; return }
        guard let id = object["id"] as? Int else { return }
        var result: [String: Any] = [:]
        switch method {
        case "initialize":
            result = provider == .muse
                ? ["schema": ["version": 1], "serverInfo": ["name": "muse"], "sessionDurability": "durable"]
                : ["protocolVersion": 1]
        case "thread/start": result = ["thread": ["id": session]]
        case "thread/resume":
            if Self.rejectCodexResume {
                emit(["id": id, "error": ["code": -32000, "message": "Thread absent from private account"]]); return
            }
            result = ["thread": ["id": session]]
        case "thread/name/set", "authenticate": break
        case "session/new":
            createdSessions += 1
            if let error = Self.acpCreateError { emit(["id": id, "error": error]); return }
            result = ["sessionId": session]
        case "session/load":
            if let error = Self.acpLoadError {
                emit(["id": id, "error": error]); return
            }
            session = params["sessionId"] as! String
            result = ["sessionId": session]
        case "session/start", "session/resume":
            result = ["session": ["sessionId": session, "workspaceRoot": Self.workspace], "pendingRequests": []]
        case "session/prompt":
            lastPromptText = (params["prompt"] as? [[String: String]])?.first?["text"] ?? ""
            prompts += 1; promptID = id; return
        case "turn/start":
            lastPromptText = (params["input"] as? [[String: String]])?.first?["text"] ?? ""
            prompts += 1
            turn = UUID().uuidString
            result = provider == .codex ? ["turn": ["id": turn]]
                : ["status": "accepted", "commandId": params["commandId"]!, "turnId": turn, "disposition": "started"]
            if holdStartAck { heldStartAck = ["id": id, "result": result]; return }
        case "turn/steer":
            precondition(params["expectedTurnId"] as? String == turn, "Steer must target the active turn")
            precondition((params["input"] as? [[String: String]])?.first?["text"] == AgentWakeReason.inboxChanged.eventText)
            steers += 1; heldSteer = object; return
        default: preconditionFailure("Unexpected method: \(method)")
        }
        emit(["id": id, "result": result])
    }
    func acknowledgeStart() {
        if let ack = heldStartAck { heldStartAck = nil; emit(ack) }
    }
    func acknowledgeSteer(reject: Bool = false) {
        let request = heldSteer!; heldSteer = nil
        let params = request["params"] as! [String: Any]
        if reject { emit(["id": request["id"]!, "error": ["code": -32000, "message": "Turn no longer active"]]); return }
        var result: [String: Any] = ["turnId": params["expectedTurnId"]!]
        if provider == .muse { result["status"] = "accepted"; result["commandId"] = params["commandId"] }
        emit(["id": request["id"]!, "result": result])
    }
    func acknowledgeInterrupt(reject: Bool = false) {
        emit(["type": "control_response", "response": ["request_id": interruptID!, "subtype": reject ? "error" : "success"]])
        interruptID = nil
    }
    func complete(cancelled: Bool = false, turnID: String? = nil) {
        switch provider {
        case .codex:
            emit(["method": "turn/completed", "params": ["threadId": session,
                "turn": ["id": turnID ?? turn, "status": "completed"]]])
        case .muse:
            emit(["method": "turn/completed", "params": ["sessionId": session, "turnId": turnID ?? turn, "terminal": "completed"]])
        case .claudeCode:
            emit(["type": "result", "session_id": session, "is_error": false])
        case .apple, .fx, .grokBuild:
            emit(["id": promptID!, "result": ["stopReason": cancelled ? "cancelled" : "end_turn"]])
        }
    }
    func emit(_ object: [String: Any]) {
        onData?(try! JSONSerialization.data(withJSONObject: object) + Data([10]), false)
    }
    func invalidate() { invalidated = true }
    func stop(reply: @escaping (Bool) -> Void) { reply(true) }
}

@MainActor final class FixtureClassifier: MessageDeliveryClassifying {
    var isAvailable = true
    var pending: [CheckedContinuation<Bool, Error>] = []
    func shouldSendImmediately(_ context: MessageDeliveryContext) async throws -> Bool {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func resolve(_ immediate: Bool) { pending.removeFirst().resume(returning: immediate) }
    func fail() { pending.removeFirst().resume(throwing: CocoaError(.coderInvalidValue)) }
}

@main struct DeliveryChecks {
    @MainActor static func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Timed out waiting for runtime state")
    }
    static func settle() async { try? await Task.sleep(for: .milliseconds(30)) }

    @MainActor static func make(_ provider: HarnessProvider, root: URL, restrictedACP: Bool = false) async throws -> any AgentRuntimeProcess {
        let workspace = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        ExtendedAgentConnection.workspace = workspace.path
        let agent = AgentRecord(displayName: "Fixture", harnessIdentifier: provider.rawValue)
        let executable = URL(fileURLWithPath: "/fixture/harness")
        let process: any AgentRuntimeProcess
        switch provider {
        case .codex:
            process = CodexAgentProcess(agent: agent, executableURL: executable, workspaceURL: workspace,
                extendedAccess: true, recoverInterruptedWork: false, onSnapshot: { _ in }, onHeartbeat: {},
                onUnexpectedTermination: { _, _, _ in })
        case .claudeCode:
            process = ClaudeAgentProcess(agent: agent, executableURL: executable, workspaceURL: workspace,
                extendedAccess: true, recoverInterruptedWork: false, onSnapshot: { _ in }, onHeartbeat: {},
                onUnexpectedTermination: { _, _, _ in })
        case .muse:
            process = MuseAgentProcess(agent: agent, executableURL: executable, workspaceURL: workspace,
                extendedAccess: true, recoverInterruptedWork: false, onSnapshot: { _ in }, onHeartbeat: {},
                onUnexpectedTermination: { _, _, _ in })
        case .apple, .fx, .grokBuild:
            process = ACPAgentProcess(provider: provider, agent: agent, executableURL: executable, workspaceURL: workspace,
                extendedAccess: provider != .apple && !restrictedACP, recoverInterruptedWork: false, onSnapshot: { _ in }, onHeartbeat: {},
                onUnexpectedTermination: { _, _, _ in })
        }
        process.start()
        await eventually { process.snapshot.phase == .ready }
        return process
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--classify") {
            let classifier = MessageDeliveryClassifier()
            guard classifier.isAvailable else { print("Apple Intelligence unavailable; Automatic uses Queue."); return }
            var failures = 0
            for (message, immediate) in [("Hold off for now", true), ("Actually use the other repository", true),
                                         ("Also add a dark theme afterwards", false), ("Thanks!", false),
                                         ("Cancel the deployment", true), ("Can you write the docs when you're finished?", false),
                                         ("This is urgent: do not publish those changes", true), ("How is it going?", false),
                                         ("The site must launch next Friday", false), ("You are editing the production config. Stop.", true),
                                         ("Add a button labelled 'Stop now' after this task", false), ("Actually hold off.. just to confirm all of the harnesses wait for end of turn right?", true)] {
                let start = ContinuousClock.now
                let result: Bool
                do {
                    result = try await classifier.shouldSendImmediately(.init(unreadMessages: [message],
                        recentMessages: ["User: Update the website.", "Assistant: I am editing the website now."]))
                } catch {
                    print("\(message): model error; Automatic would leave this queued (\(error.localizedDescription))")
                    failures += 1
                    break
                }
                print("\(message): \(result ? "immediate" : "queue") in \(start.duration(to: .now)); expected \(immediate)")
                if result != immediate { failures += 1 }
            }
            print("Classification mismatches: \(failures)")
            if failures > 0 { exit(1) }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        // A legacy thread in shared CODEX_HOME must recover through Messenger
        // after switching to private storage, even without a new inbox event.
        do {
            let workspace = root.appendingPathComponent("legacy-codex/workspace")
            let layout = AgentStorageLayout(workspace: workspace)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: layout.runtime, withIntermediateDirectories: true)
            let oldThread = UUID().uuidString
            try JSONSerialization.data(withJSONObject: ["version": 9, "threadID": oldThread])
                .write(to: layout.sessionState(provider: .codex, extendedAccess: false))
            ExtendedAgentConnection.rejectCodexResume = true
            defer { ExtendedAgentConnection.rejectCodexResume = false }
            let agent = AgentRecord(displayName: "Private Codex", harnessIdentifier: "codex")
            let process = CodexAgentProcess(agent: agent, executableURL: URL(fileURLWithPath: "/fixture/codex"),
                workspaceURL: workspace, extendedAccess: false, recoverInterruptedWork: false,
                onSnapshot: { _ in }, onHeartbeat: {}, onUnexpectedTermination: { _, _, _ in })
            process.start()
            await eventually { ExtendedAgentConnection.current.prompts == 1 && process.snapshot.phase == .working }
            let wire = ExtendedAgentConnection.current!
            precondition(wire.lastPromptText.contains(MessengerDocumentation.recoveredModelContext))
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: layout.sessionState(provider: .codex, extendedAccess: false))) as! [String: Any]
            precondition(saved["threadID"] as? String != oldThread)
            precondition(saved["needsHistoryRecovery"] as? Bool == false)
            wire.complete()
            await eventually { process.snapshot.phase == .ready }
            process.stop { _ in }
            print("PASS: Codex shared-session migration recovers context through Messenger")
        }

        for provider in HarnessProvider.allCases {
            let process = try await make(provider, root: root)
            let wire = ExtendedAgentConnection.current!
            process.notify()
            await eventually { wire.prompts == 1 && process.snapshot.phase == .working }
            await settle()
            process.notify()
            await settle()
            precondition(wire.prompts == 1 && wire.steers == 0 && wire.cancels == 0, "Queue must wait")
            wire.complete()
            await eventually { wire.prompts == 2 }
            await settle()
            process.notify(immediately: true)
            if provider == .codex || provider == .muse {
                await eventually { wire.steers == 1 }
                precondition(wire.prompts == 2, "Steering must not start another turn")
                wire.acknowledgeSteer()
                await settle()
                wire.complete()
                await eventually { process.canReceiveHeartbeat }
                precondition(wire.prompts == 2, "Accepted steering must not cause a duplicate wake")
            } else {
                await eventually { wire.cancels == 1 }
                precondition(wire.prompts == 2, "Drain the interrupted turn before sending its replacement")
                wire.complete(cancelled: true)
                if provider == .claudeCode {
                    await settle()
                    precondition(wire.prompts == 2, "Wait for the interrupt acknowledgement too")
                    wire.acknowledgeInterrupt()
                }
                await eventually { wire.prompts == 3 }
                wire.complete()
                await eventually { process.canReceiveHeartbeat }
            }
            process.stop { _ in }
            print("PASS: \(provider.rawValue) queue and immediate delivery")
        }

        for provider in [HarnessProvider.codex, .muse] {
            let process = try await make(provider, root: root)
            let wire = ExtendedAgentConnection.current!
            wire.holdStartAck = true
            process.notify()
            process.notify(immediately: true)
            precondition(wire.steers == 0)
            wire.acknowledgeStart()
            await eventually { wire.steers == 1 }
            wire.holdStartAck = false
            wire.complete() // Turn ends while the steering request is in flight.
            await settle()
            precondition(!process.canReceiveHeartbeat)
            wire.acknowledgeSteer(reject: true)
            await eventually { wire.prompts == 2 }
            await settle()
            let current = wire.turn
            wire.complete(turnID: UUID().uuidString)
            await settle()
            precondition(process.snapshot.phase == .working, "Ignore stale turn completion")
            wire.complete(turnID: current)
            await eventually { process.canReceiveHeartbeat }
            wire.holdStartAck = true
            process.notify()
            wire.complete() // Terminal event arrives before start acknowledgement.
            await settle()
            wire.acknowledgeStart()
            await eventually { process.canReceiveHeartbeat }
            process.stop { _ in }
            print("PASS: \(provider.rawValue) start/steer/completion races")
        }

        // Connection errors are scoped to the current turn and remain visible
        // while Codex retries. They must not acknowledge unfinished work.
        do {
            let process = try await make(.codex, root: root)
            let wire = ExtendedAgentConnection.current!
            let state = AgentStorageLayout(workspace: URL(fileURLWithPath: ExtendedAgentConnection.workspace))
                .sessionState(provider: .codex, extendedAccess: true)
            let recovery = AgentTurnRecovery(sessionStateURL: state)
            func reportError(thread: String? = nil, turn: String? = nil, retry: Bool = true) {
                wire.emit(["method": "error", "params": ["threadId": thread ?? wire.session,
                    "turnId": turn ?? wire.turn, "willRetry": retry, "error": [
                        "message": "private raw transport detail",
                        "codexErrorInfo": ["responseStreamConnectionFailed": ["httpStatusCode": NSNull()]]]]])
            }
            func reportOutput(turn: String? = nil) {
                wire.emit(["method": "item/agentMessage/delta", "params": ["threadId": wire.session,
                    "turnId": turn ?? wire.turn, "itemId": "reply", "delta": "Hello"]])
            }
            process.notify()
            await eventually { wire.prompts == 1 && process.snapshot.phase == .working }
            await settle()
            let savedState = try Data(contentsOf: state)
            reportError(thread: "another-thread")
            reportError(turn: "another-turn")
            await settle()
            precondition(process.snapshot.phase == .working, "Ignore errors for other work")
            reportError()
            await eventually { process.snapshot.phase == .failed }
            precondition(process.snapshot.detail.contains("Retrying automatically"))
            precondition(!process.snapshot.detail.contains("private raw"))
            precondition(process.isAlive && recovery.hasUnfinishedTurn && !process.canReceiveHeartbeat)
            let stateAfterError = try Data(contentsOf: state)
            precondition(stateAfterError == savedState)
            process.notify(immediately: true)
            await settle()
            precondition(wire.prompts == 1 && wire.steers == 0)
            reportOutput(turn: "another-turn")
            await settle()
            precondition(process.snapshot.phase == .failed, "Stale output must not clear the error")
            reportOutput()
            await eventually { process.snapshot.phase == .working && wire.steers == 1 }
            wire.acknowledgeSteer()
            await settle()
            precondition(recovery.hasUnfinishedTurn)
            wire.complete()
            await eventually { process.canReceiveHeartbeat }
            precondition(!recovery.hasUnfinishedTurn && wire.prompts == 1)
            reportError()
            await settle()
            precondition(process.snapshot.phase == .ready, "Ignore errors after completion")

            wire.holdStartAck = true
            process.notify()
            reportError()
            await settle()
            wire.acknowledgeStart()
            await eventually { process.snapshot.phase == .failed }
            precondition(recovery.hasUnfinishedTurn, "An early retry error must preserve recovery")
            reportError(retry: false)
            await eventually { !process.snapshot.detail.contains("Retrying automatically") }
            precondition(process.snapshot.detail.contains("Kick") && recovery.hasUnfinishedTurn)
            wire.emit(["method": "turn/completed", "params": ["threadId": wire.session,
                "turn": ["id": wire.turn, "status": "failed", "error": ["message": "Connection failed"]]]])
            await eventually { !recovery.hasUnfinishedTurn }
            precondition(process.snapshot.phase == .failed)
            process.stop { _ in }
            print("PASS: Codex retry errors are visible, scoped, recoverable, and preserve unfinished work")
        }

        // Claude can acknowledge interruption before or after the old result.
        // A rejected control request must leave the wake queued for that result.
        for reject in [false, true] {
            let process = try await make(.claudeCode, root: root)
            let wire = ExtendedAgentConnection.current!
            process.notify(); await settle()
            process.notify(immediately: true)
            await eventually { wire.cancels == 1 }
            wire.acknowledgeInterrupt(reject: reject); await settle()
            precondition(wire.prompts == 1 && wire.cancels == 1)
            wire.complete(cancelled: !reject)
            await eventually { wire.prompts == 2 }
            wire.complete()
            await eventually { process.canReceiveHeartbeat }
            process.stop { _ in }
        }
        print("PASS: Claude acknowledgement-first and rejected interruption")

        for provider in [HarnessProvider.fx, .grokBuild] {
            let process = try await make(provider, root: root)
            let wire = ExtendedAgentConnection.current!
            process.notify(); await settle()
            process.notify(immediately: true)
            await eventually { wire.cancels == 1 }
            wire.emit(["id": "permission-during-cancellation", "method": "session/request_permission",
                       "params": ["sessionId": wire.session]])
            await eventually { wire.permissionReply != nil }
            let result = wire.permissionReply?["result"] as? [String: Any]
            precondition((result?["outcome"] as? [String: String])?["outcome"] == "cancelled")
            wire.complete(cancelled: true)
            await eventually { wire.prompts == 2 }
            process.stop { _ in }
        }
        print("PASS: ACP permissions are cancelled while interruption drains")

        for provider in [HarnessProvider.fx, .grokBuild] {
            let process = try await make(provider, root: root, restrictedACP: true)
            let wire = ExtendedAgentConnection.current!
            precondition(wire.restrictedACP, "Restricted FX/Grok must use the restricted host endpoint")
            process.notify()
            await eventually { wire.prompts == 1 }
            wire.emit(["id": "restricted-permission", "method": "session/request_permission", "params": [
                "sessionId": wire.session, "options": [["kind": "allow_always", "optionId": "always"],
                                                      ["kind": "allow_once", "optionId": "once"]]]])
            await eventually { wire.permissionReply != nil }
            let result = wire.permissionReply?["result"] as? [String: Any]
            precondition((result?["outcome"] as? [String: String])?["optionId"] == "once")
            wire.permissionReply = nil
            process.notify(immediately: true)
            await eventually { wire.cancels == 1 }
            wire.emit(["id": "restricted-cancel", "method": "session/request_permission", "params": [
                "sessionId": wire.session, "options": [["kind": "allow_once", "optionId": "once"]]]])
            await eventually { wire.permissionReply != nil }
            let cancelled = wire.permissionReply?["result"] as? [String: Any]
            precondition((cancelled?["outcome"] as? [String: String])?["outcome"] == "cancelled")
            wire.complete(cancelled: true)
            await eventually { wire.prompts == 2 }
            wire.complete()
            await eventually { process.canReceiveHeartbeat }
            process.stop { _ in }
        }
        print("PASS: Restricted FX/Grok startup, allow-once approvals, and cancellation")

        // Missing session files must not turn into a reconnect loop or an
        // automatic history reset. Resume the same session after a manual kick.
        for error: [String: Any] in [
            ["code": -32603, "message": "Path not found.",
             "data": ["code": "FS_NOT_FOUND", "detail": "/private/account/session.json"]],
            ["code": -32603, "message": "Session not found"]
        ] {
            let workspace = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace")
            let layout = AgentStorageLayout(workspace: workspace)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: layout.runtime, withIntermediateDirectories: true)
            let stateURL = layout.sessionState(provider: .grokBuild, extendedAccess: true)
            let savedSession = UUID().uuidString
            let savedState = try JSONSerialization.data(withJSONObject: ["sessionID": savedSession])
            try savedState.write(to: stateURL)
            var recovery = AgentTurnRecovery(sessionStateURL: stateURL)
            try recovery.begin()
            let unfinishedURL = stateURL.appendingPathExtension("unfinished")
            let unfinished = try Data(contentsOf: unfinishedURL)
            let agent = AgentRecord(displayName: "Missing session fixture", harnessIdentifier: HarnessProvider.grokBuild.rawValue)
            var terminations = 0
            let process = ACPAgentProcess(provider: .grokBuild, agent: agent,
                executableURL: URL(fileURLWithPath: "/fixture/harness"), workspaceURL: workspace,
                extendedAccess: true, recoverInterruptedWork: false, onSnapshot: { _ in }, onHeartbeat: {},
                onUnexpectedTermination: { _, _, _ in terminations += 1 })
            ExtendedAgentConnection.acpLoadError = error
            process.start()
            await eventually { process.snapshot.phase == .failed }
            let wire = ExtendedAgentConnection.current!
            precondition(process.snapshot.detail.contains("saved session") && process.snapshot.detail.contains("Kick"))
            precondition(process.snapshot.failure == .missingSession(savedSession))
            precondition(!process.snapshot.detail.contains("/private") && !process.snapshot.detail.contains("sign-in"))
            precondition(process.isAlive && process.hasInterruptedWork && !process.canReceiveHeartbeat)
            precondition(wire.invalidated && wire.createdSessions == 0 && wire.prompts == 0 && terminations == 0)
            let failure = process.snapshot
            process.notify(immediately: true)
            process.heartbeat()
            process.start()
            wire.onExit?(1)
            wire.onFailure?("Late disconnect")
            wire.emit(["id": 3, "result": ["sessionId": "stale-session"]])
            await settle()
            precondition(process.snapshot == failure && terminations == 0 && wire.prompts == 0)
            let stateAfterFailure = try Data(contentsOf: stateURL)
            let unfinishedAfterFailure = try Data(contentsOf: unfinishedURL)
            precondition(stateAfterFailure == savedState && unfinishedAfterFailure == unfinished)
            process.stop { _ in }
            ExtendedAgentConnection.acpLoadError = nil

            let restarted = ACPAgentProcess(provider: .grokBuild, agent: agent,
                executableURL: URL(fileURLWithPath: "/fixture/harness"), workspaceURL: workspace,
                extendedAccess: true, recoverInterruptedWork: false, onSnapshot: { _ in }, onHeartbeat: {},
                onUnexpectedTermination: { _, _, _ in preconditionFailure("Unexpected recovery termination") })
            restarted.start()
            await eventually { restarted.snapshot.phase == .working }
            let resumed = ExtendedAgentConnection.current!
            precondition(resumed.session == savedSession && resumed.createdSessions == 0 && resumed.prompts == 1)
            resumed.complete()
            await eventually { restarted.canReceiveHeartbeat }
            precondition(!restarted.hasInterruptedWork)
            restarted.stop { _ in }
        }
        print("PASS: Missing Grok sessions pause retries, preserve history/work, and resume after repair and Kick")

        // The coordinator separately tests confirmation and stop ordering. Here
        // exercise the actual adapter after an authorized replacement, including
        // no unread messages and no unfinished marker (the inbox was consumed).
        for extended in [false, true] {
            let workspace = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace")
            let layout = AgentStorageLayout(workspace: workspace)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: layout.runtime, withIntermediateDirectories: true)
            let stateURL = layout.sessionState(provider: .grokBuild, extendedAccess: extended)
            let oldSession = UUID().uuidString
            try ACPSessionState(sessionID: oldSession).save(to: stateURL)
            try ACPSessionState.prepareRecovery(at: stateURL, replacing: oldSession)
            let agent = AgentRecord(displayName: "Confirmed recovery", harnessIdentifier: HarnessProvider.grokBuild.rawValue)
            func replacement() -> ACPAgentProcess {
                ACPAgentProcess(provider: .grokBuild, agent: agent, executableURL: URL(fileURLWithPath: "/fixture/harness"),
                    workspaceURL: workspace, extendedAccess: extended, recoverInterruptedWork: false,
                    onSnapshot: { _ in }, onHeartbeat: {},
                    onUnexpectedTermination: { _, _, _ in preconditionFailure("Recovery must not enter supervision") })
            }
            let process = replacement()
            process.start()
            await eventually { process.snapshot.phase == .working }
            let wire = ExtendedAgentConnection.current!
            let replacementID = wire.session
            precondition(wire.createdSessions == 1 && replacementID != oldSession)
            precondition(wire.lastPromptText.contains(AgentWakeReason.runtimeRecovered.eventText))
            precondition(wire.lastPromptText.contains(MessengerDocumentation.recoveredModelContext))
            precondition(wire.lastPromptText.contains("--list-messages"))
            precondition(process.hasInterruptedWork)
            process.notify(immediately: true)
            await eventually { wire.cancels == 1 }
            wire.complete(cancelled: true)
            await eventually { wire.prompts == 2 }
            precondition(wire.lastPromptText.contains(MessengerDocumentation.recoveredModelContext), "A cancelled recovery must still reconstruct history")
            wire.onExit?(1)
            await eventually { process.snapshot.failure == .recoveryFailed }
            let unfinished = try Data(contentsOf: stateURL.appendingPathExtension("unfinished"))
            process.stop { _ in }

            let relaunched = replacement()
            relaunched.start()
            precondition(relaunched.snapshot.failure == .recoveryFailed && relaunched.isAlive)
            precondition(ExtendedAgentConnection.current === wire, "App relaunch must not retry blocked recovery")
            relaunched.notify(immediately: true)
            relaunched.heartbeat()
            relaunched.start()
            precondition(ExtendedAgentConnection.current === wire)
            let unfinishedAfterRelaunch = try Data(contentsOf: stateURL.appendingPathExtension("unfinished"))
            precondition(unfinishedAfterRelaunch == unfinished)
            relaunched.stop { _ in }

            try ACPSessionState.allowRecoveryRetry(at: stateURL)
            let retry = replacement()
            retry.start()
            await eventually { retry.snapshot.phase == .working }
            let resumed = ExtendedAgentConnection.current!
            precondition(resumed.createdSessions == 0 && resumed.session == replacementID)
            precondition(resumed.lastPromptText.contains(MessengerDocumentation.recoveredModelContext))
            resumed.complete()
            await eventually { retry.canReceiveHeartbeat }
            precondition(!retry.hasInterruptedWork)
            let saved = try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: stateURL))
            precondition(saved.sessionID == replacementID && saved.previousSessionIDs == [oldSession])
            precondition(!saved.needsHistoryRecovery && !saved.recoveryBlocked)
            retry.notify()
            await eventually { resumed.prompts == 2 }
            precondition(!resumed.lastPromptText.contains(MessengerDocumentation.recoveredModelContext))
            resumed.complete()
            await eventually { retry.canReceiveHeartbeat }
            retry.stop { _ in }
        }
        print("PASS: Confirmed Grok recovery reconstructs consumed inbox context, survives cancellation, and resumes once after explicit retry")

        do {
            let workspace = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("workspace")
            let layout = AgentStorageLayout(workspace: workspace)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: layout.runtime, withIntermediateDirectories: true)
            let stateURL = layout.sessionState(provider: .grokBuild, extendedAccess: true)
            let oldSession = UUID().uuidString
            try ACPSessionState(sessionID: oldSession).save(to: stateURL)
            try ACPSessionState.prepareRecovery(at: stateURL, replacing: oldSession)
            let agent = AgentRecord(displayName: "Failed replacement", harnessIdentifier: HarnessProvider.grokBuild.rawValue)
            func replacement() -> ACPAgentProcess {
                ACPAgentProcess(provider: .grokBuild, agent: agent, executableURL: URL(fileURLWithPath: "/fixture/harness"),
                    workspaceURL: workspace, extendedAccess: true, recoverInterruptedWork: false,
                    onSnapshot: { _ in }, onHeartbeat: {},
                    onUnexpectedTermination: { _, _, _ in preconditionFailure("Failed creation must pause") })
            }
            ExtendedAgentConnection.acpCreateError = ["code": -32603, "message": "Storage unavailable"]
            let process = replacement()
            process.start()
            await eventually { process.snapshot.failure == .recoveryFailed }
            let wire = ExtendedAgentConnection.current!
            precondition(wire.createdSessions == 1 && wire.prompts == 0)
            process.stop { _ in }
            let relaunched = replacement()
            relaunched.start()
            precondition(relaunched.snapshot.failure == .recoveryFailed && ExtendedAgentConnection.current === wire)
            let state = try JSONDecoder().decode(ACPSessionState.self, from: Data(contentsOf: stateURL))
            precondition(state.sessionID == nil && state.previousSessionIDs == [oldSession] && state.recoveryBlocked)
            relaunched.stop { _ in }
            ExtendedAgentConnection.acpCreateError = nil
        }
        print("PASS: Failed Grok replacement creation is bounded across app relaunch")

        // Unknown load failures still reach supervision, and the Grok storage
        // classification must not change another provider's error handling.
        for provider in [HarnessProvider.grokBuild, .fx] {
            let ready = try await make(provider, root: root)
            let workspace = URL(fileURLWithPath: ExtendedAgentConnection.workspace)
            let stateURL = AgentStorageLayout(workspace: workspace).sessionState(provider: provider, extendedAccess: true)
            let state = try Data(contentsOf: stateURL)
            ready.stop { _ in }
            ExtendedAgentConnection.acpLoadError = ["code": -32603, "message": "Internal error",
                "data": ["code": provider == .grokBuild ? "CONNECTION_TIMEOUT" : "FS_NOT_FOUND"]]
            var terminations = 0
            let process = ACPAgentProcess(provider: provider, agent: ready.configuration,
                executableURL: URL(fileURLWithPath: "/fixture/harness"), workspaceURL: workspace,
                extendedAccess: true, recoverInterruptedWork: false, onSnapshot: { _ in }, onHeartbeat: {},
                onUnexpectedTermination: { _, _, _ in terminations += 1 })
            process.start()
            await eventually { terminations == 1 }
            precondition(!process.isAlive && !process.snapshot.detail.contains("retries are paused"))
            let stateAfterFailure = try Data(contentsOf: stateURL)
            precondition(stateAfterFailure == state)
            process.stop { _ in }
            ExtendedAgentConnection.acpLoadError = nil
        }
        // A tool/turn path error is not proof that the saved session is missing.
        do {
            let process = try await make(.grokBuild, root: root)
            let wire = ExtendedAgentConnection.current!
            process.notify()
            await eventually { wire.prompts == 1 }
            wire.emit(["id": wire.promptID!, "error": ["code": -32603, "message": "Path not found.",
                "data": ["code": "FS_NOT_FOUND"]]])
            await eventually { process.snapshot.phase == .failed }
            precondition(!wire.invalidated && !process.snapshot.detail.contains("saved session"))
            process.stop { _ in }
        }
        print("PASS: Grok missing-session handling is limited to session/load; other failures retain their recovery path")

        // Replay Grok's actual billing-failure shapes without contacting an
        // account. A disconnected, exhausted bot must wait for a manual kick.
        for failureMode in 0..<4 {
            let process = try await make(.grokBuild, root: root)
            let workspace = URL(fileURLWithPath: ExtendedAgentConnection.workspace)
            let wire = ExtendedAgentConnection.current!
            let stateURL = AgentStorageLayout(workspace: workspace).sessionState(provider: .grokBuild, extendedAccess: true)
            let savedState = try Data(contentsOf: stateURL)
            process.notify()
            await eventually { wire.prompts == 1 && process.snapshot.phase == .working }
            let message = "API error (status 402 Payment Required): Grok Build usage balance exhausted"
            if failureMode == 0 {
                wire.emit(["id": wire.promptID!, "error": ["code": -32603, "message": "Internal error",
                    "data": ["http_status": 402, "message": message]]])
            } else {
                let update: [String: Any] = failureMode == 2
                    ? ["sessionUpdate": "turn_completed", "stop_reason": "error", "agent_result": message]
                    : ["sessionUpdate": "retry_state", "type": "failed", "error_type": "api", "message": message]
                wire.emit(["method": "_x.ai/session/update", "params": ["sessionId": wire.session, "update": update]])
                await settle()
                if failureMode == 3 { wire.onExit?(1) }
                else if failureMode == 2 { wire.emit(["id": wire.promptID!, "result": ["stopReason": "error"]]) }
                else { wire.emit(["id": wire.promptID!, "error": ["code": -32603, "message": "Internal error"]]) }
            }
            await eventually { process.snapshot.phase == .failed }
            precondition(process.snapshot.detail.contains("usage limit") && process.snapshot.detail.contains("Kick"))
            precondition(process.isAlive && process.hasInterruptedWork && !process.canReceiveHeartbeat)
            precondition(wire.invalidated, "Pause must close the exhausted transport")
            let failure = process.snapshot
            process.notify(immediately: true)
            process.heartbeat()
            process.start()
            wire.onExit?(1)
            wire.onFailure?("Late disconnect")
            wire.complete()
            await settle()
            precondition(process.snapshot == failure && wire.prompts == 1, "No automatic retry or stale completion may clear the failure")
            let stateAfterFailure = try Data(contentsOf: stateURL)
            precondition(stateAfterFailure == savedState, "Keep the saved session")
            process.stop { _ in }

            let restarted = ACPAgentProcess(provider: .grokBuild, agent: process.configuration,
                executableURL: URL(fileURLWithPath: "/fixture/harness"), workspaceURL: workspace,
                extendedAccess: true, recoverInterruptedWork: false, onSnapshot: { _ in }, onHeartbeat: {},
                onUnexpectedTermination: { _, _, _ in preconditionFailure("Unexpected recovery termination") })
            restarted.start()
            await eventually { restarted.snapshot.phase == .working }
            let resumedWire = ExtendedAgentConnection.current!
            precondition(resumedWire.session == wire.session && resumedWire.prompts == 1, "Kick must resume the saved session and unfinished work")
            resumedWire.complete()
            await eventually { restarted.canReceiveHeartbeat }
            precondition(!restarted.hasInterruptedWork && !restarted.snapshot.detail.contains("usage limit"))
            restarted.stop { _ in }
        }
        print("PASS: Grok usage limits pause reconnects and preserve work for a successful kick")

        // Ignore failure text from another session, historical replay while
        // idle, and non-Grok providers.
        for provider in [HarnessProvider.grokBuild, .fx] {
            let process = try await make(provider, root: root)
            let wire = ExtendedAgentConnection.current!
            let update: [String: Any] = ["sessionUpdate": "retry_state", "type": "failed", "error_type": "api",
                "message": "Grok Build usage balance exhausted"]
            wire.emit(["method": "_x.ai/session/update", "params": ["sessionId": wire.session, "update": update]])
            await settle()
            process.notify()
            await eventually { wire.prompts == 1 && process.snapshot.phase == .working }
            wire.emit(["method": "_x.ai/session/update", "params": ["sessionId": "other-session", "update": update]])
            if provider == .fx {
                wire.emit(["method": "_x.ai/session/update", "params": ["sessionId": wire.session, "update": update]])
            }
            await settle()
            wire.complete()
            await eventually { process.canReceiveHeartbeat }
            precondition(!wire.invalidated)
            process.stop { _ in }
        }
        print("PASS: Grok billing updates are scoped to the active provider, session and turn")

        let process = try await make(.codex, root: root)
        let wire = ExtendedAgentConnection.current!
        process.notify(); await settle()
        let suite = "DeliveryRouterFixture.\(UUID())", classifier = FixtureClassifier()
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let router = MessageDeliveryRouter(defaults: defaults, classifier: classifier, timeout: .milliseconds(150))
        let context: @MainActor () async throws -> MessageDeliveryContext? = {
            .init(unreadMessages: ["hold off"], recentMessages: ["User: edit the website"])
        }
        classifier.isAvailable = false
        router.notify(process, context: context)
        await settle()
        precondition(classifier.pending.isEmpty && wire.steers == 0)
        classifier.isAvailable = true
        router.notify(process, context: context)
        await eventually { classifier.pending.count == 1 }
        classifier.resolve(true)
        await eventually { wire.steers == 1 }
        wire.acknowledgeSteer(); await settle()

        router.notify(process, context: context)
        await eventually { classifier.pending.count == 1 }
        wire.complete() // Queued wake is delivered before classification finishes.
        await eventually { wire.prompts == 2 }
        classifier.resolve(true); await settle()
        precondition(wire.steers == 1, "A late classifier must not interrupt the new turn")

        router.notify(process, context: context)
        await eventually { classifier.pending.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        classifier.resolve(true); await settle()
        precondition(wire.steers == 1, "Timed-out classification must stay queued")

        router.notify(process, context: context)
        await eventually { classifier.pending.count == 1 }
        classifier.resolve(false); await settle()
        precondition(wire.steers == 1, "Routine messages must stay queued")
        router.notify(process, context: context)
        await eventually { classifier.pending.count == 1 }
        classifier.fail(); await settle()
        precondition(wire.steers == 1, "Classifier errors must stay queued")

        router.notify(process, context: context)
        await eventually { classifier.pending.count == 1 }
        router.notify(process, context: context)
        await eventually { classifier.pending.count == 2 }
        classifier.resolve(true); await settle()
        precondition(wire.steers == 1, "A superseded classification must not promote the batch")
        classifier.resolve(false); await settle()

        defaults.set(MessageDeliveryMode.queue.rawValue, forKey: MessageDeliveryMode.defaultsKey)
        router.notify(process, context: context)
        await settle()
        precondition(classifier.pending.isEmpty && wire.steers == 1)
        defaults.set(MessageDeliveryMode.immediate.rawValue, forKey: MessageDeliveryMode.defaultsKey)
        router.notify(process, context: context)
        await eventually { wire.steers == 2 }
        precondition(classifier.pending.isEmpty)
        wire.acknowledgeSteer(); await settle()
        process.stop { _ in }
        router.cancelAll()
        print("PASS: Automatic availability, promotion, late results, timeout, and explicit settings")
    }
}
