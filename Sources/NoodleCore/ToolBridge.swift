import Darwin
import Foundation

/// Runs inside the agent's sandbox. Identity comes from the workspace session the
/// app wrote, never from a flag; the app authorizes every request again.
public enum ToolBridgeClient {
    public static let maxArgumentBytes = 1_048_576
    public static let maxResponseBytes = 16 * 1_048_576

    public static func request(_ action: ToolBridgeAction, provider: String? = nil, tool: String? = nil, arguments: Data? = nil,
                               workspace: URL, currentDirectory: URL) throws -> Data {
        guard (arguments?.count ?? 0) <= maxArgumentBytes else { throw ToolProviderError("Tool arguments exceed 1 MiB.") }
        let root = workspace.resolvingSymlinksInPath().path, current = currentDirectory.resolvingSymlinksInPath().path
        guard current == root || current.hasPrefix(root + "/") else { throw ToolProviderError("Run tool commands from this bot's workspace.") }
        let mailbox: WorkspaceMailbox
        let session: MCPBridgeSession
        do {
            mailbox = try WorkspaceMailbox(workspace: workspace, path: ToolBroker.path)
            session = try JSONDecoder().decode(MCPBridgeSession.self, from: mailbox.read("session.json", limit: 4096))
        } catch { throw ToolProviderError("Noodle's tool bridge is unavailable. Open Noodle and restart the bot.") }
        let request = ToolBridgeRequest(session: session.token, action: action, provider: provider, tool: tool, arguments: arguments,
                                        currentDirectory: String(current.dropFirst(root.count + 1)))
        let stem = request.id.uuidString.lowercased()
        try mailbox.write(request, named: stem + ".request")
        defer { mailbox.remove(stem + ".request"); mailbox.remove(stem + ".response") }
        // Providers may declare up to an hour; the broker answers sooner when a tool's own limit expires.
        let deadline = ProcessInfo.processInfo.systemUptime + 3_630
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? mailbox.read(stem + ".response", limit: maxResponseBytes + 4096) {
                let response = try JSONDecoder().decode(ToolBridgeResponse.self, from: data)
                if let error = response.error { throw ToolProviderError(error) }
                guard let result = response.result else { throw ToolProviderError("Empty tool bridge response.") }
                return result
            }
            if kill(session.processID, 0) != 0, errno != EPERM {
                throw ToolProviderError("Noodle stopped during the tool call. Verify any action before retrying.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw ToolProviderError("The tool call timed out. Verify any action before retrying.")
    }
}

public struct ToolBridgeAgent: Sendable {
    public let id: UUID
    public let workspace: URL
    public init(id: UUID, workspace: URL) { self.id = id; self.workspace = workspace }
}

/// Runs in the trusted app. `assignments` is consulted for every request, so a
/// revoked resource stops working without restarting anything.
public final class ToolBridgeBroker: @unchecked Sendable {
    private let registry: ToolProviderRegistry
    private let assignments: @Sendable (UUID) -> ToolAssignments
    private let host: ToolHostServices
    private let queue = DispatchQueue(label: "Noodle.tool-broker")
    private var timer: DispatchSourceTimer?
    private var sessions: [UUID: String] = [:]
    private var agents: [ToolBridgeAgent] = []
    private var claimed: [UUID: Date] = [:]
    private var running = 0
    private let mailboxMonitor = WorkspaceMailboxMonitor()

    public init(registry: ToolProviderRegistry, host: ToolHostServices = .none, assignments: @escaping @Sendable (UUID) -> ToolAssignments) {
        self.registry = registry; self.assignments = assignments; self.host = host
        registry.onChange { [weak self] in self?.synchronizeSkills() }
    }
    deinit { timer?.cancel() }

    /// Rewrites every agent's generated tool skills. Runs on start and whenever providers
    /// change; call it after changing what an agent is assigned.
    public func synchronizeSkills() {
        let agents = queue.sync { self.agents }
        guard !agents.isEmpty else { return }
        Task { [weak self, registry, assignments, queue] in
            for agent in agents {
                var providers: [(manifest: ToolProviderManifest, tools: [ToolDescriptor])] = []
                let granted = assignments(agent.id)
                let context = ToolCallContext(agentID: agent.id, workspace: agent.workspace, assignments: granted)
                for provider in registry.active(assignments: granted) {
                    // A provider that cannot list its tools gets no skill rather than a wrong one.
                    guard let list = try? await ToolBroker.withTimeout(30, tool: provider.manifest.id, { try await provider.tools(context: context) }),
                          let tools = try? ToolDescriptor.list(mcp: list) else { continue }
                    providers.append((provider.manifest, tools))
                }
                let listed = providers
                queue.async { [weak self] in
                    guard self?.agents.contains(where: { $0.id == agent.id }) == true else { return }
                    ToolProviderSkills.synchronize(workspace: agent.workspace, providers: listed)
                }
            }
        }
    }

    public func start(agents: [ToolBridgeAgent]) throws {
        try queue.sync {
            mailboxMonitor.reset()
            self.agents = agents
            sessions = sessions.filter { id, _ in agents.contains { $0.id == id } }
            for agent in agents where sessions[agent.id] == nil {
                let mailbox = try WorkspaceMailbox(workspace: agent.workspace, path: ToolBroker.path, create: true)
                let token = UUID().uuidString + UUID().uuidString
                try mailbox.write(MCPBridgeSession(token: token, processID: getpid()), named: "session.json")
                sessions[agent.id] = token
            }
            if timer == nil {
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.schedule(deadline: .now(), repeating: .milliseconds(100))
                source.setEventHandler { [weak self] in self?.scan() }
                timer = source
                source.resume()
            }
        }
        synchronizeSkills()
    }

    public func stop() {
        queue.sync { timer?.cancel(); timer = nil; mailboxMonitor.reset(); sessions.removeAll(); agents.removeAll() }
    }

    private func scan() {
        guard running < 16, mailboxMonitor.hasChanges() else { return }
        claimed = claimed.filter { $0.value > Date() }
        for agent in agents {
            guard mailboxMonitor.needsScan(workspace: agent.workspace, path: ToolBroker.path),
                  let mailbox = try? WorkspaceMailbox(workspace: agent.workspace, path: ToolBroker.path),
                  let names = try? mailbox.names() else { continue }
            for name in names where name.hasSuffix(".request") && running < 16 {
                let stem = String(name.dropLast(".request".count))
                guard let id = UUID(uuidString: stem), stem == id.uuidString.lowercased() else { continue }
                let request: ToolBridgeRequest
                do {
                    request = try JSONDecoder().decode(ToolBridgeRequest.self,
                        from: mailbox.read(name, limit: (ToolBridgeClient.maxArgumentBytes + 2) / 3 * 4 + 8192))
                    guard request.id == id, request.session == sessions[agent.id],
                          request.expiresAt > Date(), request.expiresAt.timeIntervalSinceNow <= 125,
                          (request.provider?.utf8.count ?? 0) <= 48, (request.tool?.utf8.count ?? 0) <= 1024,
                          request.currentDirectory.utf8.count <= 4096, claimed[id] == nil else {
                        throw ToolProviderError("Invalid or expired tool session.")
                    }
                    // Consume before dispatch: a crash never silently replays an uncertain action.
                    try mailbox.claim(name, as: stem + ".running")
                } catch {
                    mailbox.remove(name)
                    try? mailbox.write(ToolBridgeResponse(error: error.localizedDescription), named: stem + ".response")
                    continue
                }
                claimed[id] = request.expiresAt
                running += 1
                let context = ToolCallContext(agentID: agent.id, workspace: agent.workspace)
                Task { [weak self, registry, assignments, queue, host] in
                    let response: ToolBridgeResponse
                    do {
                        let result = try await ToolBroker.perform(request, registry: registry, assignments: { assignments(agent.id) }, context: context, host: host)
                        response = result.count <= ToolBridgeClient.maxResponseBytes / 4 * 3 - 4096
                            ? ToolBridgeResponse(result: result) : ToolBridgeResponse(error: "The tool result is too large. Ask the tool to write a file instead.")
                    } catch { response = ToolBridgeResponse(error: error.localizedDescription) }
                    queue.async { [weak self] in
                        try? mailbox.write(response, named: stem + ".response")
                        mailbox.remove(stem + ".running")
                        self?.running -= 1
                    }
                }
            }
        }
    }
}
