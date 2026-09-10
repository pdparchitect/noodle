import AppKit
import Foundation
import Security
import SwiftUI
import WebKit

struct DesktopConnection: Sendable {
  let url: URL
  let certificate: Data
  let password: String
  let customWeb: Bool

  init(url: URL, certificate: Data = Data(), password: String = "", customWeb: Bool = false) {
    self.url = url
    self.certificate = certificate
    self.password = password
    self.customWeb = customWeb
  }

  func permitsNavigation(to target: URL) -> Bool {
    func port(_ url: URL) -> Int? { url.port ?? (url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil) }
    return target.scheme == url.scheme && target.host == url.host && port(target) == port(url)
  }

  func authenticate(
    _ challenge: URLAuthenticationChallenge,
    completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let space = challenge.protectionSpace
    guard space.host == url.host, space.port == url.port, challenge.previousFailureCount == 0 else {
      completion(.cancelAuthenticationChallenge, nil)
      return
    }
    if customWeb {
      completion(.performDefaultHandling, nil)
      return
    }
    if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = space.serverTrust,
      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let leaf = chain.first, SecCertificateCopyData(leaf) as Data == certificate
    {
      completion(.useCredential, URLCredential(trust: trust))
    } else if space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
      completion(
        .useCredential, URLCredential(user: "agent", password: password, persistence: .forSession))
    } else {
      completion(.cancelAuthenticationChallenge, nil)
    }
  }
}

final class DesktopSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let connection: DesktopConnection
  init(_ connection: DesktopConnection) { self.connection = connection }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    connection.authenticate(challenge, completion: completionHandler)
  }
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    connection.authenticate(challenge, completion: completionHandler)
  }
}

struct ComputerDesktopView: View {
  @ObservedObject var browser: ComputerDesktopBrowser

  var body: some View {
    ZStack {
      DesktopWebView(browser: browser)
      if let failure = browser.failure {
        ContentUnavailableView {
          Label("Could Not Open Display", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
        } description: {
          Text(failure)
        } actions: {
          Button("Try Again") { browser.reload() }
        }
      } else if browser.loading {
        ProgressView("Opening desktop…")
      }
    }
  }
}

private struct DesktopWebView: NSViewRepresentable {
  let browser: ComputerDesktopBrowser
  func makeNSView(context: Context) -> WKWebView { browser.view }
  func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Owned by the computer session, not by the currently selected SwiftUI tab.
/// Starts loading when the guest connects and survives all selection changes.
@MainActor final class ComputerDesktopBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
  let connection: DesktopConnection
  let view: WKWebView
  @Published var loading = true
  @Published var failure: String?
  init(connection: DesktopConnection) {
    self.connection = connection
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    // The guest clipboard stays in the guest, not the host pasteboard.
    configuration.userContentController.addUserScript(WKUserScript(source: """
      Object.defineProperty(navigator, 'clipboard', {value: undefined});
      document.addEventListener('copy', e => e.preventDefault(), true);
      document.addEventListener('cut', e => e.preventDefault(), true);
      document.addEventListener('paste', e => e.preventDefault(), true);
      """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    // Background-only providers still need a renderable viewport for card snapshots.
    view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
    super.init()
    view.focusRingType = .none
    view.underPageBackgroundColor = .black
    view.navigationDelegate = self
    view.uiDelegate = self
    view.allowsBackForwardNavigationGestures = false
    view.load(URLRequest(url: connection.url))
  }
  func reload() {
    failure = nil
    loading = true
    view.load(URLRequest(url: connection.url))
  }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      loading = true
      failure = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loading = false
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      loading = false
      failure = error.localizedDescription
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      self.webView(webView, didFail: navigation, withError: error)
    }
    func webView(
      _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
      completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
      connection.authenticate(challenge, completion: completionHandler)
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = action.request.url, connection.permitsNavigation(to: url)
      else {
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }
    func webView(
      _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
      initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
      decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) { decisionHandler(.deny) }
    func webView(
      _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void
    ) {
      completionHandler(nil)
    }
}
