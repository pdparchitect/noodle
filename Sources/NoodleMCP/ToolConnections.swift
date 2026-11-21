import Foundation
import NoodleCore
import Observation

/// The tool connections an app or a Hub keeps, and everything about them that is the same wherever they are kept: the
/// saved registry and which bot is granted which connection, which are ready, why one last failed, one tool provider
/// per connection for the broker, the sign-ins removed connections leave behind, how a sign-in ends, watching them for
/// something new, and what each has done. Who may change them, and how a sign-in reaches a browser, belong to whoever
/// keeps them: Noodle's Settings on a Mac, or people's devices on a Hub.
@MainActor @Observable public final class ToolConnections {
    public private(set) var registry = ToolConnectionRegistry()
    /// Whether the saved registry could be read. One that could not grants nothing and is never written over.
    public private(set) var isReadable = true
    /// The connections that answer without anything more: signed in, an open server, or one the app's adapter answers
    /// without a secret.
    public private(set) var ready: Set<UUID> = []
    /// The connections whose sign-in has been read since the app started, so one found without it is noted only once.
    @ObservationIgnored private var signInsRead: Set<UUID> = []
    /// Why each connection last failed, in words safe to show, by connection.
    /// Set only through `fail`, which also adds the failure to the connection's activity.
    public private(set) var problems: [UUID: String] = [:]
    /// Whether the watched connections are being checked.
    public private(set) var isWatching = false
    /// Why each watched connection could not be checked last time, by connection.
    public private(set) var watchProblems: [UUID: String] = [:]
    /// What each watched connection's checks found since the app started, by connection.
    public private(set) var watchStatus: [UUID: WatchStatus] = [:]

    /// Keeps the connections' sign-ins, where bots never see them.
    @ObservationIgnored public let service: ToolConnectionService
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let deletions: DeletionJournal<UUID>
    @ObservationIgnored private let watcher: AlertWatcher
    /// The watched connections whose activity says they are not checked, being assigned to no bot.
    @ObservationIgnored private var toldUnassigned: Set<UUID> = []
    @ObservationIgnored private var watching: Task<Void, Never>?
    /// While watching, how bots are woken: for something new on a watched connection, or when one is signed in again.
    @ObservationIgnored private var wake: (@MainActor (UUID, String) -> Void)?
    /// The connections whose service failed a bot's request since they last worked: checked while watching, and their
    /// bots told once one works again. Kept apart from `problems`, which a sign-in clears as it starts.
    @ObservationIgnored private var down: Set<UUID> = []
    @ObservationIgnored private var providers: ToolConnectionProviders?
    @ObservationIgnored private var started = false
    /// Reading which connections are ready when whoever keeps them starts, which the first round of checks waits for.
    @ObservationIgnored private var startup: Task<Void, Never>?

    /// The bots these connections are kept for, by ID, with their names: those a watched connection wakes, and the
    /// names its activity gives them.
    @ObservationIgnored public var bots: () -> [UUID: String] = { [:] }
    /// Where one provider per connection is registered for the broker that serves bots.
    @ObservationIgnored public var toolRegistry: ToolProviderRegistry? {
        didSet {
            providers = toolRegistry.map { ToolConnectionProviders(registry: $0, service: service) }
            providers?.onError = { [weak self] id, message in self?.fail(id, "Could not offer it to agents", because: message) }
            providers?.onCall = { [weak self] in self?.record($0); self?.note($0) }
            providers?.appInstructions = { [weak self] in self?.instructions(for: $0) }
            synchronize()
        }
    }
    /// What the app says about a connection in the skill bots read for it, after what its wake means, if it is watched,
    /// and before the person's own instructions.
    @ObservationIgnored public var appInstructions: (@MainActor (ToolConnection) -> String?)? {
        didSet { synchronize() }
    }
    /// Receives the connections each bot is granted, by bot, now and on every change.
    @ObservationIgnored public var onGrantsChange: (([UUID: Set<String>]) -> Void)? { didSet { synchronize() } }
    /// Rewrites the bots' tool skills and returns once they are written. A connection that works again has its skills
    /// rewritten through it before its bots are told, so they find its tools listed and hear both at once.
    @ObservationIgnored public var refreshSkills: (@MainActor () async -> Void)?
    /// Receives each line of a connection's activity: the connection, the line, and any detail under it.
    @ObservationIgnored public var onActivity: ((UUID, String, String) -> Void)?

    public init(root: URL, service: ToolConnectionService) {
        self.root = root
        self.service = service
        deletions = DeletionJournal(url: root.appendingPathComponent("MCP/removed-sign-ins.json"))
        watcher = AlertWatcher(file: root.appendingPathComponent("alert-watch.json"), service: service)
        do { registry = try ToolConnectionRegistry.load(root: root) } catch { isReadable = false }
    }
    deinit { watching?.cancel() }

    /// Deletes the sign-ins removed connections left behind and reads which connections are ready: once, when whoever
    /// keeps them starts.
    public func start() {
        guard !started else { return }
        started = true
        // Finishes even if nothing else keeps these connections, so a sign-in left behind is never kept.
        startup = Task {
            await deleteRemovedSignIns()
            await readSignIns()
        }
    }

    /// Reads which connections are ready, after something else signed one in or out. One the app's adapter answers
    /// without a secret, or an open server, always is.
    public func readSignIns() async {
        for connection in registry.connections {
            let open = (connection.adapter != nil && !connection.keepsSecret) || connection.open == true
            let signedIn = await service.hasCredentials(connection.id)
            if open || signedIn {
                ready.insert(connection.id)
            } else {
                // Noted when first found, or when it is lost, so the mark the sidebar puts on it never opens an empty log.
                if ready.remove(connection.id) != nil || !signInsRead.contains(connection.id) {
                    recordActivity(connection.id, connection.usesToken ? "Token required"
                                   : connection.clientCredentials != nil ? "Credentials required" : "Sign-in required")
                }
            }
            signInsRead.insert(connection.id)
        }
        ready.formIntersection(registry.connections.map(\.id))
    }

    /// The adapters this app serves its own connections with, by the name catalogue entries give them, and the boards
    /// it watches on MCP servers, by the catalogue entry their connections are made from. An adapter with a feed is
    /// watched too.
    public func serve(_ adapters: [String: any ToolConnectionAdapter], triggers: [String: MCPTrigger] = [:]) {
        watcher.adapters = adapters
        watcher.triggers = triggers
        let service = service
        Task { await service.useAdapters(adapters) }
        synchronize()
    }

    // MARK: Changing them

    /// Saves a new connection or a change to one, granted to no bot it was not granted to already. Throws, changing
    /// nothing, when the organisation does not allow it or the saved registry could not be read.
    public func save(_ record: ToolConnection) throws {
        guard Organisation.allows(Organisation.action(for: record)) else { throw ToolConnectionServiceError.notAllowed }
        try requireReadable()
        var next = registry
        if let index = next.connections.firstIndex(where: { $0.id == record.id }) { next.connections[index] = record }
        else { next.connections.append(record) }
        try next.save(root: root)
        registry = next
        synchronize()
    }

    /// Replaces which connections a bot may use.
    public func assign(_ ids: Set<UUID>, to bot: UUID) throws {
        try validate(ids)
        var next = registry
        try next.assign(ids, to: bot)
        try next.save(root: root)
        registry = next
        synchronize()
    }

    /// Throws when these connections cannot be granted: the saved registry could not be read, or one no longer exists.
    public func validate(_ ids: Set<UUID>) throws {
        try requireReadable()
        guard ids.isSubset(of: Set(registry.connections.map(\.id))) else {
            throw ToolConnectionError.message("One of the selected tool connections no longer exists.")
        }
    }

    /// Reads the connections and grants again, after something else changed them in the same files. Throws rather than
    /// keep an older copy, which a later save would write over the newer one. Without `synchronizing`, the providers and
    /// grants are left as they are, for a copy that only edits the files and serves no bot.
    public func reload(synchronizing: Bool = true) throws {
        defer { if synchronizing { synchronize() } }
        do { registry = try ToolConnectionRegistry.load(root: root); isReadable = true }
        catch { isReadable = false; throw error }
        Task { [weak self] in await self?.readSignIns() }
    }

    /// Removes connections, so no bot can reach them from now on; then revokes each one's sign-in at its service, where
    /// the service allows it, and deletes it here, whatever the service said. `removed` hears how each revocation went,
    /// with any error deleting the sign-ins, which is tried again on the next removal or start.
    public func remove(_ ids: Set<UUID>,
                       removed: (@MainActor (ToolConnection, ToolConnectionService.Revocation, Error?) -> Void)? = nil) throws {
        try requireReadable()
        let records = registry.connections.filter { ids.contains($0.id) }
        guard !records.isEmpty else { return }
        var next = registry
        records.forEach { next.remove($0.id) }
        try deletions.schedule(Set(records.map(\.id)))
        try next.save(root: root)
        // No bot reaches them from now on, before the sign-ins are cleared away.
        registry = next
        synchronize()
        for record in records {
            ready.remove(record.id)
            problems[record.id] = nil
            down.remove(record.id)
        }
        let service = service
        Task {
            // Revoked at the service first, while what it signed in with is still here.
            var revocations: [(ToolConnection, ToolConnectionService.Revocation)] = []
            for record in records { revocations.append((record, await service.revoke(record))) }
            let failure = await deleteRemovedSignIns()
            for (record, revocation) in revocations { removed?(record, revocation, failure) }
        }
    }

    /// Takes away every grant of a bot that is gone.
    public func forget(bot: UUID) {
        let key = bot.uuidString.lowercased()
        guard isReadable, registry.assignments[key] != nil else { return }
        var next = registry
        next.assignments[key] = nil
        try? next.save(root: root)
        registry = next
        synchronize()
    }

    /// Deletes removed connections' sign-ins; one that fails is tried again on the next removal or start.
    @discardableResult private func deleteRemovedSignIns() async -> Error? {
        await deletions.run { id in
            // A removal whose registry write failed keeps its connection, so it keeps its sign-in too.
            guard isReadable else { throw ToolConnectionError.message("Saved tool connections could not be read.") }
            guard !registry.connections.contains(where: { $0.id == id }) else { return }
            try await service.disconnect(id)
        }
    }

    private func requireReadable() throws {
        guard isReadable else {
            throw ToolConnectionError.message("Saved tool connections could not be read. Restore the registry before making changes; the existing file has not been replaced.")
        }
    }

    /// Call after every change to `registry`. What cannot be read grants nothing; what the organisation blocks reaches
    /// no bot and is kept, to come back once it is allowed.
    public func synchronize() {
        let allowed = Set(registry.connections.filter { Organisation.allows(Organisation.action(for: $0)) }.map(\.id))
        let connections = isReadable ? registry.connections.filter { allowed.contains($0.id) } : []
        providers?.synchronize(connections) { [weak self] id in self?.registry.connections.first { $0.id == id } }
        let granted = isReadable ? registry.assignments : [:]
        onGrantsChange?(Dictionary(uniqueKeysWithValues: granted.compactMap { key, ids in
            UUID(uuidString: key).map { ($0, Set(ids.filter(allowed.contains).map(\.uuidString))) }
        }))
    }

    // MARK: Signing in

    /// A sign-in is starting: what went wrong before is forgotten.
    public func beginSignIn(_ id: UUID) { problems[id] = nil }

    /// A sign-in that worked: the connection is ready, and keeps the icon its service gave and whether it turned out to
    /// need no sign-in, as `record.open` says.
    public func signedIn(_ record: ToolConnection, icon: Data?) throws {
        guard var current = registry.connections.first(where: { $0.id == record.id }) else { return }
        let failed = down.remove(record.id) != nil
        let recovered = ready.insert(record.id).inserted || failed
        problems[record.id] = nil
        let found = current
        if let icon { current.iconData = icon }
        if record.open == true { current.open = true }
        if current != found { try save(current) }
        recordActivity(record.id, record.open == true ? "Connected, with no sign-in" : "Signed in")
        if recovered, let wake { Task { await tell([current], "is working: the person just signed it in", wake: wake) } }
    }

    /// Rewrites the bots' skills, then tells the bots of each connection, but `sparing`, that it is working: the skill a
    /// note names then lists the connection's tools, and any note the rewrite wakes a bot with arrives with this one.
    private func tell(_ connections: [ToolConnection], _ news: String, sparing: UUID? = nil, wake: (UUID, String) -> Void) async {
        await refreshSkills?()
        for connection in connections { tellBots(connection, news, sparing: sparing, wake: wake) }
    }

    /// Wakes the bots the connection is assigned to, except `sparing`, saying it is working: nothing else tells a bot
    /// that found it failed, or signed out, and is waiting on it.
    private func tellBots(_ connection: ToolConnection, _ news: String, sparing: UUID? = nil, wake: (UUID, String) -> Void) {
        let names = bots()
        let told = names.keys.filter { bot in bot != sparing && registry.assigned(to: bot).contains { $0.id == connection.id } }
            .sorted { $0.uuidString < $1.uuidString }
        guard !told.isEmpty else { return }
        let note = "The \(connection.name) tool connection \(news). Its skill is .agents/skills/\(connection.skillName)/SKILL.md. If you were waiting on it, retry what failed and carry on; otherwise finish silently."
        for bot in told { wake(bot, note) }
        recordActivity(connection.id, "Told \(told.compactMap { names[$0] }.formatted(.list(type: .and))) it is working")
    }

    /// A sign-in that failed, saying why in words safe to show. An open server that now asks for a sign-in is signed in
    /// to from now on.
    public func signInFailed(_ record: ToolConnection, _ error: Error) {
        guard var current = registry.connections.first(where: { $0.id == record.id }) else { return }
        if error is CancellationError {
            fail(record.id, "Sign-in cancelled", because: "Sign-in cancelled.", detailed: false)
        } else if case .signInRequired? = error as? ToolConnectionServiceError, record.open == true || current.open == true {
            ready.remove(record.id)
            current.open = nil
            try? save(current)
            fail(record.id, "Could not connect", because: "This server now asks for a sign-in. Connect again to sign in.")
        } else {
            fail(record.id, "Could not sign in", because: ToolConnectionProviders.safeError(error))
        }
    }

    /// Revokes what the connection signed in with at its service, where it can, and forgets it here; the connection
    /// stays, to connect again. Says how the revocation went.
    public func signOut(_ record: ToolConnection) async -> ToolConnectionService.Revocation {
        let revocation = await service.signOut(record)
        ready.remove(record.id)
        problems[record.id] = nil
        recordActivity(record.id, "Signed out")
        return revocation
    }

    // MARK: Watching

    /// What a connection's skill says before the person's own instructions: what its wake means, if it is watched, then
    /// what the app adds.
    private func instructions(for connection: ToolConnection) -> String? {
        let parts = [watcher.skillText(for: connection), appInstructions?(connection)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Starts checking the watched connections every few minutes, waking with `wake` the bots each is assigned to when
    /// it has something new. Whoever runs the bots starts it; a connection is watched only if its adapter or catalogue
    /// entry says so in code.
    public func watch(wake: @escaping @MainActor (UUID, String) -> Void) {
        guard watching == nil else { return }
        isWatching = true
        self.wake = wake
        watching = Task { [weak self] in
            // Checked as soon as the app knows which are ready, not a round later for finding none ready yet.
            await self?.startup?.value
            while !Task.isCancelled {
                await self?.checkWatched(wake: wake)
                await self?.checkFailed(wake: wake)
                try? await Task.sleep(for: AlertWatcher.interval)
            }
        }
    }

    public func stopWatching() {
        watching?.cancel()
        watching = nil
        wake = nil
        isWatching = false
    }

    /// The watched connections that are ready and have not failed, with the bots each is assigned to; every watched
    /// connection assigned to a bot, whose checks pick up where they stopped once it is ready again; and those assigned
    /// to none, which are never checked.
    private func watchedAccounts() -> (accounts: [(connection: ToolConnection, agents: [UUID])], keeping: Set<UUID>, unassigned: Set<UUID>) {
        guard isReadable else { return ([], [], []) }
        let bots = bots().keys
        var accounts: [(connection: ToolConnection, agents: [UUID])] = [], keeping: Set<UUID> = [], unassigned: Set<UUID> = []
        for connection in registry.connections where Organisation.allows(Organisation.action(for: connection)) && watcher.watches(connection) {
            let holders = bots.filter { registry.assigned(to: $0).contains { $0.id == connection.id } }
                .sorted { $0.uuidString < $1.uuidString }
            guard !holders.isEmpty else { unassigned.insert(connection.id); continue }
            keeping.insert(connection.id)
            if ready.contains(connection.id), problems[connection.id] == nil { accounts.append((connection, holders)) }
        }
        return (accounts, keeping, unassigned)
    }

    /// Whether this connection is watched: its adapter has a feed, or its MCP server a board.
    public func watches(_ connection: ToolConnection) -> Bool { watcher.watches(connection) }

    /// While watching, the connections checked each round: watched, assigned to a bot, ready and not failed.
    public var watched: [ToolConnection] {
        isWatching ? watchedAccounts().accounts.map(\.connection) : []
    }

    /// One round of checks, waking with `wake` the bots each connection with something new is assigned to, and adding
    /// each check to its connection's activity. A watched connection assigned to no bot says once that it is not checked.
    public func checkWatched(at now: Date = Date(), wake: (UUID, String) -> Void) async {
        let (accounts, keeping, unassigned) = watchedAccounts()
        for id in unassigned.subtracting(toldUnassigned) { recordActivity(id, "Not checked for alerts until it is assigned") }
        toldUnassigned = unassigned
        guard !keeping.isEmpty else { return }
        let checked = await watcher.check(accounts, keeping: keeping, at: now, wake: wake)
        watchProblems = checked.compactMapValues { if case .failed(let reason) = $0 { reason } else { nil } }
        let names = bots()
        for (connection, holders) in accounts {
            if let result = checked[connection.id] {
                let woke = holders.compactMap { names[$0] }
                watchStatus[connection.id] = WatchStatus(previous: watchStatus[connection.id], checked: now, result: result, woke: woke,
                                                         interval: watcher.trigger(for: connection)?.interval ?? AlertWatcher.interval.seconds)
            }
            switch checked[connection.id] {
            case .started?: recordActivity(connection.id, "Watching for alerts from now on")
            case .nothingNew?: recordActivity(connection.id, "Checked for alerts: nothing new")
            case .found(let what)?:
                let woke = holders.compactMap { names[$0] }.formatted(.list(type: .and))
                recordActivity(connection.id, "Found \(what); woke \(woke)")
            case .failed(let reason)?: recordActivity(connection.id, "Could not check for alerts", detail: reason)
            case nil: break
            }
        }
    }

    /// Lists the tools of each connection that failed and could work again by itself, being ready and assigned to a bot,
    /// waking with `wake` the bots of one that now answers. One that still fails changes nothing.
    public func checkFailed(wake: (UUID, String) -> Void) async {
        guard isReadable else { return }
        let bots = bots().keys
        var back: [ToolConnection] = []
        for id in down.sorted(by: { $0.uuidString < $1.uuidString }) where ready.contains(id) {
            guard let connection = registry.connections.first(where: { $0.id == id }),
                  bots.contains(where: { bot in registry.assigned(to: bot).contains { $0.id == id } }) else { continue }
            let request = MCPBridgeRequest(session: "", connectionID: id, action: .tools, tool: nil, arguments: nil)
            guard (try? await service.perform(request, connection: connection)) != nil, recovered(id) else { continue }
            back.append(connection)
        }
        if !back.isEmpty { await tell(back, Self.workingAgain, wake: wake) }
    }

    private static let workingAgain = "is working again after failing"

    /// Whether a connection that failed works again, clearing its failure if so; its bots are told by the caller.
    private func recovered(_ id: UUID) -> Bool {
        guard down.remove(id) != nil else { return false }
        problems[id] = nil
        recordActivity(id, "Working again")
        return true
    }

    // MARK: Activity

    /// Marks the connection failed, saying why in words safe to show, and adds the failure to its activity: the one way a
    /// connection fails, so a failure the person sees always has its line.
    private func fail(_ id: UUID, _ title: String, because reason: String, detailed: Bool = true) {
        problems[id] = reason
        recordActivity(id, title, detail: detailed ? reason : "")
    }

    /// Adds a line to the connection's activity, with any detail under it.
    public func recordActivity(_ connection: UUID, _ title: String, detail: String = "") {
        onActivity?(connection, title, detail)
    }

    /// A bot's request, named by the bot and what it asked for. Listing tools comes before every call, so only a failed
    /// listing is worth a line.
    private func record(_ call: ToolConnectionCall) {
        let bot = bots()[call.agent] ?? "Someone removed since"
        let asked: (done: String, failed: String)? = switch call.action {
        case .call: ("called \(call.tool ?? "a tool")", "\(call.tool ?? "a tool") failed")
        case .resources: ("listed resources", "listing resources failed")
        case .readResource: ("read a resource", "reading a resource failed")
        case .tools, .inspect: call.failure == nil ? nil : ("", "listing tools failed")
        }
        guard let asked else { return }
        let seconds = Double(call.duration.components.seconds) + Double(call.duration.components.attoseconds) / 1e18
        let took = " (\(seconds.formatted(.number.precision(.fractionLength(1)))) s)"
        if let failure = call.failure { fail(call.connection, "\(bot): \(asked.failed)" + took, because: failure) }
        else { recordActivity(call.connection, "\(bot) \(asked.done)" + took) }
    }

    /// Notes what a bot's request says about whether the connection works: a failure marks it down, and a call that
    /// worked after one tells its other bots; the bot that made it already knows. A listing proves nothing about who
    /// knows, since one is made for every bot's skill and before every call, so `checkFailed` notices those.
    private func note(_ call: ToolConnectionCall) {
        if call.failure != nil { down.insert(call.connection); return }
        guard [.call, .resources, .readResource].contains(call.action), recovered(call.connection), let wake,
              let connection = registry.connections.first(where: { $0.id == call.connection }) else { return }
        Task { await tell([connection], Self.workingAgain, sparing: call.agent, wake: wake) }
    }
}

/// What a watched connection's checks found since the app started: how many, the last one and what it found, when the
/// next is due, and the latest wakes, each with what was found and whom it woke.
public struct WatchStatus: Equatable, Sendable {
    public struct Wake: Equatable, Sendable {
        public let date: Date
        public let found: String
        public let woke: [String]
    }

    /// The most wakes kept.
    static let wakesKept = 20

    public let checks: Int
    public let lastChecked: Date
    public let last: AlertWatcher.Checked
    public let nextCheck: Date
    /// Oldest first.
    public let wakes: [Wake]

    init(previous: WatchStatus?, checked: Date, result: AlertWatcher.Checked, woke: [String], interval: TimeInterval) {
        checks = (previous?.checks ?? 0) + 1
        lastChecked = checked
        last = result
        nextCheck = checked.addingTimeInterval(interval)
        var wakes = previous?.wakes ?? []
        if case .found(let what) = result { wakes.append(Wake(date: checked, found: what, woke: woke)) }
        self.wakes = Array(wakes.suffix(Self.wakesKept))
    }
}

private extension Duration {
    var seconds: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
