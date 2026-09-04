import Foundation
import Observation
import SuperBotCore

@MainActor
@Observable
final class AgentRuntimeCoordinator {
    private(set) var installations: [HarnessInstallation]
    private(set) var snapshots: [UUID: AgentRuntimeSnapshot] = [:]

    private let discovery: HarnessDiscovery
    private var processes: [UUID: ACPAgentProcess] = [:]

    init(discovery: HarnessDiscovery = HarnessDiscovery()) {
        self.discovery = discovery
        installations = discovery.discover()
    }

    var availableInstallations: [HarnessInstallation] {
        installations.filter { $0.readiness != .unavailable }
    }

    var readyCount: Int {
        installations.filter { $0.readiness == .ready }.count
    }

    func refresh(agents: [AgentRecord]) {
        installations = discovery.discover()
        let liveIDs = Set(agents.map(\.id))
        for id in processes.keys where !liveIDs.contains(id) {
            processes[id]?.stop()
            processes[id] = nil
        }
        snapshots = Dictionary(uniqueKeysWithValues: agents.map { agent in
            if let process = processes[agent.id] {
                return (agent.id, process.snapshot)
            }
            let installation = installation(for: agent)
            let phase: AgentRuntimePhase = installation?.readiness == .ready ? .offline : .waitingForAdapter
            return (
                agent.id,
                AgentRuntimeSnapshot(
                    agentID: agent.id,
                    phase: phase,
                    detail: installation?.detail ?? "Choose a harness"
                )
            )
        })
    }

    func installation(for agent: AgentRecord) -> HarnessInstallation? {
        let requested = agent.harnessIdentifier.flatMap(HarnessProvider.init(rawValue:))
        let provider = requested ?? installations.first(where: { $0.readiness != .unavailable })?.provider
        return installations.first(where: { $0.provider == provider })
    }

    func snapshot(for agentID: UUID) -> AgentRuntimeSnapshot {
        snapshots[agentID] ?? AgentRuntimeSnapshot(
            agentID: agentID,
            phase: .offline,
            detail: "Not started"
        )
    }

    func deliver(
        message: ChatMessage,
        conversation: BotConversation,
        to agents: [AgentRecord],
        workspace: (AgentRecord) -> URL,
        onResponse: @escaping @MainActor (UUID, UUID, String) -> Void
    ) {
        for agent in agents {
            guard let installation = installation(for: agent) else {
                snapshots[agent.id] = AgentRuntimeSnapshot(
                    agentID: agent.id,
                    phase: .waitingForAdapter,
                    detail: "Choose a harness"
                )
                continue
            }
            guard installation.readiness == .ready,
                  let adapterPath = installation.acpAdapterPath else {
                snapshots[agent.id] = AgentRuntimeSnapshot(
                    agentID: agent.id,
                    phase: .waitingForAdapter,
                    detail: installation.detail
                )
                continue
            }

            let process = processFor(
                agent: agent,
                installation: installation,
                adapterPath: adapterPath,
                workspace: workspace(agent),
                onResponse: onResponse
            )
            process.deliver(message.body, conversationID: conversation.id)
            snapshots[agent.id] = process.snapshot
        }
    }

    func stopAll() {
        processes.values.forEach { $0.stop() }
        processes.removeAll()
        snapshots = snapshots.mapValues {
            AgentRuntimeSnapshot(agentID: $0.agentID, phase: .offline, detail: "Stopped")
        }
    }

    private func processFor(
        agent: AgentRecord,
        installation: HarnessInstallation,
        adapterPath: String,
        workspace: URL,
        onResponse: @escaping @MainActor (UUID, UUID, String) -> Void
    ) -> ACPAgentProcess {
        if let existing = processes[agent.id] { return existing }
        let process = ACPAgentProcess(
            agent: agent,
            installation: installation,
            adapterURL: URL(fileURLWithPath: adapterPath),
            workspaceURL: workspace,
            onSnapshot: { [weak self] snapshot in self?.snapshots[snapshot.agentID] = snapshot },
            onResponse: onResponse
        )
        processes[agent.id] = process
        return process
    }
}

@MainActor
private final class ACPAgentProcess {
    private enum RequestPurpose {
        case initialize
        case newSession(UUID)
        case prompt(UUID)
    }

    let agent: AgentRecord
    private let installation: HarnessInstallation
    private let adapterURL: URL
    private let workspaceURL: URL
    private let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    private let onResponse: @MainActor (UUID, UUID, String) -> Void

    private var process: Process?
    private var input: FileHandle?
    private var readBuffer = Data()
    private var nextRequestID = 1
    private var purposes: [Int: RequestPurpose] = [:]
    private var sessions: [UUID: String] = [:]
    private var pendingPrompts: [UUID: [String]] = [:]

    private(set) var snapshot: AgentRuntimeSnapshot

    init(
        agent: AgentRecord,
        installation: HarnessInstallation,
        adapterURL: URL,
        workspaceURL: URL,
        onSnapshot: @escaping @MainActor (AgentRuntimeSnapshot) -> Void,
        onResponse: @escaping @MainActor (UUID, UUID, String) -> Void
    ) {
        self.agent = agent
        self.installation = installation
        self.adapterURL = adapterURL
        self.workspaceURL = workspaceURL
        self.onSnapshot = onSnapshot
        self.onResponse = onResponse
        snapshot = AgentRuntimeSnapshot(agentID: agent.id, phase: .offline, detail: "Not started")
    }

    func deliver(_ prompt: String, conversationID: UUID) {
        pendingPrompts[conversationID, default: []].append(prompt)
        do {
            if process == nil { try start() }
            if let sessionID = sessions[conversationID] {
                sendNextPrompt(conversationID: conversationID, sessionID: sessionID)
            } else if !purposes.values.contains(where: {
                if case .newSession(let pendingID) = $0 { return pendingID == conversationID }
                return false
            }) {
                requestNewSession(conversationID: conversationID)
            }
        } catch {
            update(.failed, "\(installation.provider.displayName): \(error.localizedDescription)")
        }
    }

    func stop() {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        update(.offline, "Stopped")
    }

    private func start() throws {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = adapterURL
        process.currentDirectoryURL = workspaceURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        if let enginePath = installation.enginePath {
            let engineDirectory = URL(fileURLWithPath: enginePath).deletingLastPathComponent().path
            environment["PATH"] = engineDirectory + ":" + (environment["PATH"] ?? "")
        }
        environment["SUPERBOT_AGENT_ID"] = agent.id.uuidString.lowercased()
        environment["SUPERBOT_WORKSPACE"] = workspaceURL.path
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.receive(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let detail = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !detail.isEmpty else { return }
            Task { @MainActor in self?.update(.failed, detail) }
        }
        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                self?.process = nil
                self?.input = nil
                self?.update(.offline, "Exited with status \(terminated.terminationStatus)")
            }
        }

        update(.starting, "Starting \(installation.provider.displayName) through ACP")
        try process.run()
        self.process = process
        input = inputPipe.fileHandleForWriting
        snapshot.processIdentifier = process.processIdentifier
        onSnapshot(snapshot)

        let id = requestID(for: .initialize)
        try send([
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": 1,
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false
                ],
                "clientInfo": ["name": "SuperBot", "title": "SuperBot", "version": "0.2.0"]
            ]
        ])
    }

    private func requestNewSession(conversationID: UUID) {
        do {
            let id = requestID(for: .newSession(conversationID))
            try send([
                "jsonrpc": "2.0",
                "id": id,
                "method": "session/new",
                "params": ["cwd": workspaceURL.path, "mcpServers": []]
            ])
        } catch {
            update(.failed, error.localizedDescription)
        }
    }

    private func sendNextPrompt(conversationID: UUID, sessionID: String) {
        guard var queue = pendingPrompts[conversationID], !queue.isEmpty else { return }
        let body = queue.removeFirst()
        pendingPrompts[conversationID] = queue
        do {
            let id = requestID(for: .prompt(conversationID))
            try send([
                "jsonrpc": "2.0",
                "id": id,
                "method": "session/prompt",
                "params": [
                    "sessionId": sessionID,
                    "prompt": [["type": "text", "text": body]]
                ]
            ])
            update(.working, "Working in \(pendingPrompts.count) conversation\(pendingPrompts.count == 1 ? "" : "s")")
        } catch {
            update(.failed, error.localizedDescription)
        }
    }

    private func receive(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.prefix(upTo: newline)
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(value)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = message["id"] as? Int, let purpose = purposes.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                update(.failed, error["message"] as? String ?? "ACP request failed")
                return
            }
            let result = message["result"] as? [String: Any] ?? [:]
            switch purpose {
            case .initialize:
                update(.ready, "\(installation.provider.displayName) connected through ACP")
                for conversationID in pendingPrompts.keys where sessions[conversationID] == nil {
                    requestNewSession(conversationID: conversationID)
                }
            case .newSession(let conversationID):
                guard let sessionID = result["sessionId"] as? String else {
                    update(.failed, "ACP did not return a session identifier")
                    return
                }
                sessions[conversationID] = sessionID
                sendNextPrompt(conversationID: conversationID, sessionID: sessionID)
            case .prompt(let conversationID):
                update(.ready, "\(installation.provider.displayName) ready")
                if let sessionID = sessions[conversationID] {
                    sendNextPrompt(conversationID: conversationID, sessionID: sessionID)
                }
            }
            return
        }

        guard message["method"] as? String == "session/update",
              let params = message["params"] as? [String: Any],
              let sessionID = params["sessionId"] as? String,
              let conversationID = sessions.first(where: { $0.value == sessionID })?.key,
              let update = params["update"] as? [String: Any],
              let text = Self.firstText(in: update),
              !text.isEmpty else { return }
        onResponse(agent.id, conversationID, text)
    }

    private static func firstText(in value: Any) -> String? {
        if let object = value as? [String: Any] {
            if let text = object["text"] as? String { return text }
            for child in object.values {
                if let text = firstText(in: child) { return text }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let text = firstText(in: child) { return text }
            }
        }
        return nil
    }

    private func requestID(for purpose: RequestPurpose) -> Int {
        defer { nextRequestID += 1 }
        purposes[nextRequestID] = purpose
        return nextRequestID
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let input else { throw CocoaError(.fileNoSuchFile) }
        try input.write(contentsOf: data + Data([0x0A]))
    }

    private func update(_ phase: AgentRuntimePhase, _ detail: String) {
        snapshot = AgentRuntimeSnapshot(
            agentID: agent.id,
            phase: phase,
            detail: detail,
            processIdentifier: process?.processIdentifier
        )
        onSnapshot(snapshot)
    }
}
