import AppKit
import BrowserBridge
import BrowserCore
import BrowserExternal
import Darwin
import ImageIO
import WebKit

enum ViewerFileChoice: Sendable {
    case chosen([(name: String, body: Data)])
    case cancelled
    case tooLarge
    case failed
    case unavailable
}

@MainActor final class BrowserRuntime: NSObject, ObservableObject, WKDownloadDelegate {
    let library: BrowserLibrary
    @Published var failure: String?
    @Published private(set) var tabs: [UUID: BrowserTab] = [:]
    /// The icons of the open tabs' pages, kept for pages that stopped; a tab sends
    /// `objectWillChange` when its icon changes.
    var favicons: [UUID: NSImage] { stopped.compactMapValues(\.favicon).merging(tabs.compactMapValues(\.favicon)) { $1 } }
    /// What a stopped page leaves behind: its icon, and its history until the page loads again.
    private var stopped: [UUID: (favicon: NSImage?, history: Any?)] = [:]
    /// Only the memory-cache type is passed here: cookies, site storage and the current document stay intact.
    var removeWebsiteData: (WKWebsiteDataStore, Set<String>, @escaping @MainActor @Sendable () -> Void) -> Void = { store, types, completion in
        store.removeData(ofTypes: types, modifiedSince: .distantPast, completionHandler: completion)
    }
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var trimmedCaches: Set<UUID> = []
    private var trimmingCaches: Set<UUID> = []
    func startMemoryPressureMonitoring() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        memoryPressure = source
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let events = self.memoryPressure?.data else { return }
                self.handleMemoryPressure(events)
            }
        }
        source.activate()
    }
    /// Trim once per pressure episode so a busy Mac does not repeatedly throw away freshly fetched resources.
    /// WebKit may reload a previous document when going Back after this; the document currently in use stays alive.
    func handleMemoryPressure(_ events: DispatchSource.MemoryPressureEvent) {
        if events.contains(.normal) { trimmedCaches.removeAll() }
        guard !events.intersection([.warning, .critical]).isEmpty else { return }
        // Reuse the stores of live pages. Opening a store for an unloaded profile could start another network process.
        for tab in Array(tabs.values) where !trimmingCaches.contains(tab.browserID) && !trimmedCaches.contains(tab.browserID) {
            let id = tab.browserID
            trimmingCaches.insert(id); trimmedCaches.insert(id)
            removeWebsiteData(tab.web.configuration.websiteDataStore, [WKWebsiteDataTypeMemoryCache]) { [weak self] in
                self?.trimmingCaches.remove(id)
            }
        }
    }
    /// How long a tab a bot used keeps drawing out of sight after the bot's last call, long enough
    /// for a bot to think between steps.
    var agentAttention = Duration.seconds(300)
    /// From this many tabs, opening another asks the bot to close the ones it no longer needs,
    /// well before `BrowserLimits.tabs`.
    static let manyTabs = 30
    static let tabLimitReached = "This browser has reached its \(BrowserLimits.tabs)-tab limit."
    /// What a bot is told at the tab limit, so it can make room itself.
    static let botTabLimit = "\(tabLimitReached) Close tabs you no longer need (tabs, close) and try again."
    var willRemoveBrowser: ((UUID) -> Void)?
    private var server: BrowserConnectionServer?
    private var activeDownloads: [ObjectIdentifier: (download: WKDownload?, browserID: UUID, record: BrowserDownloadInfo)] = [:]
    private var busy: Set<UUID> = []
    private var deleting: Set<UUID> = []
    /// Live views, by browser. While one is watched, bots are kept off that browser.
    private var surfaces: [UUID: SurfaceStreamer] = [:]
    /// Tests supply what a person watching would choose, instead of asking a live view.
    var supplyViewerFiles: ((_ multiple: Bool, _ directories: Bool) async -> ViewerFileChoice)?
    private let transferRoot: URL?
    /// What apps outside Noodle may use, when the person allows them.
    let external: ExternalGate?
    private var externalServer: ExternalConnectionServer?
    /// How many browsers an outside app makes before the person is asked about each one.
    static let externalCreationLimit = 10
    init(library: BrowserLibrary, transferRoot: URL? = nil, external: ExternalGate? = nil) {
        self.library = library; self.transferRoot = transferRoot; self.external = external; super.init()
    }
    func startServer(socket: URL? = nil) {
        do {
            server = try BrowserConnectionServer(socket: socket ?? BrowserConnection.socketURL(), team: BrowserConnection.signingTeam(),
                                                 handler: { [weak self] request, caller in
                guard let self else { return .init(error: "Browser stopped.") }
                do { return try await self.perform(request, caller: caller) }
                catch { return .init(error: error.localizedDescription) }
            }, surface: { [weak self] request, caller, socket in
                guard let self else { return .init(error: "Browser stopped.") }
                do { return try await self.perform(request, caller: caller, surface: socket) }
                catch { return .init(error: error.localizedDescription) }
            })
        } catch { failure = error.localizedDescription }
    }
    /// Listens for apps outside Noodle while Settings allows them.
    func startExternalServer() {
        guard let external else { return }
        external.enabledChanged = { [weak self] _ in self?.updateExternalServer() }
        if library.failure == nil { external.prune(keeping: Set(library.profiles.map(\.id))) }
        updateExternalServer()
    }
    private func updateExternalServer() {
        guard external?.enabled == true else { externalServer = nil; return }
        guard externalServer == nil else { return }
        do {
            let build = BrowserBuildIdentity.current, team = try BrowserConnection.signingTeam()
            externalServer = try ExternalConnectionServer(socket: BrowserExternal.socketURL(), verify: { fd in
                // Only this app's own command-line tool, which names the app that runs it.
                try ExternalConnection.requireSigned(fd, identifier: build.cliID, team: team)
            }, handler: { [weak self] data in
                await self?.answerExternal(data) ?? ExternalConnection.failure("Browser stopped.")
            })
        } catch { failure = error.localizedDescription }
    }
    private func answerExternal(_ data: Data) async -> Data {
        var response: BrowserResponse
        do {
            let envelope: ExternalEnvelope<BrowserRequest>
            do { envelope = try JSONDecoder().decode(ExternalEnvelope<BrowserRequest>.self, from: data) }
            catch { throw BrowserError("This needs a newer \(BrowserBuildIdentity.current.appName). Update it.") }
            response = try await performExternal(envelope.request, launcher: envelope.launcher)
        } catch { response = BrowserResponse(error: error.localizedDescription) }
        return (try? JSONEncoder().encode(response)) ?? ExternalConnection.failure("Could not answer.")
    }
    /// A call from an app outside Noodle. It sees only browsers it made or the person lent it,
    /// never the Hub's, and changes or deletes only those it made.
    func performExternal(_ input: BrowserRequest, launcher: ExternalLauncher) async throws -> BrowserResponse {
        guard let external else { throw BrowserError("External tools are unavailable.") }
        guard BrowserOperation.externalCases.contains(input.operation) else { throw BrowserError("Apps outside Noodle cannot do that.") }
        let caller = try await external.admit(launcher).id
        var request = input
        // Only Noodle's broker says which bot asks.
        request.agentID = nil
        let lendable = { [library] in library.profiles.filter { $0.hub != true } }
        switch request.operation {
        case .list:
            guard library.failure == nil else { throw BrowserError(library.failure!) }
            var response = BrowserResponse()
            response.browsers = lendable().filter { external.allows(caller, $0.id) }.map(\.remote)
            return response
        case .create:
            let made = external.createdCount(caller)
            if made >= Self.externalCreationLimit {
                try await external.confirm(for: caller, message: "“\(launcher.name)” wants to create another browser. It has already created \(made).", action: "Create")
            }
            let response = try await perform(request)
            if let browser = response.browser { external.recordCreated(browser.id, by: caller) }
            return response
        case .borrow:
            let picked = try await external.borrow(for: caller, from: lendable().map { ExternalItem(id: $0.id, name: $0.name, symbol: $0.symbol) })
            var response = BrowserResponse()
            response.browser = try library.profile(picked).remote
            return response
        default:
            guard let id = request.browserID else { throw BrowserError("Specify --browser.") }
            try external.require(caller, id)
            let profile = try library.profile(id)
            guard profile.hub != true else { throw BrowserError("This browser belongs to Noodle Hub.") }
            if [.update, .delete].contains(request.operation), !external.created(caller, id) {
                throw BrowserError("Only browsers \(launcher.name) created can be changed or deleted.")
            }
            if request.operation.needsTab, request.tabID == nil {
                guard let tab = profile.selectedTabID ?? profile.tabs.first?.id else { throw BrowserError("This browser has no tabs. Use open first.") }
                request.tabID = tab
            }
            let staging = request.operation.isFileTransfer ? try transferRoot ?? BrowserExternal.root() : nil
            let response = try await perform(request, stagingRoot: staging)
            if request.operation == .delete { external.forget(id) }
            return response
        }
    }
    func saveTab(_ tab: BrowserTab) { library.updateTab(tab.info, browserID: tab.browserID) }
    @discardableResult func makeTab(browserID: UUID, configuration: WKWebViewConfiguration? = nil, restoring: BrowserTabInfo? = nil, openedBy: UUID? = nil) throws -> BrowserTab {
        guard !deleting.contains(browserID) else { throw BrowserError("This browser is being deleted.") }
        var profile = try library.profile(browserID)
        guard profile.tabs.count < BrowserLimits.tabs || restoring != nil else { throw BrowserError(Self.tabLimitReached) }
        let info = restoring ?? BrowserTabInfo(lastUsed: Date(), openedBy: openedBy)
        if let tab = tabs[info.id] { return tab }
        let tab = BrowserTab(browserID: browserID, info: info, runtime: self, configuration: configuration)
        if restoring == nil {
            profile.tabs.append(info); profile.selectedTabID = info.id
            do { try library.update(profile) } catch { tab.stop(); throw error }
        }
        tabs[info.id] = tab
        showWatchedTab(browserID)
        stopIdlePages(browserID, keeping: info.id)
        return tab
    }
    private func stopIdlePages(_ browserID: UUID, keeping kept: UUID) {
        let selected = try? library.profile(browserID).selectedTabID
        let running = tabs.values.filter { $0.browserID == browserID }
        let idle = running.filter { $0.id != kept && $0.id != selected && !$0.mustKeepRunning }.sorted { $0.lastActive < $1.lastActive }
        for tab in idle.prefix(max(0, running.count - BrowserLimits.runningPages)) {
            tab.info.loading = false; saveTab(tab)
            stopped[tab.id] = (tab.favicon ?? stopped[tab.id]?.favicon, tab.web.interactionState)
            tabs.removeValue(forKey: tab.id)?.stop()
        }
    }
    func tab(browserID: UUID, tabID: UUID) throws -> BrowserTab {
        let profile = try library.profile(browserID)
        guard let info = profile.tabs.first(where: { $0.id == tabID }) else { throw BrowserError("This tab does not belong to the selected browser.") }
        if let existing = tabs[tabID] { return existing }
        let tab = try makeTab(browserID: browserID, restoring: info)
        if let history = stopped[tabID]?.history { stopped[tabID]?.history = nil; tab.web.interactionState = history }
        else if let url = try? BrowserRequest.navigationURL(info.url) { tab.navigate(url) }
        return tab
    }
    func openBrowser(_ id: UUID) throws {
        guard !deleting.contains(id) else { throw BrowserError("This browser is being deleted.") }
        let profile = try library.profile(id)
        if profile.tabs.isEmpty { _ = try makeTab(browserID: id) }
        else if let tabID = profile.selectedTabID ?? profile.tabs.first?.id { _ = try tab(browserID: id, tabID: tabID) }
    }
    /// Someone is watching the browser live.
    func isWatched(_ browser: UUID) -> Bool { surfaces[browser]?.isWatched == true }
    /// Browsers whose filled passwords are being emptied after the last viewer left, with how many emptyings
    /// are under way; bots wait until none is.
    private var clearingSignIn: [UUID: Int] = [:]
    /// How many times emptying a page's passwords is tried before the page itself is stopped.
    static let signInClearAttempts = 3
    /// Empties the password fields people filled in the browser's pages while watching, so that a bot
    /// using the browser next cannot read them. A page that will not let them be emptied is stopped, as an
    /// idle one is, and loads afresh when next used; bots never get a page still holding a password.
    func clearSignIns(_ browserID: UUID) {
        let filled = tabs.values.filter { $0.browserID == browserID && $0.hasSignInToClear }
        guard !filled.isEmpty else { return }
        clearingSignIn[browserID, default: 0] += 1
        Task {
            for tab in filled {
                var cleared = false
                for _ in 0..<Self.signInClearAttempts where !cleared { cleared = await tab.clearSignIn() }
                guard !cleared, tabs[tab.id] === tab else { continue }
                tab.info.loading = false; saveTab(tab)
                stopped[tab.id] = (tab.favicon ?? stopped[tab.id]?.favicon, nil)
                tabs.removeValue(forKey: tab.id)?.stop()
            }
            clearingSignIn[browserID, default: 1] -= 1
            if clearingSignIn[browserID] == 0 { clearingSignIn[browserID] = nil }
        }
    }
    /// While a person watches, only the tab they see draws as if seen; bots are kept off meanwhile.
    func showWatchedTab(_ browserID: UUID, watched: Bool? = nil) {
        let watched = watched ?? isWatched(browserID)
        let selected = try? library.profile(browserID).selectedTabID
        for tab in tabs.values where tab.browserID == browserID {
            tab.watched = watched && tab.id == selected
            if watched { tab.endAttention(); tab.mediaResting = false }
        }
    }
    func selectTab(browserID: UUID, tabID: UUID) throws {
        var profile = try library.profile(browserID)
        guard profile.tabs.contains(where: { $0.id == tabID }) else { throw BrowserError("Tab not found in this browser.") }
        profile.selectedTabID = tabID; try library.update(profile)
        _ = try tab(browserID: browserID, tabID: tabID)
        showWatchedTab(browserID)
        touch(browserID: browserID, tabID: tabID)
    }
    /// A person, a bot or someone watching live used the tab. Saved at most once a minute,
    /// since people's input arrives many times a second.
    func touch(browserID: UUID, tabID: UUID, now: Date = Date()) {
        tabs[tabID]?.lastActive = now; tabs[tabID]?.mediaResting = false
        do {
            var profile = try library.profile(browserID)
            guard let index = profile.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            if let used = profile.tabs[index].lastUsed, now.timeIntervalSince(used) < 60 { return }
            profile.tabs[index].lastUsed = now; tabs[tabID]?.info.lastUsed = now
            try library.update(profile)
        } catch { failure = error.localizedDescription }
    }
    /// Closes tabs nobody has used for `age`. A tab on screen, being watched or waiting on a
    /// dialog counts as in use. One with no record of use has its time start now.
    func expireTabs(unusedFor age: TimeInterval, now: Date = Date()) {
        for var profile in library.profiles where !busy.contains(profile.id) && !deleting.contains(profile.id) {
            var expired: [UUID] = [], stamped = false
            for index in profile.tabs.indices {
                let info = profile.tabs[index], tab = tabs[info.id]
                guard let used = info.lastUsed, !inUse(browserID: profile.id, tabID: info.id) else {
                    profile.tabs[index].lastUsed = now; tab?.info.lastUsed = now; stamped = true; continue
                }
                if now.timeIntervalSince(used) >= age { expired.append(info.id) }
            }
            do {
                if stamped { try library.update(profile) }
                for id in expired { try closeTab(browserID: profile.id, tabID: id) }
            } catch { failure = error.localizedDescription }
        }
    }
    /// How long a page goes unused before its media is suspended.
    static let mediaRest: TimeInterval = 600
    /// Suspends media in pages nobody used for `age`, and resumes it in pages in use again. A page
    /// being watched live or shown in a browser window counts as used however long it goes untouched.
    func restMedia(unusedFor age: TimeInterval, now: Date = Date()) {
        for tab in tabs.values {
            tab.mediaResting = !tab.watched && !inUse(browserID: tab.browserID, tabID: tab.id)
                && now.timeIntervalSince(tab.lastActive) >= age
        }
    }
    /// A tab on screen, being watched or waiting on a dialog.
    private func inUse(browserID: UUID, tabID: UUID) -> Bool {
        let tab = tabs[tabID]
        return isWatched(browserID) || tab?.dialog != nil
            || tab.map { $0.web.window != nil && $0.web.window !== $0.surface && $0.web.window?.isVisible == true } == true
    }
    private var idle = BrowserIdleWatch()
    /// What Noodle, or the Hub when `hub`, is told once: tabs its bots opened and then left unused.
    /// A paused browser is left out, since its bots cannot close tabs in it.
    func idleNotices(hub: Bool, at now: Date = Date()) -> [BrowserIdleNotice] {
        let profiles = library.profiles
        idle.keep(Set(profiles.flatMap { $0.tabs.map(\.id) }))
        var candidates: [BrowserIdleWatch.Tab] = []
        for profile in profiles where (profile.hub == true) == hub && !profile.paused && !deleting.contains(profile.id) {
            for info in profile.tabs where info.openedBy != nil && !inUse(browserID: profile.id, tabID: info.id) {
                candidates.append(.init(browser: profile.name, browserID: profile.id, info: info))
            }
        }
        return idle.due(candidates, at: now)
    }
    /// How many days a tab may go unused before it closes, from Settings > General. None never closes them.
    static func tabExpiry(_ defaults: UserDefaults) -> TimeInterval? {
        let days = defaults.object(forKey: "BrowserTabExpiryDays") as? Int ?? 7
        return days > 0 ? TimeInterval(days) * 86_400 : nil
    }
    private var expiry: Task<Void, Never>?
    func startTabExpiry(defaults: UserDefaults = .standard) {
        expiry = Task { [weak self] in
            while !Task.isCancelled {
                if let age = Self.tabExpiry(defaults) { self?.expireTabs(unusedFor: age) }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        mediaRestTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.restMedia(unusedFor: Self.mediaRest)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
    private var mediaRestTask: Task<Void, Never>?
    func closeTab(browserID: UUID, tabID: UUID) throws {
        var profile = try library.profile(browserID)
        guard profile.tabs.contains(where: { $0.id == tabID }) else { throw BrowserError("Tab not found in this browser.") }
        profile.tabs.removeAll { $0.id == tabID }
        if profile.selectedTabID == tabID { profile.selectedTabID = profile.tabs.first?.id }
        try library.update(profile)
        tabs.removeValue(forKey: tabID)?.stop(); stopped.removeValue(forKey: tabID)
        showWatchedTab(browserID)
    }
    func setMuted(_ value: Bool, browserID: UUID) async throws {
        var profile = try library.profile(browserID); profile.muted = value; try library.update(profile)
        for tab in tabs.values where tab.browserID == browserID { tab.mute(value) }
    }
    func setPaused(_ value: Bool, browserID: UUID) throws {
        var profile = try library.profile(browserID); profile.paused = value; try library.update(profile)
        if value { for tab in tabs.values where tab.browserID == browserID { tab.resetPointer() } }
    }
    func removeBrowser(_ id: UUID) async throws {
        guard !busy.contains(id) else { throw BrowserError("Wait for the current browser operation to finish.") }
        busy.insert(id); deleting.insert(id)
        defer { busy.remove(id); deleting.remove(id) }
        willRemoveBrowser?(id)
        surfaces.removeValue(forKey: id)?.stop()
        for tab in tabs.values.filter({ $0.browserID == id }) { tabs.removeValue(forKey: tab.id)?.stop() }
        for tab in try library.profile(id).tabs { stopped.removeValue(forKey: tab.id) }
        for (key, value) in activeDownloads where value.browserID == id {
            _ = await value.download?.cancel(); activeDownloads.removeValue(forKey: key)
        }
        // Let the native library unmount its selected tab before WebKit removes
        // the profile's data store. SwiftUI can retain it through this update.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        try await Self.removeWebsiteDataStore(id)
        try library.remove(id)
        external?.forget(id)
        let root = library.root.appendingPathComponent(id.uuidString.lowercased())
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    static func removeWebsiteDataStore(_ id: UUID) async throws {
        // Initialize WebKit's main run loop before deleting a store in a fresh
        // process. Some system WebKit versions crash if removal is the first API
        // used. The bootstrap view has no window and no persistent website data.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let bootstrap = WKWebView(frame: .zero, configuration: configuration)
        defer { withExtendedLifetime(bootstrap) {} }
        // WebKit releases the page and its network-process store asynchronously.
        // Retry only its explicit in-use condition; disk errors are not retried.
        // https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/
        for attempt in 0..<20 {
            do { try await WKWebsiteDataStore.remove(forIdentifier: id); return }
            catch {
                guard attempt < 19, error.localizedDescription.localizedCaseInsensitiveContains("data store is in use") else { throw error }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    func shutdown() {
        server = nil
        externalServer = nil
        memoryPressure?.cancel(); memoryPressure = nil
        trimmedCaches.removeAll()
        expiry?.cancel(); expiry = nil
        mediaRestTask?.cancel(); mediaRestTask = nil
        for tab in tabs.values { tab.stop() }
        tabs.removeAll()
        library.flush()
    }
    /// `caller` is the signed app asking, when it came over the connection.
    /// `stagingRoot` is where file transfers wait, when not beside the companion socket.
    func perform(_ request: BrowserRequest, caller: String? = nil, surface: SurfaceSocket? = nil, stagingRoot: URL? = nil) async throws -> BrowserResponse {
        try request.validate()
        var response = BrowserResponse()
        if request.operation == .list {
            guard library.failure == nil else { throw BrowserError(library.failure!) }
            response.browsers = library.profiles.map(\.remote); response.features = [SurfaceSocket.feature, BrowserSignInForm.feature]; return response
        }
        let hub = caller == BrowserBuildIdentity.current.hubID
        if request.operation == .idle {
            response.idle = idleNotices(hub: hub)
            return response
        }
        if request.operation == .create, let draft = request.profile {
            var made = try library.create(name: draft.name, description: draft.description,
                                          symbol: draft.symbol ?? "globe", colour: draft.colour)
            if hub { made.hub = true; try library.update(made) }
            response.browser = made.remote
            return response
        }
        // Borrowing is asked over the external connection alone, where performExternal answers it.
        guard request.operation != .borrow, let id = request.browserID else { throw BrowserError("Specify --browser UUID.") }
        var profile = try library.profile(id)
        // The Hub only reaches browsers it made, so one it uses that says otherwise was
        // made before browsers recorded it.
        if hub, profile.hub != true { profile.hub = true; try library.update(profile) }
        // Noodle Hub saying whom one of its browsers is kept for, or nobody. Only the Hub says.
        if request.operation == .setOwner {
            guard hub else { throw BrowserError("Only Noodle Hub says whom its browsers are for.") }
            if profile.hubOwner != request.owner { profile.hubOwner = request.owner; try library.update(profile) }
            return response
        }
        if request.operation == .update, let draft = request.profile {
            var changed = profile
            changed.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let description = draft.description { changed.description = description }
            if let symbol = draft.symbol { changed.symbol = symbol }
            if let colour = draft.colour { changed.colour = colour }
            try library.update(changed)
            response.browser = try library.profile(id).remote
            return response
        }
        if request.operation == .delete {
            try await removeBrowser(id)
            return response
        }
        if request.operation == .history || request.operation == .bookmarks {
            let limit = request.limit ?? 50, offset = request.offset ?? 0
            response.limit = limit; response.offset = offset
            if request.operation == .history {
                let page = try library.history(id, query: request.query ?? "", limit: limit, offset: offset)
                response.history = page.entries; response.totalCount = page.total
            } else {
                let page = try library.bookmarks(id, query: request.query ?? "", limit: limit, offset: offset)
                response.bookmarks = page.entries; response.totalCount = page.total
            }
            return response
        }
        if [.status, .tabs, .downloads].contains(request.operation) {
            response.browser = profile.remote; response.tabs = profile.tabs; response.downloads = profile.downloads
            response.dialog = request.tabID.flatMap { tabs[$0]?.browserID == id ? tabs[$0]?.dialog : nil }
            response.pointer = request.tabID.flatMap { tabs[$0]?.browserID == id ? tabs[$0]?.pointer.state : nil }
            return response
        }
        // A person may watch and use a tab while bots are paused, and alongside a bot's own call.
        if request.operation == .surfaceStream {
            guard let surface else { throw BrowserError("A live view needs a connection of its own.") }
            // The view opens on the tab its link names, as the browser's window would show it.
            if let tabID = request.tabID, profile.tabs.contains(where: { $0.id == tabID }) { try selectTab(browserID: id, tabID: tabID) }
            let streamer = surfaces[id] ?? {
                let view = BrowserLiveView(browserID: id, runtime: self)
                let streamer = SurfaceStreamer(capture: { try await view.picture() }, apply: { try view.apply($0) })
                streamer.watchingChanged = { [weak self] watched in
                    // Bots are kept off until the passwords people filled are emptied, before the browser counts as unwatched.
                    if !watched { self?.clearSignIns(id) }
                    self?.showWatchedTab(id, watched: watched)
                }
                return streamer
            }()
            surfaces[id] = streamer
            streamer.attach(surface)
            return response
        }
        // Only the person watching signs in, on the tab they see, whether or not bots are paused.
        if request.operation == .signInForm || request.operation == .signInFill {
            guard isWatched(id) else { throw BrowserError("Open the browser live to sign in.") }
            guard let tabID = profile.selectedTabID ?? profile.tabs.first?.id else { throw BrowserError("This browser has no tabs.") }
            let tab = try tab(browserID: id, tabID: tabID)
            response.tabID = tab.id
            if request.operation == .signInForm { response.signInForm = try await tab.findSignIn() }
            else { response.submitted = try await tab.fillSignIn(request.signIn!) }
            return response
        }
        guard !profile.paused else { throw BrowserError("Agent control is paused for this browser. Wait for the user to resume it.") }
        guard !isWatched(id), clearingSignIn[id] == nil else { throw BrowserError("A person is using this browser right now. Try again when they're done.") }
        // Dialog replies must remain available while a JS command is waiting.
        if request.operation == .dialog {
            let tab = try tab(browserID: id, tabID: request.tabID!)
            guard tab.dialog != nil else { throw BrowserError("No dialog is pending.") }
            tab.answerDialog(accept: request.accept!, text: request.text); return response
        }
        guard !busy.contains(id) else { throw BrowserError("Another operation is using this browser. Retry after it finishes.") }
        busy.insert(id); defer { busy.remove(id) }
        switch request.operation {
        case .bookmarkAdd: response.bookmark = try library.addBookmark(id, url: request.url!, title: request.title); return response
        case .bookmarkUpdate: response.bookmark = try library.updateBookmark(id, bookmark: request.bookmarkID!, url: request.url, title: request.title); return response
        case .bookmarkRemove: try library.removeBookmark(id, bookmark: request.bookmarkID!); return response
        default: break
        }
        if request.operation == .open {
            guard profile.tabs.count < BrowserLimits.tabs else { throw BrowserError(Self.botTabLimit) }
            let tab = try makeTab(browserID: id, openedBy: request.agentID)
            tab.attend(for: agentAttention)
            if let url = request.url { tab.navigate(try BrowserRequest.navigationURL(url)) }
            response.tabID = tab.id; response.tabs = [tab.info]
            let count = try library.profile(id).tabs.count
            if count >= Self.manyTabs { response.text = "This browser has \(count) open tabs. Close the ones you no longer need." }
            return response
        }
        if request.operation == .download {
            guard let record = profile.downloads.first(where: { $0.id == request.fileID }), record.state == "complete" else { throw BrowserError("Download is not complete or does not belong to this browser.") }
            let source = try downloadURL(browserID: id, record: record)
            let destination = try staging(request, root: stagingRoot)
            response.byteCount = try await Self.copyFile(source, to: destination)
            response.filename = record.filename; return response
        }
        let tab = try tab(browserID: id, tabID: request.tabID!)
        response.tabID = tab.id
        touch(browserID: id, tabID: tab.id)
        if request.operation != .close { tab.attend(for: agentAttention) }
        if ![.inspect, .screenshot, .present].contains(request.operation) { tab.beginAgentInteraction() }
        switch request.operation {
        case .navigate: tab.navigate(try BrowserRequest.navigationURL(request.url!))
        case .back: _ = tab.web.goBack()
        case .forward: _ = tab.web.goForward()
        case .reload: _ = tab.web.reload()
        case .close: try closeTab(browserID: id, tabID: tab.id)
        case .inspect: response.text = try await tab.inspect(frame: request.frame)
        case .webMCPList, .webMCPCall: response.text = try await tab.webMCP(request)
        case .eval:
            // The bot's script may leave listeners behind in the page; a person is not offered to sign in to it.
            tab.botScriptedDocument = true
            let result = try await tab.evaluate("return JSON.stringify(await (async()=>{\n\(request.text!)\n})());", frame: request.frame)
            let text = result as? String ?? "null"
            guard text.utf8.count <= 2 * 1_048_576 else { throw BrowserError("JavaScript result exceeds 2 MiB. Return less data.") }
            response.text = text
        case .click:
            try await tab.click(target: request.target, x: request.x, y: request.y, frame: request.frame, count: request.clickCount ?? 1)
            response.pointer = tab.pointer.state
        case .move:
            try await tab.move(target: request.target, x: request.x, y: request.y, frame: request.frame)
            response.pointer = tab.pointer.state
        case .mouseReset:
            tab.resetPointer(); response.pointer = tab.pointer.state
        case .fill:
            _ = try await tab.evaluate("const e=document.querySelector(target); if(!e) throw Error('Element not found'); if(e.type==='file') throw Error('Use upload for file inputs'); e.focus(); if(e.isContentEditable){e.textContent=text;} else {const p=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:e.tagName==='SELECT'?HTMLSelectElement.prototype:HTMLInputElement.prototype; Object.getOwnPropertyDescriptor(p,'value').set.call(e,text);} e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true})); return true;", arguments: ["target": request.target!, "text": request.text!], frame: request.frame)
        case .key: try tab.press(request.text!)
        case .scroll:
            _ = try await tab.evaluate("const e=target?document.querySelector(target):window; if(!e) throw Error('Element not found'); e.scrollBy(x,y); return true;", arguments: ["target": request.target ?? "", "x": request.x ?? 0, "y": request.y ?? 600], frame: request.frame)
        case .screenshot:
            let data = try await tab.snapshot()
            let url = try staging(request, root: stagingRoot)
            guard !FileManager.default.fileExists(atPath: url.path) else { throw BrowserError("Screenshot destination already exists.") }
            try data.write(to: url, options: .withoutOverwriting)
            response.byteCount = Int64(data.count); response.filename = "screenshot.png"
        case .present:
            _ = try BrowserRequest.navigationURL(tab.info.url)
            let url = tab.info.url
            let screenshot = try await tab.snapshot()
            guard tab.info.url == url, try !library.profile(id).paused else { throw BrowserError("The page changed or browser was paused. Capture the preview again.") }
            guard let source = CGImageSourceCreateWithData(screenshot as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1280,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary),
                  let preview = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.6]),
                  preview.count <= 550_000 else { throw BrowserError("Could not prepare a browser preview.") }
            response.reference = BrowserReference(browser: profile.remote, tabID: tab.id, url: url,
                title: String(decoding: tab.info.title.utf8.prefix(1800), as: UTF8.self), previewImage: preview)
        case .upload:
            let source = try staging(request, root: stagingRoot)
            let folder = try library.directory(id, category: "Uploads").appendingPathComponent(UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let destination = folder.appendingPathComponent(BrowserLibrary.safeFilename(request.filename ?? "upload"))
            response.byteCount = try await Self.copyFile(source, to: destination)
            guard try !library.profile(id).paused else { throw BrowserError("Agent control was paused during the upload.") }
            try await tab.attach([destination], target: request.target!, frame: request.frame)
            response.filename = destination.lastPathComponent
        default: throw BrowserError("Unsupported browser operation.")
        }
        response.dialog = tab.dialog
        return response
    }
    private func staging(_ request: BrowserRequest, root: URL?) throws -> URL {
        guard let id = request.transferID else { throw BrowserError("This operation needs a broker-owned file transfer.") }
        let folder = try root ?? transferRoot ?? BrowserConnection.socketURL().deletingLastPathComponent()
        return try BrowserTransferFiles.staging(root: folder, id: id, create: false)
    }
    nonisolated static func copyFile(_ sourceURL: URL, to destinationURL: URL) async throws -> Int64 {
        try await Task.detached {
            let source = try BrowserTransferFiles.openSource(sourceURL); defer { Darwin.close(source) }
            let destination = Darwin.open(destinationURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard destination >= 0 else { throw BrowserError("Cannot create the transferred file.") }
            defer { Darwin.close(destination) }
            do { return try BrowserTransferFiles.copy(source: source, destination: destination) }
            catch { try? FileManager.default.removeItem(at: destinationURL); throw error }
        }.value
    }
    func exportUserFile(_ sourceURL: URL, to destinationURL: URL) async throws {
        let access = destinationURL.startAccessingSecurityScopedResource()
        defer { if access { destinationURL.stopAccessingSecurityScopedResource() } }
        try await Task.detached {
            let source = try BrowserTransferFiles.openSource(sourceURL); defer { Darwin.close(source) }
            // NSSavePanel has already obtained human consent to replace this file.
            let destination = Darwin.open(destinationURL.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard destination >= 0 else { throw BrowserError("Cannot save to the selected file.") }
            defer { Darwin.close(destination) }
            var original = stat(); _ = fstat(source, &original)
            var info = stat()
            guard fstat(destination, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  !(original.st_dev == info.st_dev && original.st_ino == info.st_ino),
                  ftruncate(destination, 0) == 0 else { throw BrowserError("Choose a writable regular file.") }
            _ = try BrowserTransferFiles.copy(source: source, destination: destination)
        }.value
    }
    func filesFromViewer(browserID: UUID, multiple: Bool, directories: Bool) async -> ViewerFileChoice {
        let choice: ViewerFileChoice
        if let supply = supplyViewerFiles {
            choice = await supply(multiple, directories)
        } else {
            guard let streamer = surfaces[browserID], streamer.isWatched else { return .unavailable }
            guard let answer = await streamer.requestFiles(multiple: multiple, directories: directories) else { return .unavailable }
            if answer.names == [SurfaceFileAsk.tooLarge] { return .tooLarge }
            if answer.names == [SurfaceFileAsk.failed] { return .failed }
            if answer.names.isEmpty { return .cancelled }
            let pairs = Array(zip(answer.names, answer.bodies))
            guard pairs.allSatisfy({ $0.1.count <= SurfaceFileAsk.byteLimit }) else { return .tooLarge }
            choice = .chosen(pairs.map { (name: $0.0, body: $0.1) })
        }
        guard case .chosen(let files) = choice, !multiple else { return choice }
        return .chosen(Array(files.prefix(1)))
    }
    func stageUserData(_ body: Data, name: String, browserID: UUID) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(BrowserLibrary.safeFilename(name.isEmpty ? "file" : name))
        try body.write(to: file, options: .atomic)
        return try await stageUserFile(file, browserID: browserID)
    }
    func stageUserFile(_ source: URL, browserID: UUID) async throws -> URL {
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let folder = try library.directory(browserID, category: "Uploads").appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let destination = folder.appendingPathComponent(BrowserLibrary.safeFilename(source.lastPathComponent))
        _ = try await Self.copyFile(source, to: destination)
        return destination
    }
    func receive(_ download: WKDownload, browserID: UUID) {
        track(ObjectIdentifier(download), download: download, browserID: browserID)
        download.delegate = self
    }
    func track(_ key: ObjectIdentifier, download: WKDownload? = nil, browserID: UUID,
               record: BrowserDownloadInfo = .init(filename: "download")) {
        activeDownloads[key] = (download, browserID, record)
    }
    /// Choose where a tracked download lands. Kept separate from the WebKit
    /// callback so it can be exercised without a WKDownload, which has no
    /// public initializer.
    func downloadDestination(for key: ObjectIdentifier, suggestedFilename: String) -> URL? {
        guard var value = activeDownloads[key] else { return nil }
        do {
            value.record.filename = BrowserLibrary.safeFilename(suggestedFilename)
            activeDownloads[key] = value
            var profile = try library.profile(value.browserID)
            profile.downloads.append(value.record); try library.update(profile)
            return try downloadURL(browserID: value.browserID, record: value.record)
        } catch { failure = error.localizedDescription; return nil }
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        downloadDestination(for: ObjectIdentifier(download), suggestedFilename: suggestedFilename)
    }
    func downloadURL(browserID: UUID, record: BrowserDownloadInfo) throws -> URL {
        let folder = try library.directory(browserID, category: "Downloads").appendingPathComponent(record.id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder.appendingPathComponent(BrowserLibrary.safeFilename(record.filename))
    }
    /// Forget a download and delete its stored file; one still in flight is cancelled first.
    func removeDownload(browserID: UUID, downloadID: UUID) throws {
        var profile = try library.profile(browserID)
        guard let index = profile.downloads.firstIndex(where: { $0.id == downloadID }) else { throw BrowserError("Download does not belong to this browser or no longer exists.") }
        let folder = try downloadURL(browserID: browserID, record: profile.downloads[index]).deletingLastPathComponent()
        if let key = activeDownloads.first(where: { $0.value.record.id == downloadID })?.key {
            activeDownloads.removeValue(forKey: key)?.download?.cancel { _ in }
        }
        profile.downloads.remove(at: index); try library.update(profile)
        try? FileManager.default.removeItem(at: folder)
    }
    func downloadDidFinish(_ download: WKDownload) { completeDownload(download, error: nil) }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { completeDownload(download, error: error) }
    private func completeDownload(_ download: WKDownload, error: Error?) {
        guard var value = activeDownloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        do {
            value.record.state = error == nil ? "complete" : "failed"; value.record.error = error?.localizedDescription
            let url = try downloadURL(browserID: value.browserID, record: value.record)
            value.record.byteCount = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
            var profile = try library.profile(value.browserID)
            if let index = profile.downloads.firstIndex(where: { $0.id == value.record.id }) { profile.downloads[index] = value.record; try library.update(profile) }
        } catch { failure = error.localizedDescription }
    }
}
