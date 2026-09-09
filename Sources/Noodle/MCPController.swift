import AppKit
import AuthenticationServices
import Observation
import NoodleCore
import NoodleMCP

@MainActor @Observable
final class MCPController {
    private(set) var registry = MCPRegistry()
    private(set) var connected: Set<UUID> = []
    private(set) var signingIn: UUID?
    private(set) var signInStage = ""
    private(set) var errors: [UUID: String] = [:]
    var errorMessage: String?
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let service: MCPService
    @ObservationIgnored private var sessions: [UUID: String] = [:]
    @ObservationIgnored private var bridgeTask: Task<Void, Never>?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var calls: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var agents: [AgentRecord] = []
    @ObservationIgnored private let browser = MCPBrowserAuthorization()
    @ObservationIgnored private var claimed: [UUID: Date] = [:]
    @ObservationIgnored private var registryReadable = true

    init(repository: WorkspaceRepository) {
        self.repository = repository
        service = MCPService(namespace: Bundle.main.bundleIdentifier ?? "com.pdparchitect.noodle.local")
        do { registry = try MCPRegistry.load(root: repository.rootURL) }
        catch {
            registryReadable = false
            errorMessage = "Could not read saved MCP connections. They have not been replaced."
        }
    }
    func start(agents: [AgentRecord]) {
        self.agents = agents
        do {
            for agent in agents {
                let folder = try MCPBridgeFiles.prepare(workspace: repository.directory(for: agent))
                if sessions[agent.id] == nil {
                    sessions[agent.id] = UUID().uuidString + UUID().uuidString
                    try MCPBridgeFiles.write(MCPBridgeSession(token: sessions[agent.id]!, processID: getpid()),
                                             to: folder.appendingPathComponent("session.json"))
                }
            }
            sessions = sessions.filter { id, _ in agents.contains { $0.id == id } }
        } catch { errorMessage = "Could not prepare the MCP bridge: " + error.localizedDescription }
        if bridgeTask == nil {
            bridgeTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.scan()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            Task { [weak self] in
                guard let self else { return }
                for connection in registry.connections {
                    if await service.hasCredentials(connection.id) { connected.insert(connection.id) }
                }
            }
        }
    }
    func save(_ record: MCPConnectionRecord) throws {
        try requireReadableRegistry()
        var next = registry
        if let index = next.connections.firstIndex(where: { $0.id == record.id }) { next.connections[index] = record }
        else { next.connections.append(record) }
        try next.save(root: repository.rootURL)
        registry = next
        try synchronize()
    }
    func assign(_ ids: Set<UUID>, to agent: AgentRecord) throws {
        try validateAssignment(ids)
        var next = registry
        try next.assign(ids, to: agent.id)
        try next.save(root: repository.rootURL)
        registry = next
        try repository.synchronizeAgentWorkspace(agent)
    }
    func validateAssignment(_ ids: Set<UUID>) throws {
        try requireReadableRegistry()
        guard ids.isSubset(of: Set(registry.connections.map(\.id))) else {
            throw MCPConnectionError.message("One of the selected MCP connections no longer exists.")
        }
    }
    private func requireReadableRegistry() throws {
        guard registryReadable else {
            throw MCPConnectionError.message("Saved MCP connections could not be read. Restore the registry before making changes; the existing file has not been replaced.")
        }
    }
    func selectedIDs(for agent: AgentRecord) -> Set<UUID> { Set(registry.assigned(to: agent.id).map(\.id)) }
    func remove(_ record: MCPConnectionRecord) {
        if signingIn == record.id { loginTask?.cancel() }
        var next = registry
        next.remove(record.id)
        do {
            try requireReadableRegistry()
            try next.save(root: repository.rootURL)
            registry = next // Revoke broker access immediately, before asynchronous cleanup.
            connected.remove(record.id)
            errors[record.id] = nil
            Task {
                do { try await service.disconnect(record.id) }
                catch { errorMessage = error.localizedDescription }
            }
            try synchronize()
        } catch { errorMessage = error.localizedDescription }
    }
    func connect(_ record: MCPConnectionRecord) {
        guard signingIn == nil else { return }
        signingIn = record.id
        errors[record.id] = nil
        loginTask = Task {
            defer { signingIn = nil; loginTask = nil; signInStage = "" }
            do {
                let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
                let scheme = (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "noodle-local"
                let redirect = URL(string: "\(scheme)://mcp/oauth/callback")!
                try await service.signIn(record, redirectURI: redirect, progress: { [weak self] stage in
                    await self?.setSignInStage(stage)
                }) { [browser] url in
                    try await browser.authorize(url: url, callbackScheme: scheme)
                }
                try Task.checkCancellation()
                signInStage = "Checking available tools…"
                let request = MCPBridgeRequest(session: "", connectionID: record.id, action: .tools, tool: nil, arguments: nil)
                _ = try await service.perform(request, connection: record)
                let icon = await service.icon(for: record)
                guard var current = registry.connections.first(where: { $0.id == record.id }) else { return }
                connected.insert(record.id)
                if let icon { current.iconData = icon; try save(current) }
                else { try synchronize() }
            } catch is CancellationError {
                errors[record.id] = "Sign-in cancelled."
            } catch {
                if registry.connections.contains(where: { $0.id == record.id }) {
                    errors[record.id] = Self.safeError(error)
                }
            }
        }
    }
    func cancelSignIn() { loginTask?.cancel() }
    private func setSignInStage(_ stage: String) { signInStage = stage }
    private func synchronize() throws {
        for agent in agents { try repository.synchronizeAgentWorkspace(agent) }
    }
    private func scan() {
        guard calls.count < 16 else { return }
        claimed = claimed.filter { $0.value > Date() }
        let manager = FileManager.default
        for agent in agents {
            let folder = MCPBridgeFiles.directory(workspace: repository.directory(for: agent))
            guard folder.resolvingSymlinksInPath() == folder.standardizedFileURL,
                  let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files.prefix(256) {
                if file.pathExtension == "response" || file.pathExtension == "running" {
                    if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       date < Date().addingTimeInterval(-300), UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                        try? manager.removeItem(at: file)
                    }
                    continue
                }
                guard file.pathExtension == "request", calls.count < 16,
                      let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
                let responseURL = folder.appendingPathComponent(id.uuidString.lowercased() + ".response")
                let runningURL = folder.appendingPathComponent(id.uuidString.lowercased() + ".running")
                guard let data = try? MCPBridgeFiles.read(file, limit: MCPBridgeFiles.maxRequestEnvelopeBytes),
                      let request = try? JSONDecoder().decode(MCPBridgeRequest.self, from: data),
                      request.id == id, request.session == sessions[agent.id],
                      (request.arguments?.count ?? 0) <= MCPBridgeFiles.maxRequestBytes,
                      (request.tool?.utf8.count ?? 0) <= 1024,
                      request.expiresAt > Date(), request.expiresAt < Date().addingTimeInterval(130),
                      claimed[id] == nil else {
                    try? manager.removeItem(at: file)
                    try? MCPBridgeFiles.write(MCPBridgeResponse(error: "Expired or invalid MCP request."), to: responseURL)
                    continue
                }
                // Consume before dispatch: a crash never silently replays an uncertain write.
                do { try manager.moveItem(at: file, to: runningURL) } catch { continue }
                claimed[id] = request.expiresAt
                guard let connection = registry.assigned(to: agent.id).first(where: { $0.id == request.connectionID }) else {
                    try? MCPBridgeFiles.write(MCPBridgeResponse(error: "This MCP connection is not assigned to this bot."), to: responseURL)
                    try? manager.removeItem(at: runningURL)
                    continue
                }
                calls[id] = Task { [weak self] in
                    guard let self else { return }
                    defer { calls[id] = nil; try? manager.removeItem(at: runningURL) }
                    let response: MCPBridgeResponse
                    do {
                        let result = try await service.perform(request, connection: connection) { [weak self] in
                            await self?.permits(connection.id, agentID: agent.id, session: request.session) == true
                        }
                        guard registry.assigned(to: agent.id).contains(where: { $0.id == connection.id }) else {
                            throw MCPServiceError.revoked
                        }
                        response = MCPBridgeResponse(result: result)
                    } catch {
                        response = MCPBridgeResponse(error: Self.safeError(error))
                        errors[connection.id] = Self.safeError(error)
                    }
                    // The caller may have gone away. Never retain an expired result.
                    if request.expiresAt > Date(), folder.resolvingSymlinksInPath() == folder.standardizedFileURL {
                        try? MCPBridgeFiles.write(response, to: responseURL)
                    }
                }
            }
        }
    }
    private func permits(_ connectionID: UUID, agentID: UUID, session: String) -> Bool {
        sessions[agentID] == session && agents.contains(where: { $0.id == agentID }) &&
            registry.assigned(to: agentID).contains(where: { $0.id == connectionID })
    }
    private static func safeError(_ error: Error) -> String {
        if error is MCPServiceError || error is MCPConnectionError { return error.localizedDescription }
        return "The MCP connection could not complete the request. Try reconnecting in Settings → MCP."
    }
}

@MainActor private final class MCPBrowserAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var pendingID: UUID?
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.pendingID = id
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, error in
                    Task { @MainActor in
                        if let url { self?.finish(id, .success(url)) }
                        else { self?.finish(id, .failure(CancellationError())) }
                    }
                }
                session.presentationContextProvider = self
                // Separate sign-ins must offer account choice rather than silently reuse cookies.
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if !session.start() { finish(id, .failure(MCPServiceError.invalidCallback)); return }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(180))
                    if !Task.isCancelled { self?.finish(id, .failure(MCPServiceError.timedOut)) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }
    private func finish(_ id: UUID, _ result: Result<URL, Error>) {
        guard pendingID == id else { return }
        pendingID = nil
        let continuation = continuation
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        session?.cancel(); session = nil
        continuation?.resume(with: result)
    }
}
