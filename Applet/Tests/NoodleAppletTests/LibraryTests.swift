import AppletBridge
import AppletCore
import Combine
import XCTest

@testable import NoodleApplet

/// A test library whose bots keep their work under `root/Bots`, and the Hub's under `root/Hub Bots`.
@MainActor func botLibrary(root: URL, defaults: UserDefaults, secrets: AppletSecrets = AppletSecrets(storage: MemorySecrets())) -> AppletLibrary {
    AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false,
                  botFolders: [BotFolder(url: root.appendingPathComponent("Bots"), isHub: false),
                               BotFolder(url: root.appendingPathComponent("Hub Bots"), isHub: true)],
                  secrets: secrets)
}

/// Writes a noodlet into a bot's workspace in a `botLibrary`, as the bot would, and returns its path.
func botNoodlet(_ files: [String: Data], named name: String, owner: String, root: URL, hub: Bool = false) throws -> String {
    try NoodletPackage.install(files, to: root.appendingPathComponent(
        "\(hub ? "Hub Bots" : "Bots")/\(owner)/workspace/\(name).\(AppletBuildIdentity.current.fileExtension)")).url.path
}

/// The files of a small HTML noodlet.
func htmlNoodlet(_ title: String) throws -> [String: Data] {
    ["noodlet.json": try JSONEncoder().encode(NoodletManifest(title: title)), "index.html": Data("<h1>\(title)</h1>".utf8)]
}

final class LibraryTests: XCTestCase {
    /// The watch walks bots' workspaces every two seconds. On the main thread that took a tenth of a
    /// second each time, and recordings, which capture there, froze for three frames every two seconds.
    @MainActor func testTheWatchLooksForNoodletsOffTheMainThread() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = botLibrary(root: root, defaults: defaults)
        _ = try botNoodlet(try htmlNoodlet("Late"), named: "Late", owner: "bot", root: root)
        let bots = root.appendingPathComponent("Bots")
        let found = await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            return AppletLibrary.discover(in: [], botFolders: [bots], thumbnails: root)
        }.value
        XCTAssertEqual(found.values.map(\.title), ["Late"])
        await library.refresh()
        XCTAssertTrue(library.entries.contains { $0.title == "Late" })
    }

    @MainActor func testNoodletsBotsKeepInTheirFoldersAreFoundWhereTheyAre() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let library = botLibrary(root: root, defaults: defaults)
        let own = try botNoodlet(htmlNoodlet("Counter"), named: "Counter", owner: "kai", root: root)
        let hubs = try botNoodlet(htmlNoodlet("Board"), named: "Board", owner: "ada", root: root, hub: true)
        library.scan()
        XCTAssertEqual(Set(library.entries.map(\.package.url.path)), [own, hubs])
        XCTAssertEqual(library.hub, [try NoodletPackage(url: URL(fileURLWithPath: hubs)).key])
        XCTAssertEqual(library.owner(of: URL(fileURLWithPath: own)), "kai")
        XCTAssertEqual(library.owner(of: URL(fileURLWithPath: hubs)), "ada")
        XCTAssertNil(library.owner(of: library.documents.appendingPathComponent("Mine.noodlet")))
    }

    /// Noodle Hub names each bot's owner in its agent.json; the bot's noodlets are listed under them.
    @MainActor func testHubNoodletsAreListedUnderTheirBotsOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppletLibraryTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let library = botLibrary(root: root, defaults: defaults)
        let (ada, kai) = (UUID(), UUID())
        func own(_ bot: String, by id: UUID, named name: String) throws {
            try Data(#"{"displayName":"Bot","owner":{"id":"\#(id.uuidString)","name":"\#(name)"}}"#.utf8)
                .write(to: root.appendingPathComponent("Hub Bots/\(bot)/agent.json"))
        }
        let board = try NoodletPackage(url: URL(fileURLWithPath: try botNoodlet(htmlNoodlet("Board"), named: "Board", owner: "alfred", root: root, hub: true)))
        let chess = try NoodletPackage(url: URL(fileURLWithPath: try botNoodlet(htmlNoodlet("Chess"), named: "Chess", owner: "jeeves", root: root, hub: true)))
        let loose = try NoodletPackage(url: URL(fileURLWithPath: try botNoodlet(htmlNoodlet("Loose"), named: "Loose", owner: "nobody", root: root, hub: true)))
        _ = try botNoodlet(htmlNoodlet("Counter"), named: "Counter", owner: "local", root: root)
        try own("alfred", by: ada, named: "Ada")
        try own("jeeves", by: kai, named: "Kai")
        library.scan()
        XCTAssertEqual(library.hubPeople, [HubPerson(id: ada, name: "Ada"), HubPerson(id: kai, name: "Kai")])
        XCTAssertEqual(library.hubOwners[board.key], HubPerson(id: ada, name: "Ada"))
        XCTAssertEqual(library.hubOwners[chess.key], HubPerson(id: kai, name: "Kai"))
        XCTAssertNil(library.hubOwners[loose.key], "A bot whose file names nobody has no owner.")

        try own("alfred", by: ada, named: "Ada Lovelace")
        library.scan()
        XCTAssertEqual(library.hubPeople.first, HubPerson(id: ada, name: "Ada Lovelace"))

        library.hide(chess.key)
        XCTAssertEqual(library.hubPeople.map(\.id), [ada], "Someone whose noodlets are all hidden is listed.")
    }

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
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Data/\(package.key)/User"), withIntermediateDirectories: true)
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
        for path in ["Data/\(gone)", "Thumbnails/\(gone).png"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
        }
        for path in ["Data/\(kept)", "Thumbnails/\(kept).png"] {
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
