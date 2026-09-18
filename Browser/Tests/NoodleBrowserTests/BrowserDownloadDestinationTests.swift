import BrowserCore
@testable import NoodleBrowser
import XCTest

/// Pins the download destination contract that WebKit's delegate callback
/// relies on. The callback itself takes a WKDownload, which has no public
/// initializer, so these exercise the same logic through its tracked key.
final class BrowserDownloadDestinationTests: XCTestCase {
    @MainActor private func makeLibrary() -> (BrowserLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (BrowserLibrary(root: root), root)
    }

    @MainActor func testUntrackedDownloadHasNoDestination() async throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = BrowserRuntime(library: library)
        let token = NSObject()
        XCTAssertNil(runtime.downloadDestination(for: ObjectIdentifier(token), suggestedFilename: "report.pdf"))
        XCTAssertNil(runtime.failure)
    }

    @MainActor func testTrackedDownloadLandsInTheProfileDownloadsFolder() async throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try library.create(name: "A")
        let runtime = BrowserRuntime(library: library)
        let token = NSObject()
        let key = ObjectIdentifier(token)
        runtime.track(key, browserID: profile.id)

        let url = try XCTUnwrap(runtime.downloadDestination(for: key, suggestedFilename: "report.pdf"))
        XCTAssertEqual(url.lastPathComponent, "report.pdf")
        XCTAssertTrue(url.path.contains("Downloads"), url.path)

        // The containing folder is created eagerly and kept owner-only.
        let folder = url.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        let mode = try folder.resourceValues(forKeys: [.fileSecurityKey])
        XCTAssertNotNil(mode.fileSecurity)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o700)

        // The download is persisted against the owning profile.
        let saved = try library.profile(profile.id)
        XCTAssertEqual(saved.downloads.count, 1)
        XCTAssertEqual(saved.downloads.first?.filename, "report.pdf")
        XCTAssertEqual(saved.downloads.first?.state, "downloading")
        XCTAssertNil(runtime.failure)
    }

    @MainActor func testRemovingADownloadDeletesItsRecordAndFile() async throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try library.create(name: "A"), other = try library.create(name: "B")
        let runtime = BrowserRuntime(library: library)
        var urls: [URL] = []
        for name in ["keep.pdf", "drop.pdf"] {
            let token = NSObject(), key = ObjectIdentifier(token)
            runtime.track(key, browserID: profile.id)
            let url = try XCTUnwrap(runtime.downloadDestination(for: key, suggestedFilename: name))
            try Data("fixture".utf8).write(to: url); urls.append(url)
        }
        let drop = try XCTUnwrap(library.profile(profile.id).downloads.last)
        XCTAssertThrowsError(try runtime.removeDownload(browserID: other.id, downloadID: drop.id))
        try runtime.removeDownload(browserID: profile.id, downloadID: drop.id)
        XCTAssertEqual(try library.profile(profile.id).downloads.map(\.filename), ["keep.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[1].deletingLastPathComponent().path))
        XCTAssertThrowsError(try runtime.removeDownload(browserID: profile.id, downloadID: drop.id))
    }

    @MainActor func testSuggestedFilenamesCannotEscapeTheDownloadsFolder() async throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try library.create(name: "A")
        let runtime = BrowserRuntime(library: library)

        let cases: [(suggested: String, expected: String)] = [
            ("../../etc/passwd", "passwd"),
            ("/absolute/secret.txt", "secret.txt"),
            ("..", "download"),
            ("", "download"),
            ("side\\ways:name", "side_ways_name")
        ]
        for (suggested, expected) in cases {
            let token = NSObject()
            let key = ObjectIdentifier(token)
            runtime.track(key, browserID: profile.id)
            let url = try XCTUnwrap(runtime.downloadDestination(for: key, suggestedFilename: suggested))
            XCTAssertEqual(url.lastPathComponent, expected, "suggested: \(suggested)")
            // Never escapes the profile's own download tree.
            let downloads = try library.directory(profile.id, category: "Downloads")
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(downloads.standardizedFileURL.path + "/"), url.path)
        }
    }

    @MainActor func testUnknownProfileReportsFailureAndNoDestination() async throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = BrowserRuntime(library: library)
        let token = NSObject()
        let key = ObjectIdentifier(token)
        runtime.track(key, browserID: UUID())

        XCTAssertNil(runtime.downloadDestination(for: key, suggestedFilename: "report.pdf"))
        XCTAssertNotNil(runtime.failure)
    }
}
