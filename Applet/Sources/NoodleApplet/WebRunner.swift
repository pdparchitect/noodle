import AppKit
import AppletBridge
import AppletCore
import WebKit

@MainActor
final class WebRunner: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply,
  NSWindowDelegate
{
  let package: NoodletPackage
  let dataRoot: URL
  let log: AppletLog
  let web: WKWebView
  let window: NSWindow
  private var loadContinuation: CheckedContinuation<Void, Error>?
  private var loadTimer: Task<Void, Never>?
  var failed: ((String) -> Void)?
  var closed: (() -> Void)?
  private var stopped = false
  private let network = WebNetwork()
  private var dragMonitor: Any?
  private var dragEvent: NSEvent?
  private var cancellations: [UUID: () -> Void] = [:]
  init(
    package: NoodletPackage, dataRoot: URL, log: AppletLog, size: CGSize, storeID: UUID,
    rememberFrame: Bool = true
  ) {
    self.package = package
    self.dataRoot = dataRoot
    self.log = log
    let config = WKWebViewConfiguration()
    config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
    config.preferences.inactiveSchedulingPolicy = .none
    web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
    let options = package.manifest.window ?? NoodletWindowOptions()
    window = WindowPresentation.make(options, size: size)
    super.init()
    window.title = package.manifest.title
    window.isReleasedWhenClosed = false
    window.delegate = self
    if options.background != .opaque {
      web.underPageBackgroundColor = .clear
      // macOS WebKit still exposes page-background drawing through this guarded
      // SPI; underPageBackgroundColor alone only changes overscroll regions.
      if web.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
        web.setValue(false, forKey: "drawsBackground")
      } else {
        log.append("window", "This WebKit build does not support transparent page backgrounds.")
      }
    }
    WindowPresentation.apply(
      options, to: window, content: web, size: size, key: package.key, remember: rememberFrame)
    dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      if event.window === self?.window { self?.dragEvent = event }
      return event
    }
    web.navigationDelegate = self
    config.userContentController.addScriptMessageHandler(
      self, contentWorld: .page, name: "noodle")
    let scriptURL = AppletResources.bundle.url(forResource: "Resources", withExtension: nil)!
      .appendingPathComponent("Bridge.js")
    let script = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
    config.userContentController.addUserScript(
      WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
  }
  func start(foreground: Bool) async throws {
    if !package.manifest.network {
      let rules =
        "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}},{\"trigger\":{\"url-filter\":\"^wss?://\"},\"action\":{\"type\":\"block\"}}]"
      let list = try await WKContentRuleListStore.default().compileContentRuleList(
        forIdentifier: "noodlet-local-v1", encodedContentRuleList: rules)
      if let list { web.configuration.userContentController.add(list) }
    }
    if foreground { show() }
    try await withCheckedThrowingContinuation { continuation in
      loadContinuation = continuation
      loadTimer = Task { [weak self] in
        try? await Task.sleep(for: .seconds(20))
        guard !Task.isCancelled else { return }
        self?.finishLoad(
          AppletError(
            "Page did not finish loading within 20 seconds. Inspect logs, then restart."
          ))
      }
      web.loadFileURL(
        package.url.appendingPathComponent(package.manifest.entry),
        allowingReadAccessTo: package.url)
    }
  }
  func show() {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func hide() { window.orderOut(nil) }
  func stop() {
    guard !stopped else { return }
    stopped = true
    network.stop()
    if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
    dragMonitor = nil
    dragEvent = nil
    let pending = cancellations.values
    cancellations.removeAll()
    for cancel in pending { cancel() }
    finishLoad(AppletError("Noodlet stopped."))
    web.stopLoading()
    web.configuration.userContentController.removeScriptMessageHandler(
      forName: "noodle", contentWorld: .page)
    web.navigationDelegate = nil
    window.close()
    window.contentView = nil
  }
  func windowWillClose(_ notification: Notification) { if !stopped { closed?() } }
  private func finishLoad(_ error: Error? = nil) {
    loadTimer?.cancel()
    loadTimer = nil
    guard let continuation = loadContinuation else { return }
    loadContinuation = nil
    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad() }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    log.append("navigation", error.localizedDescription)
    finishLoad(error)
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    log.append("navigation", error.localizedDescription)
    finishLoad(error)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    let message = "WebKit content process terminated. Restart the noodlet to recover."
    log.append("crash", message)
    finishLoad(AppletError(message))
    failed?(message)
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    let local = url.isFileURL && url.standardizedFileURL.path.hasPrefix(package.url.path + "/")
    // Keep the privileged page on its package origin. Remote content belongs in a browser.
    decisionHandler(local || url.absoluteString == "about:blank" ? .allow : .cancel)
  }
  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
    replyHandler: @escaping (Any?, String?) -> Void
  ) {
    guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url,
      url.isFileURL, url.standardizedFileURL.path.hasPrefix(package.url.path + "/"),
      let body = message.body as? [String: Any], let operation = body["operation"] as? String
    else {
      replyHandler(nil, "The bridge is available only to the noodlet's main page.")
      return
    }
    Task { @MainActor in
      do {
        switch operation {
        case "dragWindow":
          guard window.isVisible, let event = dragEvent, event.window === window,
            ProcessInfo.processInfo.systemUptime - event.timestamp < 1 else {
            throw AppletError("Window dragging requires a current user mouse-down inside this noodlet.")
          }
          dragEvent = nil
          window.performDrag(with: event)
          replyHandler(true, nil)
        case "fetch":
          replyHandler(try await network.fetch(body, enabled: package.manifest.network), nil)
        case "cancelFetch":
          if let id = body["id"] as? String { network.cancel(id) }
          replyHandler(true, nil)
        case "log":
          log.append(body["level"] as? String ?? "console", body["text"] as? String ?? "")
          replyHandler(true, nil)
        case "read", "write":
          guard let path = body["path"] as? String else {
            throw AppletError("A relative data path is required.")
          }
          let file = try NoodletPackage.child(path, in: dataRoot)
          if operation == "read" {
            guard FileManager.default.fileExists(atPath: file.path) else {
              replyHandler(NSNull(), nil)
              return
            }
            guard
              try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 4
                * 1_048_576
            else { throw AppletError("Data file exceeds 4 MiB.") }
            replyHandler(try String(contentsOf: file, encoding: .utf8), nil)
          } else {
            guard let text = body["text"] as? String, text.utf8.count <= 4 * 1_048_576
            else { throw AppletError("Text must fit in 4 MiB.") }
            try FileManager.default.createDirectory(
              at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
            replyHandler(true, nil)
          }
        case "openFile":
          guard window.isVisible else {
            throw AppletError(
              "File dialogs require foreground mode. Use noodle.data in background mode."
            )
          }
          let panel = NSOpenPanel()
          panel.canChooseDirectories = false
          let result = await panel.beginSheetModal(for: window)
          guard result == .OK, let file = panel.url else {
            replyHandler(NSNull(), nil)
            return
          }
          let access = file.startAccessingSecurityScopedResource()
          defer { if access { file.stopAccessingSecurityScopedResource() } }
          guard
            try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= 4
              * 1_048_576
          else { throw AppletError("Text file exceeds 4 MiB.") }
          replyHandler(
            [
              "name": file.lastPathComponent,
              "text": try String(contentsOf: file, encoding: .utf8),
            ], nil)
        case "saveFile":
          guard window.isVisible else {
            throw AppletError("File dialogs require foreground mode.")
          }
          guard let text = body["text"] as? String, text.utf8.count <= 4 * 1_048_576
          else { throw AppletError("Text must fit in 4 MiB.") }
          let panel = NSSavePanel()
          panel.nameFieldStringValue =
            URL(fileURLWithPath: body["name"] as? String ?? "Untitled.txt")
            .lastPathComponent
          guard await panel.beginSheetModal(for: window) == .OK, let file = panel.url
          else {
            replyHandler(false, nil)
            return
          }
          let access = file.startAccessingSecurityScopedResource()
          defer { if access { file.stopAccessingSecurityScopedResource() } }
          try text.write(to: file, atomically: true, encoding: .utf8)
          replyHandler(true, nil)
        default: throw AppletError("Unknown bridge operation.")
        }
      } catch { replyHandler(nil, error.localizedDescription) }
    }
  }
  func evaluate(_ source: String) async throws -> String {
    // callAsyncJavaScript awaits promises and preserves thrown JS errors.
    let result: Any
    do {
      result = try await bounded { finish in
        web.callAsyncJavaScript(
          "const value = await (async () => { \(source)\n})(); return JSON.stringify(value === undefined ? null : value);",
          arguments: [:], in: nil, in: .page, completionHandler: finish)
      }
    } catch {
      let detail =
        (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
        ?? error.localizedDescription
      log.append("javascript", detail)
      throw AppletError(detail)
    }
    guard let text = result as? String else {
      throw AppletError("JavaScript returned a value that cannot be represented as JSON.")
    }
    return text
  }
  func perform(_ request: AppletRequest) async throws -> String {
    if request.operation == .eval { return try await evaluate(request.text ?? "") }
    let bytes = try JSONEncoder().encode(request)
    let json = String(decoding: bytes, as: UTF8.self)
    return try await evaluate("return await window.__noodletControl(\(json));")
  }
  func snapshot() async throws -> NSImage {
    let config = WKSnapshotConfiguration()
    config.rect = web.bounds
    config.afterScreenUpdates = false
    return try await bounded { finish in
      web.takeSnapshot(with: config) { image, error in
        if let image {
          finish(.success(image))
        } else {
          finish(.failure(error ?? AppletError("WebKit returned no screenshot.")))
        }
      }
    }
  }
  private func bounded<T>(
    _ begin: (@escaping @MainActor @Sendable (Result<T, Error>) -> Void) -> Void
  ) async throws -> T {
    guard !stopped else { throw AppletError("Noodlet stopped.") }
    let id = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      let result = WebOperationResult(continuation)
      cancellations[id] = { result.finish(.failure(AppletError("Noodlet stopped."))) }
      let timer = Task { [weak self] in
        try? await Task.sleep(for: .seconds(20))
        guard !Task.isCancelled else { return }
        self?.cancellations.removeValue(forKey: id)
        result.finish(
          .failure(
            AppletError(
              "Web operation timed out. Inspect logs, terminate, or restart the noodlet."
            )))
      }
      begin { [weak self] value in
        timer.cancel()
        self?.cancellations.removeValue(forKey: id)
        result.finish(value)
      }
    }
  }
}

@MainActor private final class WebOperationResult<T> {
  private var continuation: CheckedContinuation<T, Error>?
  init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
  func finish(_ result: Result<T, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
  }
}
