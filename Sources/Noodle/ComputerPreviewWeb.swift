import AppKit
import ComputerBridge
import WebKit

/// A disposable, guest-origin-only browser. It never receives a host profile or
/// persistent credentials. Authorization is rechecked while the preview is open.
@MainActor final class ComputerPreviewWeb: NSObject, WKNavigationDelegate, WKUIDelegate {
    let surface = NSView()
    private let status = NSTextField(wrappingLabelWithString: "Opening display…")
    private lazy var retry = NSButton(title: "Try Again", target: self, action: #selector(retryConnection))
    private let card: ComputerCard
    private let controller: ComputerController
    private lazy var download = ComputerPreviewDownload { [controller] in try await controller.openDownload() }
    private var connection: ComputerWebConnection?
    private var view: WKWebView?
    private var task: Task<Void, Never>?
    private var active = false

    init(card: ComputerCard, controller: ComputerController) {
        self.card = card; self.controller = controller
        super.init()
        surface.wantsLayer = true; surface.layer?.backgroundColor = NSColor.black.cgColor
        status.textColor = .secondaryLabelColor
        surface.addSubview(status); status.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(retry); retry.translatesAutoresizingMaskIntoConstraints = false; retry.isHidden = true
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: surface.widthAnchor, constant: -48),
            retry.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            retry.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12)
        ])
        download.install(in: surface)
    }
    func start() {
        active = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, active else { return }
                do {
                    let response = try await controller.previewCall(.init(.display, computerID: card.computer.id,
                        agentID: card.agentID, terminalID: card.terminalID), card: card)
                    guard active, !Task.isCancelled, let current = response.display else { return }
                    if let connection {
                        guard connection.url == current.url, connection.password == current.password,
                              connection.certificate == current.certificate else {
                            throw ComputerBridgeError("The computer restarted. Reopen its preview to reconnect.")
                        }
                    } else { try await install(current) }
                } catch {
                    guard active else { return }
                    view?.stopLoading(); view?.removeFromSuperview(); view = nil; connection = nil
                    status.isHidden = false; status.stringValue = error.localizedDescription
                    retry.isHidden = false
                    download.showIfNeeded(controller.permits(card) && !controller.installed)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    private func install(_ connection: ComputerWebConnection) async throws {
        self.connection = connection
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        guard let host = connection.url.host, ["http", "https"].contains(connection.url.scheme) else {
            throw ComputerBridgeError("Invalid guest display origin.")
        }
        let schemes = connection.url.scheme == "https" ? ["https", "wss"] : ["http", "ws"]
        let ports = connection.url.port.map { [":\($0)"] } ?? ["", connection.url.scheme == "https" ? ":443" : ":80"]
        let origins = schemes.flatMap { scheme in ports.map { port in
            "^" + scheme + "://" + NSRegularExpression.escapedPattern(for: host) + port + "/"
        } } + ["^data:", "^blob:"]
        // WebKit's rule syntax deliberately excludes regex alternation.
        let rules: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]] + origins.map {
            ["trigger": ["url-filter": $0], "action": ["type": "ignore-previous-rules"]]
        }
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "Computer-" + card.computer.id.uuidString,
                                                                                     encodedContentRuleList: encoded)
        guard active, !Task.isCancelled else { return }
        if let list { configuration.userContentController.add(list) }
        configuration.userContentController.addUserScript(WKUserScript(source: """
            Object.defineProperty(navigator, 'clipboard', {value: undefined});
            document.addEventListener('copy', e => e.preventDefault(), true);
            document.addEventListener('cut', e => e.preventDefault(), true);
            document.addEventListener('paste', e => e.preventDefault(), true);
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.underPageBackgroundColor = .black; view.focusRingType = .none
        view.setAccessibilityLabel("Live display for \(card.computer.name)")
        surface.addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: surface.leadingAnchor), view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            view.topAnchor.constraint(equalTo: surface.topAnchor), view.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        self.view = view; status.isHidden = true; retry.isHidden = true
        view.load(URLRequest(url: connection.url))
        surface.window?.makeFirstResponder(view)
    }
    func stop() {
        active = false; task?.cancel(); task = nil
        download.stop()
        view?.stopLoading(); view?.removeFromSuperview(); view = nil; connection = nil
    }
    @objc private func retryConnection() {
        stop(); status.stringValue = "Opening display…"; status.isHidden = false; retry.isHidden = true
        download.showIfNeeded(false)
        start()
    }
    func integrationTestState() async -> String? {
        try? await view?.evaluateJavaScript("document.body.dataset.done === '1' ? document.querySelector('input').value : ''") as? String
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard active, controller.permits(card), let connection else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        connection.authenticate(challenge, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard active, controller.permits(card), let url = action.request.url,
              connection?.permitsNavigation(to: url) == true, !action.shouldPerformDownload else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        status.stringValue = error.localizedDescription; status.isHidden = false
        retry.isHidden = false
        webView.isHidden = true
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    deinit { task?.cancel() }
}
