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
            case "write": files[call.path ?? ""] = call.text; return .bool(true)
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
    private func page(network: Bool = false, theme: NoodletManifest.Theme? = nil, features: [String] = [],
                      files: [String: String] = [:], shape: (inout NoodletManifest) -> Void = { _ in }) throws -> (NoodletPage, MemoryStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".noodlet")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        var manifest = NoodletManifest(title: "Page")
        manifest.network = network
        manifest.theme = theme
        shape(&manifest)
        let page = NoodletPage(root: root, manifest: manifest, store: store, dataStore: .nonPersistent(),
                               frame: CGRect(x: 0, y: 0, width: 320, height: 240), features: features) { _, _ in }
        addTeardownBlock { await MainActor.run { page.stop() } }
        return (page, store, root)
    }

    nonisolated func testOnlyTheNoodletsOwnMainPageIsTrusted() {
        let package = "/tmp/Some.noodlet"
        let inside = URL(fileURLWithPath: package + "/index.html")

        XCTAssertTrue(NoodletPage.isTrustedBridgeSource(isMainFrame: true, url: inside, packagePath: package))

        // Subframes are never trusted, even from inside the package.
        XCTAssertFalse(NoodletPage.isTrustedBridgeSource(isMainFrame: false, url: inside, packagePath: package))
        // A missing URL is not trusted.
        XCTAssertFalse(NoodletPage.isTrustedBridgeSource(isMainFrame: true, url: nil, packagePath: package))
        // Remote origins are never trusted.
        XCTAssertFalse(NoodletPage.isTrustedBridgeSource(
            isMainFrame: true, url: URL(string: "https://example.com/index.html"), packagePath: package))
        // The package directory itself is not "inside" it.
        XCTAssertFalse(NoodletPage.isTrustedBridgeSource(
            isMainFrame: true, url: URL(fileURLWithPath: package), packagePath: package))
        // A sibling directory sharing the prefix must not pass.
        XCTAssertFalse(NoodletPage.isTrustedBridgeSource(
            isMainFrame: true, url: URL(fileURLWithPath: package + "-evil/index.html"), packagePath: package))
        // Traversal out of the package is rejected after standardizing.
        XCTAssertFalse(NoodletPage.isTrustedBridgeSource(
            isMainFrame: true, url: URL(fileURLWithPath: package + "/../other/index.html"), packagePath: package))
    }

    func testDataAndSecretsGoToTheStoreAsThePageAsked() async throws {
        let (page, store, _) = try page()
        let wrote = await page.handleBridge(operation: "write", body: ["operation": "write", "path": "a.txt", "text": "hi"])
        XCTAssertEqual(wrote.0 as? Bool, true)
        let read = await page.handleBridge(operation: "read", body: ["operation": "read", "path": "a.txt"])
        XCTAssertEqual(read.0 as? String, "hi")
        let names = await page.handleBridge(operation: "secret", body: ["operation": "secret", "action": "names"])
        XCTAssertEqual(names.0 as? [String], ["key"])
        XCTAssertEqual(store.calls, [
            NoodletStoreCall(operation: "write", path: "a.txt", text: "hi"),
            NoodletStoreCall(operation: "read", path: "a.txt"),
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
        XCTAssertEqual(try page().0.features, ["storage", "data", "secrets"])
        XCTAssertEqual(try page(network: true, features: ["files"]).0.features, ["storage", "data", "secrets", "network", "files"])
    }

    /// The page itself: the bridge script installs `noodle`, which lists its features and keeps data in the store.
    func testALoadedPageReachesItsStoreThroughTheBridge() async throws {
        let (page, store, _) = try page(features: ["files"], files: ["index.html": "<title>Page</title>"])
        try await page.load()
        let features = try await page.evaluate("return noodle.features")
        XCTAssertEqual(features, #"["storage","data","secrets","files"]"#)
        let score = try await page.evaluate("await noodle.storage.set('score', {best: 3}); return await noodle.storage.get('score')")
        XCTAssertEqual(score, #"{"best":3}"#)
        XCTAssertEqual(store.calls.map(\.operation), ["write", "read"])
    }

    func testTheWebStaysClosedUnlessTheManifestOpensIt() async throws {
        let (page, _, _) = try page(files: ["index.html": "<title>Page</title>"])
        try await page.load()
        let answer = await page.handleBridge(operation: "fetch", body: ["id": "one", "url": "https://example.com"])
        XCTAssertEqual(answer.1, "Set network: true in noodlet.json to make web requests.")
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
}
