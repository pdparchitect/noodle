import AppKit
import BrowserBridge
import BrowserCore
import Darwin
import ImageIO
import WebKit

@MainActor final class BrowserRuntime: NSObject, ObservableObject, WKDownloadDelegate {
    let library: BrowserLibrary
    @Published var failure: String?
    @Published private(set) var tabs: [UUID: BrowserTab] = [:]
    var showBrowser: ((UUID) -> Void)?
    var willRemoveBrowser: ((UUID) -> Void)?
    private var server: BrowserConnectionServer?
    private var activeDownloads: [ObjectIdentifier: (download: WKDownload?, browserID: UUID, record: BrowserDownloadInfo)] = [:]
    private var busy: Set<UUID> = []
    private var deleting: Set<UUID> = []
    /// Live views, by browser. While one is watched, bots are kept off that browser.
    private var surfaces: [UUID: SurfaceStreamer] = [:]
    private let transferRoot: URL?
    init(library: BrowserLibrary, transferRoot: URL? = nil) { self.library = library; self.transferRoot = transferRoot; super.init() }
    func startServer(socket: URL? = nil) {
        do {
            server = try BrowserConnectionServer(socket: socket ?? BrowserConnection.socketURL(), team: BrowserConnection.signingTeam(),
                                                 handler: { [weak self] request, _ in
                guard let self else { return .init(error: "Browser stopped.") }
                do { return try await self.perform(request) }
                catch { return .init(error: error.localizedDescription) }
            }, surface: { [weak self] request, _, socket in
                guard let self else { return .init(error: "Browser stopped.") }
                do { return try await self.perform(request, surface: socket) }
                catch { return .init(error: error.localizedDescription) }
            })
        } catch { failure = error.localizedDescription }
    }
    func saveTab(_ tab: BrowserTab) {
        do {
            var profile = try library.profile(tab.browserID)
            guard let index = profile.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
            profile.tabs[index] = tab.info; try library.update(profile)
        } catch { failure = error.localizedDescription }
    }
    @discardableResult func makeTab(browserID: UUID, configuration: WKWebViewConfiguration? = nil, restoring: BrowserTabInfo? = nil) throws -> BrowserTab {
        guard !deleting.contains(browserID) else { throw BrowserError("This browser is being deleted.") }
        var profile = try library.profile(browserID)
        guard profile.tabs.count < 100 || restoring != nil else { throw BrowserError("This browser has reached its 100-tab limit.") }
        let info = restoring ?? BrowserTabInfo()
        if let tab = tabs[info.id] { return tab }
        let tab = BrowserTab(browserID: browserID, info: info, runtime: self, configuration: configuration)
        if restoring == nil {
            profile.tabs.append(info); profile.selectedTabID = info.id
            do { try library.update(profile) } catch { tab.stop(); throw error }
        }
        tabs[info.id] = tab
        return tab
    }
    func tab(browserID: UUID, tabID: UUID) throws -> BrowserTab {
        let profile = try library.profile(browserID)
        guard let info = profile.tabs.first(where: { $0.id == tabID }) else { throw BrowserError("This tab does not belong to the selected browser.") }
        if let existing = tabs[tabID] { return existing }
        let tab = try makeTab(browserID: browserID, restoring: info)
        if let url = try? BrowserRequest.navigationURL(info.url) { tab.navigate(url) }
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
    func selectTab(browserID: UUID, tabID: UUID) throws {
        var profile = try library.profile(browserID)
        guard profile.tabs.contains(where: { $0.id == tabID }) else { throw BrowserError("Tab not found in this browser.") }
        profile.selectedTabID = tabID; try library.update(profile)
        _ = try tab(browserID: browserID, tabID: tabID)
    }
    func closeTab(browserID: UUID, tabID: UUID) throws {
        var profile = try library.profile(browserID)
        guard profile.tabs.contains(where: { $0.id == tabID }) else { throw BrowserError("Tab not found in this browser.") }
        profile.tabs.removeAll { $0.id == tabID }
        if profile.selectedTabID == tabID { profile.selectedTabID = profile.tabs.first?.id }
        try library.update(profile)
        tabs.removeValue(forKey: tabID)?.stop()
    }
    func setMuted(_ value: Bool, browserID: UUID) async throws {
        var profile = try library.profile(browserID); profile.muted = value; try library.update(profile)
        for tab in tabs.values where tab.browserID == browserID { await tab.mute(value) }
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
        for tab in tabs.values { tab.stop() }
        tabs.removeAll()
    }
    func perform(_ request: BrowserRequest, surface: SurfaceSocket? = nil) async throws -> BrowserResponse {
        try request.validate()
        var response = BrowserResponse()
        if request.operation == .list {
            guard library.failure == nil else { throw BrowserError(library.failure!) }
            response.browsers = library.profiles.map(\.remote); response.features = [SurfaceSocket.feature]; return response
        }
        if request.operation == .create, let draft = request.profile {
            response.browser = try library.create(name: draft.name, description: draft.description,
                                                  symbol: draft.symbol ?? "globe", colour: draft.colour).remote
            return response
        }
        let id = request.browserID!
        let profile = try library.profile(id)
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
                return SurfaceStreamer(capture: { try await view.picture() }, apply: { try view.apply($0) })
            }()
            surfaces[id] = streamer
            streamer.attach(surface)
            return response
        }
        guard !profile.paused else { throw BrowserError("Agent control is paused for this browser. Wait for the user to resume it.") }
        guard !isWatched(id) else { throw BrowserError("A person is using this browser right now. Try again when they're done.") }
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
        if request.operation == .show { showBrowser?(id); return response }
        if request.operation == .open {
            let tab = try makeTab(browserID: id)
            if let url = request.url { tab.navigate(try BrowserRequest.navigationURL(url)) }
            response.tabID = tab.id; response.tabs = [tab.info]; return response
        }
        if request.operation == .download {
            guard let record = profile.downloads.first(where: { $0.id == request.fileID }), record.state == "complete" else { throw BrowserError("Download is not complete or does not belong to this browser.") }
            let source = try downloadURL(browserID: id, record: record)
            let destination = try staging(request)
            response.byteCount = try await Self.copyFile(source, to: destination)
            response.filename = record.filename; return response
        }
        let tab = try tab(browserID: id, tabID: request.tabID!)
        response.tabID = tab.id
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
            let url = try staging(request)
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
            let source = try staging(request)
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
    private func staging(_ request: BrowserRequest) throws -> URL {
        guard let id = request.transferID else { throw BrowserError("This operation needs a broker-owned file transfer.") }
        let root = try transferRoot ?? BrowserConnection.socketURL().deletingLastPathComponent()
        return try BrowserTransferFiles.staging(root: root, id: id, create: false)
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
