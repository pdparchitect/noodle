import AppKit
import Observation
import NoodleCore
import NoodleMCP

@MainActor @Observable
public final class MCPController {
    public private(set) var registry = MCPRegistry()
    private(set) var connected: Set<UUID> = []
    private(set) var signingIn: UUID?
    private(set) var signInStage = ""
    public private(set) var errors: [UUID: String] = [:]
    var errorMessage: String?
    @ObservationIgnored private let repository: WorkspaceRepository
    @ObservationIgnored private let service: MCPService
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var agents: [AgentRecord] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var providers: MCPConnectionProviders?
    /// Where this controller registers one provider per connection.
    @ObservationIgnored public var toolRegistry: ToolProviderRegistry? {
        didSet {
            providers = toolRegistry.map { MCPConnectionProviders(registry: $0, service: service) }
            providers?.onError = { [weak self] id, message in self?.errors[id] = message }
            synchronizeProviders()
        }
    }
    /// Receives the connections each bot is granted, now and on every change.
    @ObservationIgnored public var onAssignmentsChange: (([UUID: Set<String>]) -> Void)? { didSet { synchronizeProviders() } }
    @ObservationIgnored private let browser = MCPBrowserAuthorization()
    @ObservationIgnored private var registryReadable = true
    @ObservationIgnored private let deletions: DeletionJournal<UUID>

    public init(repository: WorkspaceRepository, service: MCPService? = nil) {
        self.repository = repository
        self.service = service ?? MCPService(namespace: Bundle.main.bundleIdentifier ?? "com.pdparchitect.noodle.local")
        deletions = DeletionJournal(url: repository.rootURL.appendingPathComponent("MCP/removed-sign-ins.json"))
        do { registry = try MCPRegistry.load(root: repository.rootURL) }
        catch {
            registryReadable = false
            errorMessage = "Could not read saved tool connections. They have not been replaced."
        }
    }
    deinit { loginTask?.cancel() }
    /// Bots reach tool connections through Noodle's tool broker. This controller owns the
    /// connections, their sign-in, and which bot is granted which connection.
    public func start(agents: [AgentRecord]) {
        self.agents = agents
        synchronizeProviders()
        if !started {
            started = true
            Task { [weak self] in
                guard let self else { return }
                await deleteRemovedSignIns()
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
        synchronizeProviders()
        try synchronize()
    }

    /// Creates a separate saved MCP account without signing in or assigning it.
    /// Other tool types use their own storage/setup handler, not this registry.
    func addPreset(_ tool: ToolDefinition, configuration: MCPToolConfiguration, connectionID: UUID = UUID()) throws -> MCPConnectionRecord {
        guard tool.configuration == .mcp(configuration) else {
            throw MCPConnectionError.message("This tool requires a different setup method.")
        }
        let record: MCPConnectionRecord
        if let saved = registry.connections.first(where: { $0.id == connectionID }) {
            guard saved.endpoint == configuration.endpoint else {
                throw MCPConnectionError.message("The saved account does not match this tool.")
            }
            record = saved
        } else {
            record = try MCPConnectionRecord(id: connectionID,
                name: ToolCatalog.availableName(for: tool, existingNames: registry.connections.map(\.name)),
                endpoint: configuration.endpoint, description: tool.summary, instructions: tool.defaultInstructions)
        }
        try save(record)
        return registry.connections.first { $0.id == record.id }!
    }
    public func assign(_ ids: Set<UUID>, to agent: AgentRecord, synchronizeWorkspace: Bool = true) throws {
        try validateAssignment(ids)
        var next = registry
        try next.assign(ids, to: agent.id)
        try next.save(root: repository.rootURL)
        registry = next
        synchronizeProviders()
        if synchronizeWorkspace { try repository.synchronizeAgentWorkspace(agent) }
    }
    public func reloadAssignments() throws {
        defer { synchronizeProviders() }
        do { registry = try MCPRegistry.load(root: repository.rootURL); registryReadable = true }
        catch { registryReadable = false; throw error }
    }
    public func validateAssignment(_ ids: Set<UUID>) throws {
        try requireReadableRegistry()
        guard ids.isSubset(of: Set(registry.connections.map(\.id))) else {
            throw MCPConnectionError.message("One of the selected tool connections no longer exists.")
        }
    }
    private func requireReadableRegistry() throws {
        guard registryReadable else {
            throw MCPConnectionError.message("Saved tool connections could not be read. Restore the registry before making changes; the existing file has not been replaced.")
        }
    }
    public func selectedIDs(for agent: AgentRecord) -> Set<UUID> { Set(registry.assigned(to: agent.id).map(\.id)) }
    func remove(_ record: MCPConnectionRecord) {
        if signingIn == record.id { loginTask?.cancel() }
        var next = registry
        next.remove(record.id)
        do {
            try requireReadableRegistry()
            try deletions.schedule([record.id])
            try next.save(root: repository.rootURL)
            registry = next // Revoke broker access immediately, before asynchronous cleanup.
            synchronizeProviders()
            connected.remove(record.id)
            errors[record.id] = nil
            Task { if let error = await deleteRemovedSignIns() { errorMessage = error.localizedDescription } }
            try synchronize()
        } catch { errorMessage = error.localizedDescription }
    }
    /// Deletes removed connections' sign-ins; one that fails is tried again on the next removal or start.
    @discardableResult private func deleteRemovedSignIns() async -> Error? {
        await deletions.run { id in
            // A removal whose registry write failed keeps its connection, so it keeps its sign-in too.
            guard registryReadable else { throw MCPConnectionError.message("Saved tool connections could not be read.") }
            guard !registry.connections.contains(where: { $0.id == id }) else { return }
            try await service.disconnect(id)
        }
    }
    func connect(_ record: MCPConnectionRecord) {
        guard signingIn == nil else { return }
        browser.captureReturnWindow()
        signingIn = record.id
        errors[record.id] = nil
        loginTask = Task {
            defer { signingIn = nil; loginTask = nil; signInStage = "" }
            do {
                let redirect = Self.redirectURI(for: record.endpoint)
                try await service.signIn(record, redirectURI: redirect, progress: { [weak self] stage in
                    await self?.setSignInStage(stage)
                }) { [browser] url in
                    try await browser.authorize(url: url, callbackURL: redirect)
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

    /// Where a sign-in for a connection at `endpoint` returns to this app.
    public static func redirectURI(for endpoint: URL) -> URL {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let scheme = (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "noodle-dev"
        return MCPService.configuredRedirectURI(for: endpoint) ?? URL(string: "\(scheme)://mcp/oauth/callback")!
    }

    /// Opens the sign-in page of a connection kept elsewhere, as on a Noodle Hub, and returns
    /// the address the browser came back to.
    public func authorizeInBrowser(_ url: URL, callbackURL: URL) async throws -> URL {
        browser.captureReturnWindow()
        return try await browser.authorize(url: url, callbackURL: callbackURL)
    }
    @discardableResult public func receiveAuthorizationCallback(_ url: URL) -> Bool {
        browser.receive(url)
    }
    private func setSignInStage(_ stage: String) { signInStage = stage }
    private func synchronize() throws {
        for agent in agents { try repository.synchronizeAgentWorkspace(agent) }
    }
    /// Call after every change to `registry`. A connection that cannot be read grants nothing.
    private func synchronizeProviders() {
        let connections = registryReadable ? registry.connections : []
        providers?.synchronize(connections) { [weak self] id in self?.registry.connections.first { $0.id == id } }
        let granted = registryReadable ? registry.assignments : [:]
        onAssignmentsChange?(Dictionary(uniqueKeysWithValues: granted.compactMap { key, ids in
            UUID(uuidString: key).map { ($0, Set(ids.map(\.uuidString))) }
        }))
    }
    private nonisolated static func safeError(_ error: Error) -> String { MCPConnectionProviders.safeError(error) }
}

// Open an ordinary default-browser tab, retaining normal profiles and extensions.
// Only a callback for the currently pending target AND state may consume the login.
@MainActor public final class MCPBrowserAuthorization {
    private let returnWindow = ExternalEventReturnWindow()
    private var pendingID: UUID?
    private var callbackURL: URL?
    private var state: String?
    private var continuation: CheckedContinuation<URL, Error>?
    private var timeout: Task<Void, Never>?
    private let openURL: (URL) -> Bool
    private let timeoutDuration: Duration

    func captureReturnWindow() { returnWindow.capture() }

    init(timeoutDuration: Duration = .seconds(180), openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.timeoutDuration = timeoutDuration
        self.openURL = openURL
    }
    func authorize(url: URL, callbackURL: URL) async throws -> URL {
        let states = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "state" } ?? []
        guard pendingID == nil, states.count == 1, let state = states.first?.value, !state.isEmpty else {
            throw MCPServiceError.invalidCallback
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.pendingID = id
                self.callbackURL = callbackURL
                self.state = state
                self.continuation = continuation
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: self?.timeoutDuration ?? .seconds(180))
                    if !Task.isCancelled { self?.finish(id, .failure(MCPServiceError.timedOut)) }
                }
                if !openURL(url) {
                    finish(id, .failure(MCPConnectionError.message("Could not open your browser. Check your default browser and try again.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }
    @discardableResult func receive(_ url: URL) -> Bool {
        guard let id = pendingID, let callbackURL, let state,
              let expected = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              actual.scheme == expected.scheme, actual.host == expected.host,
              actual.port == expected.port, actual.path == expected.path,
              actual.user == nil, actual.password == nil, actual.fragment == nil else { return false }
        let states = actual.queryItems?.filter { $0.name == "state" } ?? []
        guard states.count == 1, states.first?.value == state else { return false }
        // MCPOAuth additionally validates code/error parameters before token exchange.
        returnWindow.restore()
        finish(id, .success(url))
        return true
    }
    private func finish(_ id: UUID, _ result: Result<URL, Error>) {
        guard pendingID == id else { return }
        pendingID = nil
        returnWindow.clear()
        callbackURL = nil
        state = nil
        let continuation = continuation
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        continuation?.resume(with: result)
    }
}

@MainActor public final class ExternalEventReturnWindow {
    private weak var window: NSWindow?

    func capture() {
        let window = NSApp.keyWindow
        self.window = window?.sheetParent ?? window
    }

    func restore() {
        let target = window
        window = nil
        // Let SwiftUI finish routing the external event to the existing scene
        // before bringing the originating Settings window back to the front.
        DispatchQueue.main.async { [weak target] in
            guard let target, NSApp.windows.contains(where: { $0 === target }) else { return }
            if target.isMiniaturized { target.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            target.makeKeyAndOrderFront(nil)
        }
    }

    func clear() { window = nil }
}
