import Foundation
@_exported import NoodletFormat
import ObjectiveC
import WebKit

#if canImport(AppKit)
import AppKit
public typealias NoodletImage = NSImage
#else
import UIKit
public typealias NoodletImage = UIImage
#endif

/// What the app running a page adds for where it runs, such as a window, file dialogs or the
/// sound a recording hears.
@MainActor public protocol NoodletPageHost: AnyObject {
    /// Answers a page operation the runtime leaves to its app. Throw `NoodletPage.unknownOperation`
    /// for one this app does not have.
    func perform(_ operation: String, body: [String: Any]) async throws -> Any
}

/// A noodlet's page in a web view confined to it: only its own folder loads, only its main page
/// reaches the bridge, the web is closed unless its manifest opens it, and a camera or microphone
/// is offered only when declared. Its data and secrets go to a `NoodletStore`; what depends on
/// the app goes to its `host`.
@MainActor public final class NoodletPage: NSObject, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandlerWithReply
{
    public static let unknownOperation = AppletError("Unknown bridge operation.")
    /// What every page may use; an app adds its own, such as "files" or "window".
    public static let commonFeatures = ["storage", "data", "secrets"]

    public let root: URL
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
    private let network = WebNetwork()
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimer: Task<Void, Never>?
    private var cancellations: [UUID: () -> Void] = [:]
    public private(set) var stopped = false

    /// `configure` adds the app's own scripts ahead of the bridge.
    public init(root: URL, manifest: NoodletManifest, store: any NoodletStore, dataStore: WKWebsiteDataStore,
                frame: CGRect = .zero, features: [String] = [], log: @escaping (String, String) -> Void,
                configure: (WKWebViewConfiguration) -> Void = { _ in }) {
        self.root = root.standardizedFileURL
        self.manifest = manifest
        self.store = store
        self.log = log
        self.features = Self.commonFeatures + (manifest.network ? ["network"] : []) + features
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configure(configuration)
        web = WKWebView(frame: frame, configuration: configuration)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        // The page sees the look its manifest asks for, else the device's.
        #if canImport(AppKit)
        web.appearance = manifest.theme == .dark ? NSAppearance(named: .darkAqua) : manifest.theme == .light ? NSAppearance(named: .aqua) : nil
        #else
        web.overrideUserInterfaceStyle = manifest.theme == .dark ? .dark : manifest.theme == .light ? .light : .unspecified
        #endif
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "noodle")
        let listed = (try? JSONSerialization.data(withJSONObject: self.features)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        configuration.userContentController.addUserScript(WKUserScript(
            source: "(() => { const features = \(listed);\n\(Self.bridge)\n})();",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    static let bridge: String = {
        guard let url = Bundle.module.url(forResource: "Bridge", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    static let closedWebRules =
        "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}},{\"trigger\":{\"url-filter\":\"^wss?://\"},\"action\":{\"type\":\"block\"}}]"

    /// Loads the entry page, returning once it has.
    public func load() async throws {
        if !manifest.network {
            let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "noodlet-local-v1", encodedContentRuleList: Self.closedWebRules)
            if let list { web.configuration.userContentController.add(list) }
        }
        let entry = try NoodletPath.child(manifest.entry, in: root)
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            loadTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finishLoad(AppletError("Page did not finish loading within 20 seconds. Inspect logs, then restart."))
            }
            web.loadFileURL(entry, allowingReadAccessTo: root)
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        network.stop()
        let pending = cancellations.values
        cancellations.removeAll()
        for cancel in pending { cancel() }
        finishLoad(AppletError("Noodlet stopped."))
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
        web.configuration.userContentController.removeScriptMessageHandler(forName: "noodle", contentWorld: .page)
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

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad() }

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
        let local = url.isFileURL && url.standardizedFileURL.path.hasPrefix(root.path + "/")
        // Keep the privileged page on its package origin. Remote content belongs in a browser.
        decisionHandler(local || url.absoluteString == "about:blank" ? .allow : .cancel)
    }

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
    #endif

    /// The bridge dispatch, split from the WebKit callback so it can be exercised without a
    /// WKScriptMessage, which has no public initializer. Returns the (value, error) pair the page receives.
    public func handleBridge(operation: String, body: [String: Any]) async -> (Any?, String?) {
        do {
            switch operation {
            case "fetch":
                return (try await network.fetch(body, enabled: manifest.network), nil)
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
    public nonisolated static func isTrustedBridgeSource(isMainFrame: Bool, url: URL?, packagePath: String) -> Bool {
        guard isMainFrame, let url, url.isFileURL, url.standardizedFileURL.path.hasPrefix(packagePath + "/") else { return false }
        return true
    }

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard Self.isTrustedBridgeSource(isMainFrame: message.frameInfo.isMainFrame, url: message.frameInfo.request.url,
                                         packagePath: root.path),
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
