import BrowserBridge
import BrowserCore
import XCTest
import AppKit

final class BrowserLibraryTests: XCTestCase {
    func testBrowserReferencesValidateFilesAndKeepBuildChannelsSeparate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var reference = BrowserReference(browser: .init(id: UUID(), name: "Work"), tabID: UUID(), url: "https://example.com/page", title: "Page", capturedAt: Date(timeIntervalSince1970: 1_789_000_000.123))
        let metadataEncoder = JSONEncoder(); metadataEncoder.dateEncodingStrategy = .iso8601
        let metadataDecoder = JSONDecoder(); metadataDecoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try metadataDecoder.decode(BrowserReference.self, from: metadataEncoder.encode(reference)), reference)
        let file = directory.appendingPathComponent("Page.noodlebrowser-dev")
        try JSONEncoder().encode(reference).write(to: file)
        XCTAssertEqual(try BrowserReference.read(file, build: .development), reference)
        XCTAssertThrowsError(try BrowserReference.read(file, build: .production))
        reference.url = "https://user:password@example.com"
        XCTAssertThrowsError(try reference.validate())
        reference.url = "javascript:alert(1)"
        XCTAssertThrowsError(try reference.validate())
        reference.url = "https://example.com"; reference.version = 2
        XCTAssertThrowsError(try BrowserReference.decode(JSONEncoder().encode(reference)))
        XCTAssertThrowsError(try BrowserReference.decode(Data(repeating: 0, count: BrowserReference.maximumBytes + 1)))
    }
    @MainActor func testPerBrowserBackgroundPersistenceAndReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root)
        XCTAssertEqual(library.nextBrowserName, "Browser")
        var a = try library.create(name: library.nextBrowserName, background: .init(preset: .ocean))
        XCTAssertEqual(library.nextBrowserName, "Browser 2")
        let b = try library.create(name: library.nextBrowserName, background: .init(preset: .forest))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<4 { for x in 0..<4 { bitmap.setColor(.blue, atX: x, y: y) } }
        let icon = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        a.iconImage = icon
        let file = try PreparedBackgroundFile.prepare(imageData: icon)
        try library.update(a, backgroundFile: file)
        let restored = BrowserLibrary(root: root)
        var saved = try restored.profile(a.id)
        let url = try XCTUnwrap(restored.backgroundURL(for: saved))
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: file.url))
        XCTAssertNotEqual(url, file.url)
        XCTAssertEqual(saved.id, a.id)
        XCTAssertEqual(saved.iconImage, icon)
        XCTAssertNotNil(saved.remote.icon.flatMap(NSImage.init(data:)))
        XCTAssertLessThanOrEqual(saved.remote.icon?.count ?? .max, 65_536)
        let remote = try JSONDecoder().decode(RemoteBrowser.self, from: JSONEncoder().encode(saved.remote))
        XCTAssertEqual(remote.icon, saved.remote.icon)
        XCTAssertNil(try JSONDecoder().decode(RemoteBrowser.self, from: JSONEncoder().encode(b.remote)).icon)
        XCTAssertNil(try restored.profile(b.id).iconImage)
        XCTAssertEqual(saved.background.mediaKind, .image)
        XCTAssertEqual(try restored.profile(b.id).background.preset, .forest)
        XCTAssertNil(restored.backgroundURL(for: b))
        // A failed archive write must retain the current background and remove
        // only the uncommitted replacement, as in Computer's appearance store.
        let archive = root.appendingPathComponent("browsers.json"), backup = root.appendingPathComponent("backup.json")
        try FileManager.default.moveItem(at: archive, to: backup)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
        XCTAssertThrowsError(try restored.update(saved, backgroundFile: file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count, 1)
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: backup, to: archive)
        saved.background = .init(preset: .dusk)
        try restored.update(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try BrowserLibrary(root: root).profile(a.id).background.preset, .dusk)
        XCTAssertEqual(try BrowserLibrary(root: root).profile(b.id).background.preset, .forest)
        saved.iconImage = nil
        try restored.update(saved)
        XCTAssertNil(try BrowserLibrary(root: root).profile(a.id).iconImage)
        XCTAssertEqual(restored.nextBrowserName, "Browser 3")
    }
    func testDevelopmentAndProductionDiscoveryNeverCrossesChannels() throws {
        let dev = URL(fileURLWithPath: "/test/Noodle Browser Dev.app"), normal = URL(fileURLWithPath: "/test/Noodle Browser.app")
        let identifiers = [dev: BrowserBuildIdentity.development.providerID, normal: BrowserBuildIdentity.production.providerID]
        XCTAssertNil(BrowserApplication.select(running: [normal], sibling: normal, registered: normal, build: .development, identify: { identifiers[$0] }))
        XCTAssertNil(BrowserApplication.select(running: [dev], sibling: dev, registered: dev, build: .production, identify: { identifiers[$0] }))
        XCTAssertEqual(BrowserApplication.select(running: [normal, dev], sibling: nil, registered: normal, build: .development, identify: { identifiers[$0] }), dev)
        XCTAssertThrowsError(try BrowserBuildIdentity.development.validateGroup("ABCDEFGHIJ." + BrowserBuildIdentity.production.groupSuffix, team: "ABCDEFGHIJ"))
        XCTAssertThrowsError(try BrowserBuildIdentity.production.validateGroup("ABCDEFGHIJ." + BrowserBuildIdentity.development.groupSuffix, team: "ABCDEFGHIJ"))
    }
    func testSiblingDiscoveryStartsFromTheAppThatContainsAnExtension() {
        let app = URL(fileURLWithPath: "/Builds/Noodle Dev.app")
        XCTAssertEqual(BrowserApplication.containingApplication(of: app).path, app.path)
        XCTAssertEqual(BrowserApplication.containingApplication(of: app.appendingPathComponent("Contents/Extensions/NoodleBrowserTools.appex")).path, app.path)
        XCTAssertEqual(BrowserApplication.containingApplication(of: app.appendingPathComponent("Contents/PlugIns/NoodleShare.appex")).path, app.path)
        let loose = URL(fileURLWithPath: "/tmp/Loose.appex")
        XCTAssertEqual(BrowserApplication.containingApplication(of: loose).path, loose.path, "an extension outside an app is left alone")
    }
    func testOnlyNoodleAndItsBrowserToolExtensionAreSocketClientsPerChannel() {
        XCTAssertEqual(BrowserBuildIdentity.production.clientIDs, ["com.pdparchitect.noodle", "com.pdparchitect.noodle.tools.browser"])
        XCTAssertEqual(BrowserBuildIdentity.development.clientIDs, ["com.pdparchitect.noodle.local", "com.pdparchitect.noodle.local.tools.browser"])
        // The extension resolves its own channel from its signed identifier, as Noodle does.
        XCTAssertEqual(BrowserBuildIdentity.identify("com.pdparchitect.noodle.tools.browser"), .production)
        XCTAssertEqual(BrowserBuildIdentity.identify("com.pdparchitect.noodle.local.tools.browser"), .development)
        for other in ["com.pdparchitect.noodle.tools.vision", "com.pdparchitect.noodle.tools.browser.evil", "com.pdparchitect.noodle.share", "com.pdparchitect.noodle.tools"] {
            XCTAssertNil(BrowserBuildIdentity.identify(other), other)
            XCTAssertFalse(BrowserBuildIdentity.allCases.contains { $0.clientIDs.contains(other) }, other)
        }
    }
    @MainActor func testHistoryPersistenceSearchPaginationAndIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), a = try library.create(name: "A"), b = try library.create(name: "B")
        // Existing profile archives need no migration or replacement of store IDs.
        let originalArchive = try Data(contentsOf: root.appendingPathComponent("browsers.json"))
        let first = try XCTUnwrap(library.recordVisit(a.id, url: "https://example.com/first", title: "Old title"))
        _ = try library.recordVisit(a.id, url: "https://example.com/second", title: "100%_complete")
        try library.updateHistoryTitle(a.id, visit: first, title: "Account")
        for url in ["about:blank", "data:text/html,Hello", "file:///private/secret", "https://user:secret@example.com"] {
            XCTAssertNil(try library.recordVisit(a.id, url: url, title: "Excluded"))
        }
        XCTAssertEqual(try library.history(a.id, query: "%_").total, 1)
        XCTAssertEqual(try library.history(a.id, query: "' OR 1=1 --").total, 0)
        XCTAssertEqual(try library.history(a.id, query: "ACCOUNT").entries.first?.id, first)
        let newest = try library.history(a.id, limit: 1)
        XCTAssertEqual(newest.total, 2); XCTAssertTrue(newest.entries[0].url.hasSuffix("second"))
        XCTAssertEqual(try library.history(a.id, limit: 1, offset: 1).entries[0].id, first)
        XCTAssertEqual(try library.history(a.id, offset: 100).entries.count, 0)
        XCTAssertEqual(try library.history(b.id).total, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("browsers.json")), originalArchive)
        let restored = BrowserLibrary(root: root)
        XCTAssertEqual(try restored.history(a.id).total, 2)
        XCTAssertEqual(try restored.profile(a.id).id, a.id)
        let bookmark = try restored.addBookmark(a.id, url: "https://example.com", title: "Keep")
        // One visit is removed without touching the rest, and only from its own browser.
        XCTAssertThrowsError(try restored.removeHistory(b.id, visit: first))
        try restored.removeHistory(a.id, visit: first)
        XCTAssertEqual(try restored.history(a.id).entries.map(\.url), ["https://example.com/second"])
        XCTAssertThrowsError(try restored.removeHistory(a.id, visit: first))
        try restored.clearHistory(a.id)
        XCTAssertEqual(try restored.history(a.id).total, 0)
        XCTAssertEqual(try restored.bookmarks(a.id).entries.first?.id, bookmark.id)
    }
    @MainActor func testBookmarkManagementPersistenceAndValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), a = try library.create(name: "A"), b = try library.create(name: "B")
        let bookmark = try library.addBookmark(a.id, url: "https://example.com", title: "Account")
        XCTAssertThrowsError(try library.updateBookmark(b.id, bookmark: bookmark.id, title: "Stolen"))
        XCTAssertThrowsError(try library.removeBookmark(b.id, bookmark: bookmark.id))
        let edited = try library.updateBookmark(a.id, bookmark: bookmark.id, url: "https://example.com/new", title: "New title")
        XCTAssertEqual(edited.createdAt, bookmark.createdAt); XCTAssertEqual(edited.id, bookmark.id)
        let restored = BrowserLibrary(root: root)
        XCTAssertEqual(try restored.bookmarks(a.id, query: "NEW").entries, [edited])
        XCTAssertEqual(try restored.bookmarks(b.id).total, 0)
        for url in ["javascript:alert(1)", "file:///tmp/file", "https://me:password@example.com"] {
            XCTAssertThrowsError(try restored.addBookmark(a.id, url: url))
        }
        XCTAssertThrowsError(try restored.updateBookmark(a.id, bookmark: bookmark.id, title: " \n"))
        XCTAssertThrowsError(try restored.bookmarks(a.id, limit: 201))
        XCTAssertThrowsError(try restored.history(a.id, offset: -1))
        try restored.removeBookmark(a.id, bookmark: bookmark.id)
        XCTAssertEqual(try restored.bookmarks(a.id).total, 0)
        XCTAssertThrowsError(try restored.removeBookmark(a.id, bookmark: bookmark.id))
    }
    @MainActor func testPersistenceAndInterruptedDownloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = BrowserLibrary(root: root)
        var profile = try first.create(name: "Work")
        XCTAssertTrue(profile.muted)
        profile.paused = true
        profile.tabs = [.init(title: "Account", url: "https://example.com/account", loading: true)]
        profile.selectedTabID = profile.tabs[0].id
        profile.downloads = [.init(filename: "pending.pdf"), .init(filename: "complete.pdf", state: "complete", byteCount: 42)]
        try first.update(profile)
        let second = BrowserLibrary(root: root)
        let restored = try second.profile(profile.id)
        XCTAssertEqual(restored.selectedTabID, profile.selectedTabID)
        XCTAssertFalse(restored.tabs[0].loading)
        XCTAssertEqual(restored.downloads[0].state, "interrupted")
        XCTAssertEqual(restored.downloads[1].byteCount, 42)
        XCTAssertTrue(restored.paused)
        let other = try second.create(name: "Personal")
        XCTAssertNotEqual(profile.id, other.id)
        XCTAssertNotEqual(try second.directory(profile.id, category: "Uploads"), try second.directory(other.id, category: "Uploads"))
    }
    @MainActor func testDescriptionsPersistReachTheCatalogueAndStayOutOfCards() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root)
        var work = try library.create(name: "Work", description: "  Company Google account.\n")
        XCTAssertEqual(work.description, "Company Google account.")
        let plain = try library.create(name: "Personal", description: " \n ")
        XCTAssertNil(plain.description)
        XCTAssertThrowsError(try library.create(name: "Long", description: String(repeating: "a", count: RemoteBrowser.maximumDescriptionLength + 1)))
        work.description = String(repeating: "b", count: RemoteBrowser.maximumDescriptionLength + 1)
        XCTAssertThrowsError(try library.update(work))
        work.description = "Staging admin console."
        try library.update(work)

        let restored = BrowserLibrary(root: root)
        XCTAssertEqual(try restored.profile(work.id).description, "Staging admin console.")
        let remote = try JSONDecoder().decode(RemoteBrowser.self, from: JSONEncoder().encode(restored.profile(work.id).remote))
        XCTAssertEqual(remote.description, "Staging admin console.")
        XCTAssertNil(try restored.profile(plain.id).remote.description)
        work.description = ""
        try restored.update(work)
        XCTAssertNil(try BrowserLibrary(root: root).profile(work.id).description)

        // Archives and catalogues written before descriptions existed still load.
        let legacy = Data(#"{"id":"\#(work.id.uuidString)","name":"Work","symbol":"globe","colour":0,"muted":true,"paused":false,"tabCount":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(RemoteBrowser.self, from: legacy).description)

        var reference = BrowserReference(browser: remote, tabID: UUID(), url: "https://example.com", title: "Page")
        XCTAssertNil(reference.browser.description)
        XCTAssertEqual(reference.browser.name, "Work")
        reference.browser.description = String(repeating: "c", count: RemoteBrowser.maximumDescriptionLength + 1)
        XCTAssertThrowsError(try reference.validate())
    }
    @MainActor func testCorruptLibraryCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("browsers.json"), data = Data("broken".utf8)
        try data.write(to: file)
        let library = BrowserLibrary(root: root)
        XCTAssertNotNil(library.failure)
        XCTAssertThrowsError(try library.create(name: "New"))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
    func testProtocolRejectsInvalidTargetsAndUnsafeNavigation() throws {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.com", "https://", "noodlebrowser://provider/start"] {
            XCTAssertThrowsError(try BrowserRequest.navigationURL(url))
        }
        XCTAssertEqual(try BrowserRequest.navigationURL("https://example.com/path").host, "example.com")
        var request = BrowserRequest(.click, browserID: UUID(), tabID: UUID())
        XCTAssertThrowsError(try request.validate())
        request.x = 10; request.y = 20; XCTAssertNoThrow(try request.validate())
        request.x = .infinity; XCTAssertThrowsError(try request.validate())
        request = .init(.download, browserID: UUID()); XCTAssertThrowsError(try request.validate())
        request.fileID = UUID(); XCTAssertNoThrow(try request.validate())
        request.version = 2; XCTAssertThrowsError(try request.validate())
    }
    @MainActor func testDownloadNamesCannotEscapeTheirDirectory() {
        for name in ["../../secret", "/tmp/file", "..", ".", "", "bad\0name", "one\\two", "x:y"] {
            let safe = BrowserLibrary.safeFilename(name)
            XCTAssertFalse(safe.contains("/")); XCTAssertFalse(safe.contains("\\"))
            XCTAssertFalse(safe.contains("\0")); XCTAssertNotEqual(safe, ".."); XCTAssertFalse(safe.isEmpty)
        }
    }
    func testPointerProtocolValidationAndRoundTrip() throws {
        for operation in [BrowserOperation.move, .click] {
            var request = BrowserRequest(operation, browserID: UUID(), tabID: UUID())
            request.target = "#menu"
            XCTAssertNoThrow(try request.validate())
            request.x = 4; XCTAssertThrowsError(try request.validate())
            request.target = nil; XCTAssertThrowsError(try request.validate())
            request.y = 8; XCTAssertNoThrow(try request.validate())
            request.frame = "child"; XCTAssertThrowsError(try request.validate())
            request.frame = nil
            let decoded = try JSONDecoder().decode(BrowserRequest.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(decoded.operation, operation); XCTAssertEqual(decoded.x, 4); XCTAssertEqual(decoded.y, 8)
        }
        var click = BrowserRequest(.click, browserID: UUID(), tabID: UUID()); click.target = "#menu"
        for count in [0, 3] { click.clickCount = count; XCTAssertThrowsError(try click.validate()) }
        click.clickCount = 2; XCTAssertNoThrow(try click.validate())
        XCTAssertEqual(try JSONDecoder().decode(BrowserRequest.self, from: JSONEncoder().encode(click)).clickCount, 2)
        click.operation = .move; XCTAssertThrowsError(try click.validate())
        let move = BrowserRequest(.move, browserID: UUID(), tabID: UUID()); XCTAssertThrowsError(try move.validate())
        for operation in [BrowserOperation.mouseReset] {
            XCTAssertNoThrow(try BrowserRequest(operation, browserID: UUID(), tabID: UUID()).validate())
            XCTAssertThrowsError(try BrowserRequest(operation, browserID: UUID()).validate())
        }
        var response = BrowserResponse(); response.pointer = .init(x: 42, y: 80, visible: true, pressed: true)
        XCTAssertEqual(try JSONDecoder().decode(BrowserResponse.self, from: JSONEncoder().encode(response)).pointer, response.pointer)
    }
}
