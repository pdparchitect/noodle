import Foundation
@testable import TerminalCore
import XCTest

/// What Noodle Terminal does the same on every system it runs on, whatever each system offers for it.
@MainActor final class PlatformTests: XCTestCase {
    /// A file sent to a conversation says what kind it is, as the Mac's own file types would.
    func testFilesAreSentWithTheirType() {
        let expected = [
            "photo.png": "image/png", "photo.JPG": "image/jpeg", "photo.jpeg": "image/jpeg", "anim.gif": "image/gif",
            "image.heic": "image/heic", "image.webp": "image/webp", "report.pdf": "application/pdf",
            "notes.txt": "text/plain", "data.json": "application/json", "page.html": "text/html",
            "sheet.csv": "text/csv", "archive.zip": "application/zip", "clip.mp4": "video/mp4",
            "voice.m4a": "audio/x-m4a", "song.mp3": "audio/mpeg", "unknown.qqq": "application/octet-stream",
            "no-extension": "application/octet-stream",
        ]
        for (name, type) in expected {
            XCTAssertEqual(HubChats.mediaType(of: URL(fileURLWithPath: "/tmp/\(name)")), type, name)
        }
    }

    /// Paired Hubs are kept where the system keeps an app's own data.
    func testHubsAreKeptWhereTheSystemKeepsAppData() {
        let path = TerminalHubs.standardDirectory.path
        #if os(macOS)
        XCTAssertTrue(path.hasSuffix("Library/Application Support/Noodle Terminal/Hubs"), path)
        #else
        let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        XCTAssertEqual(path, data.appendingPathComponent("noodle-terminal/Hubs").path)
        #endif
    }

    /// Where there is no Mac drawing, a bot's picture is its colours in a circle, clear around it, and paler
    /// while it is not running.
    func testABotsColoursAreDrawnInACircle() throws {
        let picture = AvatarDrawing.picture(colours: [0], dimmed: false, scale: 1)
        let png = AvatarDrawing.png(picture)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(png[16..<24].map { $0 }, [0, 0, 0, 48, 0, 0, 0, 48])
        let centre = picture.pixel(x: 24, y: 24), corner = picture.pixel(x: 1, y: 1)
        XCTAssertEqual(centre.alpha, 255)
        XCTAssertGreaterThan(centre.blue, centre.red, "the first colours are blues")
        XCTAssertEqual(corner.alpha, 0)
        let idle = AvatarDrawing.picture(colours: [0], dimmed: true, scale: 1)
        XCTAssertLessThan(idle.pixel(x: 24, y: 24).alpha, 128)
        // A group's bots sit on a disc of their own.
        let group = AvatarDrawing.picture(colours: [0, 2, 3], dimmed: false, scale: 1)
        XCTAssertLessThan(group.pixel(x: 24, y: 3).alpha, picture.pixel(x: 24, y: 3).alpha)
    }
}
