import NoodletFormat
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
    private func page(network: Bool = false, features: [String] = [], files: [String: String] = [:]) throws -> (NoodletPage, MemoryStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".noodlet")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore()
        var manifest = NoodletManifest(title: "Page")
        manifest.network = network
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
}
