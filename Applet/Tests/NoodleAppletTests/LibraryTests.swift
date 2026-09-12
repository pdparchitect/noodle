import AppletCore
import XCTest

@testable import NoodleApplet

final class LibraryTests: XCTestCase {
    @MainActor func testOpenedPackagesPersistWithoutDuplicatesAndDisappearWhenDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AppletLibraryTest-" + UUID().uuidString)
        let suite = "AppletLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let package = try NoodletPackage.install(
            [
                "noodlet.json": Data(
                    #"{"version":1,"title":"Opened creation","runtime":"html","entry":"index.html"}"#
                        .utf8),
                "index.html": Data("<title>Test</title>".utf8),
            ], to: root.appendingPathComponent("External/Test.noodlet"))
        var library: AppletLibrary? = AppletLibrary(
            root: root.appendingPathComponent("Library"), defaults: defaults,
            installExamples: false, watchChanges: false)
        XCTAssertTrue(library!.entries.isEmpty)
        try library!.grant(package.url)
        try library!.grant(package.url)
        let alias = root.appendingPathComponent("Alias.noodlet")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: package.url)
        try library!.grant(alias)
        XCTAssertEqual(library!.entries.map(\.id), [package.key])
        XCTAssertEqual((defaults.array(forKey: "libraryBookmarks") as? [Data])?.count, 1)
        library!.remember(package)
        let linkID = try library!.linkID(for: package)
        library!.pin(package.key)
        library = nil
        library = AppletLibrary(
            root: root.appendingPathComponent("Library"), defaults: defaults,
            installExamples: false, watchChanges: false)
        XCTAssertEqual(library!.entries.map(\.id), [package.key])
        let moved = root.appendingPathComponent("External/Moved.noodlet")
        try FileManager.default.moveItem(at: package.url, to: moved)
        XCTAssertEqual(try library!.package(for: linkID).url.path, moved.resolvingSymlinksInPath().path)
        XCTAssertEqual(try library!.linkID(for: NoodletPackage(url: moved)), linkID)
        try FileManager.default.removeItem(at: moved)
        library!.scan()
        XCTAssertTrue(library!.entries.isEmpty)
        XCTAssertTrue(library!.recent.isEmpty)
        XCTAssertTrue(library!.pinned.isEmpty)
        XCTAssertEqual((defaults.array(forKey: "libraryBookmarks") as? [Data])?.count, 0)
        library = nil
    }

    @MainActor func testDamagedBookmarkDoesNotHideOtherOpenedPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AppletLibraryTest-" + UUID().uuidString)
        let suite = "AppletLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let package = try NoodletPackage.install(
            [
                "noodlet.json": Data(
                    #"{"version":1,"title":"Valid creation","runtime":"html","entry":"index.html"}"#
                        .utf8),
                "index.html": Data("<title>Test</title>".utf8),
            ], to: root.appendingPathComponent("External/Test.noodlet"))
        let bookmark = try package.url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set([Data("broken".utf8), bookmark], forKey: "libraryBookmarks")
        let library = AppletLibrary(
            root: root.appendingPathComponent("Library"), defaults: defaults,
            installExamples: false, watchChanges: false)
        XCTAssertEqual(library.entries.map(\.id), [package.key])
        XCTAssertEqual((defaults.array(forKey: "libraryBookmarks") as? [Data])?.count, 1)
    }
}
