import AppKit
import BrowserBridge
import ImageIO
import os
import WebKit

/// Each tab has an app-owned rendering surface. Events go directly to this view,
/// never to the system event stream or another application's window.
@MainActor final class BrowserTab: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id: UUID
    let browserID: UUID
    let web: WKWebView
    let pointer: BrowserPointer
    let surface: BrowserSurfacePanel
    weak var runtime: BrowserRuntime?
    @Published var info: BrowserTabInfo
    @Published var dialog: BrowserDialog? { didSet { restoreSurface() } }
    /// Shown in place of a page that could not load or whose process stopped.
    @Published private(set) var failure: BrowserPageFailure?
    /// The page's own icon, kept while the tab stays on the same site.
    private(set) var favicon: NSImage? { willSet { runtime?.objectWillChange.send() } }
    private var faviconURL: URL?
    private var faviconSite: String?
    private var faviconTask: Task<Void, Never>?
    private var replyToDialog: ((Bool, String?) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private(set) var frames: [String: WKFrameInfo] = [:]
    var webMCPAllowed = true
    var webMCPFramePolicies: [String: Bool] = [:]
    private var upload: (id: UUID, urls: [URL], provided: Bool, origin: String, mainFrame: Bool, continuation: CheckedContinuation<Void, Error>)? {
        didSet { restoreSurface() }
    }
    private var operations: [UUID: () -> Void] = [:] { didSet { restoreSurface() } }
    /// Native input must keep its window across the JavaScript calls that locate its target.
    private var surfaceUsers = 0 { didSet { restoreSurface() } }
    private var stopped = false
    private var finishedDocument = false
    private var visitID: UUID?
    private var visitedURL: String?
    private var visitedTitle: String?
    private var humanInput = false
    /// The last click or key came from someone watching live, who may be on another device.
    private var viewerInput = false
    static let liveViewUploadNote = "Files can't be uploaded from a live view. Upload them in \(BrowserBuildIdentity.current.appName) on its Mac, or ask the bot."
    /// When a person, a bot or someone watching live last used the page, to the moment.
    var lastActive = Date()
    /// Waiting on a dialog, an upload or a page call, or being watched; stopping the page would lose that.
    var mustKeepRunning: Bool { dialog != nil || upload != nil || !operations.isEmpty || watched }
    /// Where a person watching remotely clicks and types.
    private var surfaceInjector: SurfaceEventInjector?
    private var inputMonitor: Any?
    private var inputGeneration = 0
    static let controlWorld = WKContentWorld.world(name: "NoodleBrowserControl")
    /// Sites serve their full pages only to browsers they recognise, so tabs name the Safari of
    /// this macOS, whose version has matched the system's since macOS 26.
    static let safariName: String = {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(system.majorVersion).\(system.minorVersion) Safari/605.1.15"
    }()

    init(browserID: UUID, info: BrowserTabInfo, runtime: BrowserRuntime, configuration: WKWebViewConfiguration? = nil) {
        self.id = info.id; self.browserID = browserID; self.info = info; self.runtime = runtime
        let config = configuration ?? WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        BrowserWebMCP.install(into: config.userContentController)
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: browserID)
        // Out of sight, pages slow down as in Safari; dozens of tabs at full speed made the whole browser sluggish.
        config.preferences.inactiveSchedulingPolicy = .throttle
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.applicationNameForUserAgent = Self.safariName
        web = BrowserPageWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        pointer = BrowserPointer(web: web)
        surface = BrowserSurfacePanel(contentRect: web.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        surface.isReleasedWhenClosed = false
        surface.hidesOnDeactivate = false
        // Transparent on screen, it would still show in Mission Control as an empty window.
        surface.collectionBehavior = [.transient, .ignoresCycle]
        surface.contentView = web
        web.navigationDelegate = self; web.uiDelegate = self
        mute((try? runtime.library.profile(browserID).muted) ?? true)
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self, event.window === self.web.window, event.window?.isVisible == true else { return event }
            var used = false
            if event.type != .keyDown {
                if self.web.bounds.contains(self.web.convert(event.locationInWindow, from: nil)) {
                    self.resetPointer()
                    if event.type == .leftMouseDown { self.humanInput = true; self.viewerInput = false }
                    used = event.type != .mouseMoved
                }
            } else if let view = event.window?.firstResponder as? NSView, view === self.web || view.isDescendant(of: self.web) {
                self.resetPointer()
                self.humanInput = true; self.viewerInput = false
                used = true
            }
            if used { self.runtime?.touch(browserID: self.browserID, tabID: self.id) }
            return event
        }
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
        config.userContentController.add(self, contentWorld: Self.controlWorld, name: "frameReady")
        config.userContentController.addUserScript(WKUserScript(source: "window.webkit.messageHandlers.frameReady.postMessage(null)", injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.controlWorld))
        observations = [web.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } },
                        web.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } },
                        web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } }]
        restoreSurface()
    }
    func update() {
        guard !stopped else { return }
        info.url = web.url?.absoluteString ?? info.url
        info.title = web.title?.isEmpty == false ? web.title! : (web.url?.host ?? "New Tab")
        info.loading = web.isLoading
        restoreSurface()
        runtime?.saveTab(self)
        // URL observation also catches History API and fragment navigation after
        // the document finishes; title changes update that visit, not a new row.
        if finishedDocument && !web.isLoading { recordHistory() }
    }
    private func recordHistory() {
        guard !stopped, let runtime else { return }
        do {
            if visitedURL != info.url {
                visitID = try runtime.library.recordVisit(browserID, url: info.url, title: info.title)
                visitedURL = info.url; visitedTitle = info.title
            } else if visitedTitle != info.title, let visitID {
                try runtime.library.updateHistoryTitle(browserID, visit: visitID, title: info.title)
                visitedTitle = info.title
            }
        } catch { runtime.failure = error.localizedDescription }
    }
    func beginAgentInteraction() { humanInput = false; viewerInput = false }
    func resetPointer() { inputGeneration += 1; pointer.reset() }
    /// Muting is WebKit's own page mute, as in Safari: media elements and Web Audio in every frame
    /// go silent but keep playing, so pages that decode video, such as an upload making its cover,
    /// keep working. Pages are not told; WebKit has no public call for this, so it is looked up.
    func mute(_ muted: Bool) {
        let selector = NSSelectorFromString("_setPageMuted:")
        typealias PageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else {
            // A WebKit without page muting only offers suspending playback, which pauses video too.
            mutedBySuspending = muted; suspendMedia(); return
        }
        // 1 is WebKit's audio-muted bit; cameras and microphones are refused anyway.
        unsafeBitCast(method_getImplementation(method), to: PageMuted.self)(web, selector, muted ? 1 : 0)
    }
    private var mutedBySuspending = false
    /// Nobody used the page for a while, so its video and audio are suspended where they are, and
    /// pick up from there when it is used again. Out of sight, a page still runs its players' scripts
    /// at full speed, which kept some busy for hours after a bot left them.
    var mediaResting = false {
        didSet { if mediaResting != oldValue { suspendMedia() } }
    }
    private func suspendMedia() {
        web.setAllMediaPlaybackSuspended(mediaResting || mutedBySuspending, completionHandler: nil)
    }
    func restoreSurface() {
        guard !stopped else { showUnseen(); return }
        // SwiftUI owns mounted pages, including a container waiting to enter its window.
        guard web.window == nil || web.window === surface else { showUnseen(); return }
        guard web.window != nil || web.superview == nil else { showUnseen(); return }
        let needed = watched || attended || mustKeepRunning || surfaceUsers > 0 || pointer.pressed || web.isLoading
        guard needed else {
            if web.window === surface { detachSurface() }
            showUnseen()
            return
        }
        if web.window == nil {
            // Keep the visible tab's viewport when parking it for background
            // automation. Resetting it on every switch reflows responsive pages.
            let size = web.frame.size
            surface.contentView = nil
            surface.setContentSize(size)
            surface.contentView = web
            web.setFrameOrigin(.zero)
            if watched || attended { keepScrollPosition() }
        }
        showUnseen()
    }
    /// A page scrolled while out of sight, such as in a closed browser window, goes back to its top
    /// when WebKit draws it again, which happens when its own window goes on screen for a bot or a
    /// live view. The position is read before the window moves and put back if the page jumps to
    /// its top as it starts drawing; a page that scrolls itself meanwhile is left where it went.
    private func keepScrollPosition() {
        web.callAsyncJavaScript(Self.keepScrollScript, arguments: [:], in: nil, in: Self.controlWorld, completionHandler: nil)
    }
    static let keepScrollScript = """
        const x = scrollX, y = scrollY;
        if (!x && !y) return;
        if (document.visibilityState !== 'visible') {
            const shown = await new Promise(resolve => {
                const timer = setTimeout(() => resolve(false), 2000);
                document.addEventListener('visibilitychange', () => { clearTimeout(timer); resolve(true); }, {once: true});
            });
            if (!shown) return;
        }
        // Counted in frames, which stop while the page is out of sight again, and given up after a
        // few seconds, so a position from long ago is never put back.
        const deadline = performance.now() + 5000;
        for (let frame = 0; frame < 30 && performance.now() < deadline; frame++) {
            if (scrollX !== x || scrollY !== y) {
                if (!scrollX && !scrollY) scrollTo(x, y);
                return;
            }
            await new Promise(resolve => requestAnimationFrame(resolve));
        }
        """
    func detachSurface() {
        let wasInSurface = web.window === surface
        if let window = web.window, let responder = window.firstResponder as? NSView,
           responder === web || responder.isDescendant(of: web) {
            window.makeFirstResponder(nil)
        }
        web.removeFromSuperview()
        if wasInSurface { surface.contentView = nil }
        showUnseen()
    }
    /// While a person watches from another device, or a bot works in it, the page must draw as if
    /// seen, which WebKit only does for a window on screen: out of sight, a page gets no animation
    /// frames, and sites that wait for one before showing anything stay empty. A tab not in a
    /// browser window has its own panel put there, transparent, at the back and taking no clicks.
    var watched = false {
        didSet { restoreSurface() }
    }
    /// A bot used the tab lately, so the page draws as if the bot were looking at it.
    private(set) var attended = false {
        didSet { if attended != oldValue { restoreSurface() } }
    }
    private var attention: Task<Void, Never>?
    /// A bot used the tab: it draws as if seen until `span` passes without the bot using it again.
    /// Then its view leaves the window, keeping the document alive while WebKit can release rendering resources.
    func attend(for span: Duration) {
        guard !stopped else { return }
        attention?.cancel()
        attended = true
        restoreSurface()
        attention = Task { [weak self] in
            try? await Task.sleep(for: span)
            guard !Task.isCancelled else { return }
            self?.attended = false
        }
    }
    func endAttention() { attention?.cancel(); attention = nil; attended = false; restoreSurface() }
    /// The tab's own window is on screen, out of sight, for a bot or a live view.
    private var shownUnseen = false
    private func showUnseen() {
        let unseen = (watched || attended) && !stopped && web.window === surface
        guard unseen != shownUnseen else { return }
        shownUnseen = unseen
        // The window is transparent and takes no clicks for good, so going on screen or off never shows it.
        // A transparent window at the back counts as occluded, which WebKit reports to the page as hidden.
        setOcclusionDetection(!unseen)
        if unseen { surface.showUnseen() } else { surface.orderOut(nil) }
    }
    private func setOcclusionDetection(_ enabled: Bool) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(web, selector, enabled)
    }
    func navigate(_ url: URL) {
        info.error = nil; failure = nil
        web.load(URLRequest(url: url))
    }
    func stop() {
        resetPointer()
        stopped = true
        faviconTask?.cancel()
        attention?.cancel(); attention = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        let pending = operations.values; operations.removeAll(); pending.forEach { $0() }
        finishUpload(.failure(BrowserError("Tab closed during upload.")))
        answerDialog(accept: false, text: nil)
        web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "frameReady", contentWorld: Self.controlWorld)
        observations.removeAll(); frames.removeAll(); detachSurface(); surface.close(); surface.contentView = nil
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === web, !stopped else { return }
        let key = message.frameInfo.isMainFrame ? "main" : UUID().uuidString.lowercased()
        frames[key] = message.frameInfo
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        webMCPAllowed = false; webMCPFramePolicies.removeAll()
        resetPointer()
        finishedDocument = false; visitID = nil; visitedURL = nil; visitedTitle = nil
        frames.removeAll(); info.error = nil; failure = nil; update()
        if dialog != nil { answerDialog(accept: false, text: nil) }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The page and what a person filled in it are gone; a fill meant for it must not land on the next.
        signIn = nil; signInFilled = [:]; botScriptedDocument = false
        if webView.url?.host != faviconSite { favicon = nil; faviconURL = nil; faviconSite = nil }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishedDocument = true; update(); findFavicon() }
    private func findFavicon() {
        guard let page = web.url else { return }
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            guard let self else { return }
            let links = (try? await web.callAsyncJavaScript(BrowserFavicon.script, contentWorld: Self.controlWorld)) as? [[String: String]]
            guard let url = BrowserFavicon.choose(links ?? [], page: page), url != faviconURL else { return }
            let image = await BrowserFavicon.load(url)
            guard !Task.isCancelled, !stopped, web.url?.host == page.host else { return }
            favicon = image; faviconURL = url; faviconSite = page.host
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // The web view may still show the last page; the error names the one that failed.
        if failed(error) { failure = BrowserPageFailure(error, url: (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url) }
    }
    @discardableResult private func failed(_ error: Error) -> Bool {
        // WebKit ends a load that became a download (102) or went to a plug-in (204) as if it failed.
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorCancelled), ("WebKitErrorDomain", 102), ("WebKitErrorDomain", 204): return false
        default: break
        }
        info.error = error.localizedDescription; info.loading = false; runtime?.saveTab(self)
        return true
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resetPointer()
        failed(BrowserError("Page process stopped. Reload this tab to continue."))
        failure = .stopped
        let pending = operations.values; operations.removeAll(); pending.forEach { $0() }
    }
    /// Page-initiated loads never reach local files or other applications.
    nonisolated static func permitsNavigation(_ url: URL) -> Bool {
        ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, Self.permitsNavigation(url) else {
            info.error = "This link requires an external application."; runtime?.saveTab(self)
            decisionHandler(.cancel); return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let permitted = BrowserWebMCP.permits(navigationResponse.response)
        if navigationResponse.isForMainFrame { webMCPAllowed = permitted }
        if let url = navigationResponse.response.url, webMCPFramePolicies.count < 512 {
            webMCPFramePolicies[url.absoluteString.components(separatedBy: "#")[0]] = permitted
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(!navigationResponse.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") ? .download : .allow)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { runtime?.receive(download, browserID: browserID) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { runtime?.receive(download, browserID: browserID) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // WebKit requires this exact configuration to preserve window.opener and
        // OAuth popup relationships. The popup remains in the same profile.
        do {
            // A tab a bot's page opens, such as Apply on a job listing, is the bot's to close.
            let popup = try runtime?.makeTab(browserID: browserID, configuration: configuration, openedBy: info.openedBy)
            // A sign-in window that a bot's page opens is the bot's to finish.
            if attended, let popup, let runtime { popup.attend(for: runtime.agentAttention) }
            return popup?.web
        }
        catch {
            // Only a person who just clicked or typed in the tab in a shown browser window is alerted.
            // Otherwise it is a bot's page, also when the browser window shows the bot's tab, and the
            // bot finds out from its tab.
            guard let runtime else { return nil }
            if humanInput, let window = web.window, window !== surface, window.isVisible {
                runtime.failure = error.localizedDescription; return nil
            }
            let full = (try? runtime.library.profile(browserID).tabs.count >= BrowserLimits.tabs) == true
            info.error = full ? BrowserRuntime.botTabLimit : error.localizedDescription; runtime.saveTab(self)
            return nil
        }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webViewDidClose(_ webView: WKWebView) { try? runtime?.closeTab(browserID: browserID, tabID: id) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        if let pending = upload {
            let origin = "\(frame.securityOrigin.protocol)://\(frame.securityOrigin.host):\(frame.securityOrigin.port)"
            guard origin == pending.origin, frame.isMainFrame == pending.mainFrame else {
                completionHandler(nil); finishUpload(.failure(BrowserError("The upload was opened by a different frame."))); return
            }
            guard parameters.allowsMultipleSelection || pending.urls.count == 1 else {
                completionHandler(nil); finishUpload(.failure(BrowserError("This upload control does not accept these files."))); return
            }
            guard !pending.provided else { completionHandler(nil); return }
            upload?.provided = true
            completionHandler(pending.urls); return
        }
        guard humanInput, let window = web.window, window.isVisible else {
            if viewerInput {
                let multiple = parameters.allowsMultipleSelection
                let directories = parameters.allowsDirectories
                Task { await self.completeViewerOpen(multiple: multiple, directories: directories, completion: completionHandler) }
                return
            }
            completionHandler(nil)
            info.error = "Use the upload command to provide files."
            runtime?.saveTab(self); return
        }
        humanInput = false
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { completionHandler(nil); return }
            // Stage selected files inside the sandbox. Access ends after copying,
            // while WebKit can continue reading staged bytes for multipart upload.
            Task {
                do {
                    guard let runtime = self.runtime else { throw BrowserError("Browser closed.") }
                    var staged: [URL] = []
                    for url in panel.urls { staged.append(try await runtime.stageUserFile(url, browserID: self.browserID)) }
                    completionHandler(staged)
                } catch { self.runtime?.failure = error.localizedDescription; completionHandler(nil) }
            }
        }
    }
    private func finishUpload(_ result: Result<Void, Error>) {
        let pending = upload; upload = nil; pending?.continuation.resume(with: result)
    }
    /// The person watching chooses on their own Mac or iPhone. Nothing opens on this Mac.
    private func completeViewerOpen(multiple: Bool, directories: Bool, completion: @escaping ([URL]?) -> Void) async {
        guard let runtime else { completion(nil); return }
        switch await runtime.filesFromViewer(browserID: browserID, multiple: multiple, directories: directories) {
        case .unavailable:
            info.error = Self.liveViewUploadNote
            runtime.saveTab(self)
            completion(nil)
        case .cancelled:
            completion(nil)
        case .tooLarge:
            info.error = "That file is larger than this Hub allows."
            runtime.saveTab(self)
            completion(nil)
        case .failed:
            info.error = "That file couldn't be sent. Try a smaller one."
            runtime.saveTab(self)
            completion(nil)
        case .chosen(let files):
            do {
                var staged: [URL] = []
                for file in files { staged.append(try await runtime.stageUserData(file.body, name: file.name, browserID: browserID)) }
                completion(staged)
            } catch {
                runtime.failure = error.localizedDescription
                completion(nil)
            }
        }
    }
    func attach(_ urls: [URL], target: String, frame: String?) async throws {
        guard upload == nil else { throw BrowserError("An upload is already pending.") }
        let selectedFrame: WKFrameInfo?
        if let frame, frame != "main" { selectedFrame = frames[frame] } else { selectedFrame = frames["main"] }
        guard let selectedFrame else { throw BrowserError("Inspect the loaded page before uploading a file.") }
        let origin = "\(selectedFrame.securityOrigin.protocol)://\(selectedFrame.securityOrigin.host):\(selectedFrame.securityOrigin.port)"
        try await withCheckedThrowingContinuation { continuation in
            let uploadID = UUID()
            upload = (uploadID, urls, false, origin, selectedFrame.isMainFrame, continuation)
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.evaluate("const e=document.querySelector(target); if(!e || e.tagName !== 'INPUT' || e.type !== 'file') throw Error('Target must be a file input'); return await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{e.removeEventListener('change',changed,true);reject(Error('Upload selection did not complete'))},8000);function changed(){clearTimeout(timer);resolve(true)}e.addEventListener('change',changed,{once:true,capture:true});e.click()});", arguments: ["target": target], frame: frame, world: Self.controlWorld)
                    guard self.upload?.id == uploadID else { return }
                    self.finishUpload(.success(()))
                } catch { if self.upload?.id == uploadID { self.finishUpload(.failure(error)) } }
            }
        }
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        setDialog(.init(kind: "alert", message: message, origin: frame.securityOrigin.host)) { _, _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        setDialog(.init(kind: "confirm", message: message, origin: frame.securityOrigin.host)) { yes, _ in completionHandler(yes) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        setDialog(.init(kind: "prompt", message: prompt, defaultText: defaultText, origin: frame.securityOrigin.host)) { yes, text in completionHandler(yes ? text ?? defaultText ?? "" : nil) }
    }
    private func setDialog(_ value: BrowserDialog, reply: @escaping (Bool, String?) -> Void) {
        answerDialog(accept: false, text: nil); dialog = value; replyToDialog = reply
    }
    func answerDialog(accept: Bool, text: String?) { let reply = replyToDialog; replyToDialog = nil; dialog = nil; reply?(accept, text) }

    func evaluate(_ source: String, arguments: [String: Any] = [:], frame: String? = nil, world: WKContentWorld? = nil) async throws -> Any? {
        if dialog != nil { throw BrowserError("A page dialog is pending. Use dialog before continuing.") }
        var selected: WKFrameInfo?
        if let frame, frame != "main" {
            guard let value = frames[frame] else { throw BrowserError("Frame is no longer available. Inspect the page again.") }
            selected = value
        }
        return try await evaluate(source, arguments: arguments, in: selected, world: world)
    }
    /// Runs in `frame` itself, the main frame when nil, whether or not it is still registered.
    private func evaluate(_ source: String, arguments: [String: Any], in frame: WKFrameInfo?, world: WKContentWorld?,
                          limit: Duration = .seconds(20)) async throws -> Any? {
        do {
            return try await bounded(limit: limit) { finish in
                self.web.callAsyncJavaScript(source, arguments: arguments, in: frame, in: world ?? .page, completionHandler: finish)
            }
        } catch { throw Self.scriptError(error) }
    }
    /// A script's exception in the page's own words, such as "Element not found", where WebKit says
    /// only "A JavaScript exception occurred". Any other error is left as it is.
    nonisolated static func scriptError(_ error: Error) -> Error {
        let error = error as NSError
        guard error.domain == WKError.errorDomain, error.code == WKError.javaScriptExceptionOccurred.rawValue,
              let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String, !message.isEmpty else { return error }
        // A plain Error puts "Error: " before its message; a TypeError and the like keep their name.
        return BrowserError(message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message)
    }
    func inspect(frame: String?) async throws -> String {
        let url = BrowserResources.bundle.url(forResource: "Resources", withExtension: nil)!.appendingPathComponent("Inspect.js")
        let source = try String(contentsOf: url, encoding: .utf8)
        let value = try await evaluate(source, frame: frame, world: Self.controlWorld)
        var result = value as? [String: Any] ?? [:]
        result["frames"] = frames.map { ["id": $0.key, "url": $0.value.request.url?.absoluteString ?? "", "main": $0.value.isMainFrame] as [String: Any] }
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }
    /// The sign-in form last found for someone watching live: the token a fill must name, and the frame
    /// and origin it is in, nil being the main frame. Its fields stay in the control world of that frame,
    /// where the page cannot reach them.
    private var signIn: (token: UUID, frame: WKFrameInfo?, origin: String)?
    /// Frames where a person's password went in, by their key, emptied when the last viewer leaves.
    private var signInFilled: [String: WKFrameInfo?] = [:]
    var hasSignInToClear: Bool { !signInFilled.isEmpty }
    /// A bot ran its own script in this page, which could have left listeners behind to read what a person
    /// types; nobody is offered to sign in to it until it loads again.
    var botScriptedDocument = false
    static let signInChanged = "The page changed. Try again."
    static let signInDialog = "The page is showing a dialog. Answer it, then try again."
    static let signInBotScripted = "A bot ran scripts on this page. Reload it, then try again."
    /// How long one frame may take to say what sign-in fields it has.
    static let signInFrameLimit = Duration.seconds(2)

    private func signInScript(_ mode: String, in frame: WKFrameInfo?, token: UUID = UUID(), origin: String = "",
                              entered: [String: String] = [:], submit: Bool = false,
                              limit: Duration = .seconds(20)) async throws -> Any? {
        if dialog != nil { throw BrowserError(Self.signInDialog) }
        let url = BrowserResources.bundle.url(forResource: "Resources", withExtension: nil)!.appendingPathComponent("SignIn.js")
        return try await evaluate(try String(contentsOf: url, encoding: .utf8),
                                  arguments: ["mode": mode, "token": token.uuidString, "expectedOrigin": origin, "entered": entered, "submit": submit],
                                  in: frame, world: Self.controlWorld, limit: limit)
    }

    /// Looks once, in the page and each of its frames at the same time, for the form a person would sign in
    /// with: the one holding the focused field, or else the likeliest. Nothing keeps watching the page afterwards.
    func findSignIn() async throws -> BrowserSignInForm {
        if botScriptedDocument { throw BrowserError(Self.signInBotScripted) }
        if dialog != nil { throw BrowserError(Self.signInDialog) }
        let token = UUID()
        // A frame registers again each time its document starts, so the same one can be listed more than once.
        var seen = Set<ObjectIdentifier>()
        let others = frames.filter { $0.key != "main" }.sorted { $0.key < $1.key }.map(\.value)
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
        let candidates: [WKFrameInfo?] = [nil] + others.map { Optional($0) }
        var answers = [[String: Any]?](repeating: nil, count: candidates.count)
        await withTaskGroup(of: (Int, [String: Any]?).self) { group in
            for (index, frame) in candidates.enumerated() {
                group.addTask { @MainActor in
                    // A frame that has gone or does not answer in time has no form to offer.
                    (index, try? await self.signInScript("find", in: frame, token: token, limit: Self.signInFrameLimit) as? [String: Any])
                }
            }
            for await (index, answer) in group { answers[index] = answer }
        }
        var best: (frame: WKFrameInfo?, origin: String, score: Double, fields: [BrowserSignInField])?
        var pageOrigin: String?
        var documents = Set<String>()
        for (index, found) in answers.enumerated() {
            guard let found else { continue }
            let origin = found["origin"] as? String ?? "null"
            if index == 0 { pageOrigin = origin }
            // Two registrations of one document answer alike; the first stands for both.
            if let document = found["document"] as? String, !documents.insert(document).inserted { continue }
            let score = (found["score"] as? NSNumber)?.doubleValue ?? 0
            let fields = (found["fields"] as? [[String: Any]] ?? []).compactMap { field -> BrowserSignInField? in
                guard let kind = (field["kind"] as? String).flatMap(BrowserSignInField.Kind.init(rawValue:)) else { return nil }
                let label = (field["label"] as? String).map { String($0.prefix(60)) }
                return BrowserSignInField(kind: kind, label: label?.isEmpty == false ? label : nil, length: (field["length"] as? NSNumber)?.intValue)
            }
            guard score > 0, !fields.isEmpty, score > best?.score ?? 0 else { continue }
            best = (candidates[index], origin, score, fields)
        }
        guard let best else { throw BrowserError("No sign-in fields were found on this page.") }
        signIn = (token, best.frame, best.origin)
        let site = URL(string: best.origin), page = URL(string: pageOrigin ?? "") ?? web.url
        return BrowserSignInForm(token: token, host: site?.host ?? "", pageHost: page?.host ?? "", secure: site?.scheme == "https",
                                 crossOrigin: best.origin != pageOrigin || best.origin == "null", fields: best.fields)
    }

    /// Fills the form `findSignIn` found with what a person typed or picked, then submits it if they asked.
    /// The values go straight into the page and are kept nowhere. Returns whether the form was submitted.
    func fillSignIn(_ values: BrowserSignInValues) async throws -> Bool {
        guard let found = signIn, found.token == values.token else { throw BrowserError(Self.signInChanged) }
        if botScriptedDocument { signIn = nil; throw BrowserError(Self.signInBotScripted) }
        var entered: [String: String] = [:]
        for (key, value) in [("username", values.username), ("password", values.password), ("newPassword", values.newPassword),
                             ("oneTimeCode", values.oneTimeCode)] {
            if let value, !value.isEmpty { entered[key] = value }
        }
        // Noted before filling, so a password that went in before something failed is still emptied later.
        if entered["password"] != nil || entered["newPassword"] != nil {
            signInFilled[found.frame.map { "\(ObjectIdentifier($0))" } ?? "main"] = .some(found.frame)
        }
        do {
            let result = try await signInScript("fill", in: found.frame, token: found.token, origin: found.origin, entered: entered,
                                                submit: values.submit) as? [String: Any]
            return result?["submitted"] as? Bool ?? false
        } catch let error as BrowserError where error.message == Self.signInDialog {
            throw error
        } catch {
            signIn = nil
            throw BrowserError(Self.signInChanged)
        }
    }

    /// Empties the password fields a person filled, so whoever uses the page next, a bot included, cannot read
    /// them. A dialog the page shows is dismissed first, since the page runs nothing while it waits on one.
    /// Returns false while a filled field may still hold its password; those frames stay listed.
    func clearSignIn() async -> Bool {
        signIn = nil
        for (key, frame) in signInFilled {
            if dialog != nil { answerDialog(accept: false, text: nil) }
            do {
                _ = try await signInScript("clear", in: frame)
                signInFilled.removeValue(forKey: key)
            } catch {}
        }
        return signInFilled.isEmpty
    }

    func move(target: String?, x: Double?, y: Double?, frame: String?) async throws {
        surfaceUsers += 1; defer { surfaceUsers -= 1 }
        let generation = inputGeneration
        var point: CGPoint
        if let target {
            let url = BrowserResources.bundle.url(forResource: "Resources", withExtension: nil)!.appendingPathComponent("PointerTarget.js")
            let source = try String(contentsOf: url, encoding: .utf8)
            guard let result = try await evaluate(source, arguments: ["target": target], frame: frame, world: Self.controlWorld) as? [String: Double],
                  let px = result["x"], let py = result["y"] else { throw BrowserError("Could not resolve the mouse target.") }
            point = CGPoint(x: px * web.pageZoom, y: py * web.pageZoom)
        } else if let x, let y { point = CGPoint(x: x, y: y) }
        else if let current = pointer.position { point = current }
        else { throw BrowserError("Specify --target or --x and --y, or move the mouse first.") }
        guard !stopped, generation == inputGeneration else { throw BrowserError("Page or pointer control changed. Inspect the page before retrying.") }
        guard (try runtime?.library.profile(browserID).paused) == false else { throw BrowserError("Agent control is paused for this browser.") }
        if dialog != nil { throw BrowserError("A page dialog is pending. Use dialog before continuing.") }
        try pointer.move(to: point)
    }
    func click(target: String?, x: Double?, y: Double?, frame: String?, count: Int = 1) async throws {
        surfaceUsers += 1; defer { surfaceUsers -= 1 }
        guard !pointer.pressed else { throw BrowserError("Mouse is already pressed.") }
        try await move(target: target, x: x, y: y, frame: frame)
        for number in 1...count { try pointer.down(count: number); try pointer.up(count: number) }
    }
    func press(_ key: String) throws {
        surfaceUsers += 1; defer { surfaceUsers -= 1 }
        let keys: [String: (String, UInt16)] = ["Enter": ("\r",36), "Tab": ("\t",48), "Escape": ("\u{1b}",53), "Backspace": ("\u{7f}",51), "Space": (" ",49), "ArrowLeft": ("\u{f702}",123), "ArrowRight": ("\u{f703}",124), "ArrowDown": ("\u{f701}",125), "ArrowUp": ("\u{f700}",126)]
        guard let (characters, code) = keys[key], let window = web.window else { throw BrowserError("Unsupported key or unavailable tab.") }
        if let view = window.firstResponder as? NSView, view !== web, !view.isDescendant(of: web) {
            window.makeFirstResponder(web)
        }
        let responder: NSResponder
        if let view = window.firstResponder as? NSView, view === web || view.isDescendant(of: web) { responder = view }
        else { responder = web }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            if type == .keyDown { responder.keyDown(with: event) } else { responder.keyUp(with: event) }
        }
    }
    /// The tab as a person watching it remotely sees it, pointer included, and its size in points.
    func surfacePicture() async throws -> (image: CGImage, size: CGSize) {
        let pointerState = pointer.state
        let config = WKSnapshotConfiguration(); config.rect = web.bounds; config.afterScreenUpdates = false
        let viewport = config.rect.size
        let image: NSImage = try await bounded { finish in
            self.web.takeSnapshot(with: config) { image, error in
                if let image { finish(.success(image)) } else { finish(.failure(error ?? BrowserError("The tab cannot be shown."))) }
            }
        }
        let annotated = pointer.annotate(image, state: pointerState, viewport: viewport)
        guard let picture = annotated.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw BrowserError("Could not capture the tab.")
        }
        return (picture, viewport)
    }

    /// What a person watching remotely did, as real events in the tab, the same way Noodle
    /// Computer and Noodle Applet take it.
    func apply(_ input: SurfaceInput) throws {
        surfaceUsers += 1; defer { surfaceUsers -= 1 }
        humanInput = false; viewerInput = true
        if surfaceInjector == nil { surfaceInjector = SurfaceEventInjector(view: web) }
        try surfaceInjector?.deliver(input)
    }

    func snapshot() async throws -> Data {
        let pointerState = pointer.state
        let config = WKSnapshotConfiguration(); config.rect = web.bounds; config.afterScreenUpdates = false
        let viewport = config.rect.size
        let image: NSImage = try await bounded { finish in
            self.web.takeSnapshot(with: config) { image, error in
                if let image { finish(.success(image)) } else { finish(.failure(error ?? BrowserError("Screenshot unavailable."))) }
            }
        }
        guard let tiff = pointer.annotate(image, state: pointerState, viewport: viewport).tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw BrowserError("Could not encode screenshot.") }
        return png
    }
    private func bounded<T>(limit: Duration = .seconds(20), _ start: (@escaping @MainActor @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        guard !stopped else { throw BrowserError("Tab is closed.") }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let box = BrowserOperationResult(continuation)
            operations[id] = { box.finish(.failure(BrowserError("Browser operation interrupted."))) }
            let timer = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                self?.operations.removeValue(forKey: id)
                box.finish(.failure(BrowserError("Browser operation timed out. Inspect its state before retrying.")))
            }
            start { [weak self] result in timer.cancel(); self?.operations.removeValue(forKey: id); box.finish(result) }
        }
    }
}
@MainActor private final class BrowserOperationResult<T> {
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) { let value = continuation; continuation = nil; value?.resume(with: result) }
}

/// Keeps a Finder drop readable for WebKit while the sandboxed browser copies it onto the page.
final class BrowserPageWebView: WKWebView {
    private var scoped: [URL] = []

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hold(sender.draggingPasteboard)
        return super.draggingEntered(sender)
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hold(sender.draggingPasteboard)
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hold(sender.draggingPasteboard)
        let accepted = super.performDragOperation(sender)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.releaseScoped()
        }
        return accepted
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        releaseScoped()
        super.draggingExited(sender)
    }

    private func hold(_ pasteboard: NSPasteboard) {
        releaseScoped()
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in urls where url.startAccessingSecurityScopedResource() { scoped.append(url) }
    }
    private func releaseScoped() {
        scoped.forEach { $0.stopAccessingSecurityScopedResource() }
        scoped.removeAll()
    }
}

/// Finds and fetches the icon a page names for itself.
enum BrowserFavicon {
    /// The page's `<link>` elements, as `choose` reads them.
    static let script = """
        return [...document.querySelectorAll('link[rel][href]')].slice(0, 200)
            .map(l => ({rel: l.rel, href: l.href, sizes: l.getAttribute('sizes') || '', type: l.type || ''}))
        """
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// The icon that suits a tab best: the smallest of at least 32 pixels, then any other, an Apple
    /// touch icon only when nothing else, and the site's favicon.ico without any. SVG icons are left
    /// out, since decoding one would run an SVG parser outside WebKit's sandbox.
    static func choose(_ links: [[String: String]], page: URL) -> URL? {
        guard ["http", "https"].contains(page.scheme?.lowercased() ?? ""), page.host != nil else { return nil }
        func rank(_ link: [String: String]) -> (url: URL, rank: [Int])? {
            let rel = Set((link["rel"] ?? "").lowercased().split(separator: " "))
            let touch = rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed")
            guard rel.contains("icon") || touch, let url = URL(string: link["href"] ?? "", relativeTo: page)?.absoluteURL,
                  ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            guard link["type"]?.lowercased() != "image/svg+xml", url.pathExtension.lowercased() != "svg",
                  !url.absoluteString.lowercased().hasPrefix("data:image/svg") else { return nil }
            let sizes = (link["sizes"] ?? "").lowercased()
            let side = sizes.split(separator: " ").compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }.max()
            guard let side else { return (url, [touch ? 1 : 0, 2, 0]) }
            return (url, side >= 32 ? [touch ? 1 : 0, 1, side] : [touch ? 1 : 0, 3, -side])
        }
        if let best = links.compactMap(rank).min(by: { $0.rank.lexicographicallyPrecedes($1.rank) }) { return best.url }
        var site = URLComponents(); site.scheme = page.scheme; site.host = page.host; site.port = page.port; site.path = "/favicon.ico"
        return site.url
    }

    /// The image at `url`, if it is a raster image of at most a megabyte, scaled down to at most
    /// 128 pixels as it is decoded. Reading stops past the megabyte. No cookies are sent or kept.
    static func load(_ url: URL, using session: URLSession = session) async -> NSImage? {
        guard let data = await LimitedRead(limit: 1 << 20).data(from: url, using: session) else { return nil }
        let raster: Set<String> = ["public.png", "com.microsoft.ico", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp"]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String?,
              raster.contains(type), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 128,
                  kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

/// Reads a response chunk by chunk and cancels it once it passes the limit, so a huge or endless
/// response never collects in memory.
private final class LimitedRead: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data(), finish: CheckedContinuation<Data?, Never>?
    init(limit: Int) { self.limit = limit }

    func data(from url: URL, using session: URLSession) async -> Data? {
        await withCheckedContinuation { continuation in
            lock.withLock { finish = continuation }
            let task = session.dataTask(with: url); task.delegate = self; task.resume()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        ((response as? HTTPURLResponse)?.statusCode ?? 200) < 300 && response.expectedContentLength <= limit ? .allow : .cancel
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = lock.withLock { self.data.append(data); return self.data.count > limit }
        if over { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, data) = lock.withLock { defer { finish = nil }; return (finish, self.data) }
        continuation?.resume(returning: error == nil && data.count <= limit ? data : nil)
    }
}

/// What a tab says, as browsers do, when its page could not load or its process stopped.
struct BrowserPageFailure: Equatable {
    let symbol: String
    let title: String
    let detail: String

    static let stopped = BrowserPageFailure(symbol: "exclamationmark.triangle", title: "This page stopped working",
                                            detail: "Something went wrong while showing this page.")

    init(symbol: String, title: String, detail: String) { self.symbol = symbol; self.title = title; self.detail = detail }

    init(_ error: Error, url: URL?) {
        let error = error as NSError, site = url?.host ?? "This site"
        guard error.domain == NSURLErrorDomain else {
            self.init(symbol: "exclamationmark.triangle", title: "Can't open this page", detail: error.localizedDescription); return
        }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            self.init(symbol: "wifi.slash", title: "No internet connection", detail: "Check your network and try again.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            self.init(symbol: "globe", title: "Can't find this site", detail: "The server address of \(site) could not be found.")
        case NSURLErrorCannotConnectToHost:
            self.init(symbol: "globe", title: "Can't reach this site", detail: "\(site) refused to connect.")
        case NSURLErrorTimedOut:
            self.init(symbol: "clock", title: "Can't reach this site", detail: "\(site) took too long to respond.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            self.init(symbol: "lock.slash", title: "Can't connect securely", detail: "\(site) did not offer a connection that could be trusted.")
        default:
            self.init(symbol: "exclamationmark.triangle", title: "Can't open this page", detail: error.localizedDescription)
        }
    }
}

/// A tab's own window, holding its page while no browser window shows it. It goes on screen only
/// for a live view or while a bot uses the tab, transparent and at the back. Something else once left one on screen, opaque,
/// showing a bot's page on the desktop, and was never found, so every other request is refused
/// and logged with whoever made it.
final class BrowserSurfacePanel: NSPanel {
    private static let log = Logger(subsystem: "com.pdparchitect.noodle.browser", category: "surface")
    private var showing = false

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        super.alphaValue = 0
        ignoresMouseEvents = true
    }
    /// Transparent for good, so no order of going on or off screen, or of the window server applying
    /// it, can ever show the page, as a window turned opaque whenever it was off screen could.
    override var alphaValue: CGFloat {
        get { super.alphaValue }
        set { super.alphaValue = 0 }
    }
    /// Windows a page puts up beside itself, such as a form's validation message, are as transparent and
    /// take no clicks: on screen with this window, they would show a bot's page on the desktop.
    override func addChildWindow(_ child: NSWindow, ordered place: NSWindow.OrderingMode) {
        child.alphaValue = 0; child.ignoresMouseEvents = true
        super.addChildWindow(child, ordered: place)
    }

    func showUnseen() {
        showing = true; defer { showing = false }
        orderBack(nil)
    }
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
        guard place == .out || showing else { return refuse() }
        super.order(place, relativeTo: otherWindow)
    }
    // The one way on screen that does not pass through order(_:relativeTo:).
    override func orderFrontRegardless() {
        guard showing else { return refuse() }
        super.orderFrontRegardless()
    }
    private func refuse() {
        Self.log.error("Kept a tab's window off screen. Asked by: \(Thread.callStackSymbols.joined(separator: "\n"), privacy: .public)")
    }
}
