import Foundation
import NoodletFormat
import UniformTypeIdentifiers
import WebKit

/// Serves a noodlet's package to its page as a web site of its own. A `file://` page could not
/// fetch its own files, load modules or share memory between threads, which the web exports of
/// game engines need. Only files inside the package are served, as `NoodletPath.open` allows.
@MainActor final class NoodletPackageScheme: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "noodlet-package"
    nonisolated static let host = "noodlet"
    /// Isolation lets the page share memory between threads. Remote images, scripts and frames
    /// still load: WebKit does not hold them to it on a scheme of the app's own.
    nonisolated static let isolation = ["Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Embedder-Policy": "require-corp"]
    /// WebKit isolates such a page but leaves out the SharedArrayBuffer constructor, which engines'
    /// scripts look for by name. Shared memory's own buffer has it.
    nonisolated static let sharedArrayBuffer = "if (typeof SharedArrayBuffer == 'undefined' && self.crossOriginIsolated)"
        + " self.SharedArrayBuffer = new WebAssembly.Memory({initial: 0, maximum: 0, shared: true}).buffer.constructor;"
    private nonisolated static let chunk = 1 << 20

    private let root: URL
    private var running: Set<ObjectIdentifier> = []
    /// Responses to the page's web requests, each waiting in a file to be read once.
    private var responses: [String: URL] = [:]

    init(root: URL) { self.root = root }

    /// Where the page finds `relative`, a path inside the package.
    static func url(_ relative: String) throws -> URL {
        try NoodletPath.validate(relative)
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + relative
        guard let url = components.url else { throw AppletError("Unsafe relative path: \(relative.prefix(100))") }
        return url
    }

    /// Whether `url` is one of the package's own.
    nonisolated static func contains(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }

    /// Where the page reads `file`, a response to one of its web requests, which is gone once read.
    func serve(_ file: URL) -> URL {
        let id = UUID().uuidString
        responses[id] = file
        return URL(string: "\(Self.scheme)://\(Self.host)/?response=\(id)")!
    }

    /// Discards the responses the page never read.
    func discardResponses() {
        for file in responses.values { try? FileManager.default.removeItem(at: file) }
        responses.removeAll()
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        running.insert(id)
        let request = task.request
        let root = root
        let response = request.url.flatMap(Self.response(in:)).flatMap { responses.removeValue(forKey: $0) }
        Task.detached { [weak self] in
            let reply = response.map { Self.reply(sending: $0, for: request) } ?? Self.reply(to: request, root: root)
            guard await self?.send(reply.response, to: task, id: id) == true else { return }
            if let body = reply.body, await self?.send(body, to: task, id: id) != true { return }
            var left = reply.length
            while left > 0, let file = reply.file {
                let data = (try? file.read(upToCount: min(left, Self.chunk))) ?? Data()
                guard !data.isEmpty, await self?.send(data, to: task, id: id) == true else { break }
                left -= data.count
            }
            await self?.finish(task, id: id)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    /// WebKit throws if a task hears anything after it was stopped.
    private func send(_ response: URLResponse, to task: any WKURLSchemeTask, id: ObjectIdentifier) -> Bool {
        guard running.contains(id) else { return false }
        task.didReceive(response)
        return true
    }

    private func send(_ data: Data, to task: any WKURLSchemeTask, id: ObjectIdentifier) -> Bool {
        guard running.contains(id) else { return false }
        task.didReceive(data)
        return true
    }

    private func finish(_ task: any WKURLSchemeTask, id: ObjectIdentifier) {
        guard running.remove(id) != nil else { return }
        task.didFinish()
    }

    private struct Reply {
        var response: HTTPURLResponse
        var body: Data?
        /// Or what follows it: `length` bytes of `file` from where it stands.
        var file: FileHandle?
        var length = 0
    }

    /// The response a URL from `serve` names.
    private nonisolated static func response(in url: URL) -> String? {
        guard contains(url), url.path == "/" || url.path.isEmpty else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "response" }?.value
    }

    /// A response kept in `file`, which goes once it is open: what is read from it stays readable.
    private nonisolated static func reply(sending file: URL, for request: URLRequest) -> Reply {
        let url = request.url!
        defer { try? FileManager.default.removeItem(at: file) }
        guard let handle = try? FileHandle(forReadingFrom: file), let size = try? handle.seekToEnd() else {
            return Reply(response: HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: isolation)!)
        }
        try? handle.seek(toOffset: 0)
        let headers = isolation.merging(["Content-Type": "application/octet-stream", "Content-Length": "\(size)"]) { $1 }
        return Reply(response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!,
                     file: handle, length: Int(size))
    }

    private nonisolated static func reply(to request: URLRequest, root: URL) -> Reply {
        let url = request.url ?? URL(string: "\(scheme)://\(host)/")!
        func status(_ code: Int, _ headers: [String: String] = [:]) -> Reply {
            Reply(response: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                            headerFields: headers.merging(isolation) { $1 })!)
        }
        let relative = String(url.path.dropFirst())
        guard contains(url), let file = try? NoodletPath.open(relative, in: root),
              let size = try? file.seekToEnd()
        else { return status(404) }
        let type = mimeType(relative)
        var headers = isolation.merging(["Content-Type": type, "Cache-Control": "no-cache", "Accept-Ranges": "bytes"]) { $1 }
        let head = request.httpMethod == "HEAD"
        if type == "text/javascript" {
            // Scripts are read whole, to give each the constructor before it runs.
            try? file.seek(toOffset: 0)
            let body = withSharedArrayBuffer((try? file.readToEnd()) ?? Data())
            headers["Content-Length"] = "\(body.count)"
            return Reply(response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!,
                         body: head ? nil : body)
        }
        var start: UInt64 = 0, length = size
        var code = 200
        if let header = request.value(forHTTPHeaderField: "Range") {
            guard let range = byteRange(header, size: size) else {
                return status(416, ["Content-Range": "bytes */\(size)"])
            }
            (start, length, code) = (range.lowerBound, range.upperBound - range.lowerBound, 206)
            headers["Content-Range"] = "bytes \(start)-\(start + length - 1)/\(size)"
        }
        headers["Content-Length"] = "\(length)"
        try? file.seek(toOffset: start)
        return Reply(response: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!,
                     file: head ? nil : file, length: head ? 0 : Int(length))
    }

    /// The single range a `Range` header asks for, as offsets into `size` bytes; nil when it
    /// asks for none of them. Several ranges get the whole file.
    nonisolated static func byteRange(_ header: String, size: UInt64) -> Range<UInt64>? {
        let spec = header.trimmingCharacters(in: .whitespaces)
        guard spec.lowercased().hasPrefix("bytes="), !spec.contains(",") else { return 0..<size }
        let bounds = spec.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2 else { return 0..<size }
        if bounds[0].isEmpty {
            guard let suffix = UInt64(bounds[1]), suffix > 0, size > 0 else { return nil }
            return size - min(suffix, size)..<size
        }
        guard let first = UInt64(bounds[0]), first < size else { return nil }
        let last = bounds[1].isEmpty ? size - 1 : UInt64(bounds[1]).map { min($0, size - 1) }
        guard let last, last >= first else { return nil }
        return first..<last + 1
    }

    /// The script with the constructor given first, keeping a `#!` line or `"use strict"`
    /// directive in front and every line where it was.
    nonisolated static func withSharedArrayBuffer(_ script: Data) -> Data {
        let bytes = [UInt8](script)
        var at = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        if bytes[at...].starts(with: Array("#!".utf8)) {
            guard let end = bytes[at...].firstIndex(of: UInt8(ascii: "\n")) else { return script }
            at = end + 1
        }
        var shim = Array(sharedArrayBuffer.utf8)
        for directive in ["\"use strict\"", "'use strict'"] where bytes[at...].starts(with: Array(directive.utf8)) {
            at += directive.utf8.count
            if bytes[at...].first == UInt8(ascii: ";") { at += 1 } else { shim.insert(UInt8(ascii: ";"), at: 0) }
        }
        return Data(bytes[..<at] + shim + bytes[at...])
    }

    nonisolated static func mimeType(_ path: String) -> String {
        let suffix = (path as NSString).pathExtension.lowercased()
        switch suffix {
        case "js", "mjs", "cjs": return "text/javascript"
        case "wasm": return "application/wasm"
        default: return UTType(filenameExtension: suffix)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

// TODO(Applet 0.30.0): remove with its call in AppletRuntime.launch and
// PageTests.testWhatAPageKeptInLocalStorageMovesToThePackageSite. Milestone: Applet 0.29.0.
extension NoodletPage {
    /// Copies what a page kept in localStorage at `file://`, where packages loaded before, to the
    /// package's own site in `dataStore`, leaving keys the site already has.
    public static func moveLocalStorageFromFiles(in dataStore: WKWebsiteDataStore) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NoodletStorage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blank = folder.appendingPathComponent("index.html")
        try Data("<title></title>".utf8).write(to: blank)

        let files = WKWebViewConfiguration()
        files.websiteDataStore = dataStore
        let entries = try await StorageVisit(files).run("return Object.entries(localStorage)") {
            $0.loadFileURL(blank, allowingReadAccessTo: folder)
        }
        guard let entries = entries as? [[String]], !entries.isEmpty else { return }

        let site = WKWebViewConfiguration()
        site.websiteDataStore = dataStore
        site.setURLSchemeHandler(NoodletPackageScheme(root: folder.resolvingSymlinksInPath()), forURLScheme: NoodletPackageScheme.scheme)
        let page = try NoodletPackageScheme.url("index.html")
        _ = try await StorageVisit(site).run(
            "for (const [key, value] of entries) if (localStorage.getItem(key) === null) localStorage.setItem(key, value)",
            arguments: ["entries": entries]) { $0.load(URLRequest(url: page)) }
    }
}

/// A page loaded out of sight to run one script in it.
@MainActor private final class StorageVisit: NSObject, WKNavigationDelegate {
    private let web: WKWebView
    private var loaded: CheckedContinuation<Void, Error>?

    init(_ configuration: WKWebViewConfiguration) {
        web = WKWebView(frame: .zero, configuration: configuration)
    }

    func run(_ script: String, arguments: [String: Any] = [:], loading: (WKWebView) -> Void) async throws -> Any? {
        web.navigationDelegate = self
        defer { web.navigationDelegate = nil }
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            loading(web)
        }
        return try await web.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    private func finish(_ error: Error?) {
        let continuation = loaded
        loaded = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
}
