import BrowserBridge
import Foundation
import HubCore
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
    /// Browsers being made for each user, which count towards their plan's limit already.
    private var making: [UUID: Int] = [:]

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
        if let limit = access.browserLimit(for: user), browsers(for: user).count + making[user.id, default: 0] >= limit {
            throw HubAccess.limitReached(limit, "browser", "browsers")
        }
        making[user.id, default: 0] += 1
        defer { making[user.id, default: 1] -= 1 }
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
        do { return try await surface(BrowserRequest(.surfaceStream, browserID: browser, tabID: tab)) }
        catch {
            // A Noodle Browser from before live views cannot say why; the Hub names the app to update.
            if let listed = try? await call(BrowserRequest(.list)), !(listed.features ?? []).contains(SurfaceSocket.feature) {
                throw LinkError("Update \(BrowserBuildIdentity.current.appName) to watch it live.")
            }
            throw error
        }
    }

    /// The sign-in fields of the tab the user watches live in one of their browsers, found once as they ask.
    public func signInForm(browser: UUID, for user: HubUser) async throws -> LinkSignInForm {
        try owned(browser, by: user)
        let found = try await signingIn { try await call(BrowserRequest(.signInForm, browserID: browser)).checked().signInForm }
        return LinkSignInForm(token: found.token, host: found.host, pageHost: found.pageHost, secure: found.secure,
                              crossOrigin: found.crossOrigin,
                              fields: found.fields.compactMap { field in
                                  LinkSignInField.Kind(rawValue: field.kind.rawValue).map { LinkSignInField(kind: $0, label: field.label, length: field.length) }
                              })
    }

    /// Fills the form `signInForm` found with what the user typed or picked, handed straight to Noodle Browser
    /// and kept nowhere here.
    public func fillSignIn(_ fill: LinkSignInFill, browser: UUID, for user: HubUser) async throws {
        try owned(browser, by: user)
        var request = BrowserRequest(.signInFill, browserID: browser)
        request.signIn = BrowserSignInValues(token: fill.token, username: fill.username, password: fill.password,
                                             newPassword: fill.newPassword, oneTimeCode: fill.oneTimeCode, submit: fill.submit)
        _ = try await signingIn { try await call(request).checked().submitted }
    }

    /// A Noodle Browser from before sign-in cannot say why it did nothing; the Hub names the app to update.
    private func signingIn<T>(_ body: () async throws -> T?) async throws -> T {
        let answer: T?
        do { answer = try await body() }
        catch {
            if let listed = try? await call(BrowserRequest(.list)), !(listed.features ?? []).contains(BrowserSignInForm.feature) {
                throw LinkError(Self.updateToSignIn)
            }
            throw error
        }
        guard let answer else { throw LinkError(Self.updateToSignIn) }
        return answer
    }
    public static let updateToSignIn = "Update \(BrowserBuildIdentity.current.appName) to sign in from here."

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

    /// Tabs the Hub's bots opened and then left unused, each told once.
    public func idle() async -> [BrowserIdleNotice] {
        (try? await call(BrowserRequest(.idle)).checked().idle) ?? []
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
        for id in ids {
            Task { [call] in
                var request = BrowserRequest(.setOwner, browserID: id)
                request.owner = nil
                _ = try? await call(request)
            }
        }
    }

    /// Reads the browsers and grants again, after Noodle changed them in the same files on its owner's Mac.
    /// Throws rather than keep an older copy, which a later save would write over Noodle's.
    public func reloadAssignments() throws {
        registry = try BrowserAssignments.load(root: root)
    }

    /// Reads names and states from Noodle Browser; browsers deleted there are dropped here.
    public func refresh() async {
        await reload()
        await synchronizeOwners()
    }

    /// Tells Noodle Browser whom each of the Hub's browsers is kept for, where it says otherwise,
    /// so it lists them under those people. A personal Mac's are its owner's own.
    public func synchronizeOwners() async {
        guard !access.isPersonal else { return }
        for browser in registry.browsers {
            let owner = access.owner(ofBrowser: browser.id).flatMap { id in access.users.first { $0.id == id } }
                .map { BrowserOwner(id: $0.id, name: $0.name) }
            guard browser.owner != owner else { continue }
            var request = BrowserRequest(.setOwner, browserID: browser.id)
            request.owner = owner
            // One from before owners says it cannot; it lists the browser under Hub alone.
            guard (try? await call(request).checked()) != nil,
                  let index = registry.browsers.firstIndex(where: { $0.id == browser.id }) else { continue }
            var next = registry
            next.browsers[index].owner = owner
            try? next.save(root: root)
            registry = next
        }
    }

    private func reload() async {
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

extension HubBrowsers: HubBrowsing {
    public func create(_ draft: LinkBrowserDraft, for user: HubUser) async throws -> LinkBrowser {
        link(try await create(BrowserDraft(draft), for: user), for: user)
    }

    public func update(_ id: UUID, with draft: LinkBrowserDraft, for user: HubUser) async throws -> LinkBrowser {
        link(try await update(id, with: BrowserDraft(draft), for: user), for: user)
    }

    public func keeps(_ browser: UUID, for user: HubUser) -> Bool {
        browsers(for: user).contains { $0.id == browser }
    }

    public func idleNotices() async -> [HubIdleNotice] {
        await idle().map { HubIdleNotice(agentID: $0.agentID, note: $0.note) }
    }

    public func liveView(browser: UUID, tab: UUID, for user: HubUser) async throws -> any HubLiveView {
        SurfaceLiveView(socket: try await openSurface(browser: browser, tab: tab, for: user))
    }
}
