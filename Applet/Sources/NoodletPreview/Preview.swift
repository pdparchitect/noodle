import AppKit
import AppletBridge
import AppletCore
import QuickLookUI
import WebKit

@main enum PreviewEntry { static func main() {} }

@MainActor @objc(NoodletPreviewController)
final class NoodletPreviewController: NSViewController, @preconcurrency QLPreviewingController, WKNavigationDelegate
{
  private var web: WKWebView?
  private var root: URL?
  private var completion: ((Error?) -> Void)?
  private var timeout: Task<Void, Never>?
  override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 560)) }

  func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
    finish(AppletError("Preview replaced."))
    web?.stopLoading()
    view.subviews.forEach { $0.removeFromSuperview() }
    completion = handler
    do {
      let package = try NoodletPackage(url: url)
      root = package.url
      preferredContentSize = (package.manifest.window ?? NoodletWindowOptions()).size()
      let configuration = WKWebViewConfiguration()
      configuration.websiteDataStore = .nonPersistent()
      configuration.userContentController.addUserScript(
        WKUserScript(
          source: """
            (()=>{const memory=new Map(),fail=async()=>{throw Error('Open in Noodle Applet to save data or choose files.')};
            Object.defineProperty(window,'noodle',{value:Object.freeze({version:1,preview:true,fetch:window.fetch.bind(window),
            storage:{get:async k=>memory.get(k)??null,set:async(k,v)=>{memory.set(k,v)}},
            data:{readText:async()=>null,writeText:fail},files:{openText:fail,saveText:fail}})});})();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
      let web = WKWebView(frame: view.bounds, configuration: configuration)
      web.autoresizingMask = [.width, .height]
      web.navigationDelegate = self
      self.web = web
      view.addSubview(web)
      timeout = Task { [weak self] in
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled else { return }
        self?.finish(AppletError("The noodlet preview did not finish loading."))
      }
      Task { [weak self, weak web] in
        do {
          if !package.manifest.network {
            let rules =
              "[{\"trigger\":{\"url-filter\":\"^https?://\"},\"action\":{\"type\":\"block\"}},{\"trigger\":{\"url-filter\":\"^wss?://\"},\"action\":{\"type\":\"block\"}}]"
            let list = try await WKContentRuleListStore.default().compileContentRuleList(
              forIdentifier: "noodlet-preview-local-v1", encodedContentRuleList: rules)
            if let list { web?.configuration.userContentController.add(list) }
          }
          web?.loadFileURL(
            try NoodletPath.child(package.manifest.entry, in: package.url),
            allowingReadAccessTo: package.url)
        } catch { self?.finish(error) }
      }
    } catch { finish(error) }
  }
  private func finish(_ error: Error? = nil) {
    timeout?.cancel()
    timeout = nil
    let callback = completion
    completion = nil
    callback?(error)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finish(error)
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { finish(error) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finish(AppletError("The preview renderer stopped."))
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    let url = navigationAction.request.url
    let local =
      url?.isFileURL == true
      && url!.resolvingSymlinksInPath().path.hasPrefix((root?.path ?? "") + "/")
    decisionHandler(local || url?.absoluteString == "about:blank" ? .allow : .cancel)
  }
}
