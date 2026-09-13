import Foundation
import NoodleCore

/// Deterministic transports around the actual adapters. No account or external
/// process is used; completion and acknowledgement order are controlled here.
@MainActor final class ExtendedAgentConnection {
    static var current: ExtendedAgentConnection!
    static var workspace = ""
    var onData: ((Data, Bool) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onFailure: ((String) -> Void)?
    var provider: HarnessProvider = .codex
    var session = UUID().uuidString
    var turn = UUID().uuidString
    var prompts = 0
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
        case "thread/start", "thread/resume": result = ["thread": ["id": session]]
        case "thread/name/set", "authenticate": break
        case "session/new": result = ["sessionId": session]
        case "session/load":
            session = params["sessionId"] as! String
            result = ["sessionId": session]
        case "session/start", "session/resume":
            result = ["session": ["sessionId": session, "workspaceRoot": Self.workspace], "pendingRequests": []]
        case "session/prompt": prompts += 1; promptID = id; return
        case "turn/start":
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
                onApprovals: { _ in }, onUnexpectedTermination: { _, _, _ in })
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
