import Foundation
import NoodletFormat
import WebKit

/// What a noodlet's page may do with a navigation it starts. The privileged page stays on its
/// package; saving a file and following a web link are left to the person, who picks where the
/// file goes or sees the link open in their browser.
public enum NoodletNavigation: Equatable, Sendable {
    /// Load it in the page: the package's own files and about:blank.
    case allow
    /// Save it as a file the person chooses: `<a download>` to a package file, a blob or a data URL.
    case download
    /// Show it in the person's browser: a web link followed from the main page.
    case openExternally
    case cancel

    public static func decide(_ url: URL, shouldPerformDownload: Bool, linkActivated: Bool,
                              mainFrame: Bool) -> NoodletNavigation {
        let scheme = url.scheme?.lowercased() ?? ""
        let local = NoodletPackageScheme.contains(url)
        if shouldPerformDownload { return local || scheme == "blob" || scheme == "data" ? .download : .cancel }
        if local || url.absoluteString == "about:blank" { return .allow }
        if scheme == "http" || scheme == "https", linkActivated, mainFrame { return .openExternally }
        return .cancel
    }
}

/// Saves what a page downloads where the person chooses. WebKit writes each download to a private
/// staging file; once it finishes, the file goes to the place picked in the save panel (on iOS,
/// the document picker), so nothing reaches the person's folders without their say.
@MainActor final class NoodletDownloads: NSObject, WKDownloadDelegate {
    private struct Item {
        let download: WKDownload
        var staged: URL?
        var destination: URL?
    }

    private weak var web: WKWebView?
    private let log: (String, String) -> Void
    private var items: [ObjectIdentifier: Item] = [:]

    init(web: WKWebView, log: @escaping (String, String) -> Void) {
        self.web = web
        self.log = log
    }

    /// Remembers the name the last link clicked gives what it downloads, for `name(of:in:of:)`.
    static let linkNames = """
        addEventListener('click', event => {
          const link = event.target instanceof Element && event.target.closest('a[download]');
          if (link) window.noodleDownload = [link.href, link.download];
        }, true);
        """

    /// The name the page gives what `url` downloads: its link's, else the file's own.
    static func name(of url: URL, in frame: WKFrameInfo?, of web: WKWebView) async -> String {
        let link = try? await web.callAsyncJavaScript(
            "const link = window.noodleDownload; return link && link[0] === url ? link[1] : ''",
            arguments: ["url": url.absoluteString], in: frame, contentWorld: .defaultClient) as? String
        return link.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
    }

    /// Saves a file of the package where the person chooses. WebKit downloads outside the page,
    /// where the package is out of reach, so the app copies it.
    func save(_ relative: String, in root: URL, named name: String) {
        Task { @MainActor [weak self] in
            do {
                let staged = try NoodletFiles.stagingURL(named: name)
                defer { Self.discard(staged) }
                let source = try NoodletPath.open(relative, in: root)
                try (try source.readToEnd() ?? Data()).write(to: staged)
                #if os(macOS)
                guard let web = self?.web, let destination = try await NoodletFiles.chooseDestination(named: name, over: web)
                else { return }
                try NoodletFiles.export(staged, to: destination)
                #else
                guard let web = self?.web, try await NoodletFiles.export(staged, over: web) else { return }
                #endif
                self?.log("files", "Saved \(staged.lastPathComponent).")
            } catch {
                self?.log("files", "\(name) could not be saved: \(error.localizedDescription)")
            }
        }
    }

    func receive(_ download: WKDownload) {
        items[ObjectIdentifier(download)] = Item(download: download)
        download.delegate = self
    }

    /// Ends every download still running, with the noodlet.
    func cancelAll() {
        let running = items.values
        items.removeAll()
        for item in running {
            item.download.cancel { _ in }
            if let staged = item.staged { Self.discard(staged) }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let key = ObjectIdentifier(download)
        guard let web, items[key] != nil else { return nil }
        do {
            #if os(macOS)
            guard let destination = try await NoodletFiles.chooseDestination(named: suggestedFilename, over: web) else {
                items.removeValue(forKey: key)
                return nil
            }
            #else
            // The document picker asks where it goes once the file is complete.
            let destination: URL? = nil
            #endif
            guard items[key] != nil else { return nil }
            let staged = try NoodletFiles.stagingURL(named: suggestedFilename)
            items[key]?.staged = staged
            items[key]?.destination = destination
            return staged
        } catch {
            items.removeValue(forKey: key)
            log("files", error.localizedDescription)
            return nil
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = items.removeValue(forKey: ObjectIdentifier(download)), let staged = item.staged else { return }
        Task { @MainActor [weak self] in
            defer { Self.discard(staged) }
            do {
                #if os(macOS)
                guard let destination = item.destination else { return }
                try NoodletFiles.export(staged, to: destination)
                #else
                guard let web = self?.web, try await NoodletFiles.export(staged, over: web) else { return }
                #endif
                self?.log("files", "Saved \(staged.lastPathComponent).")
            } catch {
                self?.log("files", "The download could not be saved: \(error.localizedDescription)")
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let item = items.removeValue(forKey: ObjectIdentifier(download))
        if let staged = item?.staged { Self.discard(staged) }
        log("files", "The download failed: \(error.localizedDescription)")
    }

    private static func discard(_ staged: URL) {
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    }
}
