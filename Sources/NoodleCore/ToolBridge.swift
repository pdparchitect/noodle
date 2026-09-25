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

/// A provider and its MCP tool list as one bot sees them. A Mac sends these to a Noodle Hub
/// for the bots it keeps there, so the Hub can write the same skills.
public struct ToolProviderListing: Codable, Sendable {
    public var manifest: ToolProviderManifest
    /// The provider's MCP `tools/list` result; nil when it could not list, such as a connection that needs sign-in.
    public var tools: Data?

    public init(manifest: ToolProviderManifest, tools: Data?) {
        self.manifest = manifest
        self.tools = tools
    }

    /// The providers a bot's assignments make active, each with its tools.
    public static func list(registry: ToolProviderRegistry, assignments: ToolAssignments, agentID: UUID,
                            workspace: URL) async -> [ToolProviderListing] {
        let context = ToolCallContext(agentID: agentID, workspace: workspace, assignments: assignments)
        var listings: [ToolProviderListing] = []
        for provider in registry.active(assignments: assignments) {
            // A connection that needs sign-in, or a server that is down, cannot list its tools. The bot
            // still needs the skill, which is how it learns to ask the person to reconnect.
            let tools = try? await ToolBroker.withTimeout(30, tool: provider.manifest.id, { try await provider.tools(context: context) })
            listings.append(ToolProviderListing(manifest: provider.manifest, tools: tools))
        }
        return listings
    }

    /// Writes a bot's tool skills from listings.
    public static func synchronize(workspace: URL, listings: [ToolProviderListing]) {
        ToolProviderSkills.synchronize(workspace: workspace, listed: listings.map {
            ($0.manifest, $0.tools.flatMap { try? ToolDescriptor.list(mcp: $0) })
        })
    }
}

/// Runs in the trusted app. `assignments` is consulted for every request, so a
/// revoked resource stops working without restarting anything. With a `relay`, requests go
/// to it instead of local providers, as on a Noodle Hub whose tools live on a paired Mac.
public final class ToolBridgeBroker: @unchecked Sendable {
    public typealias Relay = @Sendable (ToolBridgeRequest, _ agentID: UUID) async throws -> Data

    private let registry: ToolProviderRegistry
    private let relay: Relay?
    private let assignments: @Sendable (UUID) -> ToolAssignments
    private let host: ToolHostServices
    private let queue = DispatchQueue(label: "Noodle.tool-broker")
    private var timer: DispatchSourceTimer?
    private var sessions: [UUID: String] = [:]
    private var agents: [ToolBridgeAgent] = []
    private var claimed: [UUID: Date] = [:]
    private var running = 0
    private let mailboxMonitor = WorkspaceMailboxMonitor()
    private var skillsObserver: (@Sendable (UUID) -> Void)?
    /// Counts skill rewrites, so a listing that was overtaken by a newer one is not written.
    private var skillsGeneration = 0
    /// Called when the set or text of a bot's generated skills changed, so the app can
    /// refresh what that bot's AGENTS.md lists.
    public var onSkillsChanged: (@Sendable (UUID) -> Void)? {
        get { queue.sync { skillsObserver } }
        set { queue.sync { skillsObserver = newValue } }
    }

    public init(registry: ToolProviderRegistry, host: ToolHostServices = .none, assignments: @escaping @Sendable (UUID) -> ToolAssignments) {
        self.registry = registry; self.assignments = assignments; self.host = host; relay = nil
        registry.onChange { [weak self] in self?.synchronizeSkills() }
    }

    /// Hands every request to `relay`. Skills are written by whoever knows the tools.
    public init(relay: @escaping Relay) {
        registry = ToolProviderRegistry(); assignments = { _ in ToolAssignments() }; host = .none
        self.relay = relay
    }
    deinit { timer?.cancel() }

    /// Rewrites every agent's generated tool skills. Runs on start and whenever providers
    /// change; call it after changing what an agent is assigned.
    @discardableResult public func synchronizeSkills() -> Task<Void, Never> {
        let (agents, generation) = queue.sync { skillsGeneration += 1; return (self.agents, skillsGeneration) }
        guard !agents.isEmpty, relay == nil else { return Task {} }
        return Task { [weak self, registry, assignments, queue] in
            for agent in agents {
                let listings = await ToolProviderListing.list(registry: registry, assignments: assignments(agent.id),
                                                              agentID: agent.id, workspace: agent.workspace)
                queue.async { [weak self] in
                    guard let self, generation == self.skillsGeneration, self.agents.contains(where: { $0.id == agent.id }) else { return }
                    let before = ToolProviderSkills.generated(workspace: agent.workspace).map { $0.name + "\n" + $0.description }
                    ToolProviderListing.synchronize(workspace: agent.workspace, listings: listings)
                    if before != ToolProviderSkills.generated(workspace: agent.workspace).map({ $0.name + "\n" + $0.description }) {
                        self.skillsObserver?(agent.id)
                    }
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
            // A bot killed mid-call never collects its answer. Remove what it left, once no live
            // request can still own it, and only files named by Noodle's own request IDs.
            for name in names where name.hasSuffix(".response") || name.hasSuffix(".running") {
                let file = mailbox.url.appendingPathComponent(name), stem = (name as NSString).deletingPathExtension
                guard UUID(uuidString: stem) != nil, stem == stem.lowercased(),
                      let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < Date().addingTimeInterval(-300) else { continue }
                mailbox.remove(name)
            }
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
                Task { [weak self, registry, assignments, queue, host, relay] in
                    let response: ToolBridgeResponse
                    do {
                        let result = if let relay { try await relay(request, agent.id) } else {
                            try await ToolBroker.perform(request, registry: registry, assignments: { assignments(agent.id) }, context: context, host: host)
                        }
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
