import BrowserBridge
import Foundation
import HubLink
import NoodleBrowserTools
import NoodleCore

/// The browsers people keep through the Hub, in Noodle Browser on the Hub's Mac. Each belongs
/// to the user it was made for and reaches a bot only when that user assigns it.
@MainActor public final class HubBrowsers {
    /// Called after grants change, so bots' skills follow.
    public var onAssignmentsChange: (() -> Void)?

    private let root: URL
    private let access: HubAccess
    private let assignments: ToolAssignmentStore
    private let call: BrowserToolProvider.Transport
    private let surface: @Sendable (BrowserRequest) async throws -> SurfaceSocket
    private var registry: BrowserAssignments

    /// `surface` opens a live view of a tab; by default in Noodle Browser on this Mac.
    public init(root: URL, access: HubAccess, tools: ToolProviderRegistry, assignments: ToolAssignmentStore,
                stagingRoot: @escaping @Sendable () throws -> URL = BrowserToolProvider.liveStagingRoot,
                call: @escaping BrowserToolProvider.Transport,
                surface: (@Sendable (BrowserRequest) async throws -> SurfaceSocket)? = nil) {
        self.root = root
        self.access = access
        self.assignments = assignments
        self.call = call
        self.surface = surface ?? { try await BrowserConnection.openSurface($0, socket: BrowserConnection.socketURL(), team: BrowserConnection.signingTeam()) }
        registry = (try? BrowserAssignments.load(root: root)) ?? BrowserAssignments()
        try? tools.register(BrowserToolProvider(stagingRoot: stagingRoot, transport: call))
        publish()
    }

    public func browsers(for user: HubUser) -> [RemoteBrowser] {
        registry.browsers.filter { access.owner(ofBrowser: $0.id) == user.id }
    }

    /// The user's browsers as their devices see them.
    public func link(for user: HubUser) -> [LinkBrowser] {
        browsers(for: user).map { link($0, for: user) }
    }

    public func link(_ browser: RemoteBrowser, for user: HubUser) -> LinkBrowser {
        let bots = registry.agents.compactMap { key, ids -> UUID? in
            guard ids.contains(browser.id), let bot = UUID(uuidString: key), access.owner(ofBot: bot) == user.id else { return nil }
            return bot
        }
        return LinkBrowser(id: browser.id, name: browser.name, description: browser.description, symbol: browser.symbol,
                           colour: browser.colour, icon: browser.icon, paused: browser.paused,
                           botIDs: bots.sorted { $0.uuidString < $1.uuidString })
    }

    /// Makes a browser for the user. It reaches no bot until assigned.
    public func create(_ draft: BrowserDraft, for user: HubUser) async throws -> RemoteBrowser {
        var request = BrowserRequest(.create)
        request.profile = draft
        guard let made = try await call(request).checked().browser else {
            throw LinkError("Noodle Browser on the Hub did not return the new browser. Update it and try again.")
        }
        access.setOwner(user, ofBrowser: made.id)
        try remember(made)
        return made
    }

    public func update(_ id: UUID, with draft: BrowserDraft, for user: HubUser) async throws -> RemoteBrowser {
        try owned(id, by: user)
        var request = BrowserRequest(.update, browserID: id)
        request.profile = draft
        guard let changed = try await call(request).checked().browser else { throw LinkError("Noodle Browser did not return the browser.") }
        try remember(changed)
        return changed
    }

    /// Deletes one of the user's browsers, with its sign-ins and history; its bots lose it.
    public func delete(_ id: UUID, for user: HubUser) async throws {
        try owned(id, by: user)
        _ = try await call(BrowserRequest(.delete, browserID: id)).checked()
        var next = registry
        next.browsers.removeAll { $0.id == id }
        for key in next.agents.keys { next.agents[key]?.remove(id) }
        try next.save(root: root)
        registry = next
        access.setOwner(nil, ofBrowser: id)
        publish()
    }

    /// A live view of a tab of one of the user's browsers: video down the socket, what the person
    /// does up it. While it is open, the browser's bots wait.
    public func openSurface(browser: UUID, tab: UUID, for user: HubUser) async throws -> SurfaceSocket {
        try owned(browser, by: user)
        return try await surface(BrowserRequest(.surfaceStream, browserID: browser, tabID: tab))
    }

    /// Replaces which of the user's browsers one of their bots may use.
    public func assign(_ ids: Set<UUID>, to bot: UUID, for user: HubUser) throws {
        guard access.owner(ofBot: bot) == user.id else { throw LinkError("That bot is not yours.") }
        for id in ids { try owned(id, by: user) }
        var next = registry
        next.agents[bot.uuidString] = ids.isEmpty ? nil : ids
        try next.save(root: root)
        registry = next
        publish()
    }

    public func assigned(to bot: UUID, for user: HubUser) -> Set<UUID> {
        access.owner(ofBot: bot) == user.id ? registry.assigned(to: bot) : []
    }

    /// Drops a deleted bot's grants.
    public func forget(bot: UUID) {
        guard registry.agents[bot.uuidString] != nil else { return }
        var next = registry
        next.agents[bot.uuidString] = nil
        try? next.save(root: root)
        registry = next
        publish()
    }

    /// A removed user's browsers stay in Noodle Browser; the Hub only stops lending them.
    public func removeBrowsers(of user: HubUser) {
        let ids = Set(browsers(for: user).map(\.id))
        var next = registry
        next.browsers.removeAll { ids.contains($0.id) }
        for key in next.agents.keys { next.agents[key]?.subtract(ids) }
        try? next.save(root: root)
        registry = next
        ids.forEach { access.setOwner(nil, ofBrowser: $0) }
        publish()
    }

    /// Reads names and states from Noodle Browser; browsers deleted there are dropped here.
    public func refresh() async {
        guard let listed = try? await call(BrowserRequest(.list)).checked().browsers else { return }
        let gone = Set(registry.browsers.map(\.id)).subtracting(listed.map(\.id))
        var next = registry
        next.browsers = listed.filter { access.owner(ofBrowser: $0.id) != nil }
        for key in next.agents.keys { next.agents[key]?.subtract(gone) }
        guard next.browsers != registry.browsers || !gone.isEmpty else { return }
        try? next.save(root: root)
        registry = next
        gone.forEach { access.setOwner(nil, ofBrowser: $0) }
        publish()
    }

    private func remember(_ browser: RemoteBrowser) throws {
        var next = registry
        if let index = next.browsers.firstIndex(where: { $0.id == browser.id }) { next.browsers[index] = browser }
        else { next.browsers.append(browser) }
        try next.save(root: root)
        registry = next
    }

    private func owned(_ id: UUID, by user: HubUser) throws {
        guard access.owner(ofBrowser: id) == user.id, registry.browsers.contains(where: { $0.id == id }) else {
            throw LinkError("That browser is not yours or no longer exists.")
        }
    }

    private func publish() {
        assignments.replace("browser", with: registry.toolAssignments(readable: true))
        onAssignmentsChange?()
    }
}

extension BrowserDraft {
    public init(_ draft: LinkBrowserDraft) {
        self.init(name: draft.name, description: draft.description, symbol: draft.symbol, colour: draft.colour)
    }
}
