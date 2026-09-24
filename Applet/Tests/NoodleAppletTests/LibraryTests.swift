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

    /// Moving a noodlet to the Trash also deletes what it saved, its secrets, permissions and thumbnail.
    /// Only categories holding a visible noodlet are listed, in the fixed category order.
    @MainActor func testCategoriesListOnlyThoseWithVisibleNoodlets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
        var packages: [NoodletPackage] = []
        for (name, category) in [("Chess", "games"), ("Notes", "writing"), ("Todo", "productivity"), ("Plain", nil)] {
            let field = category.map { #","category":"\#($0)""# } ?? ""
            packages.append(try NoodletPackage.install([
                "noodlet.json": Data(#"{"version":1,"title":"\#(name)","runtime":"html","entry":"index.html"\#(field)}"#.utf8),
                "index.html": Data("<title>Test</title>".utf8),
            ], to: library.documents.appendingPathComponent("\(name).noodlet")))
        }
        for package in packages { library.remember(package) }
        library.scan()
        XCTAssertEqual(library.categories, ["games", "productivity", "writing"])

        library.hide(packages[1].key)
        XCTAssertEqual(library.categories, ["games", "productivity"], "A category holding only hidden noodlets is listed.")

        for package in [packages[0], packages[2]] { library.hide(package.key) }
        XCTAssertEqual(library.categories, [])
    }

    @MainActor func testTrashingANoodletRemovesItAndEverythingItKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
        var packages: [NoodletPackage] = []
        for name in ["Kept", "Trashed"] {
            packages.append(try NoodletPackage.install([
                "noodlet.json": Data(#"{"version":1,"title":"\#(name)","runtime":"html","entry":"index.html"}"#.utf8),
                "index.html": Data("<title>Test</title>".utf8),
            ], to: library.documents.appendingPathComponent("\(name).noodlet")))
        }
        let secrets = AppletSecrets(storage: MemorySecrets())
        for package in packages {
            library.remember(package)
            library.pin(package.key)
            defaults.set(["network"], forKey: "permissions.\(package.key)")
            _ = try secrets.perform("set", name: "token", value: "x", account: "\(package.key).user")
            _ = try secrets.perform("set", name: "token", value: "x", account: "\(package.key).test")
            for path in ["Data/\(package.key)/User", "Homes/\(package.key)"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            let thumbnails = root.appendingPathComponent("Thumbnails")
            try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
            try Data([1]).write(to: thumbnails.appendingPathComponent("\(package.key).png"))
        }
        var trashed: [URL] = []
        try await library.trash(packages[1], secrets: secrets) {
            trashed.append($0)
            try FileManager.default.removeItem(at: $0)
        }

        let (kept, gone) = (packages[0].key, packages[1].key)
        XCTAssertEqual(trashed, [packages[1].url])
        XCTAssertEqual(library.entries.map(\.id), [kept])
        XCTAssertEqual(library.recent, [kept])
        XCTAssertEqual(library.pinned, [kept])
        XCTAssertEqual(Set(AppletPermissions.grants(defaults: defaults).keys), [kept])
        XCTAssertEqual(Set(secrets.names().keys), ["\(kept).user", "\(kept).test"])
        XCTAssertEqual(Set(AppletStorage.sizes(root: root).keys), [kept])
        for path in ["Homes/\(gone)", "Thumbnails/\(gone).png"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
        }
        for path in ["Homes/\(kept)", "Thumbnails/\(kept).png"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
        }
    }

    /// When the package cannot be moved to the Trash, nothing it kept is deleted.
    @MainActor func testAFailedTrashKeepsTheNoodletsData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
        let package = try NoodletPackage.install([
            "noodlet.json": Data(#"{"version":1,"title":"Stuck","runtime":"html","entry":"index.html"}"#.utf8),
            "index.html": Data("<title>Test</title>".utf8),
        ], to: library.documents.appendingPathComponent("Stuck.noodlet"))
        let secrets = AppletSecrets(storage: MemorySecrets())
        _ = try secrets.perform("set", name: "token", value: "x", account: "\(package.key).user")
        defaults.set(["network"], forKey: "permissions.\(package.key)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Data/\(package.key)/User"), withIntermediateDirectories: true)
        library.scan()

        do {
            try await library.trash(package, secrets: secrets) { _ in throw CocoaError(.fileWriteNoPermission) }
            XCTFail("The failed move was not reported.")
        } catch {}
        XCTAssertEqual(library.entries.map(\.id), [package.key])
        XCTAssertEqual(Array(secrets.names().keys), ["\(package.key).user"])
        XCTAssertEqual(Array(AppletPermissions.grants(defaults: defaults).keys), [package.key])
        XCTAssertEqual(Array(AppletStorage.sizes(root: root).keys), [package.key])
    }
}
