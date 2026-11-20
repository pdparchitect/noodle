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

@MainActor @Observable
public final class ToolConnectionsController {
    public private(set) var registry = ToolConnectionRegistry()
    private(set) var connected: Set<UUID> = []
    private(set) var signingIn: UUID?
    private(set) var signInStage = ""
    public private(set) var errors: [UUID: String] = [:]
    var errorMessage: String?
    /// What each connection has done since the app started: bots' calls, sign-ins, and what the app adds, by connection.
    @ObservationIgnored public let activity = ActivityStore()
    @ObservationIgnored private let activityWindows = ActivityWindows()
    /// Watches the connections whose adapter has a feed, or whose catalogue entry a trigger, for something new.
    @ObservationIgnored private let watcher: AlertWatcher
    @ObservationIgnored private var watching: Task<Void, Never>?
    private var isWatching = false
    /// Why each watched account could not be checked last time, by account.
    private var watchProblems: [UUID: String] = [:]
    @ObservationIgnored private let repository: WorkspaceRepository
    /// Keeps the connections' sign-ins; This Mac as a Hub signs tools in through it too.
    @ObservationIgnored public let service: ToolConnectionService
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    private var agents: [AgentRecord] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var providers: ToolConnectionProviders?
    /// Where this controller registers one provider per connection.
    @ObservationIgnored public var toolRegistry: ToolProviderRegistry? {
        didSet {
            providers = toolRegistry.map { ToolConnectionProviders(registry: $0, service: service) }
            providers?.onError = { [weak self] id, message in self?.errors[id] = message }
            providers?.onCall = { [weak self] in self?.recordCall($0) }
            providers?.appInstructions = { [weak self] in self?.instructions(for: $0) }
            synchronizeProviders()
        }
    }
    /// What the app says about a connection in the skill bots read for it, after what its wake means, if it is watched,
    /// and before the person's own instructions.
    @ObservationIgnored public var appInstructions: (@MainActor (ToolConnection) -> String?)? {
        didSet { synchronizeProviders() }
    }
    /// Receives the connections each bot is granted, now and on every change.
    @ObservationIgnored public var onAssignmentsChange: (([UUID: Set<String>]) -> Void)? { didSet { synchronizeProviders() } }
    @ObservationIgnored private let browser = MCPBrowserAuthorization()
    @ObservationIgnored private var registryReadable = true
    @ObservationIgnored private let deletions: DeletionJournal<UUID>

    public init(repository: WorkspaceRepository, service: ToolConnectionService? = nil) {
        self.repository = repository
        self.service = service ?? ToolConnectionService(namespace: Bundle.main.bundleIdentifier ?? "com.pdparchitect.noodle.local")
        deletions = DeletionJournal(url: repository.rootURL.appendingPathComponent("MCP/removed-sign-ins.json"))
        watcher = AlertWatcher(file: repository.rootURL.appendingPathComponent("alert-watch.json"), service: self.service)
        do { registry = try ToolConnectionRegistry.load(root: repository.rootURL) }
        catch {
            registryReadable = false
            errorMessage = "Could not read saved tool connections. They have not been replaced."
        }
    }
    deinit { loginTask?.cancel(); watching?.cancel() }
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
                await readSignIns()
            }
        }
    }
    /// Reads which connections are signed in, after something besides Settings signed one in or out.
    /// One the app's adapter answers without credentials, or an open server, is always ready.
    public func readSignIns() async {
        for connection in registry.connections {
            let open = (connection.adapter != nil && !connection.keepsSecret) || connection.open == true
            let signedIn = await service.hasCredentials(connection.id)
            if open || signedIn { connected.insert(connection.id) } else { connected.remove(connection.id) }
        }
    }

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
        watcher.adapters = adapters
        watcher.triggers = triggers
        let service = service
        Task { await service.useAdapters(adapters) }
        synchronizeProviders()
    }
    func save(_ record: ToolConnection) throws {
        guard Organisation.allows(Organisation.action(for: record)) else { throw ToolConnectionServiceError.notAllowed }
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
        do { registry = try ToolConnectionRegistry.load(root: repository.rootURL); registryReadable = true }
        catch { registryReadable = false; throw error }
    }
    public func validateAssignment(_ ids: Set<UUID>) throws {
        try requireReadableRegistry()
        guard ids.isSubset(of: Set(registry.connections.map(\.id))) else {
            throw ToolConnectionError.message("One of the selected tool connections no longer exists.")
        }
    }
    private func requireReadableRegistry() throws {
        guard registryReadable else {
            throw ToolConnectionError.message("Saved tool connections could not be read. Restore the registry before making changes; the existing file has not been replaced.")
        }
    }
    public func selectedIDs(for agent: AgentRecord) -> Set<UUID> { Set(registry.assigned(to: agent.id).map(\.id)) }
    func remove(_ record: ToolConnection) {
        if signingIn == record.id { loginTask?.cancel() }
        var next = registry
        next.remove(record.id)
        do {
            try requireReadableRegistry()
            try deletions.schedule([record.id])
            try next.save(root: repository.rootURL)
            registry = next // Revoke broker access immediately, before asynchronous cleanup.
            synchronizeProviders()
            activity.retain(Set(next.connections.map(\.id)))
            activityWindows.synchronize(names: Dictionary(uniqueKeysWithValues: next.connections.map { ($0.id, $0.name) }))
            connected.remove(record.id)
            errors[record.id] = nil
            Task {
                // Revoked at the service first, while what it signed in with is still here; deleted whatever the service said.
                let revocation = await service.revoke(record)
                if let error = await deleteRemovedSignIns() { errorMessage = error.localizedDescription }
                else if case .failed(let reason) = revocation {
                    errorMessage = "\(record.name) was removed, but the service could not revoke its sign-in: \(reason) Revoke it in the service's account settings."
                }
            }
            try synchronize()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Revokes what the connection signed in with or was given at the service, where it can, and forgets it here;
    /// the connection stays, to connect again.
    public func signOut(_ record: ToolConnection) {
        if signingIn == record.id { loginTask?.cancel() }
        Task {
            let revocation = await service.signOut(record)
            connected.remove(record.id)
            errors[record.id] = nil
            recordActivity(record.id, "Signed out")
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
    /// Deletes removed connections' sign-ins; one that fails is tried again on the next removal or start.
    @discardableResult private func deleteRemovedSignIns() async -> Error? {
        await deletions.run { id in
            // A removal whose registry write failed keeps its connection, so it keeps its sign-in too.
            guard registryReadable else { throw ToolConnectionError.message("Saved tool connections could not be read.") }
            guard !registry.connections.contains(where: { $0.id == id }) else { return }
            try await service.disconnect(id)
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
        errors[record.id] = nil
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
                let icon = await service.icon(for: record)
                guard var current = registry.connections.first(where: { $0.id == record.id }) else { return }
                connected.insert(record.id)
                let found = current
                if let icon { current.iconData = icon }
                if record.open == true { current.open = true }
                if current != found { try save(current) }
                else { try synchronize() }
                recordActivity(record.id, record.open == true ? "Connected, with no sign-in" : "Signed in")
            } catch is CancellationError {
                errors[record.id] = "Sign-in cancelled."
                recordActivity(record.id, "Sign-in cancelled")
            } catch ToolConnectionServiceError.signInRequired where record.open == true {
                // No longer open: it is signed in to from now on.
                connected.remove(record.id)
                if var current = registry.connections.first(where: { $0.id == record.id }) {
                    current.open = nil
                    try? save(current)
                    errors[record.id] = "This server now asks for a sign-in. Connect again to sign in."
                    recordActivity(record.id, "Could not connect", detail: errors[record.id] ?? "")
                }
            } catch {
                if registry.connections.contains(where: { $0.id == record.id }) {
                    errors[record.id] = Self.safeError(error)
                    recordActivity(record.id, "Could not sign in", detail: Self.safeError(error))
                }
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
    private func synchronize() throws {
        for agent in agents { try repository.synchronizeAgentWorkspace(agent) }
    }
    /// Call after every change to `registry`. A connection that cannot be read grants nothing.
    private func synchronizeProviders() {
        // What the organisation blocks reaches no bot; nothing is deleted, so it comes back once allowed.
        let allowed = Set(registry.connections.filter { Organisation.allows(Organisation.action(for: $0)) }.map(\.id))
        let connections = registryReadable ? registry.connections.filter { allowed.contains($0.id) } : []
        providers?.synchronize(connections) { [weak self] id in self?.registry.connections.first { $0.id == id } }
        let granted = registryReadable ? registry.assignments : [:]
        onAssignmentsChange?(Dictionary(uniqueKeysWithValues: granted.compactMap { key, ids in
            UUID(uuidString: key).map { ($0, Set(ids.filter(allowed.contains).map(\.uuidString))) }
        }))
    }
    private nonisolated static func safeError(_ error: Error) -> String { ToolConnectionProviders.safeError(error) }

    /// What a connection's skill says before the person's own instructions: what its wake means, if it is watched, then
    /// what the app adds.
    private func instructions(for connection: ToolConnection) -> String? {
        let parts = [watcher.skillText(for: connection), appInstructions?(connection)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Starts checking the watched connections every few minutes, waking the bots each is assigned to through `runtime`
    /// when it has something new. Every app calls it once its bots run; a connection is watched only if its adapter or
    /// catalogue entry says so in code.
    public func watch(with runtime: AgentRuntimeCoordinator) {
        guard watching == nil else { return }
        isWatching = true
        watching = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkWatched { [weak self] id, note in
                    guard let self else { return }
                    runtime.wake(id, note: note, repository: self.repository)
                }
                try? await Task.sleep(for: AlertWatcher.interval)
            }
        }
    }

    public func stopWatching() {
        watching?.cancel()
        watching = nil
        isWatching = false
    }

    /// The connections watched, signed in and assigned, with the bots each is assigned to; and those watched and assigned
    /// but not signed in too, whose checks pick up where they stopped once they are signed in again.
    private func watchedAccounts() -> (accounts: [(connection: ToolConnection, agents: [UUID])], keeping: Set<UUID>) {
        let allowed = registryReadable ? registry.connections.filter { Organisation.allows(Organisation.action(for: $0)) } : []
        var accounts: [(connection: ToolConnection, agents: [UUID])] = [], keeping: Set<UUID> = []
        for connection in allowed where watcher.watches(connection) {
            let holders = agents.map(\.id).filter { registry.assigned(to: $0).contains { $0.id == connection.id } }
            guard !holders.isEmpty else { continue }
            keeping.insert(connection.id)
            if status(of: connection) == .connected { accounts.append((connection, holders)) }
        }
        return (accounts, keeping)
    }

    /// While watching, a line under each watched account in Settings › Tools, by account: that it is watched, or why it
    /// could not be checked last time, which shows as an error does.
    public var notes: [UUID: ToolConnectionNote] {
        guard isWatching else { return [:] }
        var notes: [UUID: ToolConnectionNote] = [:]
        for (connection, _) in watchedAccounts().accounts {
            notes[connection.id] = watchProblems[connection.id].map { ToolConnectionNote("Could not check for alerts: " + $0, isProblem: true) }
                ?? ToolConnectionNote("Watched for new alerts")
        }
        return notes
    }

    /// One round of checks, waking with `wake` the bots each account with something new is assigned to, and adding each
    /// check to its account's activity.
    func checkWatched(at now: Date = Date(), wake: (UUID, String) -> Void) async {
        let (accounts, keeping) = watchedAccounts()
        guard !keeping.isEmpty else { return }
        let checked = await watcher.check(accounts, keeping: keeping, at: now, wake: wake)
        watchProblems = checked.compactMapValues { if case .failed(let reason) = $0 { reason } else { nil } }
        for (connection, holders) in accounts {
            switch checked[connection.id] {
            case .nothingNew?: recordActivity(connection.id, "Checked for alerts: nothing new")
            case .found(let what)?:
                let names = holders.compactMap { id in agents.first { $0.id == id }?.displayName }.formatted(.list(type: .and))
                recordActivity(connection.id, "Found \(what); woke \(names)")
            case .failed(let reason)?: recordActivity(connection.id, "Could not check for alerts", detail: reason)
            case nil: break
            }
        }
    }

    /// Shows what the connection has done since the app started, in its own window.
    public func showActivity(_ connection: ToolConnection) {
        activityWindows.show(id: connection.id, name: connection.name, log: activity.log(for: connection.id))
    }

    /// Adds a line to the connection's activity, with any detail under it.
    public func recordActivity(_ connection: UUID, _ title: String, detail: String = "") {
        activity.log(for: connection).record(ActivityEvent(title: title, detail: detail))
    }

    /// A bot's request, named by the bot and what it asked for. Listing tools comes before every call, so only a failed
    /// listing is worth a line.
    private func recordCall(_ call: ToolConnectionCall) {
        let bot = agents.first { $0.id == call.agent }?.displayName ?? "Someone removed since"
        let asked: (done: String, failed: String)? = switch call.action {
        case .call: ("called \(call.tool ?? "a tool")", "\(call.tool ?? "a tool") failed")
        case .resources: ("listed resources", "listing resources failed")
        case .readResource: ("read a resource", "reading a resource failed")
        case .tools, .inspect: call.failure == nil ? nil : ("", "listing tools failed")
        }
        guard let asked else { return }
        let seconds = Double(call.duration.components.seconds) + Double(call.duration.components.attoseconds) / 1e18
        let took = " (\(seconds.formatted(.number.precision(.fractionLength(1)))) s)"
        if let failure = call.failure { recordActivity(call.connection, "\(bot): \(asked.failed)" + took, detail: failure) }
        else { recordActivity(call.connection, "\(bot) \(asked.done)" + took) }
    }
    /// Puts a changed organisation policy in force: blocked connections leave the bots that had them.
    public func applyOrganisationPolicy() { synchronizeProviders() }
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
