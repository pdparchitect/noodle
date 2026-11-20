import AppKit
import Observation
import NoodleCore
import NoodleMCP
import NoodleRuntime
import ProductIdentity

/// What a connection that does not sign in through the browser is given to prove who it is.
public enum ToolConnectionSecret: Sendable {
    case token(String)
    case client(id: String, secret: String)
}

/// A line an app shows under one of its accounts in Settings › Tools.
public struct ToolConnectionNote: Equatable, Sendable {
    public let text: String
    public let isProblem: Bool
    public init(_ text: String, isProblem: Bool = false) { self.text = text; self.isProblem = isProblem }
}

/// Where a connection stands for the person: ready, signing in, or waiting on them, and why.
public enum ToolConnectionStatus: Equatable, Sendable {
    /// The organisation does not allow it.
    case managed
    /// Signing in or checking access, at the stage the sign-in has reached.
    case signingIn(String)
    /// It failed, saying why.
    case failed(String)
    case connected
    case tokenRequired
    case credentialsRequired
    case signInRequired

    /// Whether the person has to do something before agents can use it.
    public var needsAttention: Bool {
        switch self {
        case .failed, .tokenRequired, .credentialsRequired, .signInRequired: true
        case .managed, .signingIn, .connected: false
        }
    }
}

/// Noodle's tool connections as its Settings and tools sidebar show them, kept in the shared `ToolConnections` that a
/// Hub keeps its people's in too. What is only the Mac's is here: signing in through this Mac's browser, or with AWS
/// IAM Identity Center, a code, a token or a client secret; where each connection stands for the person; the activity
/// window; and the bots' own workspaces, which follow every change.
@MainActor @Observable
public final class ToolConnectionsController {
    /// The connections, their grants and sign-ins, watching and activity, as every app and Hub keeps them.
    @ObservationIgnored public let store: ToolConnections
    public var registry: ToolConnectionRegistry { store.registry }
    var connected: Set<UUID> { store.ready }
    private(set) var signingIn: UUID?
    private(set) var signInStage = ""
    public var errors: [UUID: String] { store.problems }
    var errorMessage: String?
    /// What each connection has done since the app started: bots' calls, sign-ins, and what the app adds, by connection.
    @ObservationIgnored public let activity = ActivityStore()
    @ObservationIgnored private let activityWindows = ActivityWindows()
    @ObservationIgnored private let repository: WorkspaceRepository
    /// Keeps the connections' sign-ins; This Mac as a Hub signs tools in through it too.
    public var service: ToolConnectionService { store.service }
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    private var agents: [AgentRecord] = []
    /// Where this controller registers one provider per connection.
    @ObservationIgnored public var toolRegistry: ToolProviderRegistry? {
        get { store.toolRegistry }
        set { store.toolRegistry = newValue }
    }
    /// What the app says about a connection in the skill bots read for it, after what its wake means, if it is watched,
    /// and before the person's own instructions.
    @ObservationIgnored public var appInstructions: (@MainActor (ToolConnection) -> String?)? {
        get { store.appInstructions }
        set { store.appInstructions = newValue }
    }
    /// Receives the connections each bot is granted, now and on every change.
    @ObservationIgnored public var onAssignmentsChange: (([UUID: Set<String>]) -> Void)? {
        get { store.onGrantsChange }
        set { store.onGrantsChange = newValue }
    }
    /// Rewrites the bots' tool skills and returns once they are written; see `ToolConnections.refreshSkills`.
    @ObservationIgnored public var refreshSkills: (@MainActor () async -> Void)? {
        get { store.refreshSkills }
        set { store.refreshSkills = newValue }
    }
    @ObservationIgnored private let browser = MCPBrowserAuthorization()

    public init(repository: WorkspaceRepository, service: ToolConnectionService? = nil) {
        self.repository = repository
        store = ToolConnections(root: repository.rootURL,
            service: service ?? ToolConnectionService(namespace: Bundle.main.bundleIdentifier ?? "com.pdparchitect.noodle.local"))
        if !store.isReadable { errorMessage = "Could not read saved tool connections. They have not been replaced." }
        store.bots = { [weak self] in Dictionary((self?.agents ?? []).map { ($0.id, $0.displayName) }) { first, _ in first } }
        store.onActivity = { [activity] id, title, detail in activity.log(for: id).record(ActivityEvent(title: title, detail: detail)) }
    }
    deinit { loginTask?.cancel() }
    /// Bots reach tool connections through Noodle's tool broker. This controller owns the
    /// connections, their sign-in, and which bot is granted which connection.
    public func start(agents: [AgentRecord]) {
        self.agents = agents
        store.synchronize()
        store.start()
    }
    /// Reads which connections are signed in, after something besides Settings signed one in or out.
    /// One the app's adapter answers without credentials, or an open server, is always ready.
    public func readSignIns() async { await store.readSignIns() }

    public func status(of connection: ToolConnection) -> ToolConnectionStatus {
        if !OrganisationStatus.shared.allows(Organisation.action(for: connection)) { return .managed }
        if signingIn == connection.id { return .signingIn(signInStage) }
        if let error = errors[connection.id] { return .failed(error) }
        if connected.contains(connection.id) { return .connected }
        if connection.usesToken { return .tokenRequired }
        return connection.clientCredentials != nil ? .credentialsRequired : .signInRequired
    }

    /// Whether a sign-in is under way, for any connection; only one runs at a time.
    public var isSigningIn: Bool { signingIn != nil }

    /// Whether it is signed in or ready, so it offers to sign in again and to sign out.
    public func isConnected(_ connection: ToolConnection) -> Bool { connected.contains(connection.id) }

    /// The button that gets a connection working, titled.
    public enum SignInAction: Equatable {
        /// Opens the editor, where a token or client secret is entered.
        case edit(String)
        /// Signs in, or checks it again.
        case connect(String)
    }

    /// What the tools sidebar and Settings › Tools offer to get it working; nil for one that needs no sign-in and
    /// has not failed, since there is nothing to do.
    public func signInAction(for connection: ToolConnection) -> SignInAction? {
        if connection.keepsSecret, connection.awsIdentityCenter == nil {
            let what = connection.usesToken ? "Token" : "Credentials"
            return .edit(isConnected(connection) ? "Change \(what)…" : "Enter \(what)…")
        }
        if ToolConnectionService.needsNoSignIn(connection) {
            return errors[connection.id] == nil ? nil : .connect("Try Again")
        }
        return .connect(isConnected(connection) ? "Reconnect" : "Connect")
    }

    /// Whether Sign Out is offered: never for one that needs no sign-in, which has nothing to sign out of.
    public func offersSignOut(_ connection: ToolConnection) -> Bool {
        isConnected(connection) && !ToolConnectionService.needsNoSignIn(connection)
    }

    /// The adapters this app serves its own connections with, by the name catalogue entries give them, and the boards
    /// it watches on MCP servers, by the catalogue entry their connections are made from. An adapter with a feed is
    /// watched too.
    public func serve(_ adapters: [String: any ToolConnectionAdapter], triggers: [String: MCPTrigger] = [:]) {
        store.serve(adapters, triggers: triggers)
    }
    func save(_ record: ToolConnection) throws {
        try store.save(record)
        try synchronize()
    }

    /// Creates a separate saved MCP account without signing in or assigning it.
    /// Other tool types use their own storage/setup handler, not this registry.
    func addPreset(_ tool: ToolDefinition, configuration: ToolConnectionConfiguration, connectionID: UUID = UUID(),
                   name: String? = nil, values: [String: String] = [:]) throws -> ToolConnection {
        guard tool.configuration == .connection(configuration) else {
            throw ToolConnectionError.message("This tool requires a different setup method.")
        }
        let record: ToolConnection
        if let saved = registry.connections.first(where: { $0.id == connectionID }) {
            guard saved.catalogueID == tool.id || saved.endpoint == configuration.endpoint else {
                throw ToolConnectionError.message("The saved account does not match this tool.")
            }
            record = saved
        } else {
            record = try tool.makeConnection(id: connectionID,
                name: name ?? ToolCatalog.availableName(for: tool, existingNames: registry.connections.map(\.name)), values: values)
        }
        try save(record)
        return registry.connections.first { $0.id == record.id }!
    }
    public func assign(_ ids: Set<UUID>, to agent: AgentRecord, synchronizeWorkspace: Bool = true) throws {
        try store.assign(ids, to: agent.id)
        if synchronizeWorkspace { try repository.synchronizeAgentWorkspace(agent) }
    }
    public func reloadAssignments() throws { try store.reload() }
    public func validateAssignment(_ ids: Set<UUID>) throws { try store.validate(ids) }
    public func selectedIDs(for agent: AgentRecord) -> Set<UUID> { Set(registry.assigned(to: agent.id).map(\.id)) }
    func remove(_ record: ToolConnection) {
        if signingIn == record.id { loginTask?.cancel() }
        do {
            try store.remove([record.id]) { [weak self] record, revocation, failure in
                if let failure { self?.errorMessage = failure.localizedDescription }
                else if case .failed(let reason) = revocation {
                    self?.errorMessage = "\(record.name) was removed, but the service could not revoke its sign-in: \(reason) Revoke it in the service's account settings."
                }
            }
            activity.retain(Set(registry.connections.map(\.id)))
            activityWindows.synchronize(names: Dictionary(uniqueKeysWithValues: registry.connections.map { ($0.id, $0.name) }))
            try synchronize()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Revokes what the connection signed in with or was given at the service, where it can, and forgets it here;
    /// the connection stays, to connect again.
    public func signOut(_ record: ToolConnection) {
        if signingIn == record.id { loginTask?.cancel() }
        Task {
            let revocation = await store.signOut(record)
            let app = ProductIdentity.current.name
            switch revocation {
            case .revoked: break
            case .notOffered:
                errorMessage = "\(record.name) is signed out of \(app), but the service offers no way to revoke its key from here. Revoke it in the service's account settings."
            case .failed(let reason):
                errorMessage = "\(record.name) is signed out of \(app), but the service could not revoke it: \(reason) Revoke it in the service's account settings."
            }
        }
    }
    /// Signs the connection in through the browser, or through AWS IAM Identity Center with a code the person
    /// approves there, or for one with a token or a client ID and secret keeps `secret` when one is given; either way
    /// it then lists the connection's tools to show it works. A server found to need no sign-in is kept as open.
    public func connect(_ record: ToolConnection, secret: ToolConnectionSecret? = nil) {
        guard signingIn == nil else { return }
        var record = record
        let signsIn = ToolConnectionService.signsInThroughBrowser(record)
        let withCode = ToolConnectionService.signsInWithCode(record)
        if signsIn && !withCode { browser.captureReturnWindow() }
        signingIn = record.id
        store.beginSignIn(record.id)
        loginTask = Task {
            defer { signingIn = nil; loginTask = nil; signInStage = "" }
            do {
                if record.awsIdentityCenter != nil {
                    // The page opens with its code filled in; the code shows here too, to check it is the same.
                    try await service.signInWithAWS(record, progress: { [weak self] stage in
                        await self?.setSignInStage(stage)
                    }) { _, page in
                        await MainActor.run { _ = NSWorkspace.shared.open(page) }
                    }
                } else if withCode {
                    // The code shows here while the service's page is open, for the person to enter there.
                    try await service.signInWithCode(record, progress: { [weak self] stage in
                        await self?.setSignInStage(stage)
                    }) { _, page in
                        await MainActor.run { _ = NSWorkspace.shared.open(page) }
                    }
                } else if !signsIn {
                    switch secret {
                    case .token(let token): try await service.saveToken(token, for: record)
                    case .client(let id, let value): try await service.saveClientCredentials(clientID: id, secret: value, for: record)
                    case nil: break
                    }
                } else {
                    let redirect = Self.redirectURI(for: record.endpoint)
                    let result = try await service.signIn(record, redirectURI: redirect, progress: { [weak self] stage in
                        await self?.setSignInStage(stage)
                    }) { [browser] url in
                        try await browser.authorize(url: url, callbackURL: redirect)
                    }
                    if result == .open { record.open = true }
                }
                try Task.checkCancellation()
                signInStage = "Checking available tools…"
                let request = MCPBridgeRequest(session: "", connectionID: record.id, action: .tools, tool: nil, arguments: nil)
                _ = try await service.perform(request, connection: record)
                try store.signedIn(record, icon: await service.icon(for: record))
                try synchronize()
            } catch {
                store.signInFailed(record, error)
            }
        }
    }
    public func cancelSignIn() { loginTask?.cancel() }

    /// Where a sign-in for a connection at `endpoint` returns to this app.
    public static func redirectURI(for endpoint: URL) -> URL {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let scheme = (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "noodle-dev"
        return ToolConnectionService.configuredRedirectURI(for: endpoint) ?? URL(string: "\(scheme)://mcp/oauth/callback")!
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
    /// The bots' workspaces follow every change to their connections.
    private func synchronize() throws {
        for agent in agents { try repository.synchronizeAgentWorkspace(agent) }
    }

    /// Starts checking the watched connections every few minutes, waking the bots each is assigned to through `runtime`
    /// when it has something new. Every app calls it once its bots run; a connection is watched only if its adapter or
    /// catalogue entry says so in code.
    public func watch(with runtime: AgentRuntimeCoordinator) {
        let repository = repository
        store.watch { runtime.wake($0, note: $1, repository: repository) }
    }

    public func stopWatching() { store.stopWatching() }

    /// One round of checks, as the watch makes every few minutes.
    func checkWatched(at now: Date = Date(), wake: (UUID, String) -> Void) async {
        await store.checkWatched(at: now, wake: wake)
    }

    /// While watching, a line under each watched account in Settings › Tools, by account: that it is watched, or why it
    /// could not be checked last time, which shows as an error does.
    public var notes: [UUID: ToolConnectionNote] {
        var notes: [UUID: ToolConnectionNote] = [:]
        for connection in store.watched {
            notes[connection.id] = store.watchProblems[connection.id].map { ToolConnectionNote("Could not check for alerts: " + $0, isProblem: true) }
                ?? ToolConnectionNote("Watched for new alerts")
        }
        return notes
    }

    /// Shows what the connection has done since the app started, in its own window.
    public func showActivity(_ connection: ToolConnection) {
        activityWindows.show(id: connection.id, name: connection.name, log: activity.log(for: connection.id))
    }

    /// Adds a line to the connection's activity, with any detail under it.
    public func recordActivity(_ connection: UUID, _ title: String, detail: String = "") {
        store.recordActivity(connection, title, detail: detail)
    }

    /// Puts a changed organisation policy in force: blocked connections leave the bots that had them.
    public func applyOrganisationPolicy() { store.synchronize() }
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
        // Callers validate the page already; a server-supplied file, app or local address must never open even if one misses it.
        guard (try? ToolConnection.validatedEndpoint(url)) != nil,
              pendingID == nil, states.count == 1, let state = states.first?.value, !state.isEmpty else {
            throw ToolConnectionServiceError.invalidCallback
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
                    if !Task.isCancelled { self?.finish(id, .failure(ToolConnectionServiceError.timedOut)) }
                }
                if !openURL(url) {
                    finish(id, .failure(ToolConnectionError.message("Could not open your browser. Check your default browser and try again.")))
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
