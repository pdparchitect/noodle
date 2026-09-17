import AppKit
import BrowserBridge
import WebKit

/// Each tab has an app-owned rendering surface. Events go directly to this view,
/// never to the system event stream or another application's window.
@MainActor final class BrowserTab: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id: UUID
    let browserID: UUID
    let web: WKWebView
    let pointer: BrowserPointer
    let surface: NSPanel
    weak var runtime: BrowserRuntime?
    @Published var info: BrowserTabInfo
    @Published var dialog: BrowserDialog?
    private var replyToDialog: ((Bool, String?) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private(set) var frames: [String: WKFrameInfo] = [:]
    var webMCPAllowed = true
    var webMCPFramePolicies: [String: Bool] = [:]
    private var upload: (id: UUID, urls: [URL], provided: Bool, origin: String, mainFrame: Bool, continuation: CheckedContinuation<Void, Error>)?
    private var operations: [UUID: () -> Void] = [:]
    private var stopped = false
    private var finishedDocument = false
    private var visitID: UUID?
    private var visitedURL: String?
    private var visitedTitle: String?
    private var humanInput = false
    private var inputMonitor: Any?
    private var inputGeneration = 0
    static let controlWorld = WKContentWorld.world(name: "NoodleBrowserControl")

    init(browserID: UUID, info: BrowserTabInfo, runtime: BrowserRuntime, configuration: WKWebViewConfiguration? = nil) {
        self.id = info.id; self.browserID = browserID; self.info = info; self.runtime = runtime
        let config = configuration ?? WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        BrowserWebMCP.install(into: config.userContentController)
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: browserID)
        config.preferences.inactiveSchedulingPolicy = .none
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        pointer = BrowserPointer(web: web)
        surface = NSPanel(contentRect: web.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        surface.isReleasedWhenClosed = false
        surface.hidesOnDeactivate = false
        surface.contentView = web
        web.navigationDelegate = self; web.uiDelegate = self
        web.setAllMediaPlaybackSuspended((try? runtime.library.profile(browserID).muted) ?? true, completionHandler: nil)
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self, event.window === self.web.window, event.window?.isVisible == true else { return event }
            if event.type != .keyDown {
                if self.web.bounds.contains(self.web.convert(event.locationInWindow, from: nil)) {
                    self.resetPointer()
                    if event.type == .leftMouseDown { self.humanInput = true }
                }
            } else if let view = event.window?.firstResponder as? NSView, view === self.web || view.isDescendant(of: self.web) {
                self.resetPointer()
                self.humanInput = true
            }
            return event
        }
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = true
        config.userContentController.add(self, contentWorld: Self.controlWorld, name: "frameReady")
        config.userContentController.addUserScript(WKUserScript(source: "window.webkit.messageHandlers.frameReady.postMessage(null)", injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.controlWorld))
        observations = [web.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } },
                        web.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } },
                        web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.update() } }]
    }
    func update() {
        guard !stopped else { return }
        info.url = web.url?.absoluteString ?? info.url
        info.title = web.title?.isEmpty == false ? web.title! : (web.url?.host ?? "New Tab")
        info.loading = web.isLoading
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
    func beginAgentInteraction() { humanInput = false }
    func resetPointer() { inputGeneration += 1; pointer.reset() }
    func mute(_ muted: Bool) async { await web.setAllMediaPlaybackSuspended(muted) }
    func restoreSurface() {
        if !stopped && web.window == nil {
            // Keep the visible tab's viewport when parking it for background
            // automation. Resetting it on every switch reflows responsive pages.
            let size = web.frame.size
            surface.contentView = nil
            surface.setContentSize(size)
            surface.contentView = web
            web.setFrameOrigin(.zero)
        }
    }
    func detachSurface() {
        if let window = web.window, let responder = window.firstResponder as? NSView,
           responder === web || responder.isDescendant(of: web) {
            window.makeFirstResponder(nil)
        }
        web.removeFromSuperview()
    }
    func navigate(_ url: URL) {
        info.error = nil
        web.load(URLRequest(url: url))
    }
    func stop() {
        resetPointer()
        stopped = true
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
        frames.removeAll(); info.error = nil; update()
        if dialog != nil { answerDialog(accept: false, text: nil) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishedDocument = true; update() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        info.error = error.localizedDescription; info.loading = false; runtime?.saveTab(self)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resetPointer()
        failed(BrowserError("Page process stopped. Reload this tab to continue."))
        let pending = operations.values; operations.removeAll(); pending.forEach { $0() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "") else {
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
        do { return try runtime?.makeTab(browserID: browserID, configuration: configuration).web }
        catch { runtime?.failure = error.localizedDescription; return nil }
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
            completionHandler(nil)
            info.error = "Use the upload command to provide files."; runtime?.saveTab(self); return
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
        return try await bounded { finish in
            self.web.callAsyncJavaScript(source, arguments: arguments, in: selected, in: world ?? .page, completionHandler: finish)
        }
    }
    func inspect(frame: String?) async throws -> String {
        let url = Bundle.module.url(forResource: "Resources", withExtension: nil)!.appendingPathComponent("Inspect.js")
        let source = try String(contentsOf: url, encoding: .utf8)
        let value = try await evaluate(source, frame: frame, world: Self.controlWorld)
        var result = value as? [String: Any] ?? [:]
        result["frames"] = frames.map { ["id": $0.key, "url": $0.value.request.url?.absoluteString ?? "", "main": $0.value.isMainFrame] as [String: Any] }
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }
    func move(target: String?, x: Double?, y: Double?, frame: String?) async throws {
        let generation = inputGeneration
        var point: CGPoint
        if let target {
            let url = Bundle.module.url(forResource: "Resources", withExtension: nil)!.appendingPathComponent("PointerTarget.js")
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
        guard !pointer.pressed else { throw BrowserError("Mouse is already pressed.") }
        try await move(target: target, x: x, y: y, frame: frame)
        for number in 1...count { try pointer.down(count: number); try pointer.up(count: number) }
    }
    func press(_ key: String) throws {
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
    private func bounded<T>(_ start: (@escaping @MainActor @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        guard !stopped else { throw BrowserError("Tab is closed.") }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let box = BrowserOperationResult(continuation)
            operations[id] = { box.finish(.failure(BrowserError("Browser operation interrupted."))) }
            let timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
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
