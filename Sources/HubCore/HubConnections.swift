import Foundation
import HubWire
#if canImport(ImageIO)
import ImageIO
#endif
import NoodleCore
import NoodleMCP
import NoodleRuntime

/// The tool connections people keep on the Hub, kept in the shared `ToolConnections` that Noodle keeps its own in too.
/// What is only the Hub's is here: each connection belongs to one user, reaches a bot only when that user assigns it,
/// and signs in through the browser of the device that asked. Its sign-in stays in the Hub's Keychain, where bots
/// never see it.
@MainActor public final class HubConnections {
    /// The providers the Hub's tool broker serves bots from.
    public let tools: ToolProviderRegistry
    /// What each bot is granted, read by the broker for every call.
    public let assignments: ToolAssignmentStore
    /// The connections, their grants and sign-ins, watching and activity, as every app and Hub keeps them.
    public let store: ToolConnections
    /// What each connection has done since the Hub started: bots' calls, sign-ins and checks, by connection.
    public let activity = ActivityStore()
    /// Called after grants change, so bots' skills follow.
    public var onAssignmentsChange: (() -> Void)?
    /// Called with the owner when a sign-in ends, whether it worked or not.
    public var onSignInEnded: ((UUID) -> Void)?
    /// Signs a connection in through `browser`, or finds it needs no sign-in, and checks it answers. Returns its icon, and
    /// whether it is open.
    public var signInFlow: (ToolConnection, URL, @escaping @Sendable (URL) async throws -> URL) async throws -> (icon: Data?, open: Bool)

    private let access: HubAccess
    private var registry: ToolConnectionRegistry { store.registry }
    private var signingIn: Set<UUID> = []
    /// Sign-ins waiting for the device's browser to come back.
    private var pages: [UUID: (token: UUID, reply: CheckedContinuation<URL, Error>)] = [:]

    public init(root: URL, access: HubAccess, service: ToolConnectionService,
                tools: ToolProviderRegistry = ToolProviderRegistry(), assignments: ToolAssignmentStore = ToolAssignmentStore()) {
        self.tools = tools
        self.assignments = assignments
        self.access = access
        store = ToolConnections(root: root, service: service)
        signInFlow = { record, redirect, browser in
            var record = record
            if record.open != true, try await service.signIn(record, redirectURI: redirect, browser: browser) == .open { record.open = true }
            _ = try await service.perform(MCPBridgeRequest(session: "", connectionID: record.id, action: .tools, tool: nil, arguments: nil),
                                          connection: record)
            return (await service.icon(for: record), record.open == true)
        }
        store.onActivity = { [activity] id, title, detail in activity.log(for: id).record(ActivityEvent(title: title, detail: detail)) }
        store.onGrantsChange = { [weak self, assignments] granted in
            assignments.replace(ConnectionToolProvider.grantKind, with: granted)
            self?.onAssignmentsChange?()
        }
        store.toolRegistry = tools
        store.start()
    }

    /// The user's connections as their devices see them.
    public func link(for user: HubUser) -> [LinkConnection] {
        connections(for: user).map { record in
            let bots = registry.assignments.compactMap { key, ids -> UUID? in
                guard ids.contains(record.id), let bot = UUID(uuidString: key), access.owner(ofBot: bot) == user.id else { return nil }
                return bot
            }
            return LinkConnection(draft: LinkConnectionDraft(id: record.id, name: record.name, endpoint: record.endpoint,
                                                             description: record.description, instructions: record.instructions),
                                  iconData: record.iconData, botIDs: bots.sorted { $0.uuidString < $1.uuidString },
                                  signedIn: store.ready.contains(record.id), problem: store.problems[record.id])
        }
    }

    /// Signs one of the user's connections in, in the background. `show` hands the sign-in page
    /// to the device's browser; false when it cannot be reached.
    public func signIn(_ id: UUID, redirect: URL, for user: HubUser, show: @escaping (URL) -> Bool) throws {
        let record = try owned(id, by: user)
        guard !signingIn.contains(id) else { throw LinkError("This connection is already signing in.") }
        signingIn.insert(id)
        store.beginSignIn(id)
        Task {
            defer { signingIn.remove(id) }
            do {
                var signed = record
                let (icon, open) = try await signInFlow(record, redirect) { [weak self] url in
                    guard let self else { throw LinkError("Noodle Hub is stopping.") }
                    return try await self.page(url, for: id, show: show)
                }
                if open { signed.open = true }
                try? store.signedIn(signed, icon: icon)
            } catch {
                store.signInFailed(record, error)
            }
            onSignInEnded?(user.id)
        }
    }

    /// The address the device's browser returned to, for a sign-in waiting on it.
    public func finishSignIn(_ id: UUID, callback: URL, for user: HubUser) throws {
        _ = try owned(id, by: user)
        guard let page = pages.removeValue(forKey: id) else { throw LinkError("No sign-in is waiting for this connection.") }
        page.reply.resume(returning: callback)
    }

    private func page(_ url: URL, for id: UUID, show: @escaping (URL) -> Bool) async throws -> URL {
        let token = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            pages[id] = (token, continuation)
            guard show(url) else {
                pages[id] = nil
                return continuation.resume(throwing: LinkError("The device that started signing in is not connected."))
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard let self, self.pages[id]?.token == token else { return }
                self.pages.removeValue(forKey: id)?.reply.resume(throwing: ToolConnectionServiceError.timedOut)
            }
        }
    }

    public func connections(for user: HubUser) -> [ToolConnection] {
        registry.connections.filter { access.owner(ofConnection: $0.id) == user.id }
    }

    /// Saves a new connection, or changes one of the user's own. It is not assigned to any bot.
    @discardableResult public func add(_ record: ToolConnection, for user: HubUser) throws -> ToolConnection {
        if registry.connections.contains(where: { $0.id == record.id }) { _ = try owned(record.id, by: user) }
        try store.save(record)
        access.setOwner(user, ofConnection: record.id)
        return registry.connections.first { $0.id == record.id }!
    }

    /// Reads the connections and grants again, after Noodle changed them in the same files on its owner's Mac.
    /// Throws rather than keep an older copy, which a later save would write over Noodle's. Noodle's own broker serves
    /// its bots, so the grants are not handed on: doing so would have Noodle read its files again on every request.
    public func reloadAssignments() throws {
        try store.reload(synchronizing: false)
    }

    /// Replaces which of the user's connections one of their bots may use.
    public func assign(_ ids: Set<UUID>, to bot: UUID, for user: HubUser) throws {
        guard access.owner(ofBot: bot) == user.id else { throw LinkError("That bot is not yours.") }
        for id in ids { _ = try owned(id, by: user) }
        try store.assign(ids, to: bot)
    }

    public func assigned(to bot: UUID, for user: HubUser) -> Set<UUID> {
        guard access.owner(ofBot: bot) == user.id else { return [] }
        return Set(registry.assigned(to: bot).map(\.id))
    }

    /// Deletes a connection and its saved sign-in.
    public func remove(_ id: UUID, for user: HubUser) throws {
        _ = try owned(id, by: user)
        try remove([id])
    }

    /// Deletes every connection of a user who is being removed.
    public func removeConnections(of user: HubUser) {
        try? remove(Set(connections(for: user).map(\.id)))
    }

    /// Drops a deleted bot's grants.
    public func forget(bot: UUID) { store.forget(bot: bot) }

    private func remove(_ ids: Set<UUID>) throws {
        try store.remove(ids)
        activity.retain(Set(registry.connections.map(\.id)))
        ids.forEach { access.setOwner(nil, ofConnection: $0) }
    }

    private func owned(_ id: UUID, by user: HubUser) throws -> ToolConnection {
        guard access.owner(ofConnection: id) == user.id, let record = registry.connections.first(where: { $0.id == id }) else {
            throw LinkError("That connection is not yours or no longer exists.")
        }
        return record
    }
}

extension HubConnections {
    /// The catalogue's services as devices show them, icons as PNG from the app's `ToolIcons`.
    /// Only services that sign in through the browser to an MCP server: a Hub cannot yet keep an API key or a
    /// form's details, and has no app adapters.
    public static let catalogue: [LinkToolPreset] = ToolCatalog.matching("").compactMap { tool in
        guard case .connection(let configuration) = tool.configuration, !tool.staysOnThisMac else { return nil }
        return LinkToolPreset(id: tool.id, name: tool.name, summary: tool.summary, instructions: tool.defaultInstructions,
                              endpoint: configuration.endpoint, badge: tool.maturity.badge, icon: icon(named: tool.iconName))
    }

    private static func icon(named name: String) -> Data? {
        Bundle.main.url(forResource: name, withExtension: "icon", subdirectory: "ToolIcons").flatMap(largestPicture)
    }

    /// The largest picture in an icon file, as PNG, which every device reads.
    static func largestPicture(in url: URL) -> Data? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let largest = (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
            .max { $0.width < $1.width }
        guard let largest else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, largest, nil)
        return CGImageDestinationFinalize(destination) ? png as Data : nil
        #else
        return nil
        #endif
    }
}
