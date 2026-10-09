import Foundation
@_exported import NoodletFormat
import ObjectiveC
import WebKit

#if canImport(AppKit)
import AppKit
public typealias NoodletImage = NSImage
public typealias NoodletColor = NSColor
#else
import UIKit
public typealias NoodletImage = UIImage
public typealias NoodletColor = UIColor
#endif

/// What the app running a page adds for where it runs, such as a window, file dialogs or the
/// sound a recording hears.
@MainActor public protocol NoodletPageHost: AnyObject {
    /// Answers a page operation the runtime leaves to its app. Throw `NoodletPage.unknownOperation`
    /// for one this app does not have.
    func perform(_ operation: String, body: [String: Any]) async throws -> Any
}

/// A noodlet's page in a web view confined to it: only its own folder loads, only its main page
/// reaches the bridge, the public web is open but this device and its network only when allowed,
/// and a camera or microphone is offered only when declared. Its data and secrets go to a `NoodletStore`; what depends on
/// the app goes to its `host`.
@MainActor public final class NoodletPage: NSObject, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandlerWithReply
{
    public static let unknownOperation = AppletError("Unknown bridge operation.")
    /// What every page may use; an app adds its own, such as "files" or "window".
    public static let commonFeatures = ["storage", "data", "secrets", "network"]

    public let root: URL
    /// `root` with its links resolved, as the package is served from it.
    private let served: URL
    private let package: NoodletPackageScheme
    public let manifest: NoodletManifest
    public let web: WKWebView
    /// What `noodle.features` lists for the page to check before it relies on something.
    public let features: [String]
    public weak var host: NoodletPageHost?
    /// How a declared camera or microphone is offered: WebKit's own question, or granted where the
    /// person agreed before the page loaded.
    public var declaredCapture = WKPermissionDecision.prompt
    public var failed: ((String) -> Void)?
    private let store: any NoodletStore
    private let log: (String, String) -> Void
    private let network: WebNetwork
    private let localNetwork: Bool
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimer: Task<Void, Never>?
    private var cancellations: [UUID: () -> Void] = [:]
    /// What the page downloads, on its way to where the person chooses.
    private lazy var downloads = NoodletDownloads(web: web, log: log)
    public private(set) var stopped = false
    /// Whether the page is starting or not responding, for the app to show.
    public let activity = NoodletActivity()
    /// Whether the page paints its own background once it has drawn, as on the web; until then
    /// what is behind it shows.
    public var opaque = true
    var responsiveness = NoodletResponsiveness()
    /// How often the page is asked whether it is still answering.
    var beat = Duration.seconds(1)
    private var watching: Task<Void, Never>?
    private let drawnHandler = NoodletDrawnHandler()

    /// `configure` adds the app's own scripts ahead of the bridge. `localNetwork` is whether the
    /// person allowed the noodlet this device and the network it is on, as it declared.
    public init(root: URL, manifest: NoodletManifest, store: any NoodletStore, dataStore: WKWebsiteDataStore,
                frame: CGRect = .zero, features: [String] = [], localNetwork: Bool = false,
                log: @escaping (String, String) -> Void, configure: (WKWebViewConfiguration) -> Void = { _ in }) {
        self.root = root.standardizedFileURL
        served = root.standardizedFileURL.resolvingSymlinksInPath()
        package = NoodletPackageScheme(root: served)
        self.manifest = manifest
        self.store = store
        network = WebNetwork(localNetwork: localNetwork)
        self.localNetwork = localNetwork
        self.log = log
        self.features = Self.commonFeatures + (localNetwork ? ["local-network"] : []) + features
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.setURLSchemeHandler(package, forURLScheme: NoodletPackageScheme.scheme)
        configure(configuration)
        web = WKWebView(frame: frame, configuration: configuration)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        // Until the page draws, what is behind it shows rather than a blank white page.
        #if canImport(AppKit)
        if web.responds(to: NSSelectorFromString("_setDrawsBackground:")) { web.setValue(false, forKey: "drawsBackground") }
        #else
        web.isOpaque = false
        #endif
        // The page sees the look its manifest asks for, else the device's.
        let background = manifest.backgroundColor.flatMap(Self.colour)
        #if canImport(AppKit)
        web.appearance = manifest.theme == .dark ? NSAppearance(named: .darkAqua) : manifest.theme == .light ? NSAppearance(named: .aqua) : nil
        if let background { web.underPageBackgroundColor = background }
        #else
        web.overrideUserInterfaceStyle = manifest.theme == .dark ? .dark : manifest.theme == .light ? .light : .unspecified
        if let background {
            web.isOpaque = false
            web.backgroundColor = background
            web.scrollView.backgroundColor = background
            web.underPageBackgroundColor = background
        }
        if manifest.display?.fitsView == true {
            // An app stays put in its view; what scrolls inside the page still scrolls.
            web.scrollView.isScrollEnabled = false
            web.scrollView.bounces = false
            web.scrollView.pinchGestureRecognizer?.isEnabled = false
            web.scrollView.contentInsetAdjustmentBehavior = .never
        }
        #endif
        if let presentation = Self.presentation(of: manifest) {
            configuration.userContentController.addUserScript(WKUserScript(
                source: presentation, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        // The package's scripts get SharedArrayBuffer as they are served; scripts in its pages get it here.
        configuration.userContentController.addUserScript(WKUserScript(
            source: NoodletPackageScheme.sharedArrayBuffer, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "noodle")
        drawnHandler.page = self
        configuration.userContentController.add(drawnHandler, contentWorld: .defaultClient, name: NoodletDrawnHandler.name)
        configuration.userContentController.addUserScript(WKUserScript(
            source: NoodletDrawnHandler.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.addUserScript(WKUserScript(
            source: NoodletDownloads.linkNames, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        let listed = (try? JSONSerialization.data(withJSONObject: self.features)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        configuration.userContentController.addUserScript(WKUserScript(
            source: "(() => { const features = \(listed);\n\(Self.bridge)\n})();",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// What the page is given to present itself as its manifest says: its background colour, and
    /// for an app the styles and viewport that keep it to its view. They carry no weight in the
    /// page's own styles, so it can take back what it wants, such as selectable text in a field.
    static func presentation(of manifest: NoodletManifest) -> String? {
        var style = ""
        if let colour = manifest.backgroundColor, NoodletManifest.isHexColour(colour) {
            style += ":where(:root){background-color:\(colour)}"
        }
        var viewport: String?
        if manifest.display?.fitsView == true {
            style += ":where(html,body){overscroll-behavior:none;-webkit-user-select:none;user-select:none;"
                + "-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent;touch-action:manipulation}"
            // Laid out for a desktop window, it keeps that window's width, scaled to fit the view.
            if (manifest.layout ?? .desktop) == .desktop {
                let width = Int((manifest.window ?? NoodletWindowOptions()).size(width: nil, height: nil).width)
                viewport = "width=\(width), user-scalable=no, viewport-fit=cover"
            } else {
                viewport = "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover"
            }
        }
        guard !style.isEmpty || viewport != nil else { return nil }
        var script = "const style = document.createElement('style'); style.textContent = \(Self.quoted(style));"
            + " document.documentElement.prepend(style);"
        if let viewport {
            // After the page's own, which it replaces: the last one counts.
            script += " const fit = () => { const meta = document.createElement('meta'); meta.name = 'viewport';"
                + " meta.content = \(Self.quoted(viewport)); document.head.append(meta); };"
                + " if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fit); else fit();"
        }
        return "(() => { \(script) })();"
    }

    private static func quoted(_ text: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8), as: UTF8.self)
            .dropFirst().dropLast().description
    }

    /// A manifest's hex colour for the view behind the page.
    public static func colour(_ hex: String) -> NoodletColor? {
        guard NoodletManifest.isHexColour(hex) else { return nil }
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard let value = UInt32(digits, radix: 16) else { return nil }
        let channel = { (shift: UInt32) in CGFloat((value >> shift) & 0xFF) / 255 }
        return NoodletColor(red: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }

    static let bridge: String = {
        guard let url = Bundle.module.url(forResource: "Bridge", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// Loads the entry page, returning once it has.
    public func load() async throws {
        if responsiveness.began == nil {
            responsiveness.began = .now
            watch()
        }
        if !localNetwork {
            let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "noodlet-local-network-v1", encodedContentRuleList: NoodletManifest.localNetworkRules)
            if let list { web.configuration.userContentController.add(list) }
        }
        // A missing entry fails here, rather than loading as a page that says so.
        _ = try NoodletPath.open(manifest.entry, in: served)
        let entry = try NoodletPackageScheme.url(manifest.entry)
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            loadTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finishLoad(AppletError("Page did not finish loading within 20 seconds. Inspect logs, then restart."))
            }
            web.load(URLRequest(url: entry))
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        network.stop()
        package.discardResponses()
        let pending = cancellations.values
        cancellations.removeAll()
        for cancel in pending { cancel() }
        finishLoad(AppletError("Noodlet stopped."))
        watching?.cancel()
        watching = nil
        downloads.cancelAll()
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
        web.configuration.userContentController.removeScriptMessageHandler(forName: "noodle", contentWorld: .page)
        web.configuration.userContentController.removeScriptMessageHandler(forName: NoodletDrawnHandler.name, contentWorld: .defaultClient)
        web.navigationDelegate = nil
        web.uiDelegate = nil
    }

    private func finishLoad(_ error: Error? = nil) {
        loadTimer?.cancel()
        loadTimer = nil
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if loadContinuation != nil, let began = responsiveness.began { log("lifecycle", "Loaded \((.now - began).spoken) after loading began.") }
        finishLoad()
        // Out of sight a page never draws; it counts as drawn once it has loaded.
        if !onScreen { drew() }
    }

    private var onScreen: Bool {
        #if canImport(AppKit)
        web.window?.isVisible == true
        #else
        web.window != nil
        #endif
    }

    /// Asks the page a question on every beat, in a world of the app's own. A page busy in its
    /// script answers only once it is done.
    private func watch() {
        // Holds the page only for each beat, so a closed one goes at once.
        watching = Task { [weak self] in
            while !Task.isCancelled, let beat = self?.ask() { try? await Task.sleep(for: beat) }
        }
    }

    /// Asks unless a question is still unanswered, and returns how long until the next beat.
    private func ask() -> Duration {
        if responsiveness.asked == nil {
            responsiveness.asked = .now
            web.evaluateJavaScript("0", in: nil, in: .defaultClient) { [weak self] _ in
                self?.responsiveness.asked = nil
                self?.noticeMayChange()
            }
        }
        noticeMayChange()
        return beat
    }

    /// The page's first frame is on screen.
    func drew() {
        guard !activity.drawn, !stopped else { return }
        activity.drawn = true
        responsiveness.drawn = true
        if let began = responsiveness.began { log("rendering", "First frame \((.now - began).spoken) after loading began.") }
        if opaque {
            #if canImport(AppKit)
            if web.responds(to: NSSelectorFromString("_setDrawsBackground:")) { web.setValue(true, forKey: "drawsBackground") }
            #else
            if manifest.backgroundColor.flatMap(Self.colour) == nil { web.isOpaque = true }
            #endif
        }
        noticeMayChange()
    }

    private func noticeMayChange() {
        let notice = stopped ? nil : responsiveness.notice(at: .now)
        guard notice != activity.notice else { return }
        if notice == .notResponding { log("lifecycle", "Not responding.") }
        else if activity.notice == .notResponding { log("lifecycle", "Responding again.") }
        activity.notice = notice
        activity.noticeChanged?(notice)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("navigation", error.localizedDescription)
        finishLoad(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("navigation", error.localizedDescription)
        finishLoad(error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let message = "WebKit content process terminated. Restart the noodlet to recover."
        log("crash", message)
        finishLoad(AppletError(message))
        failed?(message)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        // Keep the privileged page on its package origin. Remote content belongs in a browser.
        switch NoodletNavigation.decide(url, shouldPerformDownload: navigationAction.shouldPerformDownload,
                                        linkActivated: navigationAction.navigationType == .linkActivated,
                                        mainFrame: Self.fromMainFrame(navigationAction)) {
        case .allow: decisionHandler(.allow)
        case .download where NoodletPackageScheme.contains(url):
            decisionHandler(.cancel)
            let frame: WKFrameInfo? = navigationAction.sourceFrame
            Task { [weak self] in
                guard let self else { return }
                downloads.save(String(url.path.dropFirst()), in: served, named: await NoodletDownloads.name(of: url, in: frame, of: web))
            }
        case .download: decisionHandler(.download)
        case .openExternally:
            openExternally(url)
            decisionHandler(.cancel)
        case .cancel: decisionHandler(.cancel)
        }
    }

    /// What WebKit cannot show, or is sent as an attachment, is saved rather than shown.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let attachment = disposition.lowercased().hasPrefix("attachment")
        decisionHandler(!navigationResponse.canShowMIMEType || attachment ? .download : .allow)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.receive(download)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.receive(download)
    }

    /// The page never opens windows of its own: a new window is a web link for the person's browser.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // WebKit only asks for a window after a click, unless the page may open them itself, which it may not.
        if let url = navigationAction.request.url,
           NoodletNavigation.decide(url, shouldPerformDownload: false, linkActivated: true,
                                    mainFrame: Self.fromMainFrame(navigationAction)) == .openExternally {
            openExternally(url)
        }
        return nil
    }

    private func openExternally(_ url: URL) {
        if !NoodletFiles.openExternally(url, over: web) {
            log("navigation", "Web links open in the browser only while the noodlet is in the foreground.")
        }
    }

    /// WebKit declares the source frame non-optional but can leave it out; read it as optional.
    private static func fromMainFrame(_ action: WKNavigationAction) -> Bool {
        let source: WKFrameInfo? = action.sourceFrame
        return source?.isMainFrame ?? false
    }

    #if os(macOS)
    /// A page's `<input type=file>` opens the Mac's file picker. iOS shows its own.
    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard NoodletFiles.seenWindow(of: webView) != nil else {
            log("files", "File inputs need the noodlet in the foreground, on the device it runs on.")
            return completionHandler(nil)
        }
        Task { completionHandler(await NoodletFiles.chooseUploads(parameters, over: webView)) }
    }
    #endif

    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                        initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let needed: Set<String> =
            switch type {
            case .microphone: ["microphone"]
            case .camera: ["camera"]
            case .cameraAndMicrophone: ["camera", "microphone"]
            @unknown default: ["unsupported"]
            }
        return needed.isSubset(of: Set(manifest.permissions ?? [])) ? declaredCapture : .deny
    }

    #if os(macOS)
    // WebKit has no public delegate for getDisplayMedia and refuses it without this
    // SPI. 1 asks the user to pick a screen; 0 denies. macOS still shows its own picker.
    public static let displayCaptureSelector = NSSelectorFromString(
        "_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:")

    /// Whether this WebKit lets a page capture the screen at all.
    public static var supportsDisplayCapture: Bool {
        objc_getProtocol("WKUIDelegatePrivate").map {
            protocol_getMethodDescription($0, displayCaptureSelector, false, true).name != nil
        } ?? false
    }

    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    public func webView(_ webView: WKWebView, requestDisplayCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedBy frame: WKFrameInfo, withSystemAudio: Bool,
                        decisionHandler: @escaping @convention(block) (Int) -> Void) {
        let allowed = manifest.permissions?.contains("screen-capture") == true
        log("permissions", "Screen capture \(allowed ? "offered to the user" : "denied; declare screen-capture in noodlet.json").")
        decisionHandler(allowed ? 1 : 0)
    }

    // WebKit refuses a page's pointer lock, which games use to turn with the mouse, unless its app
    // agrees through this SPI. It asks only after a click in a focused page, and Escape releases it.
    @objc(_webViewDidRequestPointerLock:completionHandler:)
    public func webView(_ webView: WKWebView, didRequestPointerLock completionHandler: @escaping @convention(block) (Bool) -> Void) {
        completionHandler(true)
    }
    #endif

    /// The bridge dispatch, split from the WebKit callback so it can be exercised without a
    /// WKScriptMessage, which has no public initializer. Returns the (value, error) pair the page receives.
    public func handleBridge(operation: String, body: [String: Any]) async -> (Any?, String?) {
        do {
            switch operation {
            case "fetch":
                // The body waits in a file, for the page to read from the package's own site.
                var reply = try await network.fetch(body)
                if let file = reply.removeValue(forKey: "file") as? URL {
                    if stopped { try? FileManager.default.removeItem(at: file) } else { reply["body"] = package.serve(file).absoluteString }
                }
                return (reply, nil)
            case "cancelFetch":
                if let id = body["id"] as? String { network.cancel(id) }
                return (true, nil)
            case "log":
                log(body["level"] as? String ?? "console", body["text"] as? String ?? "")
                return (true, nil)
            default:
                var message = body
                message["operation"] = operation
                if let call = NoodletStoreCall(page: message) { return (try await store.perform(call).object, nil) }
                guard let host else { throw Self.unknownOperation }
                return (try await host.perform(operation, body: body), nil)
            }
        } catch { return (nil, error.localizedDescription) }
    }

    /// Whether a bridge message really came from the noodlet's own main page.
    public nonisolated static func isTrustedBridgeSource(isMainFrame: Bool, url: URL?) -> Bool {
        isMainFrame && url.map(NoodletPackageScheme.contains) == true
    }

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard Self.isTrustedBridgeSource(isMainFrame: message.frameInfo.isMainFrame, url: message.frameInfo.request.url),
              let body = message.body as? [String: Any], let operation = body["operation"] as? String
        else { return (nil, "The bridge is available only to the noodlet's main page.") }
        return await handleBridge(operation: operation, body: body)
    }

    /// Runs `source` as the body of an async function in the page, answering with its JSON result.
    public func evaluate(_ source: String) async throws -> String {
        // callAsyncJavaScript awaits promises and preserves thrown JS errors.
        let result: Any
        do {
            result = try await bounded { finish in
                web.callAsyncJavaScript(
                    "const value = await (async () => { \(source)\n})(); return JSON.stringify(value === undefined ? null : value);",
                    arguments: [:], in: nil, in: .page, completionHandler: finish)
            }
        } catch {
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            log("javascript", detail)
            throw AppletError(detail)
        }
        guard let text = result as? String else {
            throw AppletError("JavaScript returned a value that cannot be represented as JSON.")
        }
        return text
    }

    public func snapshot() async throws -> NoodletImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = web.bounds
        configuration.afterScreenUpdates = false
        return try await bounded { finish in
            web.takeSnapshot(with: configuration) { image, error in
                if let image { finish(.success(image)) } else {
                    finish(.failure(error ?? AppletError("WebKit returned no screenshot.")))
                }
            }
        }
    }

    private func bounded<T>(_ begin: (@escaping @MainActor @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        guard !stopped else { throw AppletError("Noodlet stopped.") }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let result = OperationResult(continuation)
            cancellations[id] = { result.finish(.failure(AppletError("Noodlet stopped."))) }
            let timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.cancellations.removeValue(forKey: id)
                result.finish(.failure(AppletError("Web operation timed out. Inspect logs, terminate, or restart the noodlet.")))
            }
            begin { [weak self] value in
                timer.cancel()
                self?.cancellations.removeValue(forKey: id)
                result.finish(value)
            }
        }
    }
}

@MainActor private final class OperationResult<T> {
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
