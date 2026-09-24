import AppletCore
import Combine
import XCTest

@testable import NoodleApplet

final class LibraryTests: XCTestCase {
    @MainActor func testIdleScansDoNotRedrawButManifestAndPreviewChangesDo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
        let package = try NoodletPackage.install([
            "noodlet.json": Data(#"{"version":1,"title":"Original","runtime":"html","entry":"index.html"}"#.utf8),
            "index.html": Data("<title>Test</title>".utf8),
        ], to: library.documents.appendingPathComponent("Test.noodlet"))
        library.scan()
        var updates = 0
        let subscription = library.$entries.dropFirst().sink { _ in updates += 1 }
        defer { subscription.cancel() }
        for _ in 0..<3 { library.scan() }
        XCTAssertEqual(updates, 0)
        try Data(#"{"version":1,"title":"Updated","runtime":"html","entry":"index.html"}"#.utf8)
            .write(to: package.url.appendingPathComponent("noodlet.json"), options: .atomic)
        library.scan()
        XCTAssertEqual(library.entries.first?.title, "Updated")
        XCTAssertEqual(updates, 1)
        let preview = package.url.appendingPathComponent("preview.png")
        try Data([1, 2, 3]).write(to: preview)
        library.scan()
        XCTAssertEqual(updates, 2)
        let thumbnails = root.appendingPathComponent("Thumbnails")
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try Data([4, 5]).write(to: thumbnails.appendingPathComponent("\(package.key).png"))
        library.scan()
        XCTAssertEqual(updates, 3)
        library.scan()
        XCTAssertEqual(updates, 3)
    }

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

    /// A hidden noodlet stays in the library but leaves the menu bar, and stays hidden after a relaunch.
    @MainActor func testHiddenNoodletsLeaveTheMenuUntilShownAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
        var packages: [NoodletPackage] = []
        for name in ["Kept", "Secret", "Pinned secret"] {
            packages.append(try NoodletPackage.install([
                "noodlet.json": Data(#"{"version":1,"title":"\#(name)","runtime":"html","entry":"index.html"}"#.utf8),
                "index.html": Data("<title>Test</title>".utf8),
            ], to: library.documents.appendingPathComponent("\(name).noodlet")))
        }
        for package in packages { library.remember(package) }
        library.pin(packages[2].key)
        library.hide(packages[1].key)
        library.hide(packages[2].key)

        for current in [library, AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)] {
            current.scan()
            XCTAssertEqual(current.entries.count, 3, "Hiding removed a noodlet from the library.")
            XCTAssertEqual(Set(current.hidden), [packages[1].key, packages[2].key])
            XCTAssertEqual(current.menuPinned.map(\.id), [])
            XCTAssertEqual(current.menuRecent.map(\.id), [packages[0].key])
        }
        library.hide(packages[2].key)
        XCTAssertEqual(library.menuPinned.map(\.id), [packages[2].key], "Showing it again lost its pin.")
        XCTAssertEqual(library.hidden, [packages[1].key])
    }
}
