import Foundation
import HubLink
import NoodleCore
import NoodleMCP

/// The tool connections people keep on the Hub. Each belongs to one user, reaches a bot only
/// when that user assigns it, and keeps its sign-in in the Hub's Keychain, where bots never see it.
@MainActor public final class HubConnections {
    /// The providers the Hub's tool broker serves bots from.
    public let tools = ToolProviderRegistry()
    /// What each bot is granted, read by the broker for every call.
    public let assignments = ToolAssignmentStore()
    /// Called after grants change, so bots' skills follow.
    public var onAssignmentsChange: (() -> Void)?
    /// Called with the owner when a sign-in ends, whether it worked or not.
    public var onSignInEnded: ((UUID) -> Void)?
    /// Signs a connection in through `browser` and checks it answers. Returns its icon.
    public var signInFlow: (MCPConnectionRecord, URL, @escaping @Sendable (URL) async throws -> URL) async throws -> Data?

    private let root: URL
    private let access: HubAccess
    private let service: MCPService
    private let providers: MCPConnectionProviders
    private var registry: MCPRegistry
    private let deletions: DeletionJournal<UUID>
    private var signedIn: Set<UUID> = []
    private var problems: [UUID: String] = [:]
    private var signingIn: Set<UUID> = []
    /// Sign-ins waiting for the device's browser to come back.
    private var pages: [UUID: (token: UUID, reply: CheckedContinuation<URL, Error>)] = [:]

    public init(root: URL, access: HubAccess, service: MCPService) {
        self.root = root
        self.access = access
        self.service = service
        providers = MCPConnectionProviders(registry: tools, service: service)
        registry = (try? MCPRegistry.load(root: root)) ?? MCPRegistry()
        deletions = DeletionJournal(url: root.appendingPathComponent("MCP/removed-sign-ins.json"))
        signInFlow = { record, redirect, browser in
            try await service.signIn(record, redirectURI: redirect, browser: browser)
            _ = try await service.perform(MCPBridgeRequest(session: "", connectionID: record.id, action: .tools, tool: nil, arguments: nil),
                                          connection: record)
            return await service.icon(for: record)
        }
        providers.onError = { [weak self] id, message in self?.problems[id] = message }
        synchronize()
        Task { await deleteRemovedSignIns() }
        let ids = registry.connections.map(\.id)
        Task { [weak self] in
            for id in ids where await service.hasCredentials(id) { self?.signedIn.insert(id) }
        }
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
                                  signedIn: signedIn.contains(record.id), problem: problems[record.id])
        }
    }

    /// Signs one of the user's connections in, in the background. `show` hands the sign-in page
    /// to the device's browser; false when it cannot be reached.
    public func signIn(_ id: UUID, redirect: URL, for user: HubUser, show: @escaping (URL) -> Bool) throws {
        let record = try owned(id, by: user)
        guard !signingIn.contains(id) else { throw LinkError("This connection is already signing in.") }
        signingIn.insert(id)
        problems[id] = nil
        Task {
            defer { signingIn.remove(id) }
            do {
                let icon = try await signInFlow(record, redirect) { [weak self] url in
                    guard let self else { throw LinkError("Noodle Hub is stopping.") }
                    return try await self.page(url, for: id, show: show)
                }
                signedIn.insert(id)
                if let icon, var current = registry.connections.first(where: { $0.id == id }), current.iconData != icon {
                    current.iconData = icon
                    try? add(current, for: user)
                }
            } catch {
                signedIn.remove(id)
                problems[id] = MCPConnectionProviders.safeError(error)
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
                self.pages.removeValue(forKey: id)?.reply.resume(throwing: MCPServiceError.timedOut)
            }
        }
    }

    public func connections(for user: HubUser) -> [MCPConnectionRecord] {
        registry.connections.filter { access.owner(ofConnection: $0.id) == user.id }
    }

    /// Saves a new connection, or changes one of the user's own. It is not assigned to any bot.
    @discardableResult public func add(_ record: MCPConnectionRecord, for user: HubUser) throws -> MCPConnectionRecord {
        var next = registry
        if let index = next.connections.firstIndex(where: { $0.id == record.id }) {
            _ = try owned(record.id, by: user)
            next.connections[index] = record
        } else {
            next.connections.append(record)
        }
        try next.save(root: root)
        registry = next
        access.setOwner(user, ofConnection: record.id)
        synchronize()
        return registry.connections.first { $0.id == record.id }!
    }

    /// Replaces which of the user's connections one of their bots may use.
    public func assign(_ ids: Set<UUID>, to bot: UUID, for user: HubUser) throws {
        guard access.owner(ofBot: bot) == user.id else { throw LinkError("That bot is not yours.") }
        for id in ids { _ = try owned(id, by: user) }
        var next = registry
        try next.assign(ids, to: bot)
        try next.save(root: root)
        registry = next
        synchronize()
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
    public func forget(bot: UUID) {
        guard registry.assignments[bot.uuidString.lowercased()] != nil else { return }
        var next = registry
        next.assignments[bot.uuidString.lowercased()] = nil
        try? next.save(root: root)
        registry = next
        synchronize()
    }

    private func remove(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        var next = registry
        ids.forEach { next.remove($0) }
        try deletions.schedule(ids)
        try next.save(root: root)
        // Revoke access before the sign-in is deleted.
        registry = next
        synchronize()
        ids.forEach { access.setOwner(nil, ofConnection: $0) }
        Task { await deleteRemovedSignIns() }
    }

    /// Deletes removed connections' sign-ins; one that fails is tried again on the next removal or start.
    private func deleteRemovedSignIns() async {
        await deletions.run { id in
            // A removal whose registry write failed keeps its connection, so it keeps its sign-in too.
            guard !registry.connections.contains(where: { $0.id == id }) else { return }
            try await service.disconnect(id)
        }
    }

    private func owned(_ id: UUID, by user: HubUser) throws -> MCPConnectionRecord {
        guard access.owner(ofConnection: id) == user.id, let record = registry.connections.first(where: { $0.id == id }) else {
            throw LinkError("That connection is not yours or no longer exists.")
        }
        return record
    }

    private func synchronize() {
        providers.synchronize(registry.connections) { [weak self] id in self?.registry.connections.first { $0.id == id } }
        assignments.replace(ConnectionToolProvider.grantKind, with: Dictionary(uniqueKeysWithValues: registry.assignments.compactMap { key, ids in
            UUID(uuidString: key).map { ($0, Set(ids.map(\.uuidString))) }
        }))
        onAssignmentsChange?()
    }
}
