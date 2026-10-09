import NoodletFormat
import Surface
import WebKit
import XCTest

@testable import NoodletRuntime

/// A store kept in memory that remembers what it was asked.
final class MemoryStore: NoodletStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String] = [:]
    private(set) var calls: [NoodletStoreCall] = []

    func perform(_ call: NoodletStoreCall) async throws -> NoodletValue {
        lock.withLock {
            calls.append(call)
            switch call.operation {
            case "read": return files[call.path ?? ""].map(NoodletValue.text) ?? .null
            case "write": files[call.path ?? ""] = call.data; return .bool(true)
            case "list":
                return .entries(files.filter { $0.key.hasPrefix(call.path ?? "") }.keys.sorted().map {
                    NoodletEntry(path: $0, size: Data(base64Encoded: files[$0] ?? "")?.count ?? 0, modified: "2026-10-01T00:00:00Z")
                })
            default: return .names(["key"])
            }
        }
    }
}

@MainActor private final class Window: NoodletPageHost {
    func perform(_ operation: String, body: [String: Any]) async throws -> Any {
        guard operation == "window" else { throw NoodletPage.unknownOperation }
        return "moved"
    }
}

@MainActor final class PageTests: XCTestCase {
    private func page(localNetwork: Bool = false, theme: NoodletManifest.Theme? = nil, features: [String] = [],
                      files: [String: String] = [:], log: @escaping (String, String) -> Void = { _, _ in },
                      shape: (inout NoodletManifest) -> Void = { _ in }) throws -> (NoodletPage, MemoryStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".noodlet")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        var manifest = NoodletManifest(title: "Page")
        manifest.theme = theme
        shape(&manifest)
        let page = NoodletPage(root: root, manifest: manifest, store: store, dataStore: .nonPersistent(),
                               frame: CGRect(x: 0, y: 0, width: 320, height: 240), features: features,
                               localNetwork: localNetwork, log: log)
        addTeardownBlock { await MainActor.run { page.stop() } }
        return (page, store, root)
    }

    nonisolated func testThePageStaysOnItsPackageAndLeavesFilesAndLinksToThePerson() {
        let decide = { (url: String, download: Bool, link: Bool, main: Bool) in
            NoodletNavigation.decide(URL(string: url)!, shouldPerformDownload: download, linkActivated: link, mainFrame: main)
        }

        // Its own files and a blank page load as before.
        XCTAssertEqual(decide("noodlet-package://noodlet/index.html", false, false, true), .allow)
        XCTAssertEqual(decide("about:blank", false, false, true), .allow)

        // <a download> saves a package file, a blob or a data URL where the person chooses.
        XCTAssertEqual(decide("noodlet-package://noodlet/notes.txt", true, true, true), .download)
        XCTAssertEqual(decide("blob:noodlet-package://noodlet/4a1c2e0b-0000-4000-8000-000000000000", true, true, true), .download)
        XCTAssertEqual(decide("data:text/plain;base64,aGk=", true, true, true), .download)
        // ... but never a file from elsewhere, nor a blob the page merely navigates to.
        XCTAssertEqual(decide("file:///tmp/Some.noodlet/notes.txt", true, true, true), .cancel)
        XCTAssertEqual(decide("blob:noodlet-package://noodlet/4a1c2e0b-0000-4000-8000-000000000000", false, true, true), .cancel)

        // A web link the person follows from the main page opens in their browser.
        XCTAssertEqual(decide("https://example.com/", false, true, true), .openExternally)
        XCTAssertEqual(decide("http://example.com/", false, true, true), .openExternally)
        // Scripted navigation, subframes and other schemes still go nowhere.
        XCTAssertEqual(decide("https://example.com/", false, false, true), .cancel)
        XCTAssertEqual(decide("https://example.com/", false, true, false), .cancel)
        XCTAssertEqual(decide("file:///etc/hosts", false, true, true), .cancel)
        XCTAssertEqual(decide("file:///tmp/Some.noodlet/index.html", false, false, true), .cancel)
        XCTAssertEqual(decide("mailto:someone@example.com", false, true, true), .cancel)
        // The package scheme reaches only the package, under its one host.
        XCTAssertEqual(decide("noodlet-package://other/index.html", false, false, true), .cancel)
    }

    nonisolated func testDownloadNamesStayPlainFileNames() {
        XCTAssertEqual(NoodletFiles.safeName("kitten.mp4"), "kitten.mp4")
        XCTAssertEqual(NoodletFiles.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(NoodletFiles.safeName("a:b.png"), "a-b.png")
        XCTAssertEqual(NoodletFiles.safeName(""), "download")
        XCTAssertEqual(NoodletFiles.safeName(".hidden"), "download")
    }

    nonisolated func testOnlyTheNoodletsOwnMainPageIsTrusted() {
        let inside = URL(string: "noodlet-package://noodlet/index.html")

        XCTAssertTrue(NoodletPage.isTrustedBridgeSource(isMainFrame: true, url: inside))

        // Subframes are never trusted, even from inside the package.
        XCTAssertFalse(NoodletPage.isTrustedBridgeSource(isMainFrame: false, url: inside))
        // A missing URL is not trusted.
        XCTAssertFalse(NoodletPage.isTrustedBridgeSource(isMainFrame: true, url: nil))
        // Remote origins, files and other hosts of the scheme are never trusted.
        for url in ["https://example.com/index.html", "file:///tmp/Some.noodlet/index.html", "noodlet-package://other/index.html",
                    "about:blank"] {
            XCTAssertFalse(NoodletPage.isTrustedBridgeSource(isMainFrame: true, url: URL(string: url)), url)
        }
    }

    func testDataAndSecretsGoToTheStoreAsThePageAsked() async throws {
        let (page, store, _) = try page()
        let wrote = await page.handleBridge(operation: "write", body: ["operation": "write", "path": "a.txt", "data": "aGk="])
        XCTAssertEqual(wrote.0 as? Bool, true)
        let read = await page.handleBridge(operation: "read", body: ["operation": "read", "path": "a.txt"])
        XCTAssertEqual(read.0 as? String, "aGk=")
        let listed = await page.handleBridge(operation: "list", body: ["operation": "list", "path": ""])
        XCTAssertEqual((listed.0 as? [[String: Any]])?.map { $0["path"] as? String }, ["a.txt"])
        let names = await page.handleBridge(operation: "secret", body: ["operation": "secret", "action": "names"])
        XCTAssertEqual(names.0 as? [String], ["key"])
        XCTAssertEqual(store.calls, [
            NoodletStoreCall(operation: "write", path: "a.txt", data: "aGk="),
            NoodletStoreCall(operation: "read", path: "a.txt"),
            NoodletStoreCall(operation: "list", path: ""),
            NoodletStoreCall(operation: "secret", action: "names"),
        ])
    }

    func testWhatThePageLeavesToItsAppGoesToTheHost() async throws {
        let (page, _, _) = try page()
        let alone = await page.handleBridge(operation: "window", body: ["action": "zoom"])
        XCTAssertNil(alone.0)
        XCTAssertEqual(alone.1, "Unknown bridge operation.")
        let host = Window()
        page.host = host
        let answered = await page.handleBridge(operation: "window", body: ["action": "zoom"])
        XCTAssertEqual(answered.0 as? String, "moved")
        let unknown = await page.handleBridge(operation: "openFile", body: [:])
        XCTAssertEqual(unknown.1, "Unknown bridge operation.")
    }

    func testFeaturesSayWhatThePageCanUse() throws {
        XCTAssertEqual(try page().0.features, ["storage", "data", "secrets", "network"])
        XCTAssertEqual(try page(localNetwork: true, features: ["files"]).0.features,
                       ["storage", "data", "secrets", "network", "local-network", "files"])
    }

    /// The page itself: the bridge script installs `noodle`, which lists its features and keeps data in the store.
    func testALoadedPageReachesItsStoreThroughTheBridge() async throws {
        let (page, store, _) = try page(features: ["files"], files: ["index.html": "<title>Page</title>"])
        try await page.load()
        let features = try await page.evaluate("return noodle.features")
        XCTAssertEqual(features, #"["storage","data","secrets","network","files"]"#)
        let score = try await page.evaluate("await noodle.storage.set('score', {best: 3}); return await noodle.storage.get('score')")
        XCTAssertEqual(score, #"{"best":3}"#)
        XCTAssertEqual(store.calls.map(\.operation), ["write", "read"])
        // Storage lists its own names; data files are bytes, and their listing leaves storage out.
        let keys = try await page.evaluate("return await noodle.storage.list()")
        XCTAssertEqual(keys, #"["score"]"#)
        let bytes = try await page.evaluate("""
            await noodle.data.write('img/a.bin', new Uint8Array([0, 255, 128]));
            const blob = await noodle.data.read('img/a.bin');
            return [...new Uint8Array(await blob.arrayBuffer())]
            """)
        XCTAssertEqual(bytes, "[0,255,128]")
        let files = try await page.evaluate("return (await noodle.data.list()).map(entry => entry.path)")
        XCTAssertEqual(files, #"["img/a.bin"]"#)
        let gone = try await page.evaluate("return [typeof noodle.files, await noodle.data.read('missing')]")
        XCTAssertEqual(gone, #"["undefined",null]"#)
    }

    /// A game engine's web export runs from the package as it would from a web server: its files
    /// load by relative URL, with modules, streamed WebAssembly, ranges and threads.
    func testAPackageLoadsAsAWebSiteThatMayUseThreads() async throws {
        let (page, _, root) = try page(files: [
            "index.html": "<title>Game</title>",
            "engine.js": "export const answer = 42;",
            // A classic worker as Emscripten writes it: strict, and naming SharedArrayBuffer.
            "worker.js": """
                "use strict";
                onmessage = ({data}) => postMessage([data.buffer instanceof SharedArrayBuffer, (function () { return this === undefined; })(),
                                                     Atomics.add(new Int32Array(data.buffer), 0, 1)]);
                """,
        ])
        // The smallest module: no imports or exports.
        try Data([0, 0x61, 0x73, 0x6D, 1, 0, 0, 0]).write(to: root.appendingPathComponent("game.wasm"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data((0..<10).map(UInt8.init)).write(to: root.appendingPathComponent("assets/game.pck"))
        try await page.load()

        let site = try await page.evaluate("""
            const engine = await import('./engine.js');
            const wasm = await WebAssembly.instantiateStreaming(fetch('game.wasm'));
            const part = await fetch('assets/game.pck', {headers: {Range: 'bytes=2-4'}});
            return [isSecureContext, engine.answer, wasm.instance instanceof WebAssembly.Instance,
                    part.status, [...new Uint8Array(await part.arrayBuffer())],
                    (await fetch('missing.bin')).status, (await fetch('../../../etc/hosts')).status]
            """)
        XCTAssertEqual(site, "[true,42,true,206,[2,3,4],404,404]")

        let threads = try await page.evaluate("""
            const memory = new WebAssembly.Memory({initial: 1, maximum: 1, shared: true});
            const worker = new Worker('worker.js');
            const answer = await new Promise((resolve, reject) => {
                worker.onmessage = event => resolve(event.data);
                worker.onerror = event => reject(new Error(event.message));
                worker.postMessage(memory);
            });
            return [crossOriginIsolated, typeof SharedArrayBuffer, ...answer, new Int32Array(memory.buffer)[0]]
            """)
        XCTAssertEqual(threads, #"[true,"function",true,true,0,1]"#)
    }

    #if os(macOS)
    /// WebKit downloads outside the page, where the package is out of reach, so a package file the
    /// page downloads goes to the save panel from the app, under the name its link gives.
    func testAPackageFileThePageDownloadsGoesToBeSaved() async throws {
        var logged: [String] = []
        let (page, _, _) = try page(files: [
            "index.html": #"<a id="save" download="Report.txt" href="notes.txt">Save</a>"#, "notes.txt": "notes",
        ], log: { logged.append("\($0): \($1)") })
        try await page.load()
        _ = try await page.evaluate("document.querySelector('#save').click()")
        let files = { logged.filter { $0.hasPrefix("files:") } }
        try await until { !files().isEmpty }
        // A test has no window, which the save panel needs.
        XCTAssertEqual(files(), ["files: Report.txt could not be saved: Downloads need the noodlet in the foreground."])
    }
    #endif

    // TODO(Applet 0.30.0): remove with NoodletPage.moveLocalStorageFromFiles. Milestone: Applet 0.29.0.
    /// What a noodlet kept in localStorage when its package loaded from `file://` is still there
    /// once it loads as its own site.
    func testWhatAPageKeptInLocalStorageMovesToThePackageSite() async throws {
        let id = UUID()
        addTeardownBlock { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        let (old, _, root) = try page(files: ["index.html": "<title>Old</title>"])
        let before = WKWebViewConfiguration()
        before.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        let web = WKWebView(frame: .zero, configuration: before)
        web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        try await until { !web.isLoading && web.url != nil }
        _ = try await web.callAsyncJavaScript("localStorage.setItem('best', '42'); localStorage.setItem('name', 'Ada')",
                                              contentWorld: .page)
        old.stop()

        try await NoodletPage.moveLocalStorageFromFiles(in: WKWebsiteDataStore(forIdentifier: id))

        let page = NoodletPage(root: root, manifest: NoodletManifest(title: "Page"), store: MemoryStore(),
                               dataStore: WKWebsiteDataStore(forIdentifier: id)) { _, _ in }
        defer { page.stop() }
        try await page.load()
        let kept = try await page.evaluate("return [localStorage.getItem('best'), localStorage.getItem('name')]")
        XCTAssertEqual(kept, #"["42","Ada"]"#)
    }

    /// Each script gets SharedArrayBuffer first, without losing its strictness or moving a line;
    /// a range asks for bytes the file has, or for none.
    nonisolated func testPackageScriptsAndRangesAreServedAsAsked() {
        let shim = NoodletPackageScheme.sharedArrayBuffer
        let served = { (script: String) in String(decoding: NoodletPackageScheme.withSharedArrayBuffer(Data(script.utf8)), as: UTF8.self) }
        XCTAssertEqual(served("let a;\nlet b;"), shim + "let a;\nlet b;")
        XCTAssertEqual(served("\"use strict\";var a;"), "\"use strict\";" + shim + "var a;")
        XCTAssertEqual(served("'use strict'\nvar a;"), "'use strict';" + shim + "\nvar a;")
        XCTAssertEqual(served("#!/usr/bin/env node\nrun();"), "#!/usr/bin/env node\n" + shim + "run();")
        XCTAssertEqual(served("\u{FEFF}\"use strict\";x()"), "\u{FEFF}\"use strict\";" + shim + "x()")

        let range = { NoodletPackageScheme.byteRange($0, size: 10) }
        XCTAssertEqual(range("bytes=2-4"), 2..<5)
        XCTAssertEqual(range("bytes=7-"), 7..<10)
        XCTAssertEqual(range("bytes=-3"), 7..<10)
        XCTAssertEqual(range("bytes=8-99"), 8..<10)
        XCTAssertEqual(range("bytes=0-1,4-5"), 0..<10)
        XCTAssertNil(range("bytes=10-"))
        XCTAssertNil(range("bytes=5-2"))
        XCTAssertNil(range("bytes=-0"))
        XCTAssertEqual(NoodletPackageScheme.mimeType("game.wasm"), "application/wasm")
        XCTAssertEqual(NoodletPackageScheme.mimeType("lib/engine.mjs"), "text/javascript")
        XCTAssertEqual(NoodletPackageScheme.mimeType("index.html"), "text/html")
        XCTAssertEqual(NoodletPackageScheme.mimeType("game.pck"), "application/octet-stream")
    }

    /// A noodlet made for one look keeps it whatever the device's appearance; without a theme it
    /// follows the device, as any page does.
    func testAThemeFixesTheLookThePageSees() async throws {
        for (theme, dark) in [(NoodletManifest.Theme.dark, true), (.light, false)] {
            let (page, _, _) = try page(theme: theme, files: ["index.html": "<title>t</title>"])
            try await page.load()
            let answer = try await page.evaluate("return matchMedia('(prefers-color-scheme: dark)').matches;")
            XCTAssertEqual(answer, dark ? "true" : "false", "\(theme)")
        }
    }

    /// What is typed on a phone's keyboard reaches the page as a keyboard's keys, in order: into
    /// the field it focused, and to its own key handlers.
    func testTypingOnTheDeviceReachesThePageInOrder() async throws {
        let (page, _, _) = try page(files: ["index.html": """
            <input id="name" autofocus><script>window.keys=[];document.addEventListener('keydown',e=>keys.push(e.key));</script>
            """])
        let host = NoodletDeviceHost(page)
        try await page.load()
        _ = try await page.evaluate("document.querySelector('#name').focus();")
        for input: SurfaceInput in [.text("Ada"), .key(.backspace), .text("y"), .key(.enter)] { host.type(input) }
        await host.typed()
        let typed = try await page.evaluate("return [document.querySelector('#name').value, keys.join(',')];")
        XCTAssertEqual(typed, #"["Ady","A,d,a,Backspace,y,Enter"]"#)
    }

    /// A noodlet that presents itself as an app fits its view: no page zoom, scrolling past its
    /// edges, text selection or long-press menu, which the page can still turn back on where it
    /// wants them. A page stays a page. Its background colour shows until the page paints its own.
    func testAnAppFitsItsViewAndAPageStaysAPage() async throws {
        let probe = """
            const root = getComputedStyle(document.documentElement);
            return [root.webkitUserSelect, root.overscrollBehaviorY, root.backgroundColor,
                    [...document.querySelectorAll('meta[name=viewport]')].map(m => m.content).pop() ?? null];
            """
        let html = ["index.html": "<!doctype html><title>t</title><body>game</body>"]
        let (plain, _, _) = try page(files: html)
        try await plain.load()
        let asPage = try await plain.evaluate(probe)
        XCTAssertEqual(asPage, #"["text","auto","rgba(0, 0, 0, 0)",null]"#)

        let (app, _, _) = try page(files: html) {
            $0.display = .fullscreen
            $0.layout = .adaptive
            $0.backgroundColor = "#1d1d1f"
        }
        try await app.load()
        let fitted = try await app.evaluate(probe)
        XCTAssertEqual(fitted, #"["none","none","rgb(29, 29, 31)","width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover"]"#)

        // Laid out for a desktop window, it keeps that window's width, scaled to fit the view.
        let (desktop, _, _) = try page(files: html) { $0.display = .standalone }
        try await desktop.load()
        let width = Int((NoodletWindowOptions()).size(width: nil, height: nil).width)
        let scaled = try await desktop.evaluate("return document.querySelector('meta[name=viewport]').content;")
        XCTAssertEqual(scaled, "\"width=\(width), user-scalable=no, viewport-fit=cover\"")
    }

    #if os(macOS)
    /// WebKit lets a page lock the pointer, as a game turning with the mouse does, only once its
    /// app agrees through this SPI; without it the pointer stays free beside the game's own.
    func testAPageMayLockThePointer() throws {
        let (page, _, _) = try page()
        let selector = NSSelectorFromString("_webViewDidRequestPointerLock:completionHandler:")
        guard let method = class_getInstanceMethod(NoodletPage.self, selector) else {
            return XCTFail("WebKit never asks the page's app, so it refuses every pointer lock.")
        }
        typealias Request = @convention(c) (AnyObject, Selector, WKWebView, @escaping @convention(block) (Bool) -> Void) -> Void
        var granted: Bool?
        unsafeBitCast(method_getImplementation(method), to: Request.self)(page, selector, page.web) { granted = $0 }
        XCTAssertEqual(granted, true)
    }
    #endif

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "Timed out", file: file, line: line)
    }

    /// Before its first frame a page is starting; once drawn it is not responding only while it
    /// leaves the app's question unanswered.
    nonisolated func testAPageIsStartingUntilItDrawsAndNotRespondingWhileItLeavesAQuestionUnanswered() {
        let start = ContinuousClock.now
        var state = NoodletResponsiveness()
        XCTAssertNil(state.notice(at: start))
        state.began = start
        XCTAssertNil(state.notice(at: start + .milliseconds(500)))
        XCTAssertEqual(state.notice(at: start + .seconds(1)), .starting)
        state.asked = start + .seconds(1)
        XCTAssertEqual(state.notice(at: start + .seconds(5)), .starting)
        state.drawn = true
        XCTAssertNil(state.notice(at: start + .milliseconds(2500)))
        XCTAssertEqual(state.notice(at: start + .seconds(3)), .notResponding)
        state.asked = nil
        XCTAssertNil(state.notice(at: start + .seconds(9)))
    }

    /// A page busy in its own script is seen as not responding, and as itself again once it is done.
    func testAPageBusyInItsScriptIsNotRespondingUntilItIsDone() async throws {
        let (page, _, _) = try page(files: ["index.html": """
            <script>addEventListener('load', () => setTimeout(() => {
              const end = Date.now() + 3000; while (Date.now() < end) {}
            }, 200))</script>
            """])
        page.responsiveness.unansweredFor = .milliseconds(500)
        page.beat = .milliseconds(100)
        try await page.load()
        try await until { page.activity.notice == .notResponding }
        try await until { page.activity.notice == nil }
    }

    #if os(macOS)
    /// A page shows what is behind it until it first draws. An opaque one then paints its own
    /// background, as on the web; a clear one never does. One loaded out of sight counts as drawn.
    func testAPageShowsWhatIsBehindItUntilItFirstDraws() async throws {
        let (opaque, _, _) = try page(files: ["index.html": "<p>Hello</p>"])
        XCTAssertEqual(opaque.web.value(forKey: "drawsBackground") as? Bool, false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = opaque.web
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await opaque.load()
        XCTAssertFalse(opaque.activity.drawn)
        // A test run gets no animation frames, so the report the page makes after its first two is sent here.
        _ = try await opaque.web.evaluateJavaScript("webkit.messageHandlers.noodleDrawn.postMessage(0); 0", in: nil, in: .defaultClient)
        try await until { opaque.activity.drawn }
        XCTAssertEqual(opaque.web.value(forKey: "drawsBackground") as? Bool, true)

        let (clear, _, _) = try page(files: ["index.html": "<p>Hello</p>"])
        clear.opaque = false
        try await clear.load()
        XCTAssertTrue(clear.activity.drawn)
        XCTAssertEqual(clear.web.value(forKey: "drawsBackground") as? Bool, false)
    }
    #endif


}
