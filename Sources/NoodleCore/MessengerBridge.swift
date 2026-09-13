import Darwin
import Foundation

public struct MessengerBridgeRequest: Codable, Sendable {
    public let id: UUID
    public let session: String
    public let action: MessengerAction
    public let expiresAt: Date
    public init(id: UUID = UUID(), session: String, action: MessengerAction,
                expiresAt: Date = Date().addingTimeInterval(120)) {
        self.id = id; self.session = session; self.action = action; self.expiresAt = expiresAt
    }
}

public enum MessengerBridgeClient {
    public static let path = ".noodle/messenger-bridge"
    public static let maxRequestBytes = 1_048_576
    public static let maxResponseBytes = 64 * 1_048_576

    public static func request(_ action: MessengerAction, workspace: URL) throws -> MessengerCommandResult {
        let mailbox: WorkspaceMailbox
        let session: MCPBridgeSession
        do {
            mailbox = try WorkspaceMailbox(workspace: workspace, path: path)
            session = try JSONDecoder().decode(MCPBridgeSession.self, from: mailbox.read("session.json", limit: 4096))
        } catch { throw HarnessSetupError("Noodle's Messenger bridge is unavailable. Open Noodle and restart the bot.") }
        let request = MessengerBridgeRequest(session: session.token, action: action)
        let data = try JSONEncoder().encode(request)
        guard data.count <= maxRequestBytes else { throw HarnessSetupError("The Messenger request is too large.") }
        let stem = request.id.uuidString.lowercased()
        try mailbox.writeData(data, named: stem + ".request")
        defer { mailbox.remove(stem + ".request"); mailbox.remove(stem + ".response") }
        let deadline = ProcessInfo.processInfo.systemUptime + 125
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? mailbox.read(stem + ".response", limit: maxResponseBytes) {
                return try JSONDecoder().decode(MessengerCommandResult.self, from: data)
            }
            if kill(session.processID, 0) != 0, errno != EPERM {
                throw HarnessSetupError("Noodle stopped during the Messenger request. Check the conversation before retrying a send.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw HarnessSetupError("Messenger timed out. Check the conversation before retrying a send.")
    }
}

/// Runs in the trusted app, never the harness. Identity comes from the app's
/// workspace/token registry, not an agent ID, repository path, or CLI flag.
public final class MessengerBroker: @unchecked Sendable {
    private let repository: WorkspaceRepository
    private let queue = DispatchQueue(label: "Noodle.messenger-broker")
    private var timer: DispatchSourceTimer?
    private var sessions: [UUID: String] = [:]
    private var agents: [AgentRecord] = []
    private var claimed: [UUID: Date] = [:]

    public init(repository: WorkspaceRepository) { self.repository = repository }
    deinit { timer?.cancel() }

    public func start(agents: [AgentRecord]) throws {
        try queue.sync {
            self.agents = agents
            sessions = sessions.filter { id, _ in agents.contains { $0.id == id } }
            for agent in agents where sessions[agent.id] == nil {
                let mailbox = try WorkspaceMailbox(workspace: repository.directory(for: agent),
                                                   path: MessengerBridgeClient.path, create: true)
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
    }

    public func stop() {
        queue.sync { timer?.cancel(); timer = nil; sessions.removeAll(); agents.removeAll() }
    }

    private func scan() {
        claimed = claimed.filter { $0.value > Date() }
        for agent in agents {
            guard let mailbox = try? WorkspaceMailbox(workspace: repository.directory(for: agent), path: MessengerBridgeClient.path),
                  let names = try? mailbox.names() else { continue }
            for name in names where name.hasSuffix(".request") {
                let stem = String(name.dropLast(".request".count))
                guard let id = UUID(uuidString: stem), stem == id.uuidString.lowercased() else { continue }
                let response: MessengerCommandResult
                do {
                    let request = try JSONDecoder().decode(MessengerBridgeRequest.self,
                        from: mailbox.read(name, limit: MessengerBridgeClient.maxRequestBytes))
                    guard request.id == id, request.session == sessions[agent.id],
                          request.expiresAt > Date(), request.expiresAt.timeIntervalSinceNow <= 125,
                          claimed[id] == nil else { throw HarnessSetupError("Invalid or expired Messenger session.") }
                    try mailbox.claim(name, as: stem + ".running")
                    claimed[id] = request.expiresAt
                    response = MessengerCLI.perform(request.action, repository: repository, agentID: agent.id, brokered: true)
                } catch { response = .init(exitCode: 2, standardError: "messenger: \(error.localizedDescription)\n") }
                if let data = try? JSONEncoder().encode(response), data.count <= MessengerBridgeClient.maxResponseBytes {
                    try? mailbox.writeData(data, named: stem + ".response")
                } else {
                    try? mailbox.write(MessengerCommandResult(exitCode: 2, standardError: "Messenger response is too large. Read one conversation at a time.\n"), named: stem + ".response")
                }
                mailbox.remove(name); mailbox.remove(stem + ".running")
            }
        }
    }
}

public struct MessengerClient: Sendable {
    private let execute: @Sendable (MessengerAction) throws -> MessengerCommandResult
    public init(workspace: URL) {
        execute = { try MessengerBridgeClient.request($0, workspace: workspace) }
    }
    /// Explicit trusted injection for in-process tools and tests. Never selected
    /// by an environment variable or by falling back after a bridge failure.
    public init(execute: @escaping @Sendable (MessengerAction) throws -> MessengerCommandResult) { self.execute = execute }
    public func call<T: Decodable>(_ action: MessengerAction, as: T.Type = T.self) throws -> T {
        let result = try execute(action)
        guard result.exitCode == 0 else { throw HarnessSetupError(result.standardError) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(result.standardOutput.utf8))
    }
}
