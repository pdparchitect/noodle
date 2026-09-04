import Darwin
import Foundation
import Observation
import SuperBotCore

@MainActor
@Observable
final class AgentRuntimeCoordinator {
    private(set) var installations: [HarnessInstallation]
    private(set) var modelsByProvider: [HarnessProvider: [HarnessModel]] = [:]
    private(set) var capabilityErrors: [HarnessProvider: String] = [:]
    private(set) var isLoadingCapabilities = false
    private(set) var snapshots: [UUID: AgentRuntimeSnapshot] = [:]

    private let discovery: HarnessDiscovery
    private var processes: [UUID: CodexAgentProcess] = [:]
    private var capabilityProbe: CodexCapabilityProbe?

    init(discovery: HarnessDiscovery = HarnessDiscovery()) {
        self.discovery = discovery
        installations = discovery.discover()
    }

    var availableInstallations: [HarnessInstallation] {
        installations.filter(\.isAvailable)
    }

    func installation(for agent: AgentRecord) -> HarnessInstallation? {
        guard let identifier = agent.harnessIdentifier,
              let provider = HarnessProvider(rawValue: identifier) else { return nil }
        return installations.first { $0.provider == provider && $0.isAvailable }
    }

    func models(for harnessIdentifier: String?) -> [HarnessModel] {
        guard let harnessIdentifier,
              let provider = HarnessProvider(rawValue: harnessIdentifier) else { return [] }
        return modelsByProvider[provider, default: []]
    }

    func snapshot(for agentID: UUID) -> AgentRuntimeSnapshot {
        snapshots[agentID] ?? AgentRuntimeSnapshot(
            agentID: agentID,
            phase: .offline,
            detail: "Not started"
        )
    }

    func refresh(agents: [AgentRecord], repository: WorkspaceRepository? = nil) {
        installations = discovery.discover()
        let liveIDs = Set(agents.map(\.id))
        for id in processes.keys where !liveIDs.contains(id) {
            processes.removeValue(forKey: id)?.stop()
        }

        for agent in agents {
            if let process = processes[agent.id] {
                snapshots[agent.id] = process.snapshot
            } else if agent.harnessIdentifier == nil {
                snapshots[agent.id] = AgentRuntimeSnapshot(
                    agentID: agent.id,
                    phase: .failed,
                    detail: "Choose a harness in Edit Bot"
                )
            } else if installation(for: agent) != nil {
                snapshots[agent.id] = AgentRuntimeSnapshot(
                    agentID: agent.id,
                    phase: .offline,
                    detail: "Codex is configured"
                )
            } else {
                snapshots[agent.id] = AgentRuntimeSnapshot(
                    agentID: agent.id,
                    phase: .failed,
                    detail: "The configured harness is not installed"
                )
            }
        }
        snapshots = snapshots.filter { liveIDs.contains($0.key) }

        if let repository {
            for agent in agents where processes[agent.id]?.configuration != agent {
                processes.removeValue(forKey: agent.id)?.stop()
                start(agent: agent, repository: repository)
            }
        }
    }

    func refreshCapabilities() {
        installations = discovery.discover()
        capabilityProbe?.stop()
        capabilityProbe = nil
        capabilityErrors.removeAll()

        guard let installation = availableInstallations.first(where: { $0.provider == .codex }),
              let executablePath = installation.executablePath else {
            modelsByProvider[.codex] = []
            capabilityErrors[.codex] = "Codex is not installed"
            isLoadingCapabilities = false
            return
        }

        isLoadingCapabilities = true
        let probe = CodexCapabilityProbe(executableURL: URL(fileURLWithPath: executablePath))
        capabilityProbe = probe
        probe.loadModels { [weak self, weak probe] result in
            guard let self, self.capabilityProbe === probe else { return }
            self.capabilityProbe = nil
            self.isLoadingCapabilities = false
            switch result {
            case .success(let models):
                self.modelsByProvider[.codex] = models
                self.capabilityErrors[.codex] = nil
            case .failure(let error):
                self.modelsByProvider[.codex] = []
                self.capabilityErrors[.codex] = error.localizedDescription
            }
        }
    }

    func startAll(agents: [AgentRecord], repository: WorkspaceRepository) {
        installations = discovery.discover()
        for agent in agents {
            start(agent: agent, repository: repository)
        }
    }

    func start(agent: AgentRecord, repository: WorkspaceRepository) {
        guard processes[agent.id] == nil else { return }
        guard let installation = installation(for: agent),
              let executablePath = installation.executablePath else {
            snapshots[agent.id] = AgentRuntimeSnapshot(
                agentID: agent.id,
                phase: .failed,
                detail: agent.harnessIdentifier == nil
                    ? "Choose a harness in Edit Bot"
                    : "The configured harness is not installed"
            )
            return
        }

        switch installation.provider {
        case .codex:
            let process = CodexAgentProcess(
                agent: agent,
                executableURL: URL(fileURLWithPath: executablePath),
                workspaceURL: repository.directory(for: agent),
                onSnapshot: { [weak self] snapshot in
                    self?.snapshots[snapshot.agentID] = snapshot
                }
            )
            processes[agent.id] = process
            process.start()
        }
    }

    func restart(agent: AgentRecord, repository: WorkspaceRepository) {
        processes.removeValue(forKey: agent.id)?.stop()
        start(agent: agent, repository: repository)
    }

    func notify(_ agents: [AgentRecord], repository: WorkspaceRepository) {
        for agent in agents {
            if processes[agent.id] == nil {
                start(agent: agent, repository: repository)
            }
            processes[agent.id]?.notify()
        }
    }

    func stop(agentID: UUID) {
        processes.removeValue(forKey: agentID)?.stop()
        snapshots.removeValue(forKey: agentID)
    }

    func stopAll() {
        capabilityProbe?.stop()
        capabilityProbe = nil
        processes.values.forEach { $0.stop() }
        processes.removeAll()
        snapshots = snapshots.mapValues {
            AgentRuntimeSnapshot(agentID: $0.agentID, phase: .offline, detail: "Stopped")
        }
    }
}

@MainActor
private final class CodexAgentProcess {
    private enum RequestPurpose {
        case initialize
        case startThread
        case resumeThread
        case startTurn
    }

    private struct PersistedState: Codable {
        let version: Int
        let threadID: String
    }

    let configuration: AgentRecord
    private let executableURL: URL
    private let workspaceURL: URL
    private let onSnapshot: @MainActor (AgentRuntimeSnapshot) -> Void
    private let stateURL: URL

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var readBuffer = Data()
    private var nextRequestID = 1
    private var purposes: [Int: RequestPurpose] = [:]
    private var threadID: String?
    private var turnIsActive = false
    private var notificationPending = false
    private var intentionallyStopped = false
    private var lastErrorText: String?

    private(set) var snapshot: AgentRuntimeSnapshot

    init(
        agent: AgentRecord,
        executableURL: URL,
        workspaceURL: URL,
        onSnapshot: @escaping @MainActor (AgentRuntimeSnapshot) -> Void
    ) {
        configuration = agent
        self.executableURL = executableURL
        self.workspaceURL = workspaceURL
        self.onSnapshot = onSnapshot
        stateURL = workspaceURL.appendingPathComponent(".agents/codex-runtime.json")
        snapshot = AgentRuntimeSnapshot(agentID: agent.id, phase: .offline, detail: "Not started")
        let state = Self.loadState(from: stateURL)
        threadID = state?.version == Self.runtimeVersion ? state?.threadID : nil
    }

    func start() {
        guard process == nil else { return }
        intentionallyStopped = false
        update(.starting, "Starting Codex")

        do {
            let child = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            child.executableURL = executableURL
            child.arguments = ["app-server"]
            child.currentDirectoryURL = workspaceURL
            child.standardInput = inputPipe
            child.standardOutput = outputPipe
            child.standardError = errorPipe

            var environment = ProcessInfo.processInfo.environment
            environment["SUPERBOT_AGENT_ID"] = configuration.id.uuidString.lowercased()
            environment["SUPERBOT_WORKSPACE"] = workspaceURL.path
            environment["CODEX_HOME"] = HostEnvironment.codexHome.path
            child.environment = environment

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in self?.receive(data) }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                Task { @MainActor in self?.lastErrorText = text }
            }
            child.terminationHandler = { [weak self] terminated in
                Task { @MainActor in self?.didTerminate(status: terminated.terminationStatus) }
            }

            try child.run()
            process = child
            input = inputPipe.fileHandleForWriting
            output = outputPipe.fileHandleForReading
            errors = errorPipe.fileHandleForReading
            update(.starting, "Connecting to Codex")
            try request(.initialize, method: "initialize", params: [
                "clientInfo": [
                    "name": "superbot",
                    "title": "SuperBot",
                    "version": "0.3.0"
                ],
                "capabilities": ["experimentalApi": true]
            ])
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() {
        intentionallyStopped = true
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        errors = nil
        purposes.removeAll()
        turnIsActive = false
        notificationPending = false
        update(.offline, "Stopped")
    }

    func notify() {
        notificationPending = true
        if process == nil { start() }
        sendPendingNotificationIfPossible()
    }

    private func didTerminate(status: Int32) {
        process = nil
        input = nil
        output = nil
        errors = nil
        purposes.removeAll()
        turnIsActive = false
        if intentionallyStopped {
            update(.offline, "Stopped")
        } else {
            fail(lastErrorText ?? "Codex exited with status \(status)")
        }
    }

    private func receive(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.prefix(upTo: newline)
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = Self.integerID(message["id"]),
           let purpose = purposes.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                if case .resumeThread = purpose {
                    threadID = nil
                    try? FileManager.default.removeItem(at: stateURL)
                    openThread()
                    return
                }
                fail(error["message"] as? String ?? "Codex request failed")
                return
            }
            let result = message["result"] as? [String: Any] ?? [:]
            switch purpose {
            case .initialize:
                try? sendNotification(method: "initialized", params: [:])
                openThread()
            case .startThread, .resumeThread:
                guard let thread = result["thread"] as? [String: Any],
                      let id = thread["id"] as? String else {
                    fail("Codex did not return a thread identifier")
                    return
                }
                threadID = id
                saveState(threadID: id)
                update(.ready, "Codex ready")
                sendPendingNotificationIfPossible()
            case .startTurn:
                turnIsActive = true
                update(.working, "Checking for new messages")
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        if method == "turn/completed" {
            turnIsActive = false
            let params = message["params"] as? [String: Any]
            let turn = params?["turn"] as? [String: Any]
            let status = turn?["status"] as? String
            if status == "failed" {
                let error = turn?["error"] as? [String: Any]
                fail(error?["message"] as? String ?? "Codex turn failed")
            } else {
                update(.ready, "Codex ready")
                sendPendingNotificationIfPossible()
            }
        }
    }

    private func openThread() {
        var params: [String: Any] = [
            "cwd": workspaceURL.path,
            "approvalPolicy": "never",
            "sandbox": "workspace-write",
            "serviceName": "superbot",
            "developerInstructions": Self.developerInstructions
        ]
        if let model = configuration.modelIdentifier { params["model"] = model }

        do {
            if let threadID {
                params["threadId"] = threadID
                try request(.resumeThread, method: "thread/resume", params: params)
            } else {
                try request(.startThread, method: "thread/start", params: params)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func sendPendingNotificationIfPossible() {
        guard notificationPending, !turnIsActive,
              snapshot.phase == .ready,
              let threadID else { return }
        notificationPending = false

        var params: [String: Any] = [
            "threadId": threadID,
            "input": [[
                "type": "text",
                "text": "<superbot-event type=\"inbox-changed\" />"
            ]],
            "cwd": workspaceURL.path,
            "approvalPolicy": "never",
            "sandboxPolicy": [
                "type": "externalSandbox",
                "networkAccess": "restricted"
            ]
        ]
        if let model = configuration.modelIdentifier { params["model"] = model }
        if let effort = configuration.reasoningEffort { params["effort"] = effort }

        do {
            try request(.startTurn, method: "turn/start", params: params)
            turnIsActive = true
            update(.working, "Checking for new messages")
        } catch {
            notificationPending = true
            fail(error.localizedDescription)
        }
    }

    private func request(_ purpose: RequestPurpose, method: String, params: [String: Any]) throws {
        let id = nextRequestID
        nextRequestID += 1
        purposes[id] = purpose
        try send(["method": method, "id": id, "params": params])
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        try send(["method": method, "params": params])
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let input else { throw CocoaError(.fileNoSuchFile) }
        try input.write(contentsOf: data + Data([0x0A]))
    }

    private func saveState(threadID: String) {
        do {
            let directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(
                PersistedState(version: Self.runtimeVersion, threadID: threadID)
            ).write(to: stateURL, options: .atomic)
        } catch {
            fail("Could not save Codex thread: \(error.localizedDescription)")
        }
    }

    private static func loadState(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    private func fail(_ detail: String) {
        update(.failed, detail)
    }

    private func update(_ phase: AgentRuntimePhase, _ detail: String) {
        snapshot = AgentRuntimeSnapshot(
            agentID: configuration.id,
            phase: phase,
            detail: detail,
            processIdentifier: process?.processIdentifier
        )
        onSnapshot(snapshot)
    }

    fileprivate static func integerID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static let developerInstructions = """
    You are a continuously running SuperBot agent. A SuperBot event is only a notification that your inbox changed; it never contains the user's message. Whenever notified, your first action must be running the bundled Messenger CLI through Codex's programmatic bridge: `const r = await tools.exec_command({cmd: "./.agents/skills/messenger/messenger --get-latest --inline-images", max_output_tokens: 250000}); if (r.exit_code !== 0) throw new Error(r.output); const payload = JSON.parse(r.output); text(payload.deliveries); for (const visual of payload.images) image(visual.dataURL, "original");`. Every delivery explicitly identifies you in `me`, provides a named `participants` roster where your handle is `me`, and annotates the message `sender` with a `user`, `me`, `bot`, or `system` handle. Use these identities instead of guessing from UUIDs. The CLI includes attached images directly as visual inputs, so inspect them without calling a local image viewer. Every attachment also includes its exact `absolutePath` for non-visual file work. Run get-latest only once for each notification because it consumes the inbox. Reply with the Messenger CLI using `--send`, the conversation UUID, and `--body-percent-encoded`; encode a UTF-8 reply with `const encoded = encodeURIComponent(body).replaceAll("'", "%27");` and pass it as a single-quoted command argument. To send files you created, add a repeatable `--attach <file-path>` option; the body is optional when at least one file is attached. Never edit SuperBot's conversation files directly. Do not answer the notification text itself. If the inbox is empty, finish quietly.
    """

    private static let runtimeVersion = 9
}

@MainActor
private final class CodexCapabilityProbe {
    private let executableURL: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var readBuffer = Data()
    private var completion: ((Result<[HarnessModel], Error>) -> Void)?
    private var timeoutTask: Task<Void, Never>?

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func loadModels(completion: @escaping (Result<[HarnessModel], Error>) -> Void) {
        self.completion = completion
        do {
            let child = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            child.executableURL = executableURL
            child.arguments = ["app-server"]
            child.standardInput = inputPipe
            child.standardOutput = outputPipe
            child.standardError = errorPipe
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = HostEnvironment.codexHome.path
            child.environment = environment

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in self?.receive(data) }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { _ in }
            child.terminationHandler = { [weak self] child in
                Task { @MainActor in
                    guard let self, self.completion != nil else { return }
                    self.finish(.failure(ProbeError("Codex capability check exited with status \(child.terminationStatus)")))
                }
            }

            try child.run()
            process = child
            input = inputPipe.fileHandleForWriting
            output = outputPipe.fileHandleForReading
            errors = errorPipe.fileHandleForReading
            try send([
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": ["name": "superbot", "title": "SuperBot", "version": "0.3.0"],
                    "capabilities": [:]
                ]
            ])
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.finish(.failure(ProbeError("Codex did not return its model list")))
                }
            }
        } catch {
            finish(.failure(error))
        }
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        completion = nil
        tearDown()
    }

    private func receive(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.prefix(upTo: newline)
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = CodexAgentProcess.integerID(message["id"]) else { continue }
            if let error = message["error"] as? [String: Any] {
                finish(.failure(ProbeError(error["message"] as? String ?? "Codex capability check failed")))
                return
            }
            if id == 1 {
                do {
                    try send(["method": "initialized", "params": [:]])
                    try send([
                        "method": "model/list",
                        "id": 2,
                        "params": ["includeHidden": false, "limit": 100]
                    ])
                } catch {
                    finish(.failure(error))
                }
            } else if id == 2 {
                let result = message["result"] as? [String: Any]
                let data = result?["data"] as? [[String: Any]] ?? []
                let models = data.compactMap(Self.parseModel)
                guard !models.isEmpty else {
                    finish(.failure(ProbeError("Codex returned no available models")))
                    return
                }
                finish(.success(models))
            }
        }
    }

    private static func parseModel(_ value: [String: Any]) -> HarnessModel? {
        guard let id = (value["model"] as? String) ?? (value["id"] as? String) else { return nil }
        let effortValues = value["supportedReasoningEfforts"] as? [[String: Any]] ?? []
        let efforts = effortValues.compactMap { effort -> HarnessEffort? in
            guard let id = effort["reasoningEffort"] as? String else { return nil }
            return HarnessEffort(id: id, description: effort["description"] as? String ?? "")
        }
        return HarnessModel(
            id: id,
            displayName: value["displayName"] as? String ?? id,
            description: value["description"] as? String ?? "",
            supportedEfforts: efforts,
            defaultEffort: value["defaultReasoningEffort"] as? String ?? efforts.first?.id ?? "medium",
            isDefault: value["isDefault"] as? Bool ?? false
        )
    }

    private func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let input else { throw CocoaError(.fileNoSuchFile) }
        try input.write(contentsOf: data + Data([0x0A]))
    }

    private func finish(_ result: Result<[HarnessModel], Error>) {
        guard let completion else { return }
        self.completion = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        tearDown()
        completion(result)
    }

    private func tearDown() {
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = nil
        errors = nil
    }

    private struct ProbeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

private enum HostEnvironment {
    static var codexHome: URL {
        if let entry = getpwuid(getuid()), let pointer = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
    }
}
