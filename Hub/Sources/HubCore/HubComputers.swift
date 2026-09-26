import ComputerBridge
import Foundation
import HubLink
import NoodleComputerTools
import NoodleCore

/// The computers people keep through the Hub, in Noodle Computer on the Hub's Mac. Each belongs
/// to the user it was made for and reaches a bot only when that user assigns it.
@MainActor public final class HubComputers {
    /// Called after grants change, so bots' skills follow.
    public var onAssignmentsChange: (() -> Void)?

    private let root: URL
    private let access: HubAccess
    private let assignments: ToolAssignmentStore
    private let call: ComputerToolProvider.Transport
    private let surface: @Sendable (ComputerRequest) async throws -> SurfaceSocket
    private var registry: ComputerAssignments

    /// `surface` opens a live view of a computer; by default in Noodle Computer on this Mac.
    public init(root: URL, access: HubAccess, tools: ToolProviderRegistry, assignments: ToolAssignmentStore,
                stagingRoot: @escaping @Sendable () throws -> URL = ComputerToolProvider.liveStagingRoot,
                call: @escaping ComputerToolProvider.Transport,
                surface: (@Sendable (ComputerRequest) async throws -> SurfaceSocket)? = nil) {
        self.root = root
        self.access = access
        self.assignments = assignments
        self.call = call
        self.surface = surface ?? { try await ComputerConnection.openSurface($0, socket: ComputerConnection.socketURL(), team: ComputerConnection.signingTeam()) }
        registry = (try? ComputerAssignments.load(root: root)) ?? ComputerAssignments()
        try? tools.register(ComputerToolProvider(stagingRoot: stagingRoot, transport: call))
        publish()
    }

    public func computers(for user: HubUser) -> [RemoteComputer] {
        registry.computers.filter { access.owner(ofComputer: $0.id) == user.id }
    }

    /// The user's computers as their devices see them.
    public func link(for user: HubUser) -> [LinkComputer] {
        computers(for: user).map { link($0, for: user) }
    }

    public func link(_ computer: RemoteComputer, for user: HubUser) -> LinkComputer {
        let bots = registry.agents.compactMap { key, ids -> UUID? in
            guard ids.contains(computer.id), let bot = UUID(uuidString: key), access.owner(ofBot: bot) == user.id else { return nil }
            return bot
        }
        return LinkComputer(id: computer.id, name: computer.name, description: computer.description, kind: computer.kind,
                            state: computer.state, symbol: computer.symbol, colour: computer.colour, icon: computer.icon,
                            botIDs: bots.sorted { $0.uuidString < $1.uuidString })
    }

    /// The kinds of computer Noodle Computer on this Mac can make.
    public func templates() async throws -> [ComputerTemplateSummary] {
        try await manage(ComputerRequest(.templates)).templates ?? []
    }

    /// Makes a computer for the user. It reaches no bot until assigned.
    public func create(_ draft: ComputerDraft, for user: HubUser) async throws -> RemoteComputer {
        var request = ComputerRequest(.create)
        request.computer = draft
        guard let made = try await manage(request).computers?.first else { throw LinkError("Noodle Computer did not return the new computer.") }
        access.setOwner(user, ofComputer: made.id)
        try remember(made)
        return made
    }

    public func update(_ id: UUID, with draft: ComputerDraft, for user: HubUser) async throws -> RemoteComputer {
        try owned(id, by: user)
        var request = ComputerRequest(.update, computerID: id)
        request.computer = draft
        guard let changed = try await manage(request).computers?.first else { throw LinkError("Noodle Computer did not return the computer.") }
        try remember(changed)
        return changed
    }

    /// Moves one of the user's computers to the Trash on the Hub's Mac; its bots lose it.
    public func delete(_ id: UUID, for user: HubUser) async throws {
        try owned(id, by: user)
        _ = try await manage(ComputerRequest(.delete, computerID: id))
        var next = registry
        next.computers.removeAll { $0.id == id }
        for key in next.agents.keys { next.agents[key]?.remove(id) }
        try next.save(root: root)
        registry = next
        access.setOwner(nil, ofComputer: id)
        publish()
    }

    /// A live view of one of the user's computers, its display or the bot's terminal: video down
    /// the socket, what the person does up it. While it is open, the computer's bots wait.
    public func openSurface(computer: UUID, terminal: UUID?, bot: UUID, for user: HubUser) async throws -> SurfaceSocket {
        try owned(computer, by: user)
        return try await surface(ComputerRequest(.surfaceStream, computerID: computer, agentID: bot, terminalID: terminal))
    }

    /// Replaces which of the user's computers one of their bots may use.
    public func assign(_ ids: Set<UUID>, to bot: UUID, for user: HubUser) throws {
        guard access.owner(ofBot: bot) == user.id else { throw LinkError("That bot is not yours.") }
        for id in ids { try owned(id, by: user) }
        let taken = registry.assigned(to: bot).subtracting(ids)
        var next = registry
        next.agents[bot.uuidString] = ids.isEmpty ? nil : ids
        try next.save(root: root)
        registry = next
        publish()
        revoke(taken, from: bot)
    }

    public func assigned(to bot: UUID, for user: HubUser) -> Set<UUID> {
        access.owner(ofBot: bot) == user.id ? registry.assigned(to: bot) : []
    }

    /// Ends a bot's terminals on a computer it just lost, as when the broker catches a revoked call.
    public func revoke(computer: UUID, agent: UUID) { revoke([computer], from: agent) }

    /// Drops a deleted bot's grants and ends its terminals.
    public func forget(bot: UUID) {
        let taken = registry.assigned(to: bot)
        guard !taken.isEmpty else { return }
        var next = registry
        next.agents[bot.uuidString] = nil
        try? next.save(root: root)
        registry = next
        publish()
        revoke(taken, from: bot)
    }

    /// A removed user's computers stay in Noodle Computer; the Hub only stops lending them.
    public func removeComputers(of user: HubUser) {
        let ids = Set(computers(for: user).map(\.id))
        var next = registry
        next.computers.removeAll { ids.contains($0.id) }
        for key in next.agents.keys { next.agents[key]?.subtract(ids) }
        try? next.save(root: root)
        registry = next
        ids.forEach { access.setOwner(nil, ofComputer: $0) }
        publish()
    }

    /// Reads names and states from Noodle Computer; computers deleted there are dropped here.
    public func refresh() async {
        guard let listed = try? await call(ComputerRequest(.list)).checked().computers else { return }
        let gone = Set(registry.computers.map(\.id)).subtracting(listed.map(\.id))
        var next = registry
        next.computers = listed.filter { access.owner(ofComputer: $0.id) != nil }
        for key in next.agents.keys { next.agents[key]?.subtract(gone) }
        guard next.computers != registry.computers || !gone.isEmpty else { return }
        try? next.save(root: root)
        registry = next
        gone.forEach { access.setOwner(nil, ofComputer: $0) }
        publish()
    }

    private func manage(_ request: ComputerRequest) async throws -> ComputerResponse {
        var handshake = ComputerRequest(.list)
        handshake.capabilitiesOnly = true
        try ComputerCapabilities.requireManagement(try await call(handshake).checked().capabilities)
        return try await call(request).checked()
    }

    private func remember(_ computer: RemoteComputer) throws {
        var next = registry
        if let index = next.computers.firstIndex(where: { $0.id == computer.id }) { next.computers[index] = computer }
        else { next.computers.append(computer) }
        try next.save(root: root)
        registry = next
    }

    private func owned(_ id: UUID, by user: HubUser) throws {
        guard access.owner(ofComputer: id) == user.id, registry.computers.contains(where: { $0.id == id }) else {
            throw LinkError("That computer is not yours or no longer exists.")
        }
    }

    private func revoke(_ ids: Set<UUID>, from bot: UUID) {
        for id in ids {
            Task { [call] in _ = try? await call(ComputerRequest(.revoke, computerID: id, agentID: bot)) }
        }
    }

    private func publish() {
        assignments.replace("computer", with: registry.toolAssignments(readable: true))
        onAssignmentsChange?()
    }
}

extension ComputerDraft {
    public init(_ draft: LinkComputerDraft) {
        self.init(template: draft.template, name: draft.name, description: draft.description, symbol: draft.symbol, colour: draft.colour)
    }
}
